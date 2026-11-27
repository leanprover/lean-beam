/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include <lean/lean.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static lean_obj_res process_error(const char *operation, uint32_t error) {
  return lean_io_result_mk_error(lean_mk_io_error_other_error(error, lean_mk_string(operation)));
}

static lean_external_class *endpoint_class, *process_class;
static void no_children(void *data, b_lean_obj_arg visit) { (void)data; (void)visit; }
static void finalize_process(void *data);
static void finalize_endpoint(void *data);
static void register_classes(void) {
  endpoint_class = lean_register_external_class(finalize_endpoint, no_children);
  process_class = lean_register_external_class(finalize_process, no_children);
}

#if !defined(_WIN32)
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <crt_externs.h>
#define CHILD_ENV (*_NSGetEnviron())
#else
extern char **environ;
#define CHILD_ENV environ
#endif

typedef int pipe_end;
#define INVALID_END (-1)
#define BAD_ARGUMENT EINVAL
#define NO_MEMORY ENOMEM
typedef struct owned_process {
  struct owned_process *next;
  pid_t pid;
  uint32_t code;
  int collected, lost, signaled, forced_while_running;
} owned_process;

static void ensure_classes(void) {
  static pthread_once_t once = PTHREAD_ONCE_INIT;
  pthread_once(&once, register_classes);
}
static void close_end(pipe_end fd) { if (fd >= 0) close(fd); }

#if defined(__APPLE__)
#include <stdlib.h>
#include <sys/proc.h>
#include <sys/sysctl.h>

/* Darwin's kill(-pgid, ...) can return EPERM while its last members are still exiting.
   The kernel exports committed P_LEXIT as P_WEXIT before their state becomes SZOMB.
   Confirm the entire retained group is exiting; leader exit alone says nothing about children.
   A failed or truncated snapshot must preserve the original signalling error. No retries. */
static int inactive_group(pid_t pid) {
  int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pid};
  size_t capacity = 0;
  if (sysctl(query, 4, NULL, &capacity, NULL, 0) != 0) return 0;
  if (!capacity) return 1;
  struct kinfo_proc *members = malloc(capacity);
  if (!members) return 0;
  size_t size = capacity;
  int inactive = sysctl(query, 4, members, &size, NULL, 0) == 0 &&
    size <= capacity && size % sizeof(*members) == 0;
  if (inactive) {
    for (size_t i = 0; i < size / sizeof(*members); i++) {
      if (members[i].kp_proc.p_stat != SZOMB && !(members[i].kp_proc.p_flag & P_WEXIT)) {
        inactive = 0;
        break;
      }
    }
  }
  free(members);
  return inactive;
}
#endif

/* Darwin has no pipe2. Opening both ends of a private FIFO with O_CLOEXEC avoids a
   descriptor inheritance window during concurrent launches by Lean or other libraries. */
