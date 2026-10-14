/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
*/

#include <lean/lean.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

/* These handles belong exclusively to the self-check controller. Lean's supported
   runtimes wrap FS.Handle as FILE*. Never mix these operations with buffered stdio. */
static FILE *beam_pipe_file(b_lean_obj_arg handle) {
  return (FILE *)lean_get_external_data(handle);
}

static lean_obj_res beam_pipe_error(const char *operation, uint32_t code) {
#ifdef _WIN32
  char message[128];
  snprintf(message, sizeof(message), "%s (Windows error %lu)", operation, (unsigned long)code);
  return lean_io_result_mk_error(lean_mk_io_error_other_error(code, lean_mk_string(message)));
#else
  char message[256];
  snprintf(message, sizeof(message), "%s: %s", operation, strerror(code));
  return lean_io_result_mk_error(lean_mk_io_error_other_error(code, lean_mk_string(message)));
#endif
}

LEAN_EXPORT lean_obj_res lean_beam_pipe_nonblocking(b_lean_obj_arg handle, lean_obj_arg world) {
  (void)world;
#ifdef _WIN32
  HANDLE pipe = (HANDLE)_get_osfhandle(_fileno(beam_pipe_file(handle)));
  DWORD mode = PIPE_NOWAIT;
  if (!SetNamedPipeHandleState(pipe, &mode, NULL, NULL))
    return beam_pipe_error("setting self-check pipe nonblocking", GetLastError());
#else
  int fd = fileno(beam_pipe_file(handle));
  int flags = fcntl(fd, F_GETFL);
  if (flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1)
    return beam_pipe_error("setting self-check pipe nonblocking", errno);
#endif
  return lean_io_result_mk_ok(lean_box(0));
}

/* none = would block; some empty = EOF; some bytes = progress. One bounded syscall
   per call lets the controller check its deadline even under a continuous writer. */
LEAN_EXPORT lean_obj_res lean_beam_pipe_read(b_lean_obj_arg handle, lean_obj_arg world) {
  (void)world;
  lean_object *bytes = lean_alloc_sarray(1, 0, 8192);
  size_t count;
#ifdef _WIN32
  HANDLE pipe = (HANDLE)_get_osfhandle(_fileno(beam_pipe_file(handle)));
  DWORD n = 0;
  if (!ReadFile(pipe, lean_sarray_cptr(bytes), 8192, &n, NULL)) {
    DWORD error = GetLastError();
    if (error == ERROR_NO_DATA) {
      lean_dec(bytes);
      return lean_io_result_mk_ok(lean_box(0));
    }
    if (error != ERROR_BROKEN_PIPE) {
      lean_dec(bytes);
      return beam_pipe_error("reading self-check pipe", error);
    }
  }
  count = n;
#else
  ssize_t n = read(fileno(beam_pipe_file(handle)), lean_sarray_cptr(bytes), 8192);
  if (n < 0) {
    int error = errno;
    lean_dec(bytes);
    if (error == EAGAIN || error == EWOULDBLOCK || error == EINTR)
      return lean_io_result_mk_ok(lean_box(0));
    return beam_pipe_error("reading self-check pipe", error);
  }
  count = (size_t)n;
#endif
  lean_sarray_set_size(bytes, count);
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, bytes);
  return lean_io_result_mk_ok(some);
}

/* Return the number of bytes written, including zero when the pipe is full. */
LEAN_EXPORT lean_obj_res lean_beam_pipe_write(
    b_lean_obj_arg handle, b_lean_obj_arg bytes, size_t offset, lean_obj_arg world) {
  (void)world;
  size_t size = lean_sarray_size(bytes);
  size_t count = offset < size ? size - offset : 0;
  if (count > 8192) count = 8192;
  if (count == 0) return lean_io_result_mk_ok(lean_box_usize(0));
  size_t written;
#ifdef _WIN32
  HANDLE pipe = (HANDLE)_get_osfhandle(_fileno(beam_pipe_file(handle)));
  DWORD capacity;
  if (!GetNamedPipeInfo(pipe, NULL, &capacity, NULL, NULL))
    return beam_pipe_error("querying self-check pipe capacity", GetLastError());
  if (capacity == 0)
    return beam_pipe_error("self-check pipe has zero capacity", ERROR_INVALID_DATA);
  // Anonymous pipes can return zero for a write larger than their entire buffer,
  // even when empty. Such a request would otherwise never make progress.
  if (count > capacity) count = capacity;
  DWORD n = 0;
  if (!WriteFile(pipe, lean_sarray_cptr(bytes) + offset, (DWORD)count, &n, NULL))
    return beam_pipe_error("writing self-check pipe", GetLastError());
  written = n;
#else
  ssize_t n = write(fileno(beam_pipe_file(handle)), lean_sarray_cptr(bytes) + offset, count);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
      return lean_io_result_mk_ok(lean_box_usize(0));
    return beam_pipe_error("writing self-check pipe", errno);
  }
  written = (size_t)n;
#endif
  return lean_io_result_mk_ok(lean_box_usize(written));
}
