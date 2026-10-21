# Building `opencode` for Termux (aarch64)

Repo: <https://github.com/mahimmazidul/opencode> (fork of `anomalyco/opencode`, v2.1.2)

---

## First: there is no "static build"

opencode v2 is **TypeScript executed by Bun**, not a Go/Rust program. There is no `go build`, no
`CGO_ENABLED=0`, and no way to produce a binary with zero libc dependencies — a Bun standalone always
dynamically links a libc.

What you *can* get, and what people usually mean by "static build" here:

| | What it is | Runs on Termux? |
|---|---|---|
| `bun build --compile --target=bun-linux-arm64` | one ~200 MB self-contained file (runtime + JS + native bits embedded), linked against **glibc** | yes, after pointing its ELF interpreter at Termux's glibc |
| `bun build --compile --target=bun-linux-aarch64-android` | one file linked against **bionic** (the real Android target, exists since Bun 1.3.14) | yes natively — but opencode's native deps have no Android builds (see Route B) |

So: **Route A** below is what actually works today with the full TUI. **Route B** is the true
no-glibc build and explains exactly what still blocks it.

---

## Why the workflow in your fork doesn't work

`.github/workflows/build-termux.yml` in the fork runs `go build .`:

| Step in the fork | Problem |
|---|---|
| `go-version-file: go.mod` | there is no `go.mod` anywhere in the repo |
| `go build -ldflags="-s -w" -o opencode .` | no Go sources; the build entrypoint is `packages/cli/script/build.ts` |
| missing setup | the build needs Bun **1.4.2** (`packageManager` in `package.json`) and a full `bun install` |
| missing cross-target | building on an x64 runner needs `--target=opencode-linux-arm64`, otherwise it builds x64 |
| wrong artifact path | the binary lands at `packages/cli/dist/cli-linux-arm64/bin/opencode`, not `./opencode` |

That's all fixable. The replacement workflow is in `build-termux.yml`.

---

## Route A — cross-compile in CI, patch on the device (recommended)

### 1. Install the workflow

```bash
cd ~/opencode
rm -f .github/workflows/build-termux.yml          # the broken go build one
cp /path/to/build-termux.yml .github/workflows/build-termux.yml
git add .github/workflows/build-termux.yml
git commit -m "ci: real Termux build"
git push
```

### 2. Run it

GitHub → **Actions → build-termux → Run workflow**.
Expect ~20–35 min (≈10 min of it is `bun install`). It produces the artifact
**`opencode-termux-arm64`**.

What the workflow does, in one line each:

- `./.github/actions/setup-bun` → installs Bun 1.4.2 + Node 24 and runs `bun install --frozen-lockfile`
- `bun packages/cli/script/build.ts --target=opencode-linux-arm64` → Bun cross-compiles; the script
  itself runs `bun install --os="*" --cpu="*"` so the **arm64** builds of `@opentui/core` and
  `@opencode-ai/pty` get embedded (without this the cross build silently ships x64 natives)
- `BUN_COMPILE_RELEASE=bun-v1.4.2` → pins the exact Bun runtime that gets baked in
- `OPENCODE_CHANNEL=termux` → keeps it a preview build: no npm version lookup, no release notes
- add `--skip-web-ui` if you only care about the TUI (`opencode web` then serves nothing) — saves several minutes

Download it (CLI or browser):

```bash
gh run download --name opencode-termux-arm64 --dir ~/storage/downloads
unzip ~/storage/downloads/opencode          # if it arrived zipped
```

### 3. Install on the phone

Copy the binary to the phone, then run the installer from this folder:

```bash
bash install-termux.sh ~/storage/downloads/opencode
```

Or straight from a URL (e.g. a GitHub release you uploaded it to):

```bash
bash install-termux.sh https://github.com/you/opencode/releases/download/v-termux/opencode
```

The installer does five things, all of which are mandatory — that is why
"just copy the binary to `$PREFIX/bin`" never works:

