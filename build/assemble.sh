#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../module"
mkdir -p "$MOD/system/lib64/ksutools" "$MOD/system/etc/ssl/certs" "$MOD/system/etc/ssh"
docker run --rm --platform linux/arm64 -v "$HERE:/work" -v "$MOD:/mod" alpine:3.21 sh -eux /work/assemble-inner.sh
echo "=== assemble done ==="
