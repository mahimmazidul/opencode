# opencode on Termux (Android aarch64)

Everything needed to run **this fork's** opencode v2 on Termux: a CI workflow that builds the binary,
and an installer that makes it run on Android.

```bash
# on the phone
pkg install -y curl
curl -fsSL https://raw.githubusercontent.com/mahimmazidul/opencode/dev/termux/install-termux.sh -o install-termux.sh
bash install-termux.sh
opencode
```

CI builds a self-contained **linux/arm64** Bun standalone and publishes it to the rolling
[`termux-build`](../../releases/tag/termux-build) release. The installer pulls it from there.

---

## Why the previous workflow failed

The old `.github/workflows/build-termux.yml` ran:

```yaml
go-version-file: go.mod
run: go build -ldflags="-s -w" -o opencode .
```

| Problem | Reality |
|---|---|
| `go.mod` | does not exist anywhere in this repo |
| `go build .` | no Go sources — opencode v2 is TypeScript on Bun; the entrypoint is `packages/cli/script/build.ts` |
| no Bun setup | the build needs Bun **1.4.2** (`packageManager` pin) plus a full `bun install` |
| no cross-target | on an x64 runner you must pass `--target=opencode-linux-arm64`, otherwise the artifact is x64 |
| wrong artifact path | the binary lands at `packages/cli/dist/cli-linux-arm64/bin/opencode`, not `./opencode` |

It failed for that reason (Actions run history: `Build for Termux (linux/arm64) — failure`).

## There is no "static build"

A Bun standalone always dynamically links a libc, so a zero-dependency binary does not exist here.
Two targets:

| Target | Result |
|---|---|
| `bun build --compile --target=bun-linux-arm64` | one ~200 MB file, glibc. **This repo's path**: runs on Termux after its ELF interpreter is pointed at Termux's glibc loader |
| `--target=bun-linux-aarch64-android` | true bionic, no glibc — but `@opentui/core` publishes no Android `.so` (checked 0.6.1→0.6.6), so the TUI cannot start without rebuilding opentui with the NDK |