static int make_pipe(int ends[2]) {
#ifdef __APPLE__
  const char *base = getenv("TMPDIR");
  if (!base || !*base) base = "/tmp";
  char dir[PATH_MAX], path[PATH_MAX];
  int len = snprintf(dir, sizeof(dir), "%s/beam-pipe.XXXXXX", base);
  if (len < 0 || (size_t)len + sizeof("/p") > sizeof(path)) return ENAMETOOLONG;
  if (!mkdtemp(dir)) return errno;
  memcpy(path, dir, len);
  memcpy(path + len, "/p", sizeof("/p"));
  int err = 0, flags;
  if (mkfifo(path, 0600) < 0 ||
      (ends[0] = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0 ||
      (ends[1] = open(path, O_WRONLY | O_CLOEXEC)) < 0 ||
      (flags = fcntl(ends[0], F_GETFL)) < 0 ||
      fcntl(ends[0], F_SETFL, flags & ~O_NONBLOCK) < 0) err = errno;
  if (unlink(path) < 0 && !err) err = errno;
  if (rmdir(dir) < 0 && !err) err = errno;
  if (err) return err;
#else
  if (pipe2(ends, O_CLOEXEC) < 0) return errno;
#endif
  /* dup2 actions must never overwrite a source when the parent lacks a standard fd. */
  for (int i = 0; i < 2; i++) {
    if (ends[i] <= STDERR_FILENO) {
      int high = fcntl(ends[i], F_DUPFD_CLOEXEC, 3);
      if (high < 0) return errno;
      close(ends[i]);
      ends[i] = high;
    }
  }
  return 0;
}

static int ensure_reaper(void);

static int start_process(owned_process *p, char **argv, const char *cwd, pipe_end parent[3]) {
  /* Direct wait is the identity fence. Refuse a parent disposition that discards zombies. */
  struct sigaction sigchld;
  if (sigaction(SIGCHLD, NULL, &sigchld) < 0) return errno;
  if (sigchld.sa_handler == SIG_IGN || (sigchld.sa_flags & SA_NOCLDWAIT)) return ECHILD;
  typedef int (*addchdir_fn)(posix_spawn_file_actions_t *, const char *);
  addchdir_fn addchdir = NULL;
  if (cwd) {
    addchdir = (addchdir_fn)dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir");
    if (!addchdir) addchdir = (addchdir_fn)dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
    if (!addchdir) return ENOTSUP;
  }
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  int err = posix_spawn_file_actions_init(&actions);
  if (err) return err;
  err = posix_spawnattr_init(&attr);
  if (err) { posix_spawn_file_actions_destroy(&actions); return err; }
  int pipes[3][2] = {{-1,-1}, {-1,-1}, {-1,-1}};
  sigset_t defaults, mask;
  sigfillset(&defaults);
  sigdelset(&defaults, SIGKILL);
  sigdelset(&defaults, SIGSTOP);
  sigemptyset(&mask);
  short flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
#ifdef __APPLE__
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  err = posix_spawnattr_setflags(&attr, flags);
  if (!err) err = posix_spawnattr_setsigdefault(&attr, &defaults);
  if (!err) err = posix_spawnattr_setsigmask(&attr, &mask);
  if (!err && cwd) err = addchdir(&actions, cwd);
  for (int i = 0; !err && i < 3; i++) {
    err = make_pipe(pipes[i]);
    if (!err) err = posix_spawn_file_actions_adddup2(&actions, pipes[i][i != 0], i);
  }
  if (!err) err = ensure_reaper();
  if (!err) err = posix_spawn(&p->pid, argv[0], &actions, &attr, argv, CHILD_ENV);
  for (int i = 0; i < 3; i++) {
    close_end(pipes[i][i != 0]);
    if (err) close_end(pipes[i][i == 0]);
    else parent[i] = pipes[i][i == 0];
  }
  posix_spawnattr_destroy(&attr);
  posix_spawn_file_actions_destroy(&actions);
  return err;
}

static int peek_process(owned_process *p, int *exited) {
  if (p->lost) return ECHILD;
  if (p->collected) { *exited = 1; return 0; }
  siginfo_t info = {0};
  int rc;
  do rc = waitid(P_PID, p->pid, &info, WEXITED | WNOHANG | WNOWAIT); while (rc < 0 && errno == EINTR);
  if (rc < 0) {
    if (errno == ECHILD) p->lost = 1;
    return errno;
  }
  /* Darwin can return CLD_STOPPED even for WEXITED alone. Only a terminal event
     for this child permits reporting an exit and starting survivor teardown. */
  *exited = info.si_pid == p->pid &&
    (info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED);
  if (*exited) {
    p->signaled = info.si_code != CLD_EXITED;
    p->code = info.si_status;
  }
  return 0;
}

static int terminate_process(owned_process *p) {
  if (p->collected) return 0;
  int exited;
  int err = peek_process(p, &exited);
  if (err) return err;
  if (kill(-p->pid, SIGKILL) == 0) {
    p->forced_while_running = !exited;
    return 0;
  }
  if (errno == ESRCH) return 0;
  err = errno;
#ifdef __APPLE__
  if (err == EPERM && inactive_group(p->pid)) return 0;
#endif
  return err;
}

static int collect_process(owned_process *p, int block) {
  if (p->collected) return 0;
  if (p->lost) return ECHILD;
  for (;;) {
    int status;
    pid_t result = waitpid(p->pid, &status, block ? 0 : WNOHANG);
    if (result < 0) {
      if (errno == EINTR) continue;
      if (errno == ECHILD) p->lost = 1;
      return errno;
    }
    if (result == 0) return 0;
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
      p->signaled = WIFSIGNALED(status);
      p->code = p->signaled ? WTERMSIG(status) : WEXITSTATUS(status);
      p->collected = 1;
      return 0;
    }
    if (!block) return 0;
  }
}

