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
#      --sysconfdir=$PREFIX/glibc/etc, so it never reads /etc/resolv.conf
#   4. writes a launcher at $PREFIX/bin/opencode that clears termux-exec's
#      LD_PRELOAD, sets TMPDIR, and self-heals the interpreter patch
#   5. disables opencode's self-updater
#
# Data budget (aarch64, mobile data):
#   opencode.gz   ~98 MB   (209 MB raw, 2.14x gzip)
#   glibc         ~11 MB   (patchelf is NOT needed: CI pre-patches PT_INTERP)
#   ripgrep+git    ~9 MB   (skipped when already installed)
#   apt indexes    ~4 MB
#   ----------------------
#   ~122 MB total
#
# Usage:
#   bash install-termux.sh                    # latest CI build of this fork
#   bash install-termux.sh ./opencode         # local file (raw or .gz)
#   bash install-termux.sh https://...        # any URL (raw or .gz)
#   bash install-termux.sh --dir ~/apps/oc ./opencode
#   bash install-termux.sh --diag             # only check the environment, install nothing
#
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
: "${HOME:=/data/data/com.termux/files/home}"

DEFAULT_URL="https://github.com/mahimmazidul/opencode/releases/download/termux-build/opencode.gz"

INSTALL_DIR="$HOME/.local/share/opencode-termux"
BIN="$INSTALL_DIR/opencode"
BACKUP="$INSTALL_DIR/opencode.previous"
STAMP="$INSTALL_DIR/.interp.stamp"
LAUNCHER="$PREFIX/bin/opencode"
GLIBC="$PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"
GLIBC_RESOLV="$GLIBC/etc/resolv.conf"
GLIBC_LIST="$PREFIX/etc/apt/sources.list.d/glibc.list"
SOURCE=""
DIAG=0

say()  { printf '\033[1;36m[opencode-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[opencode-termux]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[opencode-termux] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
mb()   { du -b "$1" 2>/dev/null | awk '{printf "%.1f MB", $1/1000000}'; }
have() { command -v "$1" >/dev/null 2>&1; }
apt_has() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9]'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Runs a package-manager command with its output STREAMED (so a multi-minute
# download never looks like a hang) while keeping a log for the failure case.
pm() {
  local tag="$1"; shift
  local log="$TMP/pm-$tag.log"
  local rc=0
  set +e
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    warn "failed (exit $rc): $*"
    tail -n 12 "$log" | sed 's/^/    /' >&2
    return "$rc"
  fi
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) shift; INSTALL_DIR="${1:?--dir needs a value}"
           BIN="$INSTALL_DIR/opencode"; BACKUP="$INSTALL_DIR/opencode.previous"
           STAMP="$INSTALL_DIR/.interp.stamp" ;;
    --diag) DIAG=1 ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SOURCE" ] && SOURCE="$1" || die "only one binary may be given" ;;
  esac
  shift
done

# ---------------------------------------------------------------- sanity ----
have pkg || die "this script must run inside Termux"

# ------------------------------------------------------------- diagnostics --
print_diag() {
  echo
  say "diagnostics"
  echo "  termux prefix : $PREFIX"
  echo "  arch          : $(uname -m)"
  echo "  termux version: ${TERMUX_VERSION:-unknown}"
  echo "  glibc loader  : $([ -f "$LOADER" ] && echo present || echo MISSING)"
  echo "  patchelf      : $(have patchelf && patchelf --version 2>/dev/null || ([ -x "$GLIBC/bin/patchelf" ] && echo "$GLIBC/bin/patchelf (unrunnable until LD_* cleared)" || echo missing))"
  echo "  LD_PRELOAD    : ${LD_PRELOAD:-<unset>}"
  echo "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-<unset>}"
  echo "  glibc pkg     : $(apt-cache policy glibc 2>/dev/null | awk '/Candidate/{print $2}')"
  echo "  glibc repo    : $([ -f "$GLIBC_LIST" ] && echo "configured ($(grep -c '^deb' "$GLIBC_LIST") lines)" || echo "NOT configured")"
  if [ -f "$GLIBC_LIST" ]; then sed 's/^/                  /' "$GLIBC_LIST"; fi
  echo "  resolv.conf   : $([ -s "$GLIBC_RESOLV" ] && head -n1 "$GLIBC_RESOLV" || echo missing)"
  echo "  free space    : $(df -h "$HOME" | awk 'NR==2{print $4}')"
  echo
}

