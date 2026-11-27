/* Compile the production POSIX implementation with deterministic short/interrupted syscalls. */
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned reads, writes;
static ssize_t interrupted_read(int fd, void *buf, size_t count) {
  if (++reads == 1) { errno = EINTR; return -1; }
  return read(fd, buf, count);
}
static ssize_t short_write(int fd, const void *buf, size_t count) {
  if (++writes == 1) { errno = EINTR; return -1; }
  return write(fd, buf, count > 7 ? 7 : count);
}
static atomic_int denied_group;
static int fail_thread;
static int start_thread(pthread_t *thread, const pthread_attr_t *attr,
                        void *(*run)(void *), void *data) {
  if (fail_thread) return EAGAIN;
  return pthread_create(thread, attr, run, data);
}
static atomic_int racing_group;
static int exit_gate;
static int signal_group(pid_t pid, int sig) {
  if (pid == atomic_load(&racing_group)) {
    /* Production peek has already reported running. Commit a normal exit before the group kill. */
    siginfo_t info;
    assert(write(exit_gate, "go\n", 3) == 3);
    assert(waitid(P_PID, -pid, &info, WEXITED | WNOWAIT) == 0 && info.si_code == CLD_EXITED);
  }
  if (pid == atomic_load(&denied_group)) { errno = EACCES; return -1; }
  return kill(pid, sig);
}
#define pthread_create start_thread
#define kill signal_group
#define read interrupted_read
#define write short_write
#include "../../Beam/Native/process_job.c"
#undef read
#undef write
#undef kill
#undef pthread_create

/* A paused leader still owns its group. Resume the same child and collect its real exit. */
static void test_stopped_leader(void) {
  owned_process process = {0};
  pipe_end parent[3];
  char *argv[] = {"/bin/sh", "-c", "read line && exit 37", NULL};
  assert(start_process(&process, argv, NULL, parent) == 0);
  assert(kill(process.pid, SIGSTOP) == 0);
  siginfo_t info = {0};
  assert(waitid(P_PID, process.pid, &info, WSTOPPED | WNOWAIT) == 0);
  assert(info.si_pid == process.pid && info.si_code == CLD_STOPPED);
  int exited;
  assert(peek_process(&process, &exited) == 0 && !exited);
  assert(kill(process.pid, SIGCONT) == 0);
  assert(write_all(parent[0], (const uint8_t *)"go\n", 3) == 0);
  for (unsigned i = 0; i < 500 && !exited; i++) {
    assert(peek_process(&process, &exited) == 0);
    if (!exited) usleep(10000);
  }
  assert(exited && process.code == 37);
  assert(terminate_process(&process) == 0 && collect_process(&process, 1) == 0 && process.code == 37);
  for (int i = 0; i < 3; i++) close(parent[i]);
}