/* Only the last reference transfers a record. Queue ownership excludes every Lean caller.
   The worker waits only on Beam children and keeps their IDs pinned through group teardown. */
static pthread_mutex_t reaper_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t reaper_wakeup = PTHREAD_COND_INITIALIZER;
static owned_process *incoming;
static int reaper_started;

static void *reap_abandoned(void *unused) {
  (void)unused;
  owned_process *pending = NULL;
  for (;;) {
    pthread_mutex_lock(&reaper_lock);
    while (!incoming && !pending) pthread_cond_wait(&reaper_wakeup, &reaper_lock);
    if (!incoming) {
      struct timespec next;
      clock_gettime(CLOCK_REALTIME, &next);
      next.tv_nsec += 50000000;
      if (next.tv_nsec >= 1000000000) { next.tv_sec++; next.tv_nsec -= 1000000000; }
      pthread_cond_timedwait(&reaper_wakeup, &reaper_lock, &next);
    }
    owned_process *batch = incoming;
    incoming = NULL;
    pthread_mutex_unlock(&reaper_lock);
    while (batch) {
      owned_process *p = batch;
      batch = p->next;
      terminate_process(p);
      p->next = pending;
      pending = p;
    }
    owned_process **slot = &pending;
    while (*slot) {
      owned_process *p = *slot;
      collect_process(p, 0);
      if (p->collected || p->lost) {
        *slot = p->next;
        free(p);
      } else {
        slot = &p->next;
      }
    }
  }
  return NULL;
}

static int ensure_reaper(void) {
  pthread_mutex_lock(&reaper_lock);
  int err = 0;
  if (!reaper_started) {
    pthread_t thread;
    err = pthread_create(&thread, NULL, reap_abandoned, NULL);
    if (!err) {
      pthread_detach(thread);
      reaper_started = 1;
    }
  }
  pthread_mutex_unlock(&reaper_lock);
  return err;
}

static void finalize_process(void *data) {
  owned_process *p = data;
  if (p->collected || p->lost) {
    free(p);
    return;
  }
  pthread_mutex_lock(&reaper_lock);
  p->next = incoming;
  incoming = p;
  pthread_cond_signal(&reaper_wakeup);
  pthread_mutex_unlock(&reaper_lock);
}

static int read_some(pipe_end fd, uint8_t *buf, size_t count, size_t *done) {
  ssize_t n;
  do n = read(fd, buf, count); while (n < 0 && errno == EINTR);
  if (n < 0) return errno;
  *done = (size_t)n;
  return 0;
}

