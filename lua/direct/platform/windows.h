/* LuaJIT FFI declarations for the Win32 filesystem APIs used by Direct. */
typedef unsigned short direct_platform_WCHAR;
typedef void *direct_platform_HANDLE;
typedef unsigned long direct_platform_DWORD;
typedef int direct_platform_BOOL;
typedef struct { direct_platform_DWORD low, high; } direct_platform_FILETIME;
typedef struct {
  direct_platform_DWORD attributes;
  direct_platform_FILETIME created, accessed, written;
  direct_platform_DWORD volume, size_high, size_low, links, index_high, index_low;
} direct_platform_FILE_INFORMATION;
typedef unsigned long long direct_platform_UINTPTR;
typedef struct {
  direct_platform_UINTPTR internal, internal_high;
  direct_platform_DWORD offset, offset_high;
  void *event;
} direct_platform_OVERLAPPED;
typedef struct { int direct_windows_ffi_declarations_loaded; } direct_windows_ffi_declarations;

int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
  const char *lpMultiByteStr, int cbMultiByte, direct_platform_WCHAR *lpWideCharStr,
  int cchWideChar);
direct_platform_HANDLE __stdcall CreateFileW(const direct_platform_WCHAR *name,
  direct_platform_DWORD access, direct_platform_DWORD share, void *security,
  direct_platform_DWORD creation, direct_platform_DWORD flags,
  direct_platform_HANDLE template_file);
direct_platform_BOOL __stdcall GetFileInformationByHandle(direct_platform_HANDLE file,
  direct_platform_FILE_INFORMATION *information);
direct_platform_BOOL __stdcall CloseHandle(direct_platform_HANDLE object);
direct_platform_BOOL __stdcall LockFileEx(direct_platform_HANDLE file,
  direct_platform_DWORD flags, direct_platform_DWORD reserved,
  direct_platform_DWORD length_low, direct_platform_DWORD length_high,
  direct_platform_OVERLAPPED *overlapped);
direct_platform_BOOL __stdcall UnlockFileEx(direct_platform_HANDLE file,
  direct_platform_DWORD reserved, direct_platform_DWORD length_low,
  direct_platform_DWORD length_high, direct_platform_OVERLAPPED *overlapped);
int __stdcall MoveFileW(const direct_platform_WCHAR *existing_name,
  const direct_platform_WCHAR *new_name);
direct_platform_DWORD __stdcall GetLastError(void);
