/*
 * Copyright (c) 2026 Lean FRO LLC. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 */

#include <lean/lean.h>

static lean_obj_res config_error(const char *message) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}

#ifdef _WIN32

LEAN_EXPORT lean_obj_res beam_agy_config_read(b_lean_obj_arg path) {
  (void)path;
  return config_error("Antigravity MCP registration requires a POSIX installer");
}

LEAN_EXPORT lean_obj_res beam_agy_config_replace(b_lean_obj_arg path,
    b_lean_obj_arg physical, b_lean_obj_arg stamp, b_lean_obj_arg before,
    b_lean_obj_arg after) {
  (void)path;
  (void)physical;
  (void)stamp;
  (void)before;
  (void)after;
  return config_error("Antigravity MCP registration requires a POSIX installer");
}

#else

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CONFIG_LEAF "mcp_config.json"
#define CONFIG_LIMIT (1024 * 1024)
#define STAMP_SIZE 256

#ifdef __APPLE__
#define MTIME(st) ((st)->st_mtimespec)
#define CTIME(st) ((st)->st_ctimespec)
#else
#define MTIME(st) ((st)->st_mtim)
#define CTIME(st) ((st)->st_ctim)
#endif

static const char changed[] = "Antigravity MCP config changed before writing; rerun the installer";
static const char moved[] = "Antigravity MCP config location changed before writing; rerun the installer";

struct snapshot {
  char path[PATH_MAX];
  char parent[PATH_MAX];
  struct stat stat;
  bool exists;
  lean_object *bytes;
};

static void snapshot_stamp(const struct snapshot *snap, char out[STAMP_SIZE]) {
  if (!snap->exists) {
    snprintf(out, STAMP_SIZE, "absent");
    return;
  }
  const struct stat *s = &snap->stat;
  snprintf(out, STAMP_SIZE, "%ju:%ju:%jo:%jd:%jd:%ld:%jd:%ld",
    (uintmax_t)s->st_dev, (uintmax_t)s->st_ino, (uintmax_t)(s->st_mode & 07777),
    (intmax_t)s->st_size, (intmax_t)MTIME(s).tv_sec, (long)MTIME(s).tv_nsec,
    (intmax_t)CTIME(s).tv_sec, (long)CTIME(s).tv_nsec);
}

/* Resolve existing parent directory aliases while keeping missing components lexical and
   never passing the config leaf to realpath. */
static const char *resolve_location(const char *requested, struct snapshot *snap) {
  char normalized[PATH_MAX], resolved[PATH_MAX];
  size_t length = 0;
  if (*requested != '/') return "Antigravity MCP config path must be absolute";
  while (*requested) {
    while (*requested == '/') ++requested;
    size_t n = strcspn(requested, "/");
    if (n == 2 && memcmp(requested, "..", 2) == 0)
      return "Antigravity MCP config path must not contain '..'";
    if (n && !(n == 1 && *requested == '.')) {
      if (length + n + 1 >= sizeof normalized) return "Antigravity MCP config path is too long";
      normalized[length++] = '/';
      memcpy(normalized + length, requested, n);
      length += n;
    }
    requested += n;
  }
  normalized[length] = '\0';
  char *leaf = strrchr(normalized, '/');
  if (!leaf || strcmp(leaf + 1, CONFIG_LEAF) != 0)
    return "Antigravity MCP config must be named " CONFIG_LEAF;

  size_t ancestor_len = (size_t)(leaf - normalized);
  char probe[PATH_MAX];
  for (;;) {
    if (ancestor_len) {
      memcpy(probe, normalized, ancestor_len);
      probe[ancestor_len] = '\0';
    } else {
      strcpy(probe, "/");
    }
    if (realpath(probe, resolved)) break;
    struct stat st;
    if (errno != ENOENT || lstat(probe, &st) == 0 || errno != ENOENT || !ancestor_len)
      return "cannot resolve the Antigravity MCP config parent directory";
    do --ancestor_len; while (normalized[ancestor_len] != '/');
  }

  size_t prefix = strcmp(resolved, "/") == 0 ? 0 : strlen(resolved);
  if (prefix + length - ancestor_len >= sizeof snap->path)
    return "physical Antigravity MCP config path is too long";
  memcpy(snap->path, resolved, prefix);
  strcpy(snap->path + prefix, normalized + ancestor_len);
  size_t parent_len = (size_t)(strrchr(snap->path, '/') - snap->path);
  if (parent_len == 0) {
    strcpy(snap->parent, "/");
  } else {
    memcpy(snap->parent, snap->path, parent_len);
    snap->parent[parent_len] = '\0';
  }
  return NULL;
}

static const char *read_snapshot(struct snapshot *snap) {
  struct stat st;
  snap->exists = false;
  snap->bytes = lean_alloc_sarray(1, 0, 0);
  if (lstat(snap->path, &st) < 0) {
    if (errno == ENOENT || errno == ENOTDIR) return NULL;
    return "cannot inspect the Antigravity MCP config";
  }
  if (S_ISLNK(st.st_mode)) return "refusing to edit symlinked Antigravity MCP config";
  if (!S_ISREG(st.st_mode)) return "refusing to edit non-regular Antigravity MCP config";
  if (!(st.st_mode & 0222) || access(snap->path, W_OK) < 0)
    return "refusing to edit read-only Antigravity MCP config; make it writable first";
  if (st.st_size < 0 || st.st_size > CONFIG_LIMIT)
    return "Antigravity MCP config exceeds the 1 MiB size limit";

  int fd = open(snap->path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return changed;
  struct stat opened;
  if (fstat(fd, &opened) < 0 || !S_ISREG(opened.st_mode) ||
      opened.st_dev != st.st_dev || opened.st_ino != st.st_ino ||
      opened.st_size != st.st_size) {
    close(fd);
    return changed;
  }

  size_t size = (size_t)opened.st_size, used = 0;
  lean_dec(snap->bytes);
  snap->bytes = lean_alloc_sarray(1, size, size + 1);
  uint8_t *buf = lean_sarray_cptr(snap->bytes);
  while (used <= size) {
    ssize_t n = read(fd, buf + used, size + 1 - used);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      close(fd);
      return "cannot read the Antigravity MCP config";
    }
    if (n == 0) break;
    used += (size_t)n;
  }
  close(fd);
  if (used != size) return changed;
  snap->stat = opened;
  snap->exists = true;
  return NULL;
}