/* A broken stdin is an IO error even in a caller that uses SIGPIPE's default disposition. */
static int write_all(pipe_end fd, uint8_t const *buf, size_t count) {
  sigset_t set, previous, pending;
  sigemptyset(&set);
  sigaddset(&set, SIGPIPE);
  int err = pthread_sigmask(SIG_BLOCK, &set, &previous);
  if (err) return err;
  int already_pending = sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE);
  while (count) {
    ssize_t n = write(fd, buf, count > INT_MAX ? INT_MAX : count);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { err = n == 0 ? EIO : errno; break; }
    buf += n;
    count -= (size_t)n;
  }
  if (err == EPIPE && !already_pending && sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE)) {
    int sig;
    sigwait(&set, &sig);
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  return err;
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_parent_lost(void) {
  pid_t self = getpid();
  if (getpgrp() == self && getsid(0) == self) kill(-self, SIGKILL);
  _exit(1);
}
#else
#include <windows.h>
#include <wchar.h>
#ifndef PROC_THREAD_ATTRIBUTE_JOB_LIST
#define PROC_THREAD_ATTRIBUTE_JOB_LIST ProcThreadAttributeValue(13, FALSE, TRUE, FALSE)
#endif

typedef HANDLE pipe_end;
#define INVALID_END NULL
#define BAD_ARGUMENT ERROR_INVALID_PARAMETER
#define NO_MEMORY ERROR_OUTOFMEMORY
typedef struct {
  HANDLE process, job;
  DWORD pid, code;
  int collected, forced_while_running;
} owned_process;

static BOOL CALLBACK windows_classes(PINIT_ONCE once, PVOID arg, PVOID *ctx) {
  (void)once; (void)arg; (void)ctx;
  register_classes();
  return TRUE;
}
static void ensure_classes(void) {
  static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
  InitOnceExecuteOnce(&once, windows_classes, NULL, NULL);
}
static void close_end(HANDLE h) { if (h) CloseHandle(h); }

static int to_wide(const char *s, wchar_t **out) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
  if (!count) return GetLastError();
  *out = calloc(count, sizeof(wchar_t));
  if (!*out) return NO_MEMORY;
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, *out, count) ? 0 : GetLastError();
}

#define MAX_CMD 32767
/* Quote an argument using the CRT rules, including backslashes before a quote or closing quote. */
static int append_arg(wchar_t *line, size_t *len, const wchar_t *arg) {
  size_t pos = *len;
  if (pos >= MAX_CMD - 3) return ERROR_FILENAME_EXCED_RANGE;
  if (pos) line[pos++] = L' ';
  line[pos++] = L'"';
  for (;;) {
    size_t slashes = 0;
    while (*arg == L'\\') { arg++; slashes++; }
    if (*arg == L'"' || !*arg) slashes = 2 * slashes + (*arg == L'"');
    if (slashes + (*arg ? 3 : 2) > MAX_CMD - pos) return ERROR_FILENAME_EXCED_RANGE;
    while (slashes--) line[pos++] = L'\\';
    if (!*arg) break;
    line[pos++] = *arg++;
  }
  line[pos++] = L'"';
  line[pos] = 0;
  *len = pos;
  return 0;
}

static int start_process(owned_process *p, char **argv, const char *cwd, pipe_end parent[3]) {
  HANDLE children[3] = {0};
  wchar_t *exe = NULL, *dir = NULL, *line = calloc(MAX_CMD, sizeof(wchar_t));
  STARTUPINFOEXW startup = {0};
  PROCESS_INFORMATION info = {0};
  SIZE_T attr_size = 0;
  int initialized = 0;
  int err = line ? to_wide(argv[0], &exe) : NO_MEMORY;
  size_t len = 0;
  if (!err) err = append_arg(line, &len, exe);
  for (size_t i = 1; !err && argv[i]; i++) {
    wchar_t *arg = NULL;
    err = to_wide(argv[i], &arg);
    if (!err) err = append_arg(line, &len, arg);
    free(arg);
  }
  if (!err && cwd) err = to_wide(cwd, &dir);
  if (err) goto cleanup;
  p->job = CreateJobObjectW(NULL, NULL);
  if (!p->job) { err = GetLastError(); goto cleanup; }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(p->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    err = GetLastError(); goto cleanup;
  }
  for (int i = 0; i < 3; i++) {
    HANDLE read_end, write_end;
    if (!CreatePipe(&read_end, &write_end, NULL, 0)) { err = GetLastError(); goto cleanup; }
    parent[i] = i == 0 ? write_end : read_end;
    children[i] = i == 0 ? read_end : write_end;
    if (!SetHandleInformation(children[i], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) {
      err = GetLastError(); goto cleanup;
    }
  }
  InitializeProcThreadAttributeList(NULL, 2, 0, &attr_size);
  startup.lpAttributeList = malloc(attr_size);
  if (!startup.lpAttributeList) { err = NO_MEMORY; goto cleanup; }
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 2, 0, &attr_size)) {
    err = GetLastError(); goto cleanup;
  }
  initialized = 1;
  if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                 &p->job, sizeof(p->job), NULL, NULL) ||
      !UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                 children, sizeof(children), NULL, NULL)) {
    err = GetLastError(); goto cleanup;
  }
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = children[0];
  startup.StartupInfo.hStdOutput = children[1];
  startup.StartupInfo.hStdError = children[2];
  if (!CreateProcessW(exe, line, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT |
                      CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW, NULL, dir, &startup.StartupInfo, &info)) {
    err = GetLastError(); goto cleanup;
  }
  p->pid = info.dwProcessId;
  p->process = info.hProcess;
  CloseHandle(info.hThread);
