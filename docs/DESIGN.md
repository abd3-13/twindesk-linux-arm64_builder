# Design

This document explains **why** the builder is shaped this way. For usage see
the [README](../README.md); for failure recovery see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Goal

Produce an installable `arm64` Debian package of TwinDesk on an arm64 host
without installing Node, Rust, GCC or any other build dependency on the host
system. The host should only need `sudo`, `git`, `debootstrap`, and coreutils.

## Why a chroot

TwinDesk's Linux build needs:

* Node.js 22 LTS (Electron 44 requires `node >= 22.12.0`)
* a Rust toolchain (the `linux-helper` crate)
* GCC, `pkg-config`, X11 and GLib headers for the native helper
* Ruby + `fpm` for the final `.deb`
* electron-builder's own downloads (Electron, `app-builder`, `fpm`)

Installing all of that on the host is invasive and version-sensitive. A
Debian `debootstrap` chroot gives a disposable, reproducible environment that
can be deleted with `rm -rf`. Only two paths are created on the host:
`chroot/` and `build.swap`; `scripts/99-cleanup.sh` removes both.

The chroot is **native** (`--arch=arm64` on an `aarch64` host) — no QEMU
emulation, so compilation speed is normal.

## Why Debian 11 (bullseye)

The chroot release sets the package's runtime floor. Building in bullseye
means:

* the bundled helper links against glibc 2.31 at most;
* the resulting `.deb` installs on Debian 11+, Ubuntu 20.04+, Devuan and
  anything newer.

Building in a newer suite would silently raise the glibc requirement and break
older targets. `scripts/03-verify.sh` checks the GLIBC symbol versions of the
helper binaries against 2.31.

Bullseye itself is EOL as a distribution, but it is only the **build**
environment; the artifact is not tied to bullseye repositories at runtime.

## Stage model

Each stage is a standalone script and is idempotent, so a failed run can be
resumed by re-running only the failing stage.

```
00-fetch.sh     clone TwinDesk at the configured tag into repo/
00-prep.sh      swap + debootstrap + apt build toolchain
01-toolchain.sh Node.js + Rust + system fpm inside the chroot
02-build.sh     patch, npm install, npm run dist, collect the .deb
03-verify.sh    read-only inspection of the artifact
99-cleanup.sh   unmount + delete chroot and swap
run-all.sh      runs the five stages in order, tees to build.log
```

State is kept in well-known locations inside the workspace:

| Path | Owner | Reused by |
|---|---|---|
| `repo/` | source clone | fetch, build |
| `chroot/` | root | prep, toolchain, build, verify |
| `chroot/root/.twindesk-stage0-done` | root | prep (skip apt) |
| `chroot/build/` | root | build (`node_modules`, `target`, caches) |
| `build.swap` | root | prep |

Because `chroot/build` and the caches survive, re-running `02-build.sh` after a
network failure does not redo `npm install` or the Rust compile from scratch.

## Configuration

`config.sh` is the single source of truth. It uses `: "${VAR:=default}"` so
environment variables win, then exports everything for child scripts. This
means both of these work:

```sh
TWINDESK_VERSION=2.6.0 bash scripts/run-all.sh
TWINDESK_VERSION=2.6.0 make all
```

## The arm64 patch

Upstream `linux/installer/build.js` assumes x86-64. `patches/arm64.patch`
changes only that file:

1. **Architecture** — target `Arch.arm64` instead of `Arch.x64`, and build only
   the `.deb` (upstream also builds an AppImage, which this project does not
   need).
2. **Bundled adb** — the `platform-tools` archive downloaded by upstream is
   x86-64 only. On arm64 the bundled binary is skipped and `adb` is added to
   `Recommends`, so the distribution package is used. Desktop features do not
   need adb; phone-over-ADB needs a recent `adb` from the distribution.
3. **Runtime dependencies** — Electron's direct `NEEDED` libraries
   (`libasound2`, `libgbm1`, `libxkbcommon0`, `libxcomposite1`, `libxdamage1`,
   `libcups2`, `libudev1`) are declared so the app starts on lean arm64
   installs instead of failing at launch.

The patch is applied idempotently: `git apply --reverse --check` detects an
already-patched tree. If upstream changes `build.js`, refresh the patch with:

```sh
git -C repo diff -- linux/installer/build.js > patches/arm64.patch
```

## Why system fpm

electron-builder downloads its own `fpm` when it cannot find one. On arm64 that
download can be an x86-64 binary, which fails at the `.deb` step. The reliable
combination is:

```sh
apt install ruby ruby-dev build-essential
gem install --no-document fpm
export USE_SYSTEM_FPM=true
```

`00-prep.sh` installs Ruby, `01-toolchain.sh` installs the gem, and
`02-build.sh` exports `USE_SYSTEM_FPM=true` for both `npm install` and
`npm run dist`.

## Memory and swap

The Rust helper and Electron packaging are memory-hungry. On a host with
~2.6 GB RAM the build can be killed by the OOM killer. `00-prep.sh` therefore
creates a 4 GB disk-backed swap file (never a RAM-backed one). The chroot and
swap must live on disk, which the script verifies via `df -PT`.

`SKIP_SWAP=1` disables this for CI runners and large hosts.

## Network resilience

npm and Electron downloads are the fragile part of the build. The scripts:

* configure generous npm retries and timeouts (`fetch-retries=10`,
  `fetch-timeout=900000`, `maxsockets=4`);
* wrap `npm install` (4 attempts) and `npm run dist` (3 attempts) in outer
  retry loops;
* keep caches between attempts.

Cargo uses its own retry behaviour with the same persistent cache.

## Artifact and verification

The `.deb` is copied to the workspace root and never deleted by cleanup.
`03-verify.sh` checks control fields, dependencies, absence of the x86-64
`vendor/adb`, ARM ELF architecture, the glibc 2.31 ceiling, `ldd` resolution
inside the chroot, and the SHA-256 checksum. It does not modify the package.

## CI

`.github/workflows/build.yml` runs the same `scripts/run-all.sh` on GitHub's
native arm64 runner (`ubuntu-24.04-arm`), with `SKIP_SWAP=1`. The artifact and
the log are uploaded. CI is a convenience mirror of the local build, not a
different build path.
