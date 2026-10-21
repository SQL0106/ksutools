#!/usr/bin/env bash
# Host entry point: build everything inside an arm64 Alpine container.
# No native build on the host, no cross toolchain, no QEMU-only surprises.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$(cd "$HERE/.." && pwd)/module"

mkdir -p "$MOD/system/bin/.ksutools" "$MOD/system/etc/ssl/certs" "$MOD/system/etc/ssh"

exec docker run --rm \
	--platform linux/arm64 \
	-v "$HERE:/work" \
	-v "$MOD:/mod" \
	alpine:3.21 \
	sh -eux /work/assemble-inner.sh
