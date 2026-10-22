# ksutools

Fully static musl userspace tools for the Android shell, shipped as a KernelSU
module. Works in **any mount namespace** — an app shell, `adb shell`, another
container, or a freshly created one.

The module only provides `system/` content — mounting is left to a metamodule
(`meta-overlayfs`, `hybrid-mount`, …).

## What's inside

13 binaries, all in `/system/bin/.ksutools/`:

| command | version | size |
|---|---|---|
| `curl` | 8.14.1 (OpenSSL 3.3.7, zlib, zstd, nghttp2, HTTP/2) | 5.09 MB |
| `dig` | BIND 9.18.50 | 6.63 MB |
| `jq` | 1.7.1 | 0.96 MB |
| `tcpdump` | 4.99.5 (libpcap 1.10.5) | 4.59 MB |
| `ssh` `scp` `sftp` `ssh-keygen` `ssh-add` `ssh-agent` `ssh-keyscan` | OpenSSH 9.9p2 | 0.31–4.26 MB |
| `sshd` + `sshd-session` | OpenSSH 9.9p2 (privsep child) | 3.76 / 4.32 MB |

Plus `/system/etc/ssl/certs/ca-certificates.crt` (CA bundle) and a minimal
`system/etc/{passwd,group}` so `sshd` resolves `root`'s home to
`/data/adb/ksutools/home/root`.

`/system/bin/{curl,dig,jq,tcpdump,ssh,scp,sftp,ssh-keygen,ssh-add,ssh-agent,ssh-keyscan,sshd}`
are **relative symlinks** to `.ksutools-wrapper`, which sets `SSL_CERT_FILE`,
`SSL_CERT_DIR`, `TMPDIR`, `HOME` and the default `sshd -f` config, then `exec`s
the real binary.

There is **no `/system/lib64/ksutools` layer**: no `ld-musl`, no `.so`, no
`patchelf`, no `LD_LIBRARY_PATH`.

## Why static is not optional

`/system/bin` and `/system/lib64` are **separate overlay mounts** on Android. A
dynamically linked musl binary installed under `/system/bin` needs its
interpreter from `/system/lib64/ksutools`, which only exists in namespaces that
can see *that* overlay. From any other namespace the file is present but `exec`
fails with `No such file or directory`.

Static binaries carry their own libc, so they run regardless of which overlays
the caller can see. That is the whole point of this module — and why every
release fails the build if any output still has an ELF `INTERP` or a `NEEDED`
entry.

## Installation

```sh
# ksud is not in PATH
/data/adb/ksu/bin/ksud module install ksutools-v2.0.0.zip
```

KernelSU stages new modules to `/data/adb/modules_update/<id>/`; the switch
happens **on the next reboot**. Reboot, then:

```sh
ssh root@<device>:8022          # key-only
sh verify-device.sh             # expect: RESULT: ALL PASS
```

### Upgrading from v1

v1 shipped `/system/lib64/ksutools` plus ~20 extra symlinks (`bash`, `vim`,
`htop`, `zip`, `rsync`, …). KernelSU *merges* rather than replaces a module
directory, so those stale links survive an in-place upgrade and point at
binaries that no longer exist. Move them aside instead of installing over:

```sh
mv /data/adb/modules/ksutools /data/local/old-module-v1
mv /data/adb/modules_update/ksutools /data/adb/modules/ksutools
rmdir /data/adb/modules_update
```

## sshd

- Port **8022**, key-only, host key generated on first boot, `Subsystem sftp
  internal-sftp` (no `sftp-server` binary needed).
- Persistent state: `/data/adb/ksutools`
  - `etc/ssh/` — host keys and `sshd_config` (seeded from the module on first boot)
  - `home/root/.ssh/authorized_keys` — public keys allowed to log in
  - `var/run/` — pid file
- Bundled `system/etc/ksutools/authorized_keys` is copied in only if the target
  does not exist yet, so upgrades never overwrite your keys.
- Markers:
  - `/data/adb/ksutools/no-autostart-sshd` — do not start sshd at boot
  - `KEEP_ON_UNINSTALL=1` (env) — keep `/data/adb/ksutools` when uninstalling
- `resolv.conf` is generated at boot from `dumpsys connectivity` / `getprop` and
  bind-mounted onto `/system/etc/resolv.conf`, because Android's shell has no
  `/etc/resolv.conf`.

## Building (GitHub Actions only)

Nothing is built on the host. The workflow runs three groups in parallel on a
**native arm64 runner** (`runs-on: ubuntu-24.04-arm`, no QEMU) with a persisted
`ccache`, then a `package` job merges the artifacts, verifies they are static
and zips the module. **One full round takes about 2 minutes** (cold cache).

```
build (matrix)                          package
├── core    jq + curl + libpcap/tcpdump ─┐
├── bind    dig                         ─┼─→ verify static → zip → release
└── openssh 9 ssh binaries              ─┘
```

- `build/assemble.sh <group>` — runs `alpine:3.21` with the repo mounted at
  `/work`; `build/build-static.sh <group>` compiles `all|core|bind|openssh`.
- `build/package.sh` — host side: copies the 13 binaries + CA bundle into
  `module/` and fails if anything still has `INTERP`.
- `.github/workflows/dig-debug.yml` — `workflow_dispatch`, builds `dig`
  unstripped with `-O0 -g` (`NO_STRIP=1`) for `gdb`/`strace` work.

```sh
gh workflow run build.yml                  # or just push
gh run download <run-id> -D art            # no --clobber: use a fresh dir
```

Tagging `v*` publishes the release asset.

## Build pitfalls (read before touching `build-static.sh`)

- **curl** ignores `LDFLAGS` for `src/curl` (it uses `CURL_LDFLAGS_BIN`), so
  `-static` is injected by the `CC` wrapper.
- **BIND** refuses to configure with `-static` (`AC_MSG_ERROR`) and its
  `dlopen` probe needs a *dynamic* link. It uses a second wrapper without
  `-static` (`/work/cc-plain`), gets `-all-static` only on `make -C bin/dig`,
  and must be built `--without-jemalloc`.
- **BIND, the subtle one:** `isc__initialize()` is declared `ISC_CONSTRUCTOR`
  and has no callers in the source, so a static archive link drops `lib.o`
  entirely, `trampolines` stays `NULL`, and `dig` dies instantly with
  `SIGSEGV si_addr=0x8`. The link line must carry
  `-Wl,--undefined=isc__initialize`.
- **OpenSSH** `configure` errors out if it sees `--with-ldflags=-static`;
  staticness comes from the `CC` wrapper instead. Private temp dirs are moved
  to `/data/local/tmp`, and `EPERM` from `link()` is treated as "not
  supported" (Android denies hard links on some paths).

## Notes

- Target: Android 16, arm64, kernel 6.1.x. Page size does not matter for static
  binaries.
- No package manager, no automatic upgrades: the versions above are what you
  get. Rebuild the zip to move forward.
- Never test mount behaviour with `unshare -m` + `umount` on the device —
  `/system/bin` is `shared:83` propagation, so the unmount leaks into the host
  namespace and wrecks the running system. `verify-device.sh` uses an empty
  `chroot` jail instead, which is both safer and stricter.