cleanup:
  if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
  free(startup.lpAttributeList);
  for (int i = 0; i < 3; i++) {
    close_end(children[i]);
    if (err) close_end(parent[i]);
  }
  if (err) close_end(p->job);
  free(exe); free(dir); free(line);
  return err;
}

static int peek_process(owned_process *p, int *exited) {
  if (p->collected) { *exited = 1; return 0; }
  DWORD result = WaitForSingleObject(p->process, 0);
  if (result == WAIT_TIMEOUT) { *exited = 0; return 0; }
  if (result != WAIT_OBJECT_0 || !GetExitCodeProcess(p->process, &p->code)) return GetLastError();
  *exited = 1;
  return 0;
}
static int terminate_process(owned_process *p, DWORD marker) {
  if (!p->job) return 0;
  int exited = 0;
  int err = peek_process(p, &exited);
  if (!err) {
    if (TerminateJobObject(p->job, marker)) p->forced_while_running = !exited;
    else err = GetLastError();
  }
  /* Keep the job through successful collection so last-close cannot supply its exit code.
     On failure attempt last-close containment and preserve the explicit operation error. */
  if (err && CloseHandle(p->job)) p->job = NULL;
  return err;
}
static int collect_process(owned_process *p, int block) {
  if (p->collected) return 0;
  DWORD result = WaitForSingleObject(p->process, block ? INFINITE : 0);
  if (result == WAIT_TIMEOUT) return 0;
  if (result != WAIT_OBJECT_0 || !GetExitCodeProcess(p->process, &p->code)) return GetLastError();
  if (p->job && !CloseHandle(p->job)) return GetLastError();
  p->job = NULL;
  if (!CloseHandle(p->process)) return GetLastError();
  p->process = NULL;
  p->collected = 1;
  return 0;
}
static void finalize_process(void *data) {
  owned_process *p = data;
  close_end(p->job);
  close_end(p->process);
  free(p);
}

