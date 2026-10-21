#!/data/data/com.termux/files/usr/bin/bash
#
# install-termux.sh — install the self-contained opencode linux/arm64 build on Termux
#
# Turns the single-file `opencode` binary produced by
# .github/workflows/build-termux.yml (a Bun standalone compiled for linux/arm64)
# into something that actually runs on Android:
#
#   1. installs Termux's glibc runtime (glibc-repo) — Android's bionic cannot run it
#   2. rewrites the ELF PT_INTERP to $PREFIX/glibc/lib/ld-linux-aarch64.so.1
#   3. writes $PREFIX/glibc/etc/resolv.conf — Termux's glibc is built with
#      --sysconfdir=$PREFIX/glibc/etc, so it never looks at /etc/resolv.conf
#      (this replaces the old LD_PRELOAD shim, and its clang build dependency,
#      saving ~86 MB of downloads)
#   4. writes a launcher at $PREFIX/bin/opencode that clears termux-exec's
#      LD_PRELOAD, sets TMPDIR, and self-heals the interpreter patch
#   5. disables opencode's self-updater (it would install a binary Android
#      cannot exec)
#
# Data budget (mobile data, aarch64):
#   opencode.gz  ~98 MB   (209 MB raw, 2.1x gzip)
#   glibc+patchelf ~36 MB
#   ripgrep+git   ~9 MB  (skipped if already installed)
#   apt indexes   ~4 MB
#   ----------------------
#   ~147 MB total, versus ~361 MB for the old shim-based installer.
#
# Usage:
#   bash install-termux.sh                    # latest CI build of this fork
#   bash install-termux.sh ./opencode         # local file (raw or .gz)
#   bash install-termux.sh https://...        # any URL (raw or .gz)
#   bash install-termux.sh --dir ~/apps/oc ./opencode
#
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
: "${HOME:=/data/data/com.termux/files/home}"

# Rolling release published by .github/workflows/build-termux.yml
DEFAULT_URL="https://github.com/mahimmazidul/opencode/releases/download/termux-build/opencode.gz"

INSTALL_DIR="$HOME/.local/share/opencode-termux"
BIN="$INSTALL_DIR/opencode"
BACKUP="$INSTALL_DIR/opencode.previous"
STAMP="$INSTALL_DIR/.interp.stamp"
LAUNCHER="$PREFIX/bin/opencode"
GLIBC="$PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"
GLIBC_RESOLV="$GLIBC/etc/resolv.conf"
SOURCE=""

say()  { printf '\033[1;36m[opencode-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[opencode-termux]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[opencode-termux] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
mb()   { du -b "$1" 2>/dev/null | awk '{printf "%.1f MB", $1/1000000}'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) shift; INSTALL_DIR="${1:?--dir needs a value}"
           BIN="$INSTALL_DIR/opencode"; BACKUP="$INSTALL_DIR/opencode.previous"
           STAMP="$INSTALL_DIR/.interp.stamp" ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SOURCE" ] && SOURCE="$1" || die "only one binary may be given" ;;
  esac
  shift
done

[ -n "$SOURCE" ] || { SOURCE="$DEFAULT_URL"; say "no binary given - using the latest CI build of this fork"; }

# ---------------------------------------------------------------- sanity ----
command -v pkg >/dev/null 2>&1 || die "this script must run inside Termux"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "Termux aarch64 only (uname -m = $(uname -m))" ;;
esac

# ------------------------------------------------------------ glibc layer ---
# glibc + patchelf-glibc pull ~36 MB. binutils-glibc is NOT installed: it is
# only needed to link the old DNS shim, which is gone.
if [ ! -f "$LOADER" ] || ! command -v patchelf >/dev/null 2>&1; then
  say "installing Termux glibc runtime (~36 MB)"
  pkg install -y glibc-repo >/dev/null 2>&1 || die "failed to install glibc-repo"
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y glibc patchelf-glibc >/dev/null 2>&1 \
    || die "failed to install glibc / patchelf-glibc"
fi
[ -f "$LOADER" ] || die "glibc loader missing at $LOADER"

PATCHELF="$(command -v patchelf || true)"
[ -x "$PATCHELF" ] || PATCHELF="$GLIBC/bin/patchelf"
[ -x "$PATCHELF" ] || die "patchelf not found (pkg install patchelf-glibc)"

# ----------------------------------------------------------- dns + tools ----
# Termux's glibc reads $PREFIX/glibc/etc/resolv.conf (verified: the path is
# baked into libc.so.6). Android has no /etc/resolv.conf at all.
if [ ! -s "$GLIBC_RESOLV" ] || ! grep -q '^nameserver' "$GLIBC_RESOLV" 2>/dev/null; then
  say "configuring DNS in $GLIBC_RESOLV"
  mkdir -p "$(dirname "$GLIBC_RESOLV")"
  {
    # Prefer the carrier/network resolver Android already knows about;
    # some mobile networks block third-party DNS.
    for p in net.dns1 net.dns2 net.dns3 net.dns4; do
      ip="$(getprop "$p" 2>/dev/null || true)"
      case "$ip" in
        ""|0.0.0.0|::1|"::"|"") ;;
        *) printf 'nameserver %s\n' "$ip" ;;
      esac
    done
    if ! grep -q '^nameserver' "$GLIBC_RESOLV" 2>/dev/null; then
      printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
    fi
  } >> "$GLIBC_RESOLV"