static void wait_for_handoff(pid_t pid) {
  for (int i = 0; i < 500; i++) {
    siginfo_t info;
    if (waitid(P_PID, pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
      assert(errno == ECHILD);
      return;
    }
    usleep(10000);
  }
  assert(0 && "reaper failed to collect the owned child");
}

static void test_intervening_exit(void) {
  owned_process p = {0};
  pipe_end parent[3];
  char *argv[] = {"/bin/sh", "-c", "sleep 30 & read gate && exit 23", NULL};
  assert(start_process(&p, argv, NULL, parent) == 0);
  exit_gate = parent[0];
  atomic_store(&racing_group, -p.pid);
  assert(terminate_process(&p) == 0 && p.forced_while_running);
  atomic_store(&racing_group, 0);
  assert(collect_process(&p, 1) == 0 && p.collected && !p.signaled && p.code == 23);
  for (int i = 0; i < 3; i++) close(parent[i]);
}

static void test_abandoned(void) {
  pipe_end first[3], second[3];
  char *gate[] = {"/bin/sh", "-c", "read line", NULL};
  owned_process *live = calloc(1, sizeof(*live));
  assert(live);
  fail_thread = 1;
  assert(start_process(live, gate, NULL, first) == EAGAIN && live->pid == 0);
  fail_thread = 0;
  assert(start_process(live, gate, NULL, first) == 0);
  pid_t pid = live->pid;
  atomic_store(&denied_group, -pid);
  assert(terminate_process(live) == EACCES && !live->forced_while_running);
  assert(collect_process(live, 0) == 0 && !live->collected);
  /* A releasing thread must return even when the child cannot yet settle. */
  alarm(15);
  finalize_process(live);

  owned_process *exited = calloc(1, sizeof(*exited));
  char *survivor[] = {"/bin/sh", "-c", "sleep 30 & exit 23", NULL};
  assert(exited && start_process(exited, survivor, NULL, second) == 0);
  pid_t second_pid = exited->pid;
  siginfo_t info;
  assert(waitid(P_PID, second_pid, &info, WEXITED | WNOWAIT) == 0);
  struct pollfd output = {second[1], POLLIN, 0};
  assert(poll(&output, 1, 0) == 0);
  finalize_process(exited);
  wait_for_handoff(second_pid);
  assert(poll(&output, 1, 3000) == 1);
  char byte;
  assert(read(second[1], &byte, 1) == 0);
  for (int i = 0; i < 3; i++) close(second[i]);
  assert(waitid(P_PID, pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && !info.si_pid);
  close(first[0]);
  wait_for_handoff(pid);
  close(first[1]); close(first[2]);
  atomic_store(&denied_group, 0);
  alarm(0);
}

#ifdef __APPLE__
static void test_tmpdir(void) {
  const char *env = getenv("TMPDIR");
  char *saved = env ? strdup(env) : NULL;
  char dir[] = "/tmp/beam fifo test.XXXXXX";
  assert(mkdtemp(dir) && setenv("TMPDIR", dir, 1) == 0);
  int ends[2] = {-1, -1};
  assert(make_pipe(ends) == 0 && !(fcntl(ends[0], F_GETFL) & O_NONBLOCK));
  close(ends[0]); close(ends[1]);
  assert(rmdir(dir) == 0);
  assert(make_pipe(ends) == ENOENT);
  char long_path[PATH_MAX + 1];
  memset(long_path, 'x', PATH_MAX); long_path[PATH_MAX] = 0;
  assert(setenv("TMPDIR", long_path, 1) == 0 && make_pipe(ends) == ENAMETOOLONG);
  if (saved) { setenv("TMPDIR", saved, 1); free(saved); } else unsetenv("TMPDIR");
}
#endif

int main(void) {
  int ends[2] = {-1, -1};
  assert(make_pipe(ends) == 0);
  uint8_t payload[127], echo[sizeof(payload)];
  for (size_t i = 0; i < sizeof(payload); i++) payload[i] = i;
  assert(write_all(ends[1], payload, sizeof(payload)) == 0 && writes > 2);
  size_t count;
  assert(read_some(ends[0], echo, sizeof(echo), &count) == 0 && reads == 2);
  assert(count == sizeof(payload) && memcmp(echo, payload, count) == 0);
  close(ends[0]);
  signal(SIGPIPE, SIG_DFL);
  assert(write_all(ends[1], payload, 1) == EPIPE);
  close(ends[1]);

  test_abandoned();
  test_intervening_exit();
  test_stopped_leader();
#ifdef __APPLE__
  test_tmpdir();
#endif

  /* No standard fd initially exists. The child must still have three working pipes, a
     new session, inherited environment and the requested cwd. It stays alive for inspection. */
  assert(setenv("BEAM_PIPE_FIXTURE", "inherited", 1) == 0);
  close(0); close(1); close(2);
  char *argv[] = {"/bin/sh", "-c",
    "test \"$BEAM_PIPE_FIXTURE\" = inherited && test . -ef / && "
    "read line && printf '%s' \"$line\" && printf err >&2 && exit 73", NULL};
  owned_process process = {0};
  pipe_end parent[3];
  assert(start_process(&process, argv, "/", parent) == 0);
  assert(getsid(process.pid) == process.pid && getpgid(process.pid) == process.pid);
  for (size_t i = 0; i < 3; i++) assert(parent[i] >= 3 && (fcntl(parent[i], F_GETFD) & FD_CLOEXEC));
  assert(write_all(parent[0], (const uint8_t *)"ok\n", 3) == 0);
  assert(read_some(parent[1], echo, sizeof(echo), &count) == 0 && count == 2 && !memcmp(echo, "ok", 2));
  assert(read_some(parent[2], echo, sizeof(echo), &count) == 0 && count == 3 && !memcmp(echo, "err", 3));
  siginfo_t info;
  assert(waitid(P_PID, process.pid, &info, WEXITED | WNOWAIT) == 0);
  assert(terminate_process(&process) == 0 && collect_process(&process, 1) == 0 && process.code == 73);
  assert(terminate_process(&process) == 0 && collect_process(&process, 1) == 0 && process.code == 73);
  for (size_t i = 0; i < 3; i++) close(parent[i]);

  /* Exercise loss of ownership without ever signalling an arbitrary numeric PID. */
  owned_process lost = {0};
  char *quick[] = {"/bin/sh", "-c", "exit 0", NULL};
  assert(start_process(&lost, quick, NULL, parent) == 0);
  assert(waitpid(lost.pid, NULL, 0) == lost.pid);
  assert(terminate_process(&lost) == ECHILD && lost.lost);
  assert(collect_process(&lost, 1) == ECHILD);
  for (size_t i = 0; i < 3; i++) close(parent[i]);
  return 0;
}