That second target is what [`guysoft/opencode-termux`](https://github.com/guysoft/opencode-termux)
does (their `opencode2` package). It works and it is prebuilt, but it ships *their* build, not this
fork's code. See [Alternatives](#alternatives).

---

## Build (CI)

Automatic: any push to `dev` that touches `.github/workflows/build-termux.yml` or `termux/**` runs the
build and refreshes the `termux-build` release.

Manual: **Actions → build-termux → Run workflow** (inputs: skip the web UI for a faster build, or
skip publishing and only keep the artifact).

Steps inside the job:

- `./.github/actions/setup-bun` → Bun 1.4.2 + Node 24, `bun install --frozen-lockfile`
- `bun ./packages/cli/script/build.ts --target=opencode-linux-arm64` — the script re-installs
  `@opentui/core` and `@opencode-ai/pty` with `--os="*" --cpu="*"`, which is what puts arm64 natives
  into an x64-hosted cross build
- `BUN_COMPILE_RELEASE=bun-v1.4.2` pins the embedded runtime
- `OPENCODE_CHANNEL=termux` keeps it a preview build (no npm version lookup, no release notes)
- uploads `opencode-termux-arm64` and recreates the `termux-build` release

Expect ~25–40 min cold, most of it `bun install`.

## Install (device)

`termux/install-termux.sh` — needs Termux from **F-Droid/GitHub** (not the abandoned Play Store
build), aarch64, Android 12+ recommended.

```bash
bash install-termux.sh                     # latest termux-build release of this fork
bash install-termux.sh ./opencode          # a local file
bash install-termux.sh --skip-web-ui ...   # n/a; that's a build flag
bash install-termux.sh --no-shim ./opencode   # skip the DNS shim
bash install-termux.sh --dir ~/apps/oc ./opencode
```

What it does, and why each part is required:

1. **glibc runtime** — `pkg install glibc-repo` then `glibc patchelf-glibc binutils-glibc`. The binary
   wants `/lib/ld-linux-aarch64.so.1`, which does not exist on Android; Termux's glibc repo provides
   a loader at `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`.
2. **patchelf `--set-interpreter`** rewrites `PT_INTERP` to it. Do **not** run the binary via `grun`:
   Bun standalones find their embedded payload through `/proc/self/exe`, which under `grun` points at
   `ld.so`, so the binary exits as if it had no payload.
3. **resolver shim** — a ~10 KB `LD_PRELOAD` `.so` that maps `/etc/resolv.conf` (absent on Android) to
   `$PREFIX/etc/resolv.conf`, and clears `LD_PRELOAD`/`LD_LIBRARY_PATH` before `execve` so bionic
   children (`bash`, `git`, `rg`) don't inherit a glibc preload.
4. **launcher** at `$PREFIX/bin/opencode` — clears termux-exec's injected `LD_PRELOAD`, sets `TMPDIR`
   (Bun unpacks its OpenTUI `libopentui.so` there; Android has no `/tmp`), and re-applies the
   interpreter patch if the binary was replaced.
5. **`"update": "disable"`** in `~/.config/opencode/opencode.jsonc` — the built-in updater downloads
   the stock glibc binary, which will not start on Android. Update by re-running the installer.

Result:

```
~/.local/share/opencode-termux/opencode     # patched binary (+ opencode.previous)
$PREFIX/bin/opencode                        # launcher
$PREFIX/lib/opencode-resolvfix.so           # DNS shim
$PREFIX/etc/resolv.conf                     # dns for the glibc binary
```

## RAM

Measured on opencode v2.1.2 (peak RSS; an arm64 phone is in the same range, usually 10–20 % higher):

| What you run | Peak RSS |
|---|---|
| `opencode --version` | ~24 MB |
| `opencode serve` (headless, idle) | ~156 MB |
| `opencode` — TUI idle, no session | **~420 MB** (163 MB TUI + 256 MB `opencode serve --service` child) |
| `opencode run "..."` — one shot | ~407 MB |
| real session with LSP/MCP/tools/long context | 700 MB – 1.5 GB |

v2 is two processes: the TUI frontend spawns a separate server backend, both on JavaScriptCore. Each
LSP/MCP server or plugin is another process on top.

- 4 GB phone: fine for the TUI alone; use `termux-wake-lock` so Android doesn't freeze Termux when
  the screen locks.
- 6 GB+: comfortable.
- 3 GB: skip the TUI. Run `opencode serve --hostname 0.0.0.0 --port 4096` (~156 MB, prints a password)
  and use the web UI from another device.
- Prefer `opencode run "..."` for one-shot jobs; don't keep a huge session alive for days.

The **build** is heavier than the runtime (`bun install` peaks around 2–3 GB), which is why it runs in
CI rather than on the phone.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot execute: required file not found` | `PT_INTERP` still `/lib/ld-linux-aarch64.so.1` | re-run the installer |
| `CANNOT LINK EXECUTABLE "cat": ... bad ELF magic` | `LD_LIBRARY_PATH`/`LD_PRELOAD` exported into your shell | `unset LD_LIBRARY_PATH LD_PRELOAD`; run the launcher, never `source` it |
| starts, but no network / DNS | Android has no `/etc/resolv.conf` | installer's shim + `$PREFIX/etc/resolv.conf` |
| `Bad system call` / exit 159 at startup | Android 10/11 seccomp traps `statx`/`close_range`/`clone3` that Bun calls directly | Android 12+, or a seccomp shim (`HanSoBored/opencode-termux`, guysoft's build) |
| TUI renders garbage or monochrome | `TERM` | `export TERM=xterm-256color` |
| grep/glob tools error | `ripgrep` missing | `pkg install ripgrep` |
| broke after `opencode upgrade` | updater replaced the patched binary | keep `"update": "disable"`; launcher auto-re-patches if you forget |
| `bun install` OOM inside CI | runner memory | not expected on `ubuntu-latest`; locally it needs 2–3 GB |

## Building on the phone

Possible, unpleasant: the monorepo's `node_modules` plus a Vite/Solid build of the web UI.

```bash
# bionic Bun 1.4.x for Termux
curl -fsSL https://raw.githubusercontent.com/Hope2333/bun-termux/main/install.sh | bash

git clone --depth 1 https://github.com/mahimmazidul/opencode ~/opencode && cd ~/opencode
bun install --frozen-lockfile
BUN_COMPILE_RELEASE=bun-v1.4.2 OPENCODE_CHANNEL=termux \
  bun ./packages/cli/script/build.ts --target=opencode-linux-arm64 --skip-web-ui
bash ~/opencode/termux/install-termux.sh ./packages/cli/dist/cli-linux-arm64/bin/opencode
```

1–2 hours and ~6 GB free storage on a phone. CI is the sane path.

## Alternatives

- [`guysoft/opencode-termux`](https://github.com/guysoft/opencode-termux) — true bionic builds:
  `opencode` (v1, cross-compiled Bun+JSC) and `opencode2` (v2, official Bun 1.4.2 Android target +
  NDK-built `libopentui.so`), packaged as `.pkg.tar.xz`/`.deb`. Ships Android seccomp fixes. Lags
  upstream (v2 reports `2.0.0-android-termux.2`, OpenTUI 0.5.10 vs upstream 0.6.6) and is not this
  fork's code. It is the best blueprint if you ever want to do the bionic path here.
- [`Hope2333/opencode-termux`](https://github.com/Hope2333/opencode-termux) — native bionic, several
  package families.
- [`Lucas7X7/opencode-termux-native`](https://github.com/Lucas7X7/opencode-termux-native) — native
  bionic single ELF, no glibc.
- [`amrmrkjr/opencode-termux`](https://github.com/amrmrkjr/opencode-termux) — glibc + patchelf
  bootstrap with checksum pinning.