if [ "$DIAG" = 1 ]; then print_diag; exit 0; fi

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "Termux aarch64 only (uname -m = $(uname -m))" ;;
esac

# ------------------------------------------------------------ glibc layer ---
# glibc + patchelf-glibc pull ~36 MB. binutils-glibc is NOT installed: it was
# only needed to link the old DNS shim, which no longer exists.
ensure_glibc() {
  if [ -f "$LOADER" ]; then return 0; fi

  say "installing Termux glibc runtime (~36 MB)"
  say "this downloads roughly 40 MB - on mobile data it will sit here for a few minutes"
  if ! pm glibc-repo pkg install -y glibc-repo; then
    warn "could not install glibc-repo (see the error above)"
    return 1
  fi

  if ! pm update1 pkg update -y; then warn "pkg update reported errors, trying anyway"; fi

  if ! pm glibc pkg install -y glibc patchelf-glibc; then
    # Most common cause on a phone: the glibc index never loaded, because the
    # Cloudflare mirror in glibc.list is unreachable or blocked on this network.
    # The repo also publishes a non-Cloudflare endpoint; swap to it and retry.
    if [ -f "$GLIBC_LIST" ] && grep -q 'packages-cf\.termux\.dev' "$GLIBC_LIST"; then
      say "retrying with packages.termux.dev (non-Cloudflare mirror)"
      sed -i 's|^deb https://packages-cf\.termux\.dev|deb https://packages.termux.dev|' "$GLIBC_LIST"
      pm update2 pkg update -y || warn "pkg update still reporting errors"
      if pm glibc2 pkg install -y glibc patchelf-glibc; then return 0; fi
    fi
    # dpkg may have been left half-configured by an earlier interrupted install
    say "attempting dpkg --configure -a, then one final retry"
    pm configure dpkg --configure -a || true
    pm glibc3 pkg install -y glibc patchelf-glibc || return 1
  fi
  return 0
}

if ! ensure_glibc; then
  print_diag
  cat >&2 <<'HINT'
what to try, in order:
  1. termux-change-repo        # pick a mirror close to you, then re-run this script
  2. pkg upgrade               # if you are on the Play Store Termux, switch to F-Droid first
  3. pkg install -y glibc patchelf-glibc      # run it by hand to see the real error
  4. if that says "Unable to locate package glibc", the glibc repo index is not
     loading; check:  cat $PREFIX/etc/apt/sources.list.d/glibc.list
     and try:         curl -sI https://packages.termux.dev/apt/termux-glibc/dists/glibc/stable/binary-aarch64/Packages
  5. no glibc at all is needed by the bionic build - see termux/README.md "Alternatives"
HINT
  die "glibc setup failed; nothing was installed"
fi
[ -f "$LOADER" ] || die "glibc loader missing at $LOADER"

# patchelf is optional: the published artifact arrives already patched.

# ----------------------------------------------------------- dns + tools ----
# Termux's glibc reads $PREFIX/glibc/etc/resolv.conf (the path is baked into
# libc.so.6). Android has no /etc/resolv.conf at all.
if [ ! -s "$GLIBC_RESOLV" ] || ! grep -q '^nameserver' "$GLIBC_RESOLV" 2>/dev/null; then
  say "configuring DNS in $GLIBC_RESOLV"
  mkdir -p "$(dirname "$GLIBC_RESOLV")"
  {
    for p in net.dns1 net.dns2 net.dns3 net.dns4; do
      ip="$(getprop "$p" 2>/dev/null || true)"
      case "$ip" in
        ""|0.0.0.0|::1|"::") ;;
        *) printf 'nameserver %s\n' "$ip" ;;
      esac
    done
    if ! grep -q '^nameserver' "$GLIBC_RESOLV" 2>/dev/null; then
      printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
    fi
  } >> "$GLIBC_RESOLV"
fi

have rg  || { say "installing ripgrep (~1 MB)";  pm rg  pkg install -y ripgrep || warn "ripgrep install failed"; }
have git || { say "installing git (~8 MB)";      pm git pkg install -y git     || warn "git install failed"; }
have gzip || pm gz pkg install -y gzip || true

# ---------------------------------------------------------------- binary ----
mkdir -p "$INSTALL_DIR"

[ -n "$SOURCE" ] || { SOURCE="$DEFAULT_URL"; say "no binary given - using the latest CI build of this fork"; }

