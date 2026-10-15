# AGENTS.md — Termux apk-tools Fork

## What this repo is

A port of Alpine's **apk-tools 3.0.8** to Android/Termux, forked from upstream at commit `44dcdfc` (tag 3.0.8). It lets `apk` run natively on Termux (in `$PREFIX`) without root, without `--root`, and without `LD_LIBRARY_PATH`, plus the scripts/packages/repos that make apk the primary package manager.

## Working environment

- Host: Android 12+, aarch64 device running Termux (`/data/data/com.termux/files/usr`)
- Toolchain: Termux clang (in `$PREFIX`), ninja, pkg-config; meson via a venv
- Network: works on-device (curl to packages-cf.termux.dev, github raw+api)
- gh authenticated to github.com/BOBBUBO; special repos:
  - `repo/` — nested git repo → `https://github.com/BOBBUBO/apk-termux-repo` (main app repo)
  - `x11-repo/` — nested git repo → `https://github.com/BOBBUBO/x11-repo-apk` (x11 repo)

## Codebase layout

| path | what it is |
|---|---|
| `src/` | apk-tools upstream source (+ local patches — see Local changes) |
| `portability/` | bionic compat shims auto-detected by meson: `fget{pw,gr}ent.c/h`, `posix_spawn.c`, `spawn.h`, `getrandom.c`, `qsort_r.c`, etc. |
| `libfetch/` | TLS/HTTP fetch backend |
| `packages/apk-tools/` | the **Termux package recipe** (`build.sh`, `repositories`, `apk-termux@local.rsa.pub`) — cloned into `termux-packages/packages/` at CI time |
| `.github/workflows/termux.yml` | CI: builds the Termux deb for all 4 arches, uploads artifacts |
| `repack-debs.sh` | converts Termux `.deb`s into signed `.apk`s in a repo dir |
| `make-apk-bootstrap.sh` | builds `apk-bootstrap-<arch>.zip` (stock bootstrap − apt/dpkg + apk + pkg shim + custom motd) |
| `install-apk-bootstrap.sh` | device-side installer: prepare `usr-n/` and swap it into place in failsafe; keeps `usr.old` for rollback |
| `motd` | custom MOTD injected into the bootstrap |
| `build/` | meson build output (gitignored) |

## Local changes vs upstream (commit-by-commit)

Branching from `44dcdfc apk-tools-3.0.8`:

| commit | change |
|---|---|
| `e222ada` | `portability/posix_spawn.c` + `spawn.h` — fork+execvp fallback when `spawn.h`/`posix_spawn` isn't available (Android API<28 in Termux standalone NDK sysroot) |
| `portability/fgetpwent.c`, `portability/fgetpwent.h` (and grp) | Bionic has neither `fgetpwent` (passwd scanning) nor `fgetgrent`; implemented to parse `/etc/passwd`/`/etc/group` directly |
| `meson.build` | adds `-DAPK_PREFIX/APK_CONFDIR/APK_LIBDIR`; defaults to using meson `prefix` (`$PREFIX`) |
| `src/context.c` | on `__ANDROID__`: default `--root` is `$PREFIX`; auto-enable `APK_OPENF_USERMODE` when run as non-root (Termux has no root) |
| `src/io.c` | `O_TMPFILE`/`linkat(/proc/self/fd/...)` safe-atomic write path — **Android's SELinux blocks linkat via /proc/self/fd**, so this only runs on Linux; Android uses plain open |
| `src/apk.c` | config file reads look in `APK_CONFDIR "/config"` / `APK_LIBDIR "/apk/config"` |

## Port-wranglers (details)

`portability/meson.build` runs `cc.has_header_symbol` for each function; missing ones get `-DNEED_<NAME>` + a portability implementation compiled in. Result varies by whether we run on the real site NDK (standalone headers) or the CI docker (API 24 standalone toolchain), both work.

| function | Termux CI (standalone NDK r27, API 24) | device (Termux headers) |
|---|---|---|
| posix_spawn | missing → portability fallback | present at API 21+ |
| fget*ent | missing in NDK headers → portability fallback | declared in `$PREFIX/include/pwd.h` patches? → if declared, used |
| getrandom (API 24) | missing → use `/dev/urandom` fallback | native (API 28+) |
| qsort_r GNU signature | missing → our GNU-flip shim | same |
| `reallocarray`, `memrchr`, `strchrnul`, ... | portability | most exist |

## Building locally (from scratch on device)

