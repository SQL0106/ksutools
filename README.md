# ksutools

Static musl userspace tools for the Android shell, shipped as a KernelSU module.

The module only provides `system/` content — mounting is left to a metamodule
(`meta-overlayfs`, `hybrid-mount`, …).

## Tools

| group | commands |
|---|---|
| HTTP | `curl` |
| JSON | `jq` |
| DNS | `dig` |
| capture | `tcpdump` |
| SSH | `sshd`, `ssh`, `scp`, `sftp`, `ssh-keygen`, `ssh-add`, `ssh-agent`, `ssh-keyscan` |

All of them are **fully static** binaries (musl, no `ld-musl`, no shared
libraries, no `patchelf`, no `LD_LIBRARY_PATH`).

### Why static is not optional

`/system/bin` and `/system/lib64` are **separate overlay mounts** on Android.
A dynamically linked musl binary installed under `/system/bin` needs its
interpreter from `/system/lib64/ksutools`, which only exists in namespaces that
can see that particular overlay. From any other namespace (an app's shell,
another mount namespace, a container) the file is present but `exec` fails with
`No such file or directory`.

Static binaries carry their own libc, so they run regardless of which overlays
the caller can see. That is the whole point of this module.

## Installation

1. Flash the zip via KernelSU / Magisk.
2. Mount the module's `system/` with a metamodule and reboot.
3. `ssh root@<device>:8022` (key-only).

Commands are symlinks to `.ksutools-wrapper`, which sets `HOME`, `TMPDIR`,
`SSL_CERT_FILE` and the default `sshd -f` config.

## sshd

- Port **8022**, key-only, host keys generated on first boot.
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

Nothing is built on the host. `build/assemble.sh` runs an arm64 Alpine container
(QEMU on the runner) and:

- `build/build-static.sh` — downloads upstream sources and compiles
  `curl 8.14.1`, `jq 1.7.1`, `libpcap 1.10.5` + `tcpdump 4.99.5`,
  `BIND 9.18.50` (`dig`) and `OpenSSH 9.9p2` with `--disable-shared
  --enable-static`, then fails if any output still has an ELF interpreter.
- `build/assemble-inner.sh` — copies the binaries into
  `module/system/bin/.ksutools/` plus the CA bundle.

```sh
bash build/assemble.sh                     # local (needs docker)
gh workflow run build.yml                  # or just push
```

Tagging `v*` publishes a release asset.

## Notes

- Target: Android 16, arm64, kernel 6.1.x. Page size does not matter for static
  binaries (v1's 4096-byte constraint is gone with the musl loader).
- Android-specific patches: OpenSSH private temp dirs are moved to
  `/data/local/tmp`, and `EPERM` from `link()` is treated as "not supported"
  (Android denies hard links on some paths).
- No package manager, no automatic upgrades: the versions above are what you
  get. Rebuild the zip to move forward.