static const char *ensure_parent_dirs(const char *parent) {
  char path[PATH_MAX];
  size_t len = strlen(parent);
  if (len >= sizeof path) return "physical Antigravity MCP config parent path is too long";
  memcpy(path, parent, len + 1);
  for (char *p = path + 1; *p; ++p) {
    if (*p == '/') {
      *p = '\0';
      if (mkdir(path, 0700) < 0 && errno != EEXIST)
        return "cannot create the physical Antigravity MCP config parent";
      *p = '/';
    }
  }
  if (mkdir(path, 0700) < 0 && errno != EEXIST)
    return "cannot create the physical Antigravity MCP config parent";
  return NULL;
}

static bool write_all(int fd, b_lean_obj_arg output) {
  const uint8_t *bytes = lean_sarray_cptr(output);
  size_t size = lean_sarray_size(output), used = 0;
  while (used < size) {
    ssize_t n = write(fd, bytes + used, size - used);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    used += (size_t)n;
  }
  return true;
}

static bool same_bytes(b_lean_obj_arg a, b_lean_obj_arg b) {
  return lean_sarray_size(a) == lean_sarray_size(b) &&
    memcmp(lean_sarray_cptr(a), lean_sarray_cptr(b), lean_sarray_size(a)) == 0;
}

LEAN_EXPORT lean_obj_res beam_agy_config_read(b_lean_obj_arg path) {
  struct snapshot snap = {0};
  const char *error = resolve_location(lean_string_cstr(path), &snap);
  if (!error) error = read_snapshot(&snap);
  if (error) {
    if (snap.bytes) lean_dec(snap.bytes);
    return config_error(error);
  }
  char stamp[STAMP_SIZE];
  snapshot_stamp(&snap, stamp);
  lean_object *result = lean_alloc_ctor(0, 3, 0);
  lean_ctor_set(result, 0, lean_mk_string(snap.path));
  lean_ctor_set(result, 1, lean_mk_string(stamp));
  lean_ctor_set(result, 2, snap.bytes);
  return lean_io_result_mk_ok(result);
}

LEAN_EXPORT lean_obj_res beam_agy_config_replace(b_lean_obj_arg path,
    b_lean_obj_arg physical, b_lean_obj_arg stamp, b_lean_obj_arg before,
    b_lean_obj_arg after) {
  struct snapshot current = {0};
  char actual_stamp[STAMP_SIZE], staged_path[PATH_MAX];
  int staged_fd = -1;
  bool staged_created = false;

  const char *error = resolve_location(lean_string_cstr(path), &current);
  if (error) goto done;
  if (strcmp(current.path, lean_string_cstr(physical)) != 0) {
    error = moved;
    goto done;
  }
  error = read_snapshot(&current);
  if (error) goto done;
  snapshot_stamp(&current, actual_stamp);
  if (strcmp(actual_stamp, lean_string_cstr(stamp)) != 0 || !same_bytes(current.bytes, before)) {
    error = changed;
    goto done;
  }

  error = ensure_parent_dirs(current.parent);
  if (error) goto done;
  int n = snprintf(staged_path, sizeof staged_path, "%s/.%s.lean-beam-XXXXXX",
    current.parent, CONFIG_LEAF);
  if (n < 0 || (size_t)n >= sizeof staged_path) {
    error = "staged Antigravity MCP config path is too long";
    goto done;
  }
  staged_fd = mkstemp(staged_path);
  if (staged_fd < 0) {
    error = "cannot stage the Antigravity MCP config";
    goto done;
  }
  staged_created = true;
  if (!write_all(staged_fd, after)) {
    error = "cannot write the staged Antigravity MCP config";
    goto done;
  }
  mode_t mode = current.exists ? (current.stat.st_mode & 07777) : 0600;
  if (fchmod(staged_fd, mode) < 0) {
    error = "cannot preserve Antigravity MCP config mode";
    goto done;
  }
  if (fsync(staged_fd) < 0) {
    error = "cannot sync the staged Antigravity MCP config";
    goto done;
  }
  if (close(staged_fd) < 0) {
    staged_fd = -1;
    error = "cannot close the staged Antigravity MCP config";
    goto done;
  }
  staged_fd = -1;

  if (!current.exists) {
    if (link(staged_path, current.path) < 0)
      error = errno == EEXIST ? changed : "cannot publish new Antigravity MCP config";
  } else {
    if (rename(staged_path, current.path) < 0) {
      error = "cannot replace the Antigravity MCP config";
    } else {
      staged_created = false;
    }
  }

done:
  if (staged_fd >= 0) close(staged_fd);
  if (staged_created && unlink(staged_path) < 0 && !error)
    error = "cannot remove the staged Antigravity MCP config";
  if (current.bytes) lean_dec(current.bytes);
  return error ? config_error(error) : lean_io_result_mk_ok(lean_box(0));
}

#endif
