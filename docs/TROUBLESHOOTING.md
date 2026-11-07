# Troubleshooting

Every stage is resumable. Read the error, fix the cause, then re-run only that
stage (or `make all` again — completed work is skipped).

Quick reference:

| Symptom | Stage | Fix |
|---|---|---|
| `this build is native arm64 ...` | prep | Run on an `aarch64` host; no emulation is supported. |
| `missing host command: debootstrap` | prep | `sudo apt install git debootstrap dpkg-dev file binutils` |
| `missing Debian keyring` | prep | `sudo apt install debian-archive-keyring` |
| `not a valid signing key` / debootstrap GPG error | prep | Install the keyring above, or set `KEYRING=/path/to/keyring.gpg`. |
| `No space left on device` | prep/build | Need ≥ 8 GB free. `make clean`, then retry. |
| Chroot hangs at `debootstrap` | prep | Mirror/network issue. Retry; optionally set `MIRROR=https://deb.debian.org/debian`. |
| Node/npm `Class extends value undefined` | toolchain | Stale modules after extracting Node over an old tree. `FORCE_NODE=1 make toolchain`. |
| `EBADENGINE` / Electron wants node ≥ 22.12 | toolchain | `FORCE_NODE=1 make toolchain` to reinstall the pinned Node 22. |
| `npm install` keeps timing out | build | Re-run `02-build.sh`; the cache is kept. Check `MIRROR`/DNS. |
| Build killed (exit 137 / OOM) | build | Ensure swap is enabled (`swapon --show`); lower `CARGO_BUILD_JOBS=2 NODE_HEAP_MB=1024`. |
| `ENOENT ... rename .../electron -> .../twindesk` | build | Interrupted earlier run left `linux-arm64-unpacked`. `02-build.sh` removes it automatically; if not, delete `chroot/build/linux/dist/linux-arm64-unpacked`. |
| fpm `Exec format error` / wrong-arch fpm | build | electron-builder picked an x86-64 `fpm`. Install `ruby ruby-dev build-essential`, `gem install --no-document fpm`, export `USE_SYSTEM_FPM=true` (scripts do this). |
| `no .deb produced in .../dist` | build | Scroll up for the real error — usually a missing library, a failed Electron download, or disk full. |
| `patch does not apply cleanly` | build | Upstream changed `linux/installer/build.js`; refresh `patches/arm64.patch`. |
| App installs but does not start | verify | Run `03-verify.sh`; missing libs usually mean `Depends` was not updated. `ldd` inside the chroot shows the gap. |
| `adb pair` unsupported | runtime | Distribution `adb` is too old; install a newer adb (backports/trixie). Desktop features do not need adb. |
| Chroot mounts are gone after reboot | any | Each stage remounts `/proc`, `/sys`, `/dev`, `/dev/pts` automatically. |
| `make clean` fails to unmount | cleanup | A process is still using the chroot; `sudo umount -l chroot/dev/pts`, or reboot, then retry. |

## Rebuilding from scratch

```sh
RECREATE=1 make prep        # delete and debootstrap the chroot again
FORCE_NODE=1 make toolchain # reinstall Node
rm -rf chroot/build         # discard copied source, node_modules and target
```

A full `make clean && make all` is the last resort; it keeps `repo/` and any
`.deb` unless you also run `make distclean`.

## Inspecting a failure

`build.log` contains the complete output of the last `run-all.sh` run:

```sh
tail -n 200 build.log
grep -nE 'error|Error|failed|ENOENT|Killed' build.log | tail -n 40
```

Inside the chroot:

```sh
sudo chroot chroot /bin/bash -lc 'df -h; free -h; node -v; cargo -V; fpm --version'
```

## Node.js installation details

`01-toolchain.sh` wipes `/usr/local/*` before extracting Node. Extracting a
new Node over an old one leaves nested `minipass`/`minizip` copies that make
npm crash with `Class extends value undefined`. If you installed Node manually
and see that, use `FORCE_NODE=1`.

## npm registry issues

The scripts already set retries and timeouts. If the registry is reachable but
slow, lower parallelism:

```sh
npm config set maxsockets 2
```

inside the chroot (`sudo chroot chroot /bin/bash -lc 'export HOME=/root; npm config set maxsockets 2'`).

## Verification failures

`03-verify.sh` exits non-zero on real problems. Common causes:

* `Architecture is 'amd64'` — the patch was not applied; check
  `git -C repo diff -- linux/installer/build.js`.
* `package contains bundled vendor/adb` — the adb part of the patch is missing.
* `requires GLIBC_2.xx newer than 2.31` — the chroot was not bullseye, or a
  prebuilt helper was used. Rebuild with `SUITE=bullseye`.
* `ldd reported missing libraries` — add the library to `Depends` in the patch.

`03-verify.sh` needs `dpkg-deb`, `file` and `objdump` on the host; it skips the
`ldd` check when the chroot has already been cleaned up.

## CI failures

The GitHub workflow runs `scripts/run-all.sh` with `SKIP_SWAP=1` on
`ubuntu-24.04-arm`. If the runner label is unavailable (for private
repositories or older plans), run the build locally instead. Download the
`build.log` artifact to see the failing stage.