case "$SOURCE" in
  http://*|https://*)
    say "downloading $(basename "$SOURCE")"
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar "$SOURCE" -o "$TMP/dl"; then
      die "download failed: $SOURCE"
    fi
    say "downloaded $(mb "$TMP/dl")"
    if curl -fsL --max-time 20 "$SOURCE.sha256" -o "$TMP/dl.sha256" 2>/dev/null; then
      want="$(cut -d' ' -f1 < "$TMP/dl.sha256")"
      got="$(sha256sum "$TMP/dl" | cut -d' ' -f1)"
      if [ -n "$want" ] && [ "$want" != "$got" ]; then
        die "checksum mismatch (expected $want, got $got) - refusing to install"
      fi
      say "sha256 ok"
    else
      warn "no .sha256 next to $SOURCE - skipping checksum verification"
    fi
    ;;
  *)
    [ -f "$SOURCE" ] || die "no such file: $SOURCE"
    cp "$SOURCE" "$TMP/dl"
    say "using local file ($(mb "$TMP/dl"))"
    ;;
esac

if [ "$(head -c 2 "$TMP/dl" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
  say "decompressing"
  gzip -dc "$TMP/dl" > "$TMP/opencode" || die "gunzip failed"
  rm -f "$TMP/dl"
else
  mv "$TMP/dl" "$TMP/opencode"
fi

head -c 4 "$TMP/opencode" | od -An -tx1 | grep -q "7f 45 4c 46" || die "not an ELF file"
MACHINE="$(od -An -tx1 -j18 -N2 "$TMP/opencode" | tr -d ' \n')"
[ "$MACHINE" = "b700" ] || die "not an aarch64 binary (e_machine=$MACHINE)"

chmod +x "$TMP/opencode"

# The release artifact is already patched in CI (PT_INTERP ->
# $PREFIX/glibc/lib/ld-linux-aarch64.so.1), so normally there is nothing to do.
# Only a locally built binary, or a different Termux prefix, needs this.
patch_interp() {
  local bin="$1"
  if grep -aqF -- "$LOADER" "$bin"; then
    say "interpreter already points at Termux glibc - no patchelf needed"
    return 0
  fi
  say "patching ELF interpreter -> $LOADER"
  local -a cands=()
  [ -x "$GLIBC/bin/patchelf" ] && cands+=("$GLIBC/bin/patchelf")
  local p; p="$(command -v patchelf || true)"
  [ -n "$p" ] && [ "$p" != "$GLIBC/bin/patchelf" ] && cands+=("$p")
  have grun && cands+=("grun patchelf")
  if [ ${#cands[@]} -eq 0 ]; then
    warn "no patchelf found; installing glibc-runner (it provides 'grun patchelf')"
    pm runner pkg install -y glibc-runner || true
    have grun && cands+=("grun patchelf")
  fi
  [ ${#cands[@]} -gt 0 ] || die "patchelf unavailable - pkg install glibc-runner, or use the pre-patched release"

  local c
  for c in "${cands[@]}"; do
    # LD_PRELOAD / LD_LIBRARY_PATH must be cleared: termux-exec's bionic
    # preload and any exported glibc path make glibc binaries fail with
    # "libc.so: invalid ELF header" - that is the usual patchelf failure.
    if env -u LD_PRELOAD -u LD_LIBRARY_PATH $c --set-interpreter "$LOADER" "$bin" 2>"$TMP/patch.err"; then
      if grep -aqF -- "$LOADER" "$bin"; then
        say "patched with $c"
        return 0
      fi
      warn "$c exited 0 but the interpreter did not change"
      continue
    fi
    warn "$c failed: $(head -n1 "$TMP/patch.err" 2>/dev/null)"
  done
  warn "LD_PRELOAD=${LD_PRELOAD:-<unset>}  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
  die "could not patch the interpreter"
}

patch_interp "$TMP/opencode"

# ------------------------------------------------------------- install ------
say "verifying with Termux glibc"
if ! env -u LD_PRELOAD -u LD_LIBRARY_PATH TMPDIR="$PREFIX/tmp" \
      "$TMP/opencode" --version >"$TMP/ver" 2>"$TMP/err"; then
  warn "opencode --version failed:"
  sed 's/^/    /' "$TMP/err" >&2 || true
  print_diag
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
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
DIR="$HOME_DIR/.local/share/opencode-termux"
BIN="$DIR/opencode"
STAMP="$DIR/.interp.stamp"
GLIBC="$PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"

unset LD_PRELOAD
unset LD_LIBRARY_PATH

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
  // interpreter, which does not exist on Android.
  "update": "disable",
  // Language servers cost 300-500 MB each.
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
