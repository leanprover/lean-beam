/*
 * Copyright (c) 2026 Lean FRO LLC. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/xattr.h>
#elif defined(__APPLE__)
#include <sys/acl.h>
#endif

#define CONFIG_LEAF "mcp_config.json"
#define CONFIG_LIMIT (1024 * 1024)
#define STAMP_SIZE 512
#define DIR_FLAGS (O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

#ifdef O_SEARCH
#define DIR_SEARCH O_SEARCH
#elif defined(O_PATH)
#define DIR_SEARCH O_PATH
#else
#define DIR_SEARCH O_RDONLY
#endif

static const char changed[] = "Antigravity MCP config changed before writing; rerun the installer";
static const char moved[] = "Antigravity MCP config location changed before writing; rerun the installer";
static const char unsafe_acl[] = "refusing to replace an Antigravity MCP config with an extended ACL";

struct location {
  char path[PATH_MAX];
  const char *missing;
  struct stat anchor;
  int dir;
};

struct config {
  struct stat stat;
  bool exists;
  lean_object *bytes;
  int fd;
};

static void close_config(struct config *config) {
  if (config->fd >= 0) close(config->fd);
  if (config->bytes) lean_dec(config->bytes);
}

static bool same_inode(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

#ifdef __APPLE__
#define MTIME(st) ((st)->st_mtimespec)
#define CTIME(st) ((st)->st_ctimespec)
#else
#define MTIME(st) ((st)->st_mtim)
#define CTIME(st) ((st)->st_ctim)
#endif

static bool same_file(const struct stat *a, const struct stat *b) {
  return same_inode(a, b) && a->st_mode == b->st_mode && a->st_uid == b->st_uid &&
    a->st_gid == b->st_gid && a->st_size == b->st_size &&
    MTIME(a).tv_sec == MTIME(b).tv_sec && MTIME(a).tv_nsec == MTIME(b).tv_nsec &&
    CTIME(a).tv_sec == CTIME(b).tv_sec && CTIME(a).tv_nsec == CTIME(b).tv_nsec;
}

static void snapshot_stamp(const struct location *location, const struct config *config,
    char stamp[STAMP_SIZE]) {
  const struct stat *a = &location->anchor;
  const struct stat *s = &config->stat;
  if (!config->exists) {
    snprintf(stamp, STAMP_SIZE, "%ju:%ju:absent", (uintmax_t)a->st_dev, (uintmax_t)a->st_ino);
    return;
  }
  snprintf(stamp, STAMP_SIZE, "%ju:%ju:%ju:%ju:%jo:%ju:%ju:%jd:%jd:%ld:%jd:%ld",
    (uintmax_t)a->st_dev, (uintmax_t)a->st_ino, (uintmax_t)s->st_dev, (uintmax_t)s->st_ino,
    (uintmax_t)s->st_mode, (uintmax_t)s->st_uid, (uintmax_t)s->st_gid, (intmax_t)s->st_size,
    (intmax_t)MTIME(s).tv_sec, MTIME(s).tv_nsec, (intmax_t)CTIME(s).tv_sec, CTIME(s).tv_nsec);
}

/* Walk from a pinned directory. Every component, including an existing directory
   left by a concurrent creator, must open as a directory without following symlinks. */
static int walk_directories(int dir, const char *parts, bool create) {
  while (*parts) {
    char name[PATH_MAX];
    size_t length = strcspn(parts, "/");
    memcpy(name, parts, length);
    name[length] = '\0';
    if (create && mkdirat(dir, name, 0700) < 0 && errno != EEXIST) {
      close(dir);
      return -1;
    }
    int access_mode = create || !parts[length] ? O_RDONLY : DIR_SEARCH;
    int next = openat(dir, name, access_mode | DIR_FLAGS);
    close(dir);
    if (next < 0) return -1;
    dir = next;
    parts += length;
    if (*parts == '/') ++parts;
  }
  return dir;
}

/* Follow existing directory aliases only. Keep the missing suffix lexical and never
   pass the config leaf to realpath. Match the shell's normalization of slashes and dots. */
