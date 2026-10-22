#!/usr/bin/env bash
# Host-side packaging: copy the static binaries produced by build/assemble.sh
# (or downloaded from the CI build jobs) into module/ and verify they are
# really static. No docker needed.
#
# Usage: bash build/package.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MOD="$ROOT/module"
OUT="$HERE/static-out"
KSDIR="$MOD/system/bin/.ksutools"

TOOLS="curl jq dig tcpdump ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan sshd sshd-session"

mkdir -p "$KSDIR" "$MOD/system/etc/ssl/certs"

for t in $TOOLS; do
	[ -f "$OUT/$t" ] || { echo "FATAL: $OUT/$t missing" >&2; exit 1; }
	cp "$OUT/$t" "$KSDIR/$t"
	chmod 0755 "$KSDIR/$t"
done

[ -f "$OUT/ca-certificates.crt" ] || { echo "FATAL: ca-certificates.crt missing" >&2; exit 1; }
cp "$OUT/ca-certificates.crt" "$MOD/system/etc/ssl/certs/ca-certificates.crt"

echo "--- verify static ---"
fail=0
for t in $TOOLS; do
	if readelf -l "$KSDIR/$t" 2>/dev/null | grep -q 'INTERP'; then
		echo "DYNAMIC: $t" >&2
		fail=1
	fi
done
[ "$fail" = 0 ] || { echo "FATAL: dynamic binaries in payload" >&2; exit 1; }

ls -l "$KSDIR"
du -sh "$KSDIR"
echo "PACKAGE OK"