fi

# ripgrep powers the grep/glob tools; git powers change tracking.
# Both are tiny (~9 MB together) and skipped when present.
command -v rg >/dev/null 2>&1 || { say "installing ripgrep (~1 MB)"; pkg install -y ripgrep >/dev/null 2>&1 || warn "ripgrep install failed"; }
command -v git >/dev/null 2>&1 || { say "installing git (~8 MB)"; pkg install -y git >/dev/null 2>&1 || warn "git install failed"; }
command -v gzip >/dev/null 2>&1 || pkg install -y gzip >/dev/null 2>&1 || true

# ---------------------------------------------------------------- binary ----
mkdir -p "$INSTALL_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$SOURCE" in
  http://*|https://*)
    say "downloading $(basename "$SOURCE")"
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar "$SOURCE" -o "$TMP/dl"; then
      die "download failed: $SOURCE"
    fi
    say "downloaded $(mb "$TMP/dl")"
    # verify against <url>.sha256 when the release publishes one
    if curl -fsL --max-time 20 "$SOURCE.sha256" -o "$TMP/dl.sha256" 2>/dev/null; then
      want="$(cut -d' ' -f1 < "$TMP/dl.sha256")"
      got="$(sha256sum "$TMP/dl" | cut -d' ' -f1)"
      if [ -n "$want" ] && [ "$want" != "$got" ]; then
        die "checksum mismatch (expected $want, got $got) - refusing to install"
      fi
      say "sha256 ok"
    else
      warn "no .sha256 published next to $SOURCE - skipping checksum verification"
    fi
    ;;
  *)
    [ -f "$SOURCE" ] || die "no such file: $SOURCE"
    cp "$SOURCE" "$TMP/dl"
    say "using local file ($(mb "$TMP/dl"))"
    ;;
esac

# .gz transparently (the release ships a gzipped binary: 98 MB instead of 209 MB)
if [ "$(head -c 2 "$TMP/dl" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
  say "decompressing"
  gzip -dc "$TMP/dl" > "$TMP/opencode" || die "gunzip failed"
  rm -f "$TMP/dl"
else
  mv "$TMP/dl" "$TMP/opencode"
fi

# sanity: ELF magic + aarch64 e_machine, so a wrong artifact fails early
head -c 4 "$TMP/opencode" | od -An -tx1 | grep -q "7f 45 4c 46" || die "not an ELF file"
MACHINE="$(od -An -tx1 -j18 -N2 "$TMP/opencode" | tr -d ' \n')"
[ "$MACHINE" = "b700" ] || die "not an aarch64 binary (e_machine=$MACHINE)"

say "patching ELF interpreter -> $LOADER"
chmod +x "$TMP/opencode"
"$PATCHELF" --set-interpreter "$LOADER" "$TMP/opencode" || die "patchelf failed"

# ------------------------------------------------------------- install ------
say "verifying with Termux glibc"
if ! env -u LD_PRELOAD -u LD_LIBRARY_PATH TMPDIR="$PREFIX/tmp" \
      "$TMP/opencode" --version >"$TMP/ver" 2>"$TMP/err"; then
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

exec "$BIN" "$@"
LAUNCH
chmod 755 "$LAUNCHER"

# --------------------------------------------------------------- config -----
mkdir -p "$HOME/.config/opencode"
CFG="$HOME/.config/opencode/opencode.jsonc"
if [ ! -f "$CFG" ]; then
  say "writing $CFG (updater disabled, LSP off to save RAM)"
  cat > "$CFG" <<'EOF'
{
  // Termux: the official updater downloads a glibc binary with the stock ELF
  // interpreter, which does not exist on Android. Update by re-running
  // install-termux.sh with a freshly built binary instead.
  "update": "disable",
  // Language servers cost 300-500 MB each. Set true if you need them and have
  // the RAM; `pkg install nodejs` is required for most.
  "lsp": false
}
EOF
else
  grep -q '"update"' "$CFG" 2>/dev/null || warn "add \"update\": \"disable\" to $CFG"
fi

# --------------------------------------------------------------- done -------
say "installed: $VER"
say "binary:   $BIN  ($(mb "$BIN"))"
say "launcher: $LAUNCHER"
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) warn "\$PREFIX/bin is not on PATH" ;; esac
say "run: opencode"
