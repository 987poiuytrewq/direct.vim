/* LuaJIT FFI declarations for POSIX filesystem primitives. */
typedef struct { int direct_unix_ffi_declarations_loaded; } direct_unix_ffi_declarations;

int flock(int fd, int operation);
int renamex_np(const char *from, const char *to, unsigned int flags);
int renameat2(int olddirfd, const char *oldpath, int newdirfd,
  const char *newpath, unsigned int flags);
char *strerror(int errnum);
