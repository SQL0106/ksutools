#!/usr/bin/env bash
# Build sshd (OpenSSH 9.9p2) with Alpine musl for the Android KSU module.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

[ -f openssh-9.9p2.tar.gz ] || curl -fsSL -o openssh-9.9p2.tar.gz \
	https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz
[ -d openssh-9.9p2 ] || tar xzf openssh-9.9p2.tar.gz

docker run --rm -v "$HERE":/work -w /work alpine:3.21 sh -eux -c '
	apk add --no-cache build-base openssl-dev zlib-dev wget ca-certificates

	# fresh source copy each run
	rm -rf /work/ssh-src /work/ssh-obj /work/sshd-out
	cp -a /work/openssh-9.9p2 /work/ssh-src
	cd /work/ssh-src

	# --- Android/musl tweaks ---
	# Android has no /tmp; route runtime temp files to /data/local/tmp.
	sed -i "s#\"/tmp/ssh-XXXXXXXXXX\"#\"/data/local/tmp/ssh-XXXXXXXXXX\"#"   session.c
	sed -i "s#\"/tmp/sshauth.XXXXXXXXXXXXXXX\"#\"/data/local/tmp/sshauth.XXXXXXXXXXXXXXX\"#" session.c
	sed -i "s#\"/tmp/ssh-XXXXXXXXXXXX\"#\"/data/local/tmp/ssh-XXXXXXXXXXXX\"#"         misc.c
	# Android filesystems often reject hardlink() with EPERM (not EOPNOTSUPP).
	sed -i "s#errno == EOPNOTSUPP || errno == ENOSYS#errno == EOPNOTSUPP || errno == ENOSYS || errno == EPERM#" sftp-server.c

	mkdir -p /work/ssh-obj
	cd /work/ssh-obj
	/work/ssh-src/configure \
		--prefix=/system \
		--sysconfdir=/data/adb/ksutools/etc/ssh \
		--libexecdir=/system/lib64/ksutools \
		--with-pid-dir=/data/adb/ksutools/var/run \
		--with-privsep-user=root \
		--with-privsep-path=/ \
		--with-default-path=/system/bin:/system/xbin \
		--with-maildir=/data/adb/ksutools/var/mail \
		--without-pam \
		--without-kerberos5 \
		--without-libedit \
		--without-security-key \
		--without-selinux \
		--without-audit \
		--disable-utmp \
		--disable-wtmp \
		--disable-utmpx \
		--disable-wtmpx \
		--disable-lastlog \
		--disable-strip \
		--with-cflags="-O2 -fPIE" \
		--with-ldflags="-pie"

	make -j"$(nproc)" sshd sshd-session sftp-server

	mkdir -p /work/sshd-out
	for b in sshd sshd-session sftp-server; do
		cp -f "$b" /work/sshd-out/"$b"
	done
	ls -l /work/sshd-out
'
