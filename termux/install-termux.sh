#!/data/data/com.termux/files/usr/bin/bash
#
# install-termux.sh — install a self-contained opencode linux/arm64 build on Termux
#
# Turns the single-file `opencode` binary produced by
# .github/workflows/build-termux.yml (a Bun standalone compiled for
# linux/arm64 + glibc) into something that actually runs on Android:
#
#   1. installs Termux's own glibc runtime (glibc-repo), used by the binary
#      instead of Android's bionic libc
#   2. rewrites the ELF PT_INTERP from /lib/ld-linux-aarch64.so.1 to
#      $PREFIX/glibc/lib/ld-linux-aarch64.so.1  (patchelf)
#   3. builds a tiny LD_PRELOAD shim so /etc/resolv.conf resolves to
#      $PREFIX/etc/resolv.conf and children don't inherit the preload
#   4. writes a launcher at $PREFIX/bin/opencode that clears termux-exec's
#      LD_PRELOAD, sets TMPDIR, and self-heals the interpreter after an
#      in-app update
#   5. disables opencode's self-updater (it would download a glibc binary
#      with the stock interpreter and break the install)
#
# Usage:
#   bash install-termux.sh                                # latest CI build of this fork
#   bash install-termux.sh ./opencode                     # local file
#   bash install-termux.sh https://.../opencode           # any URL
#   bash install-termux.sh --no-shim ./opencode           # skip DNS shim
#   bash install-termux.sh --dir ~/apps/oc ./opencode     # custom install dir
#
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
: "${HOME:=/data/data/com.termux/files/home}"

# Rolling release published by .github/workflows/build-termux.yml
DEFAULT_URL="https://github.com/mahimmazidul/opencode/releases/download/termux-build/opencode"

INSTALL_DIR="$HOME/.local/share/opencode-termux"
BIN="$INSTALL_DIR/opencode"
BACKUP="$INSTALL_DIR/opencode.previous"
STAMP="$INSTALL_DIR/.interp.stamp"
LAUNCHER="$PREFIX/bin/opencode"
SHIM="$PREFIX/lib/opencode-resolvfix.so"
RESOLV="$PREFIX/etc/resolv.conf"
GLIBC="$PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"
USE_SHIM=1
SOURCE=""

say()  { printf '\033[1;36m[opencode-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[opencode-termux]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[opencode-termux] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-shim) USE_SHIM=0 ;;
    --dir) shift; INSTALL_DIR="${1:?--dir needs a value}"; BIN="$INSTALL_DIR/opencode"
           BACKUP="$INSTALL_DIR/opencode.previous"; STAMP="$INSTALL_DIR/.interp.stamp" ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SOURCE" ] && SOURCE="$1" || die "only one binary may be given" ;;
  esac
  shift
done

if [ -z "$SOURCE" ]; then
  SOURCE="$DEFAULT_URL"
  say "no binary given - using the latest CI build of this fork"
fi

# ---------------------------------------------------------------- sanity ----
command -v pkg >/dev/null 2>&1 || die "this script must run inside Termux"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "Termux aarch64 only (uname -m = $(uname -m)). opencode publishes no armv7 build." ;;
esac

say "installing base packages"
pkg install -y curl tar ripgrep git >/dev/null 2>&1 || warn "base package install had errors (continuing)"

# ------------------------------------------------------------ glibc layer ---
if [ ! -f "$LOADER" ]; then
  say "installing Termux glibc runtime (glibc-repo)"
  pkg install -y glibc-repo >/dev/null 2>&1 || die "failed to install glibc-repo"
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y glibc patchelf-glibc binutils-glibc >/dev/null 2>&1 \
    || die "failed to install glibc / patchelf-glibc / binutils-glibc"
fi
[ -f "$LOADER" ] || die "glibc loader missing at $LOADER"

PATCHELF="$(command -v patchelf || true)"
[ -x "$PATCHELF" ] || PATCHELF="$GLIBC/bin/patchelf"
[ -x "$PATCHELF" ] || die "patchelf not found (pkg install patchelf-glibc)"

# ---------------------------------------------------------------- binary ----
mkdir -p "$INSTALL_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$SOURCE" in
  http://*|https://*)
    say "downloading $SOURCE"
    curl -fL --retry 3 --retry-delay 2 "$SOURCE" -o "$TMP/opencode" || die "download failed"
    ;;
  *)
    [ -f "$SOURCE" ] || die "no such file: $SOURCE"
    cp "$SOURCE" "$TMP/opencode"
    ;;
esac

# Bun standalone binaries end with a "---- Bun! ----" trailer; sanity-check the
# ELF magic + aarch64 machine type so a wrong artifact fails early and loudly.
head -c 4 "$TMP/opencode" | od -An -tx1 | grep -q "7f 45 4c 46" || die "not an ELF file"
MACHINE="$(od -An -tx1 -j18 -N2 "$TMP/opencode" | tr -d ' \n')"
[ "$MACHINE" = "b700" ] || die "not an aarch64 binary (e_machine=$MACHINE)"

say "patching ELF interpreter -> $LOADER"
chmod +x "$TMP/opencode"
"$PATCHELF" --set-interpreter "$LOADER" "$TMP/opencode" || die "patchelf failed"

# ----------------------------------------------------------------- shim -----
if [ "$USE_SHIM" = 1 ] && [ ! -f "$SHIM" ]; then
  if command -v clang >/dev/null 2>&1; then
    say "building DNS resolver shim"
    cat > "$TMP/fix_resolv.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/types.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_execve)(const char *, char *const[], char *const[]);