1. `pkg install glibc-repo` → `glibc patchelf-glibc binutils-glibc`. The binary wants
   `/lib/ld-linux-aarch64.so.1`, which does not exist on Android; Termux's glibc repo provides a
   loader at `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`.
2. `patchelf --set-interpreter` rewrites `PT_INTERP` to that path. (Do **not** instead run
   `grun ./opencode`: Bun standalones locate their embedded payload via `/proc/self/exe`, which under
   `grun` points at `ld.so`, so the binary exits as if it had no payload.)
3. Writes `$PREFIX/glibc/etc/resolv.conf`, the only resolver path this glibc reads — Android has no
   `/etc/resolv.conf`, so without it every API call fails. (The old `LD_PRELOAD` shim did this, at the
   cost of an 86 MB `clang` install; see the data-cost section.)
4. Writes `$PREFIX/bin/opencode` that clears termux-exec's `LD_PRELOAD`, sets `TMPDIR` (Bun unpacks
   its OpenTUI `libopentui.so` there; Android has no `/tmp`), and re-applies the interpreter patch if
   the binary was replaced.
5. Sets `"update": "disable"` in `~/.config/opencode/opencode.jsonc` — opencode's updater downloads the
   stock glibc binary, which will not start.

### 4. Run

```bash
opencode            # TUI
opencode --version
opencode upgrade    # don't - the updater is disabled on purpose; rebuild + reinstall instead
```

Requirements: Termux from **F-Droid/GitHub** (not the abandoned Play Store build), `aarch64`,
Android 12+ recommended.

---

## Data cost on mobile (aarch64)

Everything below is measured from the real repositories and the real artifact, not estimated.

| Item | Download |
|---|---|
| `opencode.gz` — the app, gzipped (209.6 MB raw) | **98.1 MB** |
| Termux `glibc` + `patchelf-glibc` + deps (incl. `gcc-libs-glibc` 24.3 MB) | **35.5 MB** |
| `ripgrep` + `git` + deps (skipped if you already have them) | **9.0 MB** |
| apt index refresh (`pkg update`, main + glibc repos) | **~4 MB** |
| **Total, first install** | **≈ 147 MB** |
| Subsequent rebuild/reinstall (everything already present) | **≈ 98 MB** |

What it used to cost, and why it changed:

| Old flow | Now |
|---|---|
| raw 209.6 MB binary | 98.1 MB gzipped (2.14×, saves 111 MB) |
| `clang` for building the DNS shim: **86.2 MB** of packages | **0** — the shim is gone |
| `binutils-glibc` for linking that shim: 18.6 MB extra in the glibc pull | dropped |
| **≈ 361 MB** | **≈ 147 MB** |