static const char *open_location(const char *requested, struct location *location) {
  char path[PATH_MAX], resolved[PATH_MAX];
  size_t length = 0;
  if (*requested != '/') return "Antigravity MCP config path must be absolute";
  while (*requested) {
    size_t n = 0;
    while (*requested == '/') ++requested;
    n = strcspn(requested, "/");
    if (n == 2 && memcmp(requested, "..", n) == 0)
      return "Antigravity MCP config path must not contain '..'";
    if (n && !(n == 1 && *requested == '.')) {
      if (length + n + 1 >= sizeof path) return "Antigravity MCP config path is too long";
      path[length++] = '/';
      memcpy(path + length, requested, n);
      length += n;
    }
    requested += n;
  }
  path[length] = '\0';
  char *end = strrchr(path, '/');
  if (!end || strcmp(end + 1, CONFIG_LEAF) != 0)
    return "Antigravity MCP config must be named " CONFIG_LEAF;

  char parent[PATH_MAX];
  size_t ancestor_length = (size_t)(end - path);
  for (;;) {
    if (ancestor_length) {
      memcpy(parent, path, ancestor_length);
      parent[ancestor_length] = '\0';
    } else {
      strcpy(parent, "/");
    }
    if (realpath(parent, resolved)) break;
    struct stat status;
    if (errno != ENOENT || lstat(parent, &status) == 0 || errno != ENOENT || !ancestor_length)
      return "cannot resolve the Antigravity MCP config parent directory";
    do --ancestor_length; while (path[ancestor_length] != '/');
  }
  size_t prefix = strcmp(resolved, "/") == 0 ? 0 : strlen(resolved);
  if (prefix + length - ancestor_length >= sizeof location->path)
    return "physical Antigravity MCP config path is too long";
  memcpy(location->path, resolved, prefix);
  strcpy(location->path + prefix, path + ancestor_length);
  /* Keep the suffix relative to the pinned ancestor, including the final leaf. */
  location->missing = location->path + prefix;
  int root = open("/", (resolved[1] ? DIR_SEARCH : O_RDONLY) | DIR_FLAGS);
  if (root < 0) return "cannot open the filesystem root for Antigravity MCP registration";
  location->dir = walk_directories(root, resolved + 1, false);
  if (location->dir < 0) return "cannot pin the physical Antigravity MCP config ancestor";
  if (fstat(location->dir, &location->anchor) < 0)
    return "cannot inspect the physical Antigravity MCP config ancestor";
  return NULL;
}

static bool parent_exists(const struct location *location) {
  return strcmp(location->missing, "/" CONFIG_LEAF) == 0;
}

static const char *read_config(const struct location *location, struct config *config) {
  struct stat entry, opened, after;
  config->bytes = lean_alloc_sarray(1, 0, 0);
  if (!parent_exists(location)) return NULL;
  int dir = location->dir;
  if (fstatat(dir, CONFIG_LEAF, &entry, AT_SYMLINK_NOFOLLOW) < 0)
    return errno == ENOENT ? NULL : "cannot inspect the Antigravity MCP config";
  if (S_ISLNK(entry.st_mode)) return "refusing to edit symlinked Antigravity MCP config";
  if (!S_ISREG(entry.st_mode)) return "refusing to edit non-regular Antigravity MCP config";
#ifdef __APPLE__
  /* Darwin's faccessat rejects AT_SYMLINK_NOFOLLOW with EINVAL; leaf symlinks were rejected above
     and openat below uses O_NOFOLLOW plus same_file verification. */
  if (!(entry.st_mode & 0222) || faccessat(dir, CONFIG_LEAF, W_OK, 0) < 0)
    return "refusing to edit read-only Antigravity MCP config; make it writable first";
#else
  if (!(entry.st_mode & 0222) || faccessat(dir, CONFIG_LEAF, W_OK, AT_SYMLINK_NOFOLLOW) < 0)
    return "refusing to edit read-only Antigravity MCP config; make it writable first";
#endif
  config->fd = openat(dir, CONFIG_LEAF, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (config->fd < 0 || fstat(config->fd, &opened) < 0 ||
      !S_ISREG(opened.st_mode) || !same_file(&entry, &opened)) return changed;
  if (opened.st_size < 0 || opened.st_size > CONFIG_LIMIT)
    return "Antigravity MCP config exceeds the 1 MiB size limit";

  size_t size = (size_t)opened.st_size, used = 0;
  lean_dec(config->bytes);
  config->bytes = lean_alloc_sarray(1, size, size + 1);
  uint8_t *bytes = lean_sarray_cptr(config->bytes);
  while (used <= size) {
    ssize_t n = read(config->fd, bytes + used, size + 1 - used);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return "cannot read the Antigravity MCP config";
    if (n == 0) break;
    used += (size_t)n;
  }
  if (used != size || fstat(config->fd, &after) < 0 || !same_file(&opened, &after) ||
      fstatat(dir, CONFIG_LEAF, &entry, AT_SYMLINK_NOFOLLOW) < 0 ||
      !same_file(&after, &entry)) return changed;
  config->stat = after;
  config->exists = true;
  return NULL;
}

static bool ordinary_acl(int fd) {
#if defined(__linux__)
  if (fgetxattr(fd, "system.posix_acl_access", NULL, 0) >= 0) return false;
  return errno == ENODATA || errno == ENOTSUP || errno == EOPNOTSUPP;
#elif defined(__APPLE__)
  acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
  if (!acl) return errno == ENOENT || errno == ENOTSUP;
  acl_entry_t entry;
  // Darwin returns zero for an entry and EINVAL when an ACL has no first entry.
  bool empty = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) < 0 && errno == EINVAL;
  acl_free(acl);
  return empty;
#else
  (void)fd;
  return true;
#endif
}

