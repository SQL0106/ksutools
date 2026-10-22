#!/usr/bin/env bash
# Host entry point: run one build group inside an arm64 Alpine container.
#
# Usage: bash build/assemble.sh [all|core|bind|openssh]
#
# On an arm64 runner (ubuntu-24.04-arm) the container runs natively; --platform
# is kept so the same script still works on x86 hosts (slowly, via binfmt).
# Output lands in build/static-out/ (host-visible via the bind mount).
# Copying into module/ is package.sh's job.
set -euo pipefail

GROUP="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HERE/static-out" "$HERE/.ccache"

exec docker run --rm \
	--platform linux/arm64 \
	-v "$HERE:/work" \
	-e "JOBS=${JOBS:-}" \
	alpine:3.21 \
	sh -eux /work/build-static.sh "$GROUP"
