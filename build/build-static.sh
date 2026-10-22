#!/bin/sh
# Build fully static musl binaries for the ksutools module.
# Runs INSIDE an arm64 Alpine container (see assemble.sh); no host build.
#
# Every user-invokable command must be static: the module is overlaid into
# /system/bin, which lives in an overlay mount. A dynamically linked musl
# binary only works in namespaces that can see /system/lib64, which is a
# SEPARATE overlay on Android -> "file exists but exec fails" elsewhere.
# Static binaries carry their own libc and work in any namespace.
set -eu

SRC=/work/src
OUT=/work/static-out
JOBS="${JOBS:-4}"

mkdir -p "$SRC" "$OUT"
cd "$SRC"

apk add --no-cache \
	build-base pkgconf linux-headers ca-certificates wget tar xz perl \
	flex bison \
	openssl-dev openssl-libs-static \
	zlib-dev zlib-static \
	nghttp2-dev nghttp2-static \
	zstd-dev zstd-static \
	libuv-dev libuv-static \
	ncurses-dev

# Force static linking at the compiler-driver level. Several upstream
# Makefiles (curl's src/Makefile uses $(CURL_LDFLAGS_BIN), not $(LDFLAGS))
# silently drop -static when it is only passed via LDFLAGS, so we wrap CC:
# compile-only steps pass through, every link step gets -static -no-pie.
cat > /work/cc-static <<'WRAP'
#!/bin/sh
for a in "$@"; do
	case "$a" in
		-c|-E|-S|-M|-MM) exec gcc "$@" ;;
	esac
done
exec gcc -static -no-pie "$@"
WRAP
chmod +x /work/cc-static
export CC=/work/cc-static

fetch() {
	# fetch <url> <outfile>; skip if already present
	[ -s "$2" ] && return 0
	wget -q --tries=5 --timeout=30 -O "$2.part" "$1"
	mv "$2.part" "$2"
}

# stage markers: make CI failures attributable at a glance
stage() { echo "===== STAGE: $* ====="; }