static const char *stage_permissions(int fd, const struct config *before) {
  if (!ordinary_acl(fd) || (before->exists && !ordinary_acl(before->fd))) return unsafe_acl;
  const struct stat *old = &before->stat;
  mode_t mode = before->exists ? old->st_mode & 07777 : 0600;
  bool keep_group = before->exists && (mode & (0077 | S_ISGID)) != 0;
  struct stat staged;
  if (before->exists) {
    if (fstat(fd, &staged) < 0) return "cannot inspect staged Antigravity MCP config permissions";
    uid_t uid = staged.st_uid == old->st_uid ? (uid_t)-1 : old->st_uid;
    gid_t gid = keep_group && staged.st_gid != old->st_gid ? old->st_gid : (gid_t)-1;
    if ((uid != (uid_t)-1 || gid != (gid_t)-1) && fchown(fd, uid, gid) < 0)
      return "cannot preserve Antigravity MCP config ownership";
  }
  if (fchmod(fd, mode) < 0 || fstat(fd, &staged) < 0 || (staged.st_mode & 07777) != mode)
    return "cannot preserve Antigravity MCP config mode";
  if (before->exists && (staged.st_uid != old->st_uid || (keep_group && staged.st_gid != old->st_gid)))
    return "cannot preserve Antigravity MCP config ownership";
  return NULL;
}

static int stage_config(int dir, char name[64]) {
  uint8_t random[16];
  size_t used = 0;
  int source = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (source < 0) return -1;
  while (used < sizeof random) {
    ssize_t n = read(source, random + used, sizeof random - used);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    used += (size_t)n;
  }
  close(source);
  if (used != sizeof random) return -1;
  size_t prefix = sizeof "." CONFIG_LEAF ".lean-beam-" - 1;
  strcpy(name, "." CONFIG_LEAF ".lean-beam-");
  for (size_t i = 0; i < sizeof random; ++i)
    snprintf(name + prefix + 2 * i, 3, "%02x", (unsigned)random[i]);
  return openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
}

