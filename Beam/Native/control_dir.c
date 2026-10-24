/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
*/

#include <lean/lean.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#if !defined(_WIN32)
#include <unistd.h>
#endif

/* Kept private to Beam.System: mode is meaningful only for PRIVATE_POSIX_MODE. */
enum private_dir_kind {
  PRIVATE_ABSENT, PRIVATE_DIRECTORY, PRIVATE_LINK, PRIVATE_NOT_DIRECTORY,
  PRIVATE_POSIX_MODE, PRIVATE_WINDOWS_DACL, PRIVATE_POSIX_OWNER
};

static lean_obj_res observation(enum private_dir_kind kind, uint32_t mode) {
  lean_object *result = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(result, 0, lean_box(kind));
  lean_ctor_set(result, 1, lean_box_uint32(mode));
  return lean_io_result_mk_ok(result);
}

static int valid_path(b_lean_obj_arg path) {
  return strlen(lean_string_cstr(path)) == lean_string_size(path) - 1;
}

static lean_obj_res path_error(int error, b_lean_obj_arg path) {
  return lean_io_result_mk_error(lean_decode_io_error(error, path));
}

#if defined(_WIN32)
/* Lean provides a minimal windows.h for generated C. Import native APIs explicitly. */
#include <windef.h>
#include <winbase.h>
#include <fileapi.h>
#include <handleapi.h>
#include <processthreadsapi.h>
#include <errhandlingapi.h>
#include <securitybaseapi.h>
#include <stringapiset.h>
#include <winnls.h>
#include <aclapi.h>

static int missing_path(DWORD error) {
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

static lean_obj_res windows_error(DWORD error, b_lean_obj_arg path) {
  lean_inc(path);
  lean_object *message = lean_mk_string("Beam exact-leaf filesystem operation");
  if (missing_path(error))
    return lean_io_result_mk_error(lean_mk_io_error_no_file_or_directory(path, error, message));
  if (error == ERROR_ACCESS_DENIED)
    return lean_io_result_mk_error(lean_mk_io_error_permission_denied_file(path, error, message));
  lean_dec(path);
  return lean_io_result_mk_error(lean_mk_io_error_other_error(error, message));
}

static DWORD wide_path(b_lean_obj_arg path, WCHAR **result) {
  const char *utf8 = lean_string_cstr(path);
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
  if (!size) return GetLastError();
  WCHAR *wide = malloc((size_t)size * sizeof(WCHAR));
  if (!wide) return ERROR_NOT_ENOUGH_MEMORY;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide, size)) {
    DWORD error = GetLastError();
    free(wide);
    return error;
  }
  *result = wide;
  return ERROR_SUCCESS;
}

/* One handle identifies the exact leaf throughout attribute and DACL observation. */
static DWORD open_path_no_follow(b_lean_obj_arg path, DWORD access, HANDLE *result) {
  WCHAR *wide = NULL;
  DWORD error = wide_path(path, &wide);
  if (error != ERROR_SUCCESS) return error;
  HANDLE handle = CreateFileW(wide, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  error = handle == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  free(wide);
  *result = handle;
  return error;
}

static DWORD current_user(TOKEN_USER **result) {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return GetLastError();
  DWORD size = 0;
  BOOL success = GetTokenInformation(token, TokenUser, NULL, 0, &size);
  DWORD error = success ? ERROR_INVALID_DATA : GetLastError();
  TOKEN_USER *user = NULL;
  if (error == ERROR_INSUFFICIENT_BUFFER && size) {
    user = malloc(size);
    if (!user) error = ERROR_NOT_ENOUGH_MEMORY;
    else error = GetTokenInformation(token, TokenUser, user, size, &size)
      ? ERROR_SUCCESS : GetLastError();
  }
  CloseHandle(token);
  if (error != ERROR_SUCCESS) free(user);
  else *result = user;
  return error;
}

/* Accept a simple allow-only DACL, not an approximation of arbitrary effective access. */
static DWORD private_directory(HANDLE handle, TOKEN_USER *user, BOOL *result) {
  PSID owner = NULL;
  PACL acl = NULL;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  DWORD error = GetSecurityInfo(handle, SE_FILE_OBJECT,
    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
    &owner, NULL, &acl, NULL, &descriptor);
  if (error != ERROR_SUCCESS) return error;
  BOOL private = owner && EqualSid(owner, user->User.Sid) && acl && IsValidAcl(acl);
  BOOL user_access = FALSE;
  for (DWORD i = 0; private && i < acl->AceCount; ++i) {
    ACE_HEADER *header;
    if (!GetAce(acl, i, (void **)&header)) { error = GetLastError(); break; }
    /* Deny, object and callback entries require an effective-access evaluator; reject them. */
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) { private = FALSE; break; }
    ACCESS_ALLOWED_ACE *ace = (ACCESS_ALLOWED_ACE *)header;
    PSID sid = &ace->SidStart;
    if (!EqualSid(sid, user->User.Sid) && !IsWellKnownSid(sid, WinLocalSystemSid) &&
        !IsWellKnownSid(sid, WinBuiltinAdministratorsSid)) {
      if (ace->Mask) private = FALSE;
    } else if (EqualSid(sid, user->User.Sid) && !(header->AceFlags & INHERIT_ONLY_ACE)) {
      user_access = user_access || (ace->Mask & GENERIC_ALL) ||
        ((ace->Mask & FILE_ALL_ACCESS) == FILE_ALL_ACCESS);
    }
  }
  LocalFree(descriptor);
  *result = private && user_access;
  return error;
}
#endif

