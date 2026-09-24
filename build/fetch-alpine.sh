#!/bin/sh
# Fetch prebuilt aarch64 musl packages from Alpine and stage their files.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/alpine-rootfs"
rm -rf "$OUT"
mkdir -p "$OUT"

docker run --rm -v "$OUT:/out" alpine:3.21 sh -eux -c '
	apk add --no-cache \
		curl rsync jq sqlite openssl bind-tools zip bash zsh htop nano vim \
		openssh-client ncurses-terminfo-base ca-certificates
	echo "--- layout ---"
	ls -ld /bin /sbin /lib /usr/bin /usr/lib /etc/terminfo /usr/share/terminfo 2>&1 || true
	tar -C / -cf /out/rootfs.tar \
		--exclude=./usr/share/man \
		--exclude=./usr/share/doc \
		./usr ./lib ./bin ./sbin ./etc/ssl ./etc/ssh ./etc/terminfo
'

tar -C "$OUT" -xf "$OUT/rootfs.tar"
rm -f "$OUT/rootfs.tar"

echo "== staged tools =="
ls "$OUT/usr/bin"
