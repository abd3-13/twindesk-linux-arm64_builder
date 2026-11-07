# TwinDesk Linux arm64 builder

Build an **arm64 Debian package** for [TwinDesk](https://github.com/InukaAsith/TwinDesk)
inside a disposable Debian chroot — no build packages are installed on the host.

The scripts are resumable: every stage detects completed work and continues where
it left off. A full first build takes roughly 45–90 minutes on an 8-core arm64
machine; retries take 10–20 minutes.

> This is an independent build tool. It is not affiliated with the TwinDesk
> author. The resulting package contains GPL-3.0 code from TwinDesk.

## Result

```
TwinDesk-<version>-arm64.deb    ~95–110 MB
```

Tested end to end with TwinDesk **2.5.3**: the package installs with
`apt install ./TwinDesk-2.5.3-arm64.deb` and the app launches.

## Requirements

* **aarch64 / arm64 Linux host** — the build is native, no QEMU.
* `sudo`, `git`, `debootstrap`, `mount`, `chroot`, `dpkg-deb`, `file`, `objdump`.
* **≥ 8 GB free disk** in the repository (~3.5 GB peak for the chroot plus source
  and output).
* Network access to Debian, nodejs.org, static.rust-lang.org, npm, GitHub and
  rubygems.org.

On Debian/Devuan/Ubuntu:

```sh
sudo apt install git debootstrap dpkg-dev file binutils
```

## Quick start

```sh
git clone git@github.com:abd3-13/twindesk-linux-arm64_builder.git
cd twindesk-linux-arm64_builder
make all
```

`make all` runs fetch → prep → toolchain → build → verify and writes the full log
to `build.log`. The `.deb` lands in the repository root.

With cleanup after a successful build:

```sh
CLEANUP=1 bash scripts/run-all.sh
```

## Stage by stage

| Command | What it does |
|---|---|
| `make fetch` | Shallow-clones TwinDesk at `TWINDESK_TAG` into `repo/` |
| `make prep` | Adds a 4 GB swap file, debootstraps Debian `SUITE` arm64 into `chroot/`, installs GCC/X11/GLib/Ruby |
| `make toolchain` | Installs Node 22 LTS, Rust, and system `fpm` inside the chroot |
| `make build` | Applies `patches/arm64.patch`, runs `npm install` and `npm run dist`, copies the `.deb` out |
| `make verify` | Checks control fields, dependencies, ELF architecture, glibc floor, `ldd`, SHA-256 |
| `make clean` | Unmounts and deletes `chroot/` and `build.swap`; keeps the `.deb` and source |

Each stage is safe to re-run. After a failure, fix the cause and re-run only the
failing stage. To rebuild the chroot from scratch:

```sh
RECREATE=1 make prep
```

## Configuration

All defaults live in [`config.sh`](config.sh) and can be overridden from the
environment or on the `make` command line:

| Variable | Default | Meaning |
|---|---|---|
| `TWINDESK_VERSION` | `2.5.3` | Package version and source tag base |
| `TWINDESK_TAG` | `v2.5.3` | Git tag/ref to clone |
| `TWINDESK_REPO` | upstream URL | Source repository |
| `DEB_ARCH` | `arm64` | Debian architecture |
| `SUITE` | `bullseye` | Chroot Debian release (glibc 2.31 floor) |
| `MIRROR` | deb.debian.org | Debian mirror |
| `NODE_VER` | `v22.23.4` | Node.js version (Electron 44 needs ≥ 22.12) |
| `RUST_VER` | `1.99.1` | Rust toolchain |
| `CARGO_BUILD_JOBS` | `4` | Compile parallelism |
| `NODE_HEAP_MB` | `1536` | Node old-space limit |
| `SKIP_SWAP` | `0` | Set to `1` when the host already has enough swap/RAM |
| `WORKSPACE` | repository root | Where `repo/`, `chroot/`, `build.swap`, `build.log` and the `.deb` live. Defaults to the parent directory if the clone sits inside an existing workspace (a sibling `repo/` or `chroot/`). |

Examples:

```sh
TWINDESK_VERSION=2.6.0 make fetch build
SUITE=bookworm RECREATE=1 make prep
CARGO_BUILD_JOBS=2 NODE_HEAP_MB=1024 make build
WORKSPACE=/srv/twindesk-build make all
```

`WORKSPACE` is where all generated state goes. It defaults to the repository
root, except when the clone is placed inside a directory that already contains
`repo/` or `chroot/` — then that parent is reused, so an existing build
environment keeps working.

## How it works

1. **Fetch** — shallow clone of TwinDesk at the configured tag.
2. **Chroot** — `debootstrap --variant=minbase --arch=arm64` into `chroot/`,
   plus bind mounts for `/proc`, `/sys`, `/dev`, `/dev/pts`. A temporary 4 GB
   swap file is added on small-RAM hosts.
3. **Toolchain** — Node.js 22, Rust (minimal profile), Ruby + `fpm` inside the
   chroot only.
4. **Build** — the source is copied to `chroot/build`; `npm install` and
   `npm run dist` run as root with `HOME=/root`, Rust on `PATH`, and
   `USE_SYSTEM_FPM=true`.
5. **Package** — electron-builder produces the `.deb`; it is copied back to the
   repository root and its SHA-256 is printed.
6. **Verify** — architecture, dependencies, absence of the x86-64 bundled adb,
   helper ELF/glibc checks, `ldd`, checksum.

The host is only touched in two removable ways: `chroot/` and `build.swap`.
`make clean` removes both. Nothing is installed on the host.

## arm64 patches

[`patches/arm64.patch`](patches/arm64.patch) changes only
`linux/installer/build.js`:

1. **Architecture** — target `Arch.arm64` and build only the `.deb` (upstream
   hard-codes `Arch.x64` and AppImage + deb).
2. **Bundled adb** — Google's `platform-tools` zip is x86-64 only. On arm64 the
   bundled adb is skipped and the distribution `adb` is used instead
   (`Recommends: adb`).
3. **Runtime dependencies** — adds Electron's direct NEEDED libraries
   (`libasound2`, `libgbm1`, `libxkbcommon0`, `libxcomposite1`, `libxdamage1`,
   `libcups2`, `libudev1`) so the app starts on lean arm64 installs.

If upstream changes `build.js`, refresh the patch:

```sh
git -C repo diff -- linux/installer/build.js > patches/arm64.patch
```

## Verification and install

```sh
make verify
# or
bash scripts/03-verify.sh TwinDesk-2.5.3-arm64.deb
```

```sh
sudo apt install ./TwinDesk-<version>-arm64.deb
```

On Debian 12, `adb` 29.x does not support `adb pair`. Phone-over-ADB features
need a newer adb (backports/trixie). Desktop features do not need adb.

## Known limitations

* No full Android APK is bundled (the upstream clone has no
  `android/dist/*-full.apk`); the optional “install the full Android app”
  feature is unavailable. Normal desktop/phone features work.
* Upstream publishes only x64/amd64 Linux releases. The in-app updater filters
  by architecture and will not offer arm64 updates; rebuild per release.
* Debian `bullseye` is EOL as a distro, but it is only the *build* chroot. The
  package keeps a glibc 2.31 floor and runs on Debian 11+, Ubuntu 20.04+ and
  current Devuan.

## CI

`.github/workflows/build.yml` builds the deb on GitHub's
`ubuntu-24.04-arm` runners via **Actions → Build arm64 deb → Run workflow**,
or on `v*` tags. The artifact is uploaded for 14 days. CI sets `SKIP_SWAP=1`
because the runner has enough RAM.

## Repository layout

```
.
├── config.sh                 versions, chroot suite, tuning
├── Makefile                  convenience targets
├── scripts/
│   ├── 00-fetch.sh
│   ├── 00-prep.sh
│   ├── 01-toolchain.sh
│   ├── 02-build.sh
│   ├── 03-verify.sh
│   ├── 99-cleanup.sh
│   └── run-all.sh
├── patches/arm64.patch
├── docs/
│   ├── DESIGN.md
│   └── TROUBLESHOOTING.md
└── .github/workflows/build.yml
```

Generated paths (`repo/`, `chroot/`, `build.swap`, `build.log`, `*.deb`) live in
`WORKSPACE` and are ignored by Git.

## License

GPL-3.0. See [LICENSE](LICENSE). TwinDesk itself is Copyright (C) 2026
inukaasith and GPL-3.0; this builder only automates its documented build.