/* Lean's Windows symlinkMetadata follows links. Inspect the exact leaf's tag instead. */
LEAN_EXPORT lean_obj_res lean_beam_path_is_link(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  if (!valid_path(path)) return path_error(EINVAL, path);
  int linked;
#if defined(_WIN32)
  HANDLE handle;
  DWORD error = open_path_no_follow(path, FILE_READ_ATTRIBUTES, &handle);
  if (missing_path(error)) return lean_io_result_mk_ok(lean_box(0));
  if (error != ERROR_SUCCESS) return windows_error(error, path);
  FILE_ATTRIBUTE_TAG_INFO info;
  BOOL success = GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &info, sizeof(info));
  error = success ? ERROR_SUCCESS : GetLastError();
  CloseHandle(handle);
  if (error != ERROR_SUCCESS) return windows_error(error, path);
  linked = (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
    (info.ReparseTag == IO_REPARSE_TAG_SYMLINK || info.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT);
#else
  struct stat status;
  if (lstat(lean_string_cstr(path), &status) != 0) {
    if (errno == ENOENT) return lean_io_result_mk_ok(lean_box(0));
    return path_error(errno, path);
  }
  linked = S_ISLNK(status.st_mode);
#endif
  return lean_io_result_mk_ok(lean_box(linked));
}

/* Observation only: Windows ACLs are deliberately not approximated by POSIX execute bits. */
LEAN_EXPORT lean_obj_res lean_beam_file_execute_bits(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  if (!valid_path(path)) return path_error(EINVAL, path);
#if defined(_WIN32)
  return lean_io_result_mk_ok(lean_box(0));
#else
  struct stat status;
  if (lstat(lean_string_cstr(path), &status) != 0) return path_error(errno, path);
  if (!S_ISREG(status.st_mode)) return path_error(EINVAL, path);
  lean_object *result = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(result, 0, lean_box((status.st_mode & 0111) != 0));
  return lean_io_result_mk_ok(result);
#endif
}

LEAN_EXPORT lean_obj_res lean_beam_observe_private_dir(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  if (!valid_path(path)) return path_error(EINVAL, path);
#if defined(_WIN32)
  HANDLE handle;
  DWORD error = open_path_no_follow(path, READ_CONTROL | FILE_READ_ATTRIBUTES, &handle);
  if (missing_path(error)) return observation(PRIVATE_ABSENT, 0);
  if (error != ERROR_SUCCESS) return windows_error(error, path);
  enum private_dir_kind kind;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(handle, &info)) error = GetLastError();
  else if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) kind = PRIVATE_LINK;
  else if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) kind = PRIVATE_NOT_DIRECTORY;
  else {
    TOKEN_USER *user = NULL;
    error = current_user(&user);
    if (error == ERROR_SUCCESS) {
      BOOL private = FALSE;
      error = private_directory(handle, user, &private);
      kind = private ? PRIVATE_DIRECTORY : PRIVATE_WINDOWS_DACL;
    }
    free(user);
  }
  CloseHandle(handle);
  if (error != ERROR_SUCCESS) return windows_error(error, path);
  return observation(kind, 0);
#else
  struct stat status;
  if (lstat(lean_string_cstr(path), &status) != 0) {
    if (errno == ENOENT) return observation(PRIVATE_ABSENT, 0);
    return path_error(errno, path);
  }
  if (S_ISLNK(status.st_mode)) return observation(PRIVATE_LINK, 0);
  if (!S_ISDIR(status.st_mode)) return observation(PRIVATE_NOT_DIRECTORY, 0);
  if (status.st_uid != geteuid()) return observation(PRIVATE_POSIX_OWNER, 0);
  uint32_t mode = (uint32_t)(status.st_mode & 0777);
  return mode == 0700 ? observation(PRIVATE_DIRECTORY, 0) : observation(PRIVATE_POSIX_MODE, mode);
#endif
}

/* Set permissions in the creation syscall, never by reopening/chmodding a pathname. */
LEAN_EXPORT lean_obj_res lean_beam_create_private_dir(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  if (!valid_path(path)) return path_error(EINVAL, path);
#if defined(_WIN32)
  WCHAR *wide = NULL;
  TOKEN_USER *user = NULL;
  PACL acl = NULL;
  DWORD error = wide_path(path, &wide);
  if (error == ERROR_SUCCESS) error = current_user(&user);
  if (error == ERROR_SUCCESS) {
    EXPLICIT_ACCESSW access = {0};
    access.grfAccessPermissions = FILE_ALL_ACCESS;
    access.grfAccessMode = SET_ACCESS;
    access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    access.Trustee.TrusteeType = TRUSTEE_IS_USER;
    access.Trustee.ptstrName = (LPWSTR)user->User.Sid;
    error = SetEntriesInAclW(1, &access, NULL, &acl);
  }
  if (error == ERROR_SUCCESS) {
    SECURITY_DESCRIPTOR descriptor;
    if (!InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION) ||
        !SetSecurityDescriptorOwner(&descriptor, user->User.Sid, FALSE) ||
        !SetSecurityDescriptorDacl(&descriptor, TRUE, acl, FALSE) ||
        !SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED))
      error = GetLastError();
    else {
      SECURITY_ATTRIBUTES attributes = { sizeof(attributes), &descriptor, FALSE };
      if (!CreateDirectoryW(wide, &attributes)) error = GetLastError();
    }
  }
  LocalFree(acl);
  free(user);
  free(wide);
  if (error != ERROR_SUCCESS && error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS)
    return windows_error(error, path);
#else
  if (mkdir(lean_string_cstr(path), 0700) != 0 && errno != EEXIST)
    return path_error(errno, path);
#endif
  return lean_io_result_mk_ok(lean_box(0));
}
