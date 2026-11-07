# TwinDesk 2.5.3 → arm64 `.deb` — manual build scripts

Everything needed to rebuild the package by hand, on an **arm64 Linux host**, without
installing build packages on that host. All build tools live in a throw-away Debian 11
(`bullseye`) chroot under this directory.

```
workspace/
├── repo/                    TwinDesk source (created by 00-fetch.sh)
├── chroot/                  Debian 11 arm64 build environment (created by 00-prep.sh)
├── build.swap               4 GB temporary swap file (created by 00-prep.sh)
├── TwinDesk-2.5.3-arm64.deb  the result
├── build.log                full log from run-all.sh
├── ASSESSMENT.md            why the build is done this way
└── build-scripts/
    ├── 00-fetch.sh          clone the source
    ├── 00-prep.sh           swap + chroot + gcc/X11/GLib toolchain
    ├── 01-toolchain.sh      Node.js 22 LTS + Rust 1.99 inside the chroot
    ├── 02-build.sh          patch, npm install, npm run dist, collect .deb
    ├── 03-verify.sh         control fields, deps, ELF/glibc, ldd, sha256
    ├── 99-cleanup.sh        unmount + delete chroot and swap
    ├── run-all.sh           all of the above, logged to build.log
    └── patches/
        └── arm64.patch      the three arm64 fixes
```

The scripts derive the workspace path from their own location, so the whole folder
can be moved or copied to another arm64 machine.

## Requirements (host)

* **arm64 / aarch64** host (the build is native, no QEMU).
* Debian/Devuan/Ubuntu host with these already installed:
  `sudo`, `debootstrap`, `git`, `mount`, `chroot`, `dpkg-deb`, `file`, `objdump`.
* **≥ 8 GB free disk** in the workspace (peak usage ~3.5 GB, plus source and output).
* Network access to Debian, nodejs.org, static.rust-lang.org, npm, GitHub.
* Working `sudo`. If swap is nearly full, `00-prep.sh` adds a 4 GB swap file on disk.

The host is never modified except for the temporary `chroot/` directory and
`build.swap` file, both removed by `99-cleanup.sh`.

## One-command build

```sh
cd /path/to/workspace
bash build-scripts/run-all.sh
```

On success:

```
TwinDesk-2.5.3-arm64.deb   ~100–110 MB
```

Full output is also appended to `build.log`. Add `CLEANUP=1` to remove the chroot and
swap automatically after a successful build:

```sh
CLEANUP=1 bash build-scripts/run-all.sh
```

## Stage-by-stage build (resumable)

Run the stages manually, in order. Every script is safe to re-run; each one detects
completed work and continues.

```sh
cd /path/to/workspace
bash build-scripts/00-fetch.sh      # clone TwinDesk v2.5.3 into repo/
bash build-scripts/00-prep.sh       # swap + Debian 11 arm64 chroot + toolchain
bash build-scripts/01-toolchain.sh  # Node.js 22.23.4 + Rust 1.99.1 (in chroot)
bash build-scripts/02-build.sh      # apply patch, npm install, npm run dist
bash build-scripts/03-verify.sh     # inspect the .deb
```

If a stage fails, fix the cause and re-run **only that stage**. For example, after a
network timeout during `npm install`, run `02-build.sh` again; the chroot,
`node_modules`, npm cache and cargo cache are all kept.

### Starting over

```sh
RECREATE=1 bash build-scripts/00-prep.sh   # delete + rebuild the chroot
```

To delete everything generated (keep the .deb and source):

```sh
bash build-scripts/99-cleanup.sh
```

`KEEP_CHROOT=1` keeps the chroot, `KEEP_SWAP=1` keeps the swap file.

## What `02-build.sh` does

1. Re-creates the chroot bind mounts (`/proc`, `/sys`, `/dev`, `/dev/pts`).
2. Applies `patches/arm64.patch` to `repo/linux/installer/build.js`, idempotently.
   The check is `git apply --reverse --check`: if the patch is already applied, it is
   skipped; otherwise it is applied and verified first.
3. Copies `repo/` into `chroot/build/` with `cp -a`. This overlays the source but does
   **not** delete `node_modules`, `target/` or caches from a previous run.
4. Inside the chroot, as root, with `HOME=/root` and Rust on `PATH`:
   * `npm install --unsafe-perm --no-audit --no-fund --foreground-scripts`
   * `npm run dist`