static int read_some(pipe_end fd, uint8_t *buf, size_t count, size_t *done) {
  DWORD n = 0;
  if (!ReadFile(fd, buf, (DWORD)count, &n, NULL)) {
    DWORD err = GetLastError();
    if (err != ERROR_BROKEN_PIPE) return err;
    n = 0;
  }
  *done = n;
  return 0;
}
static int write_all(pipe_end fd, uint8_t const *buf, size_t count) {
  while (count) {
    DWORD n;
    if (!WriteFile(fd, buf, (DWORD)(count > INT_MAX ? INT_MAX : count), &n, NULL)) return GetLastError();
    if (!n) return ERROR_WRITE_FAULT;
    buf += n;
    count -= n;
  }
  return 0;
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_parent_lost(void) {
  ExitProcess(1);
}
#endif

static void finalize_endpoint(void *data) { close_end((pipe_end)(intptr_t)data); }

static char *checked_string(b_lean_obj_arg str) {
  char *s = (char *)lean_string_cstr(str);
  return strlen(s) + 1 == lean_string_size(str) ? s : NULL;
}

LEAN_EXPORT lean_obj_res lean_beam_owned_spawn(b_lean_obj_arg cmd, b_lean_obj_arg args,
                                                b_lean_obj_arg cwd) {
  size_t count = lean_array_size(args);
  owned_process *p = calloc(1, sizeof(*p));
  char **argv = calloc(count + 2, sizeof(char *));
  pipe_end parent[3] = {INVALID_END, INVALID_END, INVALID_END};
  int err = (!p || !argv) ? NO_MEMORY : 0;
  const char *dir = NULL;
  if (!err && !(argv[0] = checked_string(cmd))) err = BAD_ARGUMENT;
  for (size_t i = 0; !err && i < count; i++) {
    if (!(argv[i+1] = checked_string(lean_array_uget_borrowed(args, i)))) err = BAD_ARGUMENT;
  }
  if (!err && !lean_is_scalar(cwd) && !(dir = checked_string(lean_ctor_get(cwd, 0)))) err = BAD_ARGUMENT;
  ensure_classes();
  if (!err) err = start_process(p, argv, dir, parent);
  free(argv);
  if (err) { free(p); return process_error("launch Beam process", err); }
  lean_object *launch = lean_alloc_ctor(0, 4, sizeof(uint32_t));
  lean_ctor_set_uint32(launch, 4 * sizeof(lean_object *), p->pid);
  lean_ctor_set(launch, 0, lean_alloc_external(process_class, p));
  for (int i = 0; i < 3; i++)
    lean_ctor_set(launch, i + 1, lean_alloc_external(endpoint_class, (void *)(intptr_t)parent[i]));
  return lean_io_result_mk_ok(launch);
}

LEAN_EXPORT lean_obj_res lean_beam_owned_read(b_lean_obj_arg endpoint, size_t count) {
  /* A short read is legal. Bound one native allocation, even for USize.max. */
  if (count > 65536) count = 65536;
  lean_object *bytes = lean_alloc_sarray(1, count, count);
  size_t n = 0;
  int err = count ? read_some((pipe_end)(intptr_t)lean_get_external_data(endpoint),
                             lean_sarray_cptr(bytes), count, &n) : 0;
  if (err) { lean_dec(bytes); return process_error("read Beam process pipe", err); }
  lean_sarray_set_size(bytes, n);
  return lean_io_result_mk_ok(bytes);
}
LEAN_EXPORT lean_obj_res lean_beam_owned_write(b_lean_obj_arg endpoint, b_lean_obj_arg bytes) {
  int err = write_all((pipe_end)(intptr_t)lean_get_external_data(endpoint),
                      lean_sarray_cptr(bytes), lean_sarray_size(bytes));
  return err ? process_error("write Beam process pipe", err) : lean_io_result_mk_ok(lean_box(0));
}
static lean_obj_res exit_status(const owned_process *p, int exited) {
  if (!exited) return lean_io_result_mk_ok(lean_box(0));
  /* ExitStatus.exited, .signaled, .windows each carry one unboxed UInt32. */
#ifdef _WIN32
  unsigned tag = 2;
#else
  unsigned tag = p->signaled ? 1 : 0;
#endif
  lean_object *status = lean_alloc_ctor(tag, 0, sizeof(uint32_t));
  lean_ctor_set_uint32(status, 0, p->code);
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, status);
  return lean_io_result_mk_ok(some);
}

LEAN_EXPORT lean_obj_res lean_beam_owned_peek(b_lean_obj_arg process) {
  owned_process *p = lean_get_external_data(process);
  int exited = 0;
  int err = peek_process(p, &exited);
  if (err) return process_error("observe Beam process", err);
  return exit_status(p, exited);
}
LEAN_EXPORT lean_obj_res lean_beam_owned_signal(b_lean_obj_arg process, uint32_t marker) {
  owned_process *p = lean_get_external_data(process);
#ifdef _WIN32
  int err = terminate_process(p, marker);
#else
  (void)marker;
  int err = terminate_process(p);
#endif
  return err ? process_error("terminate Beam process group", err)
             : lean_io_result_mk_ok(lean_box(p->forced_while_running));
}

LEAN_EXPORT lean_obj_res lean_beam_owned_collect(b_lean_obj_arg process, uint8_t block) {
  owned_process *p = lean_get_external_data(process);
  int err = collect_process(p, block);
  if (err) return process_error("collect Beam process", err);
  return exit_status(p, p->collected);
}
