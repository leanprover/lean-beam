/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
*/

#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <lean/lean.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>

#if defined(_WIN32)
#include <windef.h>
#include <winbase.h> /* Lean's MinGW SDK declares the Job Object APIs here. */
#include <errhandlingapi.h>
#include <handleapi.h>
#include <processthreadsapi.h>
#include <synchapi.h>

static lean_obj_res job_error(const char *operation) {
  char message[160];
  snprintf(message, sizeof(message), "%s failed (Windows error %lu)", operation,
    (unsigned long)GetLastError());
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_attach(uint32_t pid, lean_obj_arg world) {
  (void)world;
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return job_error("CreateJobObjectW");
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    DWORD error = GetLastError(); CloseHandle(job); SetLastError(error);
    return job_error("SetInformationJobObject");
  }
  HANDLE process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, pid);
  if (!process || !AssignProcessToJobObject(job, process)) {
    DWORD error = GetLastError();
    if (process) CloseHandle(process);
    CloseHandle(job); SetLastError(error);
    return job_error("AssignProcessToJobObject");
  }
  CloseHandle(process);
  return lean_io_result_mk_ok(lean_box_usize((size_t)job));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_close(size_t job, lean_obj_arg world) {
  (void)world;
  if (job && !CloseHandle((HANDLE)job)) return job_error("CloseHandle(job)");
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_terminate_posix(uint32_t pid, lean_obj_arg world) {
  /* Windows uses Lean's original process handle, after the enclosing job has closed. */
  (void)pid; (void)world;
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_poll(uint32_t pid, lean_obj_arg world) {
  (void)world;
  /* The caller retains the original Child handle, so this PID cannot be recycled here. */
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!process) return job_error("OpenProcess(poll)");
  DWORD status = WaitForSingleObject(process, 0);
  DWORD error = GetLastError(); CloseHandle(process); SetLastError(error);
  if (status == WAIT_FAILED) return job_error("WaitForSingleObject");
  return lean_io_result_mk_ok(lean_box(status == WAIT_OBJECT_0 ? 1 : 0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_parent_lost(lean_obj_arg world) {
  (void)world;
  /* The parent's non-inheritable kill-on-close job owns any project/compiler descendants. */
  ExitProcess(1);
  return lean_io_result_mk_ok(lean_box(0));
}
#else
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
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

static lean_obj_res process_error(const char *operation, int error) {
  char message[160];
  snprintf(message, sizeof(message), "%s failed (POSIX error %d)", operation, error);
  return lean_io_result_mk_error(lean_mk_io_error_other_error(error, lean_mk_string(message)));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_attach(uint32_t pid, lean_obj_arg world) {
  (void)pid; (void)world;
  return lean_io_result_mk_ok(lean_box_usize(0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_close(size_t job, lean_obj_arg world) {
  (void)job; (void)world;
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_terminate_posix(uint32_t pid, lean_obj_arg world) {
  (void)world;
  if ((pid_t)pid <= 0)
    return lean_io_result_mk_error(lean_decode_io_error(EINVAL, NULL));
  /* The child may not have reached setsid yet. Kill its retained leader first, then any group
     it established before that signal. Do not reap until both operations have completed. */
  int leader_error = 0;
  if (kill((pid_t)pid, SIGKILL) != 0 && errno != ESRCH) leader_error = errno;
  int group_error = 0;
  if (kill(-(pid_t)pid, SIGKILL) != 0 && errno != ESRCH) {
    group_error = errno;
#if defined(__APPLE__)
    if (group_error == EPERM && inactive_group((pid_t)pid)) group_error = 0;
#endif
  }
  if (leader_error) return process_error("kill(helper leader)", leader_error);
  if (group_error) return process_error("kill(helper process group)", group_error);
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_poll(uint32_t pid, lean_obj_arg world) {
  (void)world;
  siginfo_t status = {0};
  if (waitid(P_PID, (id_t)pid, &status, WEXITED | WNOHANG | WNOWAIT) != 0) {
    if (errno == EINTR) return lean_io_result_mk_ok(lean_box(0));
    if (errno == ECHILD) return lean_io_result_mk_ok(lean_box(2));
    return process_error("waitid(helper leader)", errno);
  }
  /* Observation must not reap: retain PID/group ownership until termination and Child.wait. */
  return lean_io_result_mk_ok(lean_box(status.si_pid ? 1 : 0));
}

LEAN_EXPORT lean_obj_res lean_beam_process_job_parent_lost(lean_obj_arg world) {
  (void)world;
  pid_t self = getpid();
  /* Direct/manual invocations must never signal the caller's shell or process group. */
  if (getpgrp() == self && getsid(0) == self) kill(-self, SIGKILL);
  _exit(1);
}
#endif