The shim could be dropped because Termux's `glibc` is built with
`--sysconfdir=$PREFIX/glibc/etc`: `strings libc.so.6` shows it reads
`/data/data/com.termux/files/usr/glibc/etc/resolv.conf`, never `/etc/resolv.conf`. The installer now
just writes that file (using Android's own DNS from `getprop net.dns1..4`, falling back to 1.1.1.1),
so no C compiler is involved anywhere.

Ways to spend even less data:

- Install `ripgrep` and `git` beforehand (or skip `git` if you do not need change tracking) — saves up to 9 MB.
- Re-runs only download the ~98 MB binary; the glibc layer is cached on the device.
- If you have Wi-Fi anywhere, do the first install there and only the binary updates will cost ~98 MB later.
- The binary is a single file: you can also download `opencode.gz` on another machine and
  `bash install-termux.sh /path/to/opencode.gz`, which skips nothing but lets you use a cheaper link.

## RAM: what is actually using it

**No model runs on your phone.** opencode is a client: it sends your prompt to Google/Anthropic/OpenAI
over HTTPS and receives text back. The model weights (hundreds of GB) live on their servers. When
"running a model" it is not the model eating your RAM, it is the program around it.

Measured peak RSS, unauthenticated first screen, same machine, same method (sum of the whole process
tree):

| CLI | Version | Peak tree RSS | Processes |
|---|---|---|---|
| `claude` (Claude Code) | 2.1.197 | **287 MB** (settles to 169 MB) | 1 |
| `gemini` (Gemini CLI) | 0.65.0 | **357 MB** (136 MB + 221 MB) | 2 |
| `opencode` (v2) | 2.1.2 | **420 MB** (163 MB + 256 MB) | 2 |

So: opencode uses ~1.2–1.5× what Gemini CLI uses, not 10×. They are all the same kind of program —
a JS runtime + a terminal UI — and Gemini CLI is not the lightweight option people assume (its own
`--help` path peaks at 309 MB; bare `node -e 0` is 18 MB, so ~290 MB is the CLI itself).

Where the memory goes, in rough order:

1. **The JS runtime** (JavaScriptCore in opencode, V8 in the Node-based ones) — JIT code, heap, baseline
   ~150–200 MB before you do anything.
2. **The TUI + its renderer.** opencode v2 splits into two processes: the TUI frontend and an
   `opencode serve --service` backend, ~256 MB of the 420 MB is the backend.
3. **LSP servers** — the quiet killer. `typescript-language-server` alone sits at 300–500 MB, and
   there is one per language in play. This is usually why a "420 MB" tool becomes 1.2 GB.
4. **MCP servers** — each one is a separate Node process, 50–200 MB each.
5. **Session/context** — message history, file contents read by tools, tool output. Grows with the
   conversation; auto-compaction keeps it bounded.

Measured opencode modes for reference: `--version` 24 MB · `serve` headless 156 MB · TUI idle 420 MB ·
`run "..."` one-shot 407 MB.

### Turn the expensive parts off

Drop `opencode.jsonc` from this folder into `~/.config/opencode/opencode.jsonc`. Every key in it is
valid against the official v2 schema. The two that matter most:

```jsonc
{
  "lsp": false,                 // saves 300-500 MB per language server
  "mcp": { "servers": {} },     // each server is another process
  "tool_output": { "max_lines": 1000, "max_bytes": 65536 },
  "warming": false,
  "update": "disable"
}
```

Phone rules of thumb:

- **4 GB** — fine for the TUI alone, with `"lsp": false`. Use `termux-wake-lock` so Android does not
  freeze Termux when the screen locks.
- **6 GB+** — comfortable, LSP can stay on.
- **3 GB or less** — skip the TUI: `opencode serve --hostname 0.0.0.0 --port 4096` (~156 MB, prints a
  password) and drive it from the web UI on another device.
- Prefer `opencode run "do X"` for one-shot jobs and start a fresh session per task instead of
  keeping a week-old conversation alive.
- Android's zram makes a ~400 MB process cheaper than it looks on paper, but a 500 MB LSP server plus
  a browser will still get you killed on a 4 GB phone.

The *build* is heavier than the runtime: `bun install` peaks around 2–3 GB, which is why it runs in CI
and not on the phone.

---|---|
| `opencode --version` | ~24 MB |
| `opencode serve` (headless, idle) | ~156 MB |
| `opencode` — TUI, idle, no session | **~420 MB** (163 MB TUI frontend + 256 MB `opencode serve --service` child) |
| `opencode run "..."` — one-shot, one reply | ~407 MB |
| real session with LSP servers, shell tools, long context | 700 MB – 1.5 GB |

Why it is heavy: v2 is two processes — the TUI frontend spawns a separate `opencode serve --service`
backend — on top of a JavaScriptCore runtime that keeps model metadata, tool schemas and the session
state in memory. Every LSP server, MCP server and plugin it starts is another process on top.

Practical guidance for a phone:

- **4 GB total RAM** is workable for the TUI alone; keep other apps out of memory and run
  `termux-wake-lock` during long agent runs, or Android freezes Termux the moment the screen locks.
- **6 GB+** is where it feels comfortable, especially with a browser open.
- **3 GB** will thrash / get killed. Use the headless mode instead:
  `opencode serve --hostname 0.0.0.0 --port 4096` (~156 MB) and open the web UI from another
  device — that skips the 163 MB TUI process entirely. The server prints a password on startup.
- Prefer `opencode run "do X"` for one-shot jobs; exit and restart rather than keeping a huge
  session open for days.
- `--smol` is already baked into the binary's exec args, so the GC heap is as small as upstream
  makes it.

The *build* is heavier than the runtime: `bun install` alone wants ~2–3 GB peak, which is the other
reason to build in CI rather than on the phone.

---

## Route B — native Bionic build (no glibc at all)

This is the "real" Android target. The toolchain side works today; I verified it:

```console
$ bun --version
1.4.3
$ bun build --compile --target=bun-linux-aarch64-android ./t.ts --outfile t-android
$ file t-android
t-android: ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
           interpreter /system/bin/linker64, for Android 28, built by NDK r27c
```

So Bun ≥ 1.3.14 ships official Android runtimes and `bun build --compile` can target them. The
blocker is not Bun, it's opencode's native dependencies:

| Dependency | Android build available? | Consequence |
|---|---|---|
| `@opentui/core` (the TUI renderer, a native `.so`) | no — checked all of 0.6.1…0.6.6; only darwin/linux/win32, gnu+musl | TUI cannot start; you must build `libopentui.so` for Android with the NDK |
| `@opencode-ai/pty` | no | `packages/cli/script/opencode-pty.ts` returns `undefined` for `android`, so PTY-backed features degrade gracefully |
| `@parcel/watcher` | no | file watching breaks (the build script hardcodes `@parcel/watcher-linux-arm64-glibc`) |

To attempt it you would: add `{ os: "android", arch: "arm64" }` to `allTargets` in
`packages/cli/script/build.ts`, map it to the `bun-linux-aarch64-android` compile target (the script
currently derives the target as `bun-${os}-${arch}`, which yields the right string), and swap in
Android builds of the three natives above.

People who already did that surgery — read their patches instead of starting from zero:

- `bd-loser/opencode-bionic` + `MobileStudio-AndroidIDE/opencode-android-build` — @androidtui (NDK-built
  `libopentui.so` for bionic), `.deb` releases
- `kimcrowing/opencode-termux` — NDK + Zig build of `libopentui.so`, then bundles opencode onto an
  Android Bun
- `Hope2333/opencode-termux`, `Lucas7X7/opencode-termux-native` — native bionic single-ELF releases
- `guysoft/opencode-termux` — its **v2 pipeline** now uses exactly this: official Bun 1.4.2 Android
  target + NDK-built `libopentui.so` + a Bun seccomp patch. Best blueprint to copy (see last section)

Verdict: only go this way if you specifically need zero glibc *and* are ready to maintain an opentui
Android build. Otherwise Route A gives you the same CLI, half an hour of work, and no fork to maintain.

---

## Building on the phone itself

Possible but unpleasant: the build needs the full monorepo's `node_modules` and a Vite/Solid build of
the web UI.

```bash
# bionic Bun 1.4.x for Termux (official Android build, repackaged)
curl -fsSL https://raw.githubusercontent.com/Hope2333/bun-termux/main/install.sh | bash

git clone --depth 1 https://github.com/mahimmazidul/opencode ~/opencode && cd ~/opencode
bun install --frozen-lockfile                     # several GB, maybe 3+ GB RAM peak
BUN_COMPILE_RELEASE=bun-v1.4.2 OPENCODE_CHANNEL=termux \
  bun ./packages/cli/script/build.ts --target=opencode-linux-arm64 --skip-web-ui
bash ~/install-termux.sh ./packages/cli/dist/cli-linux-arm64/bin/opencode
```

Plan on 1–2 hours and ~6 GB free storage on a phone. CI is the sane path.

---

## Stopping the CI auto-rebuild

The workflow used to rebuild on every push touching `termux/**` or the workflow itself. Three ways to
stop that, pick one:

| Where | What | Effect |
|---|---|---|
| GitHub UI | **Actions → build-termux → ⋯ → Disable workflow** | instant, no commit needed |
| CLI | `gh workflow disable build-termux` | same, scriptable |
| Code | the `push:` block in `build-termux.yml` is now commented out — the file in this folder is **manual-dispatch only** | permanent, survives clones |

Note: this repo is public, so Actions minutes on standard runners are **free** — the reason to stop it
is not billing. It is that every run deletes and re-uploads a ~200 MB release asset and adds a
25–40 min job to your queue on every `termux/**` commit.

If you want auto-rebuilds back, uncomment:

```yaml
  push:
    branches: [dev]
    paths:
      - ".github/workflows/build-termux.yml"
      - "termux/**"
```

## `pkg install glibc` fails (the most common first-run problem)

The glibc packages live in a **separate Termux repo** (`glibc-repo` adds it). If that repo's index
does not load, you get exactly this:

```
[opencode-termux] ERROR: failed to install glibc / patchelf-glibc / binutils-glibc
```

(the mention of `binutils-glibc` means you are running the *old* installer — the current one installs
`glibc patchelf-glibc` only and prints the real apt error instead of hiding it)

Try these in order:

```bash
# 1. what does the phone actually think?
bash install-termux.sh --diag

# 2. pick a nearby mirror, then retry
termux-change-repo

# 3. run it by hand to see the real error
pkg install -y glibc-repo
pkg update
apt-cache policy glibc          # should print a Candidate: 2.44
pkg install -y glibc patchelf-glibc
```

If step 3 says **`Unable to locate package glibc`**, the repo index never loaded. The glibc repo is
reachable over two hosts and `glibc.list` only enables the Cloudflare one:

```bash
cat $PREFIX/etc/apt/sources.list.d/glibc.list
# deb https://packages-cf.termux.dev/apt/termux-glibc/ glibc stable
# deb https://packages.termux.dev/apt/termux-glibc/ glibc stable   <- commented fallback

sed -i 's|^deb https://packages-cf\.termux\.dev|deb https://packages.termux.dev|' \
  $PREFIX/etc/apt/sources.list.d/glibc.list
pkg update && pkg install -y glibc patchelf-glibc
```

The current installer does that mirror swap **automatically** and retries, plus `dpkg --configure -a`
in case an earlier run was interrupted.

If `pkg update` itself prints GPG/signature errors, your Termux is too old — the Play Store build is
abandoned; install Termux from **F-Droid** or GitHub and start again.

If none of that works, the glibc route is blocked on your device and you do not need it: the native
bionic build in [Alternatives](#alternatives) requires **zero** apt packages.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot execute: required file not found` | `PT_INTERP` still `/lib/ld-linux-aarch64.so.1` | re-run the installer (or `patchelf --set-interpreter $PREFIX/glibc/lib/ld-linux-aarch64.so.1`) |
| `CANNOT LINK EXECUTABLE "cat": ... bad ELF magic` | `LD_LIBRARY_PATH`/`LD_PRELOAD` exported into your shell | `unset LD_LIBRARY_PATH LD_PRELOAD`; never source the launcher, run it |
| loads, but every API call fails / no DNS | Android has no `/etc/resolv.conf` | make sure `$PREFIX/glibc/etc/resolv.conf` has a reachable `nameserver` |
| `Bad system call` / exit 159 at startup | Android 10/11 seccomp traps `statx`/`clone3` that Bun calls directly | use Android 12+, or the seccomp shim from `HanSoBored/opencode-termux` |
| TUI renders garbage / monochrome | `TERM` wrong | `export TERM=xterm-256color` |
| grep/glob tools error | `ripgrep` missing | `pkg install ripgrep` |
| crash unpacking Opentui `.so` | no writable `/tmp` | `export TMPDIR=$PREFIX/tmp` (launcher does this) |
| broke after `opencode upgrade` | updater replaced the patched binary | `"update": "disable"`; launcher auto-re-patches if you forget |

---

## Files here

- `build-termux.yml` → put at `.github/workflows/build-termux.yml` (manual-dispatch only)
- `install-termux.sh` → runs **on the phone**, args: `<binary-path-or-url> [--dir DIR]` (a `.gz` is fine);
  no argument = latest `termux-build` release
- `opencode.jsonc` → copy to `~/.config/opencode/opencode.jsonc` for the phone-tuned settings
  (`"lsp": false` is the big one)

## Notes

- The binary is unsigned and ~200 MB; that's normal for Bun standalones (the official release
  binaries are the same size).
- Builds are per-commit: there's no channel that makes Termux-friendly official binaries, so pin your
  fork to a commit you trust and rebuild when you want to update.
---

## Prebuilt alternative: `guysoft/opencode-termux`

Worth knowing about, because it is the mature version of Route B — and it is actively maintained
(last commits Oct 15–17, 2026).

It ships two lines that install side by side:

| Command | Line | Runtime |
|---|---|---|
| `opencode` | OpenCode **1.x** (stable) | Bun 1.2.13 + WebKit/JSC cross-compiled from source by hand |
| `opencode2` | OpenCode **2.x** (pre-release) | official **Bun 1.4.2 Android target** + `libopentui.so` built with the NDK, via the `linux-arm64-android` compile target |

Install (v2):

```bash
curl -LO https://github.com/guysoft/opencode-termux/releases/download/v1.0.3/opencode2-1.0.3-1-aarch64.pkg.tar.xz
pacman -U opencode2-1.0.3-1-aarch64.pkg.tar.xz
opencode2
```

Strengths, compared with Route A:

- **true bionic** — no `glibc-repo`, no patchelf, no launcher shims, works on stock Termux
- ships the **Bun seccomp fix** (`close_range`/`openat2` → `ENOSYS` instead of `SIGSYS`), so the
  Android 10/11 "Bad system call" class of crashes is handled for you
- packaged as `.pkg.tar.xz` / `.deb` / zip with `ripgrep` as a dependency

Trade-offs:

- it lags upstream: the v2 pre-release reports an app version like `2.0.0-android-termux.2` while your
  fork is `2.1.2`, and its TUI is pinned to OpenTUI **0.5.10** (upstream is on 0.6.6), so upstream TUI
  fixes land late
- it is a maintained patch stack (33 Bun patches, 5 WebKit patches, an OpenTUI patch), not a
  one-command build — you get guysoft's build of opencode, **not your fork's code**
- RAM is the same ballpark as Route A (same JSC + two-process design), so see the RAM section above

Use it if you want a working native `opencode2` **today** without touching the toolchain. Use Route A
if you need *your* fork's commits, or Route B (forking guysoft's pipeline) if you need native *and*
your own code. Other prebuilt projects: `Hope2333/opencode-termux`, `amrmrkjr/opencode-termux`,
`Lucas7X7/opencode-termux-native`.