# Emit a static binary and fail loudly if it still has an ELF interpreter.
emit() {
	[ -f "$1" ] || { echo "FATAL: $1 missing" >&2; exit 1; }
	# Refuse libtool wrapper scripts: they are shell, not ELF.
	if [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
		echo "FATAL: $1 is not an ELF binary (libtool wrapper?)" >&2
		exit 1
	fi
	cp "$1" "$OUT/$2"
	chmod 0755 "$OUT/$2"
	if readelf -l "$OUT/$2" 2>/dev/null | grep -q 'INTERP'; then
		echo "FATAL: $2 is dynamically linked" >&2
		readelf -l "$OUT/$2" | sed -n '1,25p' >&2
		exit 1
	fi
	echo "static: $2 ($(wc -c <"$OUT/$2") bytes)"
}

# ---------------------------------------------------------------- jq 1.7.1
stage jq
fetch https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz jq.tar.gz
rm -rf jq-1.7.1 && tar xzf jq.tar.gz
(
	cd jq-1.7.1
	./configure --disable-shared --enable-static --with-oniguruma=builtin \
		--disable-maintainer-mode CFLAGS="-O2"
	# jq links through libtool: plain -static is not enough, libtool needs
	# -all-static to pass -static down to the final compiler invocation.
	make -j"$JOBS" LDFLAGS="-all-static"
)
JQ=jq-1.7.1/jq
[ -f jq-1.7.1/.libs/jq ] && JQ=jq-1.7.1/.libs/jq
emit "$JQ" jq

# --------------------------------------------------------------- curl 8.14.1
stage curl
fetch https://curl.se/download/curl-8.14.1.tar.xz curl.tar.xz
rm -rf curl-8.14.1 && tar xf curl.tar.xz
(
	cd curl-8.14.1
	./configure --disable-shared --enable-static \
		--with-openssl --with-zlib --with-nghttp2 --with-zstd \
		--without-libpsl --without-libidn2 \
		--with-ca-bundle=/system/etc/ssl/certs/ca-certificates.crt \
		--without-ca-path --enable-ipv6 \
		--disable-ldap --disable-ldaps --without-libssh2 \
		--disable-manual --disable-docs --disable-debug \
		CFLAGS="-O2" LDFLAGS="-static"
	make -j"$JOBS" -C lib
	# Command-line LDFLAGS wins over the recorded ones; curl's own makefile
	# otherwise drops -static for the src/ link.
	make -j"$JOBS" -C src curl LDFLAGS="-static -no-pie"
)
CURL=curl-8.14.1/src/curl
[ -f curl-8.14.1/src/.libs/curl ] && CURL=curl-8.14.1/src/.libs/curl
emit "$CURL" curl

# ----------------------------------------------------- libpcap + tcpdump
stage libpcap-tcpdump
fetch https://www.tcpdump.org/release/libpcap-1.10.5.tar.gz libpcap.tar.gz
rm -rf libpcap-1.10.5 && tar xzf libpcap.tar.gz
(
	cd libpcap-1.10.5
	./configure --prefix=/usr --disable-shared --enable-static CFLAGS="-O2"
	make -j"$JOBS" && make install
)
fetch https://www.tcpdump.org/release/tcpdump-4.99.5.tar.gz tcpdump.tar.gz
rm -rf tcpdump-4.99.5 && tar xzf tcpdump.tar.gz
(
	cd tcpdump-4.99.5
	./configure --prefix=/usr CFLAGS="-O2" LDFLAGS="-static"
	make -j"$JOBS" LDFLAGS="-static -no-pie"
)
emit tcpdump-4.99.5/tcpdump tcpdump

# ----------------------------------------------------------------- BIND (dig)
stage bind-dig
fetch https://downloads.isc.org/isc/bind9/9.18.50/bind-9.18.50.tar.xz bind.tar.xz
rm -rf bind-9.18.50 && tar xf bind.tar.xz
(
	cd bind-9.18.50
	# NOTE: BIND 的 configure 不能看见 -static，也不能用静态 CC 包装器：
	# 它的 libtool 探测会链接一个 dlopen 测试程序（"whether a program can dlopen
	# itself"），静态链接下必然失败，随后直接 AC_MSG_ERROR
	# （"... disables dlopen() ... RELRO, ASLR"）。
	# 所以这里用普通 gcc 做 configure/编译，只在 make 链接阶段加 -all-static。
	CC=gcc CFLAGS="-O2" ./configure --prefix=/usr --disable-shared --enable-static \
		--without-libxml2 --without-json-c --without-readline \
		--without-python --disable-linux-caps --without-cmocka
	# dig needs libisc/libdns/libirs/libisccc built first.
	make -j"$JOBS" -C lib CC=gcc
	# libtool links dig: -all-static is required to reach the compiler.
	make -j"$JOBS" -C bin/dig CC=gcc LDFLAGS="-all-static"
)
DIG=bind-9.18.50/bin/dig/dig
[ -f "$DIG" ] || DIG=bind-9.18.50/bin/dig/.libs/dig
emit "$DIG" dig

# ------------------------------------------------------------- OpenSSH 9.9p2
stage openssh
fetch https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz openssh.tar.gz
rm -rf openssh-9.9p2 && tar xzf openssh.tar.gz
(
	cd openssh-9.9p2
	# Android: /tmp does not exist for the shell user; private dirs go to /data.
	sed -i 's#"/tmp/ssh-XXXXXXXXXX"#"/data/local/tmp/ssh-XXXXXXXXXX"#' session.c
	sed -i 's#"/tmp/sshauth.XXXXXXXXXXXXXXX"#"/data/local/tmp/sshauth.XXXXXXXXXXXXXXX"#' session.c
	sed -i 's#"/tmp/ssh-XXXXXXXXXXXX"#"/data/local/tmp/ssh-XXXXXXXXXXXX"#' misc.c
	# Android refuses hard links on some paths (EPERM means unsupported here).
	sed -i 's#errno == EOPNOTSUPP || errno == ENOSYS#errno == EOPNOTSUPP || errno == ENOSYS || errno == EPERM#' sftp-server.c
	# NOTE: 不要传 --with-ldflags="-static"：OpenSSH 9.9 的 configure 见到 LDFLAGS 含
	# -static 会直接 AC_MSG_ERROR（"Static linking is not supported ..."）。
	# 静态化由全局 CC 包装器 /work/cc-static（exec gcc -static -no-pie）在链接时完成。
	./configure \
		--prefix=/system \
		--sysconfdir=/system/etc/ssh \
		--libexecdir=/system/bin/.ksutools \
		--with-pid-dir=/data/adb/ksutools/var/run \
		--with-privsep-user=root \
		--with-privsep-path=/ \
		--with-default-path=/system/bin:/system/xbin \
		--with-maildir=/data/adb/ksutools/var/mail \
		--without-pam --without-kerberos5 --without-libedit \
		--without-security-key --without-selinux --without-audit \
		--disable-utmp --disable-wtmp --disable-utmpx --disable-wtmpx \
		--disable-lastlog --disable-strip \
		--with-cflags="-O2"
	make -j"$JOBS" sshd sshd-session ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan
)
for b in sshd sshd-session ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan; do
	emit "openssh-9.9p2/$b" "$b"
done

echo "--- static binaries in $OUT ---"
ls -l "$OUT"
