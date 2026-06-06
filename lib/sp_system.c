/* sp_system.c -- system()/backtick support in libspinel_rt.a.
 * See sp_system.h.
 *
 * Self-contained (libc + OS process API only); does not include
 * sp_runtime.h, so it carries its own mrb_bool/TRUE/FALSE locally to
 * avoid the mruby_shim.h mrb_bool conflict (same as sp_core.c). */
#include "sp_system.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <errno.h>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#include <sys/wait.h>
#endif

typedef int mrb_bool;
#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

int sp_last_status = 0;

#ifdef _WIN32
/* Quote a single argv element for the Windows command line, following
   the CommandLineToArgvW backslash/quote rules so spaces and embedded
   quotes survive the round-trip through _spawnvp's flat command string. */
static char *sp_win_quote_arg(const char *arg) {
  const char *p = arg;
  size_t len = 2;
  mrb_bool quote = (*p == '\0') ? TRUE : FALSE;
  while (*p) {
    if (isspace((unsigned char)*p) || *p == '"') quote = TRUE;
    if (*p == '"') {
      len += 2;
    }
    else {
      len += 1;
    }
    p++;
  }
  if (!quote) {
    char *copy = (char *)malloc(len - 1);
    if (copy) memcpy(copy, arg, len - 1);
    return copy;
  }

  p = arg;
  size_t bs = 0;
  len = 3;
  while (*p) {
    if (*p == '\\') {
      bs++;
    }
    else if (*p == '"') {
      len += bs * 2 + 2;
      bs = 0;
    }
    else {
      len += bs + 1;
      bs = 0;
    }
    p++;
  }
  len += bs * 2;

  char *out = (char *)malloc(len);
  if (!out) return NULL;
  char *q = out;
  *q++ = '"';
  p = arg;
  bs = 0;
  while (*p) {
    if (*p == '\\') {
      bs++;
    }
    else if (*p == '"') {
      while (bs > 0) {
        *q++ = '\\';
        *q++ = '\\';
        bs--;
      }
      *q++ = '\\';
      *q++ = '"';
      bs = 0;
    }
    else {
      while (bs > 0) {
        *q++ = '\\';
        bs--;
      }
      *q++ = *p;
      bs = 0;
    }
    p++;
  }
  while (bs > 0) {
    *q++ = '\\';
    *q++ = '\\';
    bs--;
  }
  *q++ = '"';
  *q = '\0';
  return out;
}
#endif

int sp_system_args(int argc, const char *const *argv) {
  if (argc <= 0 || argv == NULL || argv[0] == NULL) {
    sp_last_status = -1;
    return FALSE;
  }
  fflush(NULL);
#ifdef _WIN32
  char **quoted_argv = (char **)malloc(sizeof(char *) * (size_t)(argc + 1));
  if (!quoted_argv) {
    sp_last_status = -1;
    return FALSE;
  }
  int i = 0;
  while (i < argc) {
    if (argv[i] == NULL) {
      while (i-- > 0) free(quoted_argv[i]);
      free(quoted_argv);
      sp_last_status = -1;
      return FALSE;
    }
    quoted_argv[i] = sp_win_quote_arg(argv[i]);
    if (!quoted_argv[i]) {
      while (i-- > 0) free(quoted_argv[i]);
      free(quoted_argv);
      sp_last_status = -1;
      return FALSE;
    }
    i++;
  }
  quoted_argv[argc] = NULL;

  intptr_t rc = _spawnvp(_P_WAIT, argv[0], (const char *const *)quoted_argv);
  for (i = 0; i < argc; i++) free(quoted_argv[i]);
  free(quoted_argv);
  if (rc < 0) {
    sp_last_status = -1;
    return FALSE;
  }
  sp_last_status = (int)rc << 8;
  return rc == 0 ? TRUE : FALSE;
#else
  pid_t pid = fork();
  if (pid < 0) {
    sp_last_status = -1;
    return FALSE;
  }
  if (pid == 0) {
    execvp(argv[0], (char * const *)argv);
    _exit(127);
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno == EINTR) continue;
    sp_last_status = -1;
    return FALSE;
  }
  sp_last_status = status;
  return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? TRUE : FALSE;
#endif
}