static const char *redirect(const char *p) {
  if (p && strcmp(p, "/etc/resolv.conf") == 0) return "/data/data/com.termux/files/usr/etc/resolv.conf";
  return p;
}

int open(const char *p, int f, ...) {
  mode_t m = 0;
  if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); }
  if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
  return real_open(redirect(p), f, m);
}

int open64(const char *p, int f, ...) {
  mode_t m = 0;
  if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); }
  if (!real_open64) real_open64 = dlsym(RTLD_NEXT, "open64");
  return real_open64(redirect(p), f, m);
}

int openat(int d, const char *p, int f, ...) {
  mode_t m = 0;
  if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); }
  if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
  return real_openat(d, redirect(p), f, m);
}

/* children are bionic (bash, git, rg) - a glibc preload would kill them */
int execve(const char *p, char *const argv[], char *const envp[]) {
  if (!real_execve) real_execve = dlsym(RTLD_NEXT, "execve");
  unsetenv("LD_PRELOAD");
  unsetenv("LD_LIBRARY_PATH");
  return real_execve(p, argv, envp);
}
EOF
    clang --target=aarch64-linux-gnu -fPIC -O2 -fno-stack-protector -c "$TMP/fix_resolv.c" -o "$TMP/fix_resolv.o" 2>/dev/null
    "$GLIBC/bin/ld" -shared -o "$TMP/libopencode-resolvfix.so" "$TMP/fix_resolv.o" \
      -L"$GLIBC/lib" -l:libc.so.6 -l:libdl.so.2 2>/dev/null \
      || { warn "shim link failed, continuing without it"; USE_SHIM=0; }
    [ "$USE_SHIM" = 1 ] && install -m 755 "$TMP/libopencode-resolvfix.so" "$SHIM"
  else
    warn "clang not installed - skipping DNS shim (pkg install clang to enable it)"
    USE_SHIM=0
  fi
elif [ ! -f "$SHIM" ]; then
  USE_SHIM=0
fi

if [ ! -s "$RESOLV" ] || ! grep -q '^nameserver' "$RESOLV" 2>/dev/null; then
  say "writing $RESOLV (Android has no /etc/resolv.conf)"
  mkdir -p "$(dirname "$RESOLV")"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RESOLV"
fi

# ------------------------------------------------------------- install ------
PRELOAD=""
[ "$USE_SHIM" = 1 ] && PRELOAD="$SHIM"

say "verifying binary with Termux glibc"
if ! env LD_PRELOAD="$PRELOAD" TMPDIR="$PREFIX/tmp" "$TMP/opencode" --version >"$TMP/ver" 2>"$TMP/err"; then
  warn "opencode --version failed:"
  sed 's/^/    /' "$TMP/err" >&2 || true
  die "binary did not start; nothing was installed"
fi
VER="$(head -n1 "$TMP/ver")"

[ -x "$BIN" ] && cp -f "$BIN" "$BACKUP"
install -m 755 "$TMP/opencode" "$BIN"
touch "$STAMP"

# ------------------------------------------------------------- launcher -----
say "writing launcher $LAUNCHER"
cat > "$LAUNCHER" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/sh
# opencode launcher - runs the linux/arm64 build through Termux's glibc loader
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
DIR="$HOME_DIR/.local/share/opencode-termux"
BIN="$DIR/opencode"
STAMP="$DIR/.interp.stamp"
GLIBC="$PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"
SHIM="$PREFIX/lib/opencode-resolvfix.so"

# termux-exec injects a bionic LD_PRELOAD that glibc cannot load
unset LD_PRELOAD
unset LD_LIBRARY_PATH

# self-heal: an in-app update replaces the binary with one that has the stock
# interpreter, which does not exist on Android
if [ -x "$BIN" ] && { [ ! -f "$STAMP" ] || [ "$BIN" -nt "$STAMP" ]; }; then
  if [ -x "$GLIBC/bin/patchelf" ]; then
    "$GLIBC/bin/patchelf" --set-interpreter "$LOADER" "$BIN" 2>/dev/null || :
  elif command -v patchelf >/dev/null 2>&1; then
    patchelf --set-interpreter "$LOADER" "$BIN" 2>/dev/null || :
  fi
  touch "$STAMP"
fi

TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMPDIR
mkdir -p "$TMPDIR" 2>/dev/null || :

if [ -f "$SHIM" ]; then
  exec env LD_PRELOAD="$SHIM" "$BIN" "$@"
fi
exec "$BIN" "$@"
LAUNCH
chmod 755 "$LAUNCHER"

# --------------------------------------------------------------- config -----
mkdir -p "$HOME/.config/opencode"
CFG="$HOME/.config/opencode/opencode.jsonc"
if [ ! -f "$CFG" ]; then
  say "writing $CFG with the self-updater disabled"
  cat > "$CFG" <<'EOF'
{
  // Termux: the official updater downloads a glibc binary with the stock
  // ELF interpreter, which does not exist on Android. Update by re-running
  // install-termux.sh with a freshly built binary instead.
  "update": "disable"
}
EOF
else
  grep -q '"update"' "$CFG" 2>/dev/null || warn "add \"update\": \"disable\" to $CFG"
fi

# --------------------------------------------------------------- done -------
say "installed: $VER"
say "binary:   $BIN"
say "launcher: $LAUNCHER"
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) warn "\$PREFIX/bin is not on PATH" ;; esac
say "run: opencode"