---

## Status: live in your repo

Pushed to `mahimmazidul/opencode@dev`:

- `termux/install-termux.sh` — installer (zero-arg mode pulls the release below)
- `termux/README.md` — build / install / RAM / troubleshooting
- `.github/workflows/build-termux.yml` — replaced the broken `go build .` workflow

`build-termux #2` ran green on `7a4fa9c` and published:
<https://github.com/mahimmazidul/opencode/releases/download/termux-build/opencode>
(209.6 MB, ELF aarch64, interpreter `/lib/ld-linux-aarch64.so.1`, embedded Bun 1.4.2,
version `0.0.0-termux-2`).

Install on the phone:

```bash
pkg install -y curl
curl -fsSL https://raw.githubusercontent.com/mahimmazidul/opencode/dev/termux/install-termux.sh -o install-termux.sh
bash install-termux.sh
opencode
```

That run was triggered by the push, so no build flags were passed: the web UI **is** embedded
(`opencode web` works). Use the manual dispatch input `skip_web_ui` if you want a faster build
without it.

Tested locally first: the same binary was downloaded and inspected — `ELF 64-bit LSB executable,
ARM aarch64`, `interpreter /lib/ld-linux-aarch64.so.1`, embedded `bun-v1.4.2`, version
`0.0.0-termux-2`, plus the `---- Bun! ----` standalone trailer.