5. Copies the newest `*.deb` from `chroot/build/linux/dist/` back to the workspace
   and prints its SHA-256.

### Tunables

| Variable | Default | Purpose |
|---|---|---|
| `CARGO_BUILD_JOBS` | `4` | Parallel compile jobs; lower it if RAM is tight. |
| `NODE_HEAP_MB` | `1536` | Node.js old-space limit for the packaging step. |
| `SUITE` | `bullseye` | Chroot release (used by `00-prep.sh`). |
| `MIRROR` | `http://deb.debian.org/debian` | Debian mirror. |
| `NODE_VER` | `v22.23.4` | Node.js version. |
| `RUST_VER` | `1.99.1` | Rust version. |

Example for a very small machine:

```sh
CARGO_BUILD_JOBS=2 NODE_HEAP_MB=1024 bash build-scripts/run-all.sh
```

## The three arm64 patches

`patches/arm64.patch` changes only `linux/installer/build.js`:

1. **Target architecture** — `createTarget(['AppImage','deb'], Arch.x64)` becomes
   `createTarget(['deb'], Arch.arm64)`. Without this electron-builder downloads x64
   Electron and produces an amd64-labelled package.
2. **Bundled adb** — Google's `platform-tools-latest-linux.zip` is x86-64 only, so
   `fetchAdb()` runs only on x64. On arm64 the app uses the distribution's `adb`
   instead, otherwise it would prefer a bundled binary that cannot execute.
3. **Runtime dependencies** — adds Electron's direct NEEDED libraries to `Depends`
   (`libasound2`, `libgbm1`, `libxkbcommon0`, `libxcomposite1`, `libxdamage1`,
   `libcups2`, `libudev1`) and `adb` to `Recommends`.

AppImage is intentionally not built; only the `.deb` was requested.

## Verifying the result

```sh
bash build-scripts/03-verify.sh
# or a specific file:
bash build-scripts/03-verify.sh /path/to/TwinDesk-2.5.3-arm64.deb
```

Checks:

* `Architecture: arm64`;
* `Depends` contains the added Electron libraries;
* `Recommends` contains `adb`;
* no `vendor/adb` (x86-64) in the package;
* helpers are ARM aarch64 ELF and require no glibc newer than 2.31;
* `ldd` resolves every library inside the chroot;
* SHA-256 is printed.

Manual checks if you prefer:

```sh
dpkg-deb -f TwinDesk-2.5.3-arm64.deb Architecture
dpkg-deb -I TwinDesk-2.5.3-arm64.deb
dpkg-deb -c TwinDesk-2.5.3-arm64.deb | grep -E 'adb|linux-helper/bin'
```

## Installing

```sh
sudo apt install ./TwinDesk-2.5.3-arm64.deb
```

On Debian 12 the package's `adb` (29.x) lacks `adb pair`. If you use the phone-over-ADB
features there, install a newer adb from backports/trixie. Desktop features do not
need adb.

## Known limitations

* The clone has no prebuilt full Android APK (`android/dist/*-full.apk`), so the
  optional "install the full Android app" feature is not bundled. Normal desktop and
  phone features are unaffected.
* Upstream publishes only x64/amd64 Linux assets. The in-app updater filters by
  architecture, so it will not offer an arm64 update; rebuild per release.
* No code signing is needed for a local `.deb`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Killed` / OOM during `npm run dist` | Ensure `build.swap` is active (`swapon --show`), lower `CARGO_BUILD_JOBS` and `NODE_HEAP_MB`, then re-run `02-build.sh`. |
| `Could not get lock .../lists/lock` | A previous apt is still running; wait or `sudo kill <pid>`, then re-run `00-prep.sh`. |
| Download stalls | Re-run the same stage; curl/npm/cargo resume from caches. |
| `patch does not apply cleanly` | `repo/` was edited. `git -C repo checkout -- linux/installer/build.js`, then re-run `02-build.sh`. |
| `no .deb produced` | Read the `npm run dist` output above it; usually a missing system library inside the chroot, or the Electron download failed. |
| Chroot mounts missing after reboot | Just re-run the stage; it re-creates `/proc`, `/sys`, `/dev`, `/dev/pts`. |
| Need a different distro base | `SUITE=bookworm MIRROR=http://deb.debian.org/debian RECREATE=1 bash build-scripts/00-prep.sh`. Note bookworm raises the glibc floor to 2.36. |

The build log from `run-all.sh` is the first thing to inspect: `tail -100 build.log`.