static bool write_content(int fd, b_lean_obj_arg output) {
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

static bool stage_is_named(int dir, const char *name, int fd) {
  struct stat held, named;
  return fstat(fd, &held) == 0 && fstatat(dir, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
    same_file(&held, &named);
}

static bool location_is_current(const char *requested, const struct location *pinned) {
  struct location current = {.dir = -1};
  struct stat parent;
  bool same = !open_location(requested, &current) && parent_exists(&current) &&
    strcmp(current.path, pinned->path) == 0 &&
    fstat(pinned->dir, &parent) == 0 && same_inode(&parent, &current.anchor);
  if (current.dir >= 0) close(current.dir);
  return same;
}

static bool same_bytes(b_lean_obj_arg a, b_lean_obj_arg b) {
  return lean_sarray_size(a) == lean_sarray_size(b) &&
    memcmp(lean_sarray_cptr(a), lean_sarray_cptr(b), lean_sarray_size(a)) == 0;
}

LEAN_EXPORT lean_obj_res beam_agy_config_read(b_lean_obj_arg path) {
  struct location location = {.dir = -1};
  struct config config = {.fd = -1};
  const char *error = open_location(lean_string_cstr(path), &location);
  if (!error) error = read_config(&location, &config);
  if (location.dir >= 0) close(location.dir);
  if (error) {
    close_config(&config);
    return config_error(error);
  }
  char stamp[STAMP_SIZE];
  snapshot_stamp(&location, &config, stamp);
  lean_object *snapshot = lean_alloc_ctor(0, 3, 0);
  lean_ctor_set(snapshot, 0, lean_mk_string(location.path));
  lean_ctor_set(snapshot, 1, lean_mk_string(stamp));
  lean_ctor_set(snapshot, 2, config.bytes);
  if (config.fd >= 0) close(config.fd);
  return lean_io_result_mk_ok(snapshot);
}

LEAN_EXPORT lean_obj_res beam_agy_config_replace(b_lean_obj_arg path,
    b_lean_obj_arg physical, b_lean_obj_arg stamp, b_lean_obj_arg before,
    b_lean_obj_arg after) {
  const char *requested = lean_string_cstr(path);
  struct location location = {.dir = -1};
  struct config current = {.fd = -1}, final = {.fd = -1};
  int staged = -1;
  char name[64], actual_stamp[STAMP_SIZE];
  const char *error = open_location(requested, &location);
  if (error) goto done;
  if (strcmp(location.path, lean_string_cstr(physical)) != 0) {
    error = moved;
    goto done;
  }
  error = read_config(&location, &current);
  if (error) goto done;
  snapshot_stamp(&location, &current, actual_stamp);
  if (strcmp(actual_stamp, lean_string_cstr(stamp)) != 0 || !same_bytes(current.bytes, before)) {
    error = changed;
    goto done;
  }

  if (!parent_exists(&location)) {
    char missing[PATH_MAX];
    size_t missing_size = (size_t)(strrchr(location.missing, '/') - location.missing);
    memcpy(missing, location.missing + 1, missing_size - 1);
    missing[missing_size - 1] = '\0';
    location.dir = walk_directories(location.dir, missing, true);
    if (location.dir < 0) {
      error = "cannot create the physical Antigravity MCP config parent";
      goto done;
    }
    location.missing = strrchr(location.path, '/');
  }
  staged = stage_config(location.dir, name);
  if (staged < 0) {
    error = "cannot stage the Antigravity MCP config";
    goto done;
  }
  if (!write_content(staged, after)) {
    error = "cannot write the staged Antigravity MCP config";
    goto done;
  }
  error = stage_permissions(staged, &current);
  if (error) goto done;
  if (fsync(staged) < 0) {
    error = "cannot sync the staged Antigravity MCP config";
    goto done;
  }
  if (!location_is_current(requested, &location)) {
    error = moved;
    goto done;
  }
  if (current.exists) {
    // Compare exact bytes while the old file is pinned, then recheck its name before renaming.
    error = read_config(&location, &final);
    if (error) goto done;
    if (!final.exists || !same_file(&current.stat, &final.stat) ||
        !same_bytes(before, final.bytes) || !ordinary_acl(final.fd)) {
      error = changed;
      goto done;
    }
  }
  if (!stage_is_named(location.dir, name, staged)) {
    error = "staged Antigravity MCP config was displaced";
    goto done;
  }
  if (!current.exists) {
    if (linkat(location.dir, name, location.dir, CONFIG_LEAF, 0) < 0)
      error = errno == EEXIST ? changed : "cannot publish new Antigravity MCP config";
  } else {
    struct stat named;
    if (fstatat(location.dir, CONFIG_LEAF, &named, AT_SYMLINK_NOFOLLOW) < 0 ||
        !same_file(&final.stat, &named)) {
      error = changed;
      goto done;
    }
    if (renameat(location.dir, name, location.dir, CONFIG_LEAF) < 0)
      error = "cannot replace the Antigravity MCP config";
  }

done:
  if (staged >= 0) {
    if (stage_is_named(location.dir, name, staged) &&
        unlinkat(location.dir, name, 0) < 0 && !error)
      error = "cannot remove the staged Antigravity MCP config";
    close(staged);
  }
  close_config(&final);
  close_config(&current);
  if (location.dir >= 0) close(location.dir);
  return error ? config_error(error) : lean_io_result_mk_ok(lean_box(0));
}

#endif