```sh
python3 -m venv /some/venv  # meson needed
./venv/bin/pip install meson
export PATH=<venv>/bin:$PATH
meson setup build -Ddocs=disabled -Dlua=disabled -Dpython=disabled -Dtests=disabled -Dprefix=$PREFIX
ninja -C build
./build/src/apk --version        # 3.0.8+ ...
```

The built apk finds `libapk.so` via baked-in RPATH `$PREFIX/lib` — works without `LD_LIBRARY_PATH`.

## repack-debs.sh — deb→apk repo maintainer

```sh
./repack-debs.sh cbonsai            # resolve+download dependencies, repackage
./repack-debs.sh --rm cbonsai       # remove from repo (also re-index)
./repack-debs.sh --update           # rebuild everything whose apt ver is newer
./repack-debs.sh --auto 25          # scan apt list, take first 25 new/outdated
./repack-debs.sh --size-cap 131072  # skip debs bigger than this many KB (default 64MB)
./repack-debs.sh --x11 ...          # same, but into x11-repo/
./repack-debs.sh *.deb              # repackage the deb files in cwd
```

Details worth knowing:
- state (searched keys, manifests, download caches): `.apk-sign/` + `*.index-services repo/`
- every package is signed with the same key (`.apk-sign/apk-termux@local.rsa`)
- deb version → apk version: strip epoch, `X-Y` → `X-rY`, sanitize chars outside `[0-9.]`
- The x11 deb resolution path differs (uses tarball downloads via http to termux repos since x11 isn't in this device's apt sources by default)

## make-apk-bootstrap.sh — bootstrap zip generator

```sh
./make-apk-bootstrap.sh aarch64    # stock bootstrap, minus apt/dpkg, plus apk-tools
```

It downloads the latest stock bootstrap zip from the termux-packages release, strips apt/dpkg/termux-keyring, injects runtime deps (zlib zstd openssl ca-certificates) from the termux deb pool, injects the CI-built apk-tools deb (or a local path given as arg 2), replaces the second-stage with one that runs `apk add --initdb`, installs the `pkg` shim (`install/remove/update`...→apk verbs), writes a custom MOTD, and re-zips with correctly regenerated SYMLINKS.

The script must keep `tmp/` in the tree after stripping — the commit `89e501c` was specifically to keep it (lock files land in `$PREFIX/tmp`).

## install-apk-bootstrap.sh — usr/usern swap switcher

Run it in two phases:
```sh
./install-apk-bootstrap.sh            # ← in a normal Termux session
# restart the app in failsafe mode, then:
./install-apk-bootstrap.sh --finalize # ← in the failsafe shell
```

It downloads the bootstrap zip (defaults to the published one in the apk repo), extracts to `usr-n/`, symlinks, then in failsafe swaps `usr → usr.old`, `usr-n → usr`, and runs `apk add --initdb`.

## Packages-set (what a consumer needs)

- The Termux package `./packages/apk-tools/build.sh` injects `etc/apk/repositories` (our main repo adb URL) + the pubkey under `etc/apk/keys/` and kicks off `apk add --initdb` as a one-shot postinst
- CI builds it via `.github/workflows/termux.yml` for all 4 arches in the termux package-builder docker image

## Terminal quirks we hit

- **SELinux** blocks O_TMPFILE+linkat-through-/proc/self/fd commit path (io.c fallback path exists)
- **NDK standalone toolchain (`API 24` headers)** in the CI image lacks `spawn.h`, `fgetpwent`, etc — portability/ covers
- **LineageOS 24 / Android 16+** users reported the X11 server binary aborting in dual-space containers — we established it's an environment quirk (X-server is in the *host* environment app), not our packaging (kitty runs fine)
- githubusercontent raw has CDN staleness ~1min; `apk --force-refresh update` after pushing a repo update

## Repo hygiene rules

- do not commit `build/`, `.apk-sign/`, `.apk-bootstrap/`, `repo/`, `x11-repo/` — they're separate repos or build dirs
- never let an apk > 100 MB enter git history on the repo repos (github hard limit; gotbit by 0ad-data which is 200+). use --size-cap to stop the big ones getting converted at all.

## Quick verification scratch (don't touch the live prefix)

```sh
mkdir -p $PREFIX_TMP/$PWD/kroot
apk --root $T add --initdb
apk --root $T --cache-dir $T/etc/apk/cache update
apk --root $T add cbonsai && $T/bin/cbonsai --help | head -1
apk --root $T del cbonsai
```
