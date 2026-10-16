/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
*/

#include <lean/lean.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>

#if defined(_WIN32)
/* Lean provides a minimal windows.h for generated C. Import the native API headers directly. */
#include <windef.h>
#include <winbase.h>
#include <aclapi.h>

/* Use handles opened without following reparse points for both inspection and protection. */
static HANDLE open_directory(b_lean_obj_arg path, DWORD access) {
  const char *utf8 = lean_string_cstr(path);
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
  if (!size) return INVALID_HANDLE_VALUE;
  WCHAR *wide = malloc((size_t)size * sizeof(WCHAR));
  if (!wide) return INVALID_HANDLE_VALUE;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide, size);
  HANDLE handle = CreateFileW(wide, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) return handle;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(handle, &info) ||
      !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    CloseHandle(handle);
    return INVALID_HANDLE_VALUE;
  }
  return handle;
}

static TOKEN_USER *current_user(void) {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  TOKEN_USER *user = malloc(size);
  if (user && !GetTokenInformation(token, TokenUser, user, size, &size)) {
    free(user);
    user = NULL;
  }
  CloseHandle(token);
  return user;
}

static BOOL private_directory(HANDLE handle, TOKEN_USER *user) {
  PSID owner = NULL;
  PACL acl = NULL;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  if (GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, NULL, &acl, NULL, &descriptor) != ERROR_SUCCESS) return FALSE;
  BOOL private = owner && EqualSid(owner, user->User.Sid) && acl && IsValidAcl(acl);
  BOOL user_access = FALSE;
  for (DWORD i = 0; private && i < acl->AceCount; ++i) {
    ACE_HEADER *header;
    if (!GetAce(acl, i, (void **)&header)) { private = FALSE; break; }
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    /* Reject unknown/object/callback grants rather than guessing their effective access. */
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
  return private && user_access;
}

static lean_obj_res security_error(b_lean_obj_arg path) {
  return lean_io_result_mk_error(lean_decode_io_error(EACCES, path));
}
#endif

LEAN_EXPORT lean_obj_res lean_beam_lstat_mode(
    b_lean_obj_arg path,
    lean_obj_arg world) {
  (void)world;
#if defined(_WIN32)
  HANDLE handle = open_directory(path, READ_CONTROL);
  TOKEN_USER *user = current_user();
  if (handle == INVALID_HANDLE_VALUE || !user) {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    free(user);
    return security_error(path);
  }
  uint32_t mode = private_directory(handle, user) ? 0700 : 0777;
  CloseHandle(handle);
  free(user);
  return lean_io_result_mk_ok(lean_box_uint32(mode));
#else
  struct stat status;
  if (lstat(lean_string_cstr(path), &status) != 0) {
    return lean_io_result_mk_error(lean_decode_io_error(errno, path));
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)(status.st_mode & 0777)));
#endif
}

LEAN_EXPORT lean_obj_res lean_beam_set_private_dir_rights(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
#if defined(_WIN32)
  HANDLE handle = open_directory(path, READ_CONTROL | WRITE_DAC | WRITE_OWNER);
  TOKEN_USER *user = current_user();
  if (handle == INVALID_HANDLE_VALUE || !user) {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    free(user);
    return security_error(path);
  }
  EXPLICIT_ACCESSW access = {0};
  access.grfAccessPermissions = FILE_ALL_ACCESS;
  access.grfAccessMode = SET_ACCESS;
  access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  access.Trustee.TrusteeType = TRUSTEE_IS_USER;
  access.Trustee.ptstrName = (LPWSTR)user->User.Sid;
  PACL acl = NULL;
  DWORD result = SetEntriesInAclW(1, &access, NULL, &acl);
  if (result == ERROR_SUCCESS) {
    result = SetSecurityInfo(handle, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      user->User.Sid, NULL, acl, NULL);
  }
  LocalFree(acl);
  CloseHandle(handle);
  free(user);
  if (result != ERROR_SUCCESS) return security_error(path);
#else
  if (chmod(lean_string_cstr(path), 0700) != 0)
    return lean_io_result_mk_error(lean_decode_io_error(errno, path));
#endif
  return lean_io_result_mk_ok(lean_box(0));
}

/* Windows runtime installations do not provide the Unix date command. */
LEAN_EXPORT lean_obj_res lean_beam_utc_timestamp(lean_obj_arg world) {
  (void)world;
  char timestamp[32];
#if defined(_WIN32)
  SYSTEMTIME now;
  GetSystemTime(&now);
  int length = snprintf(timestamp, sizeof(timestamp), "%04u-%02u-%02uT%02u:%02u:%02uZ",
    now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond);
  if (length < 0 || (size_t)length >= sizeof(timestamp)) {
#else
  time_t now = time(NULL);
  struct tm utc;
  if (now == (time_t)-1 || !gmtime_r(&now, &utc) ||
      !strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", &utc)) {
#endif
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("cannot read UTC time")));
  }
  return lean_io_result_mk_ok(lean_mk_string(timestamp));
}
