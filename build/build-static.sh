#!/bin/sh
# Build fully static musl binaries for the ksutools module.
# Runs INSIDE an arm64 Alpine container (see assemble.sh); no host build.
#
# Every user-invokable command must be static: the module is overlaid into
# /system/bin, which lives in an overlay mount. A dynamically linked musl
# binary only works in namespaces that can see /system/lib64, which is a
# SEPARATE overlay on Android -> "file exists but exec fails" elsewhere.
# Static binaries carry their own libc and work in any namespace.
#
# Usage: build-static.sh [all|core|bind|openssh]
#   core    = jq + curl + libpcap/tcpdump   (~most of the wall time)
#   bind    = dig
#   openssh = sshd/sshd-session + ssh/scp/sftp/ssh-keygen/ssh-add/ssh-agent/ssh-keyscan
# The groups are independent so CI can build them in parallel jobs.
set -eu

SRC=/work/src
OUT=/work/static-out
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
GROUP="${1:-all}"

mkdir -p "$SRC" "$OUT"
cd "$SRC"

apk add --no-cache \
	build-base pkgconf linux-headers ca-certificates wget tar xz perl \
	flex bison ccache \
	openssl-dev openssl-libs-static \
	zlib-dev zlib-static \
	nghttp2-dev nghttp2-static \
	zstd-dev zstd-static \
	libuv-dev libuv-static \
	ncurses-dev

# ---------------------------------------------------------------- ccache
# Cache lives on the host via the /work bind mount, so CI can persist it
# with actions/cache. Paths are made relative to /work/src so the cache
# survives checkout-directory changes.
export CCACHE_DIR=/work/.ccache
export CCACHE_BASEDIR=/work/src
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
export CCACHE_MAXSIZE=3G
mkdir -p "$CCACHE_DIR"

# Force static linking at the compiler-driver level. Several upstream
# Makefiles (curl's src/Makefile uses $(CURL_LDFLAGS_BIN), not $(LDFLAGS))
# silently drop -static when it is only passed via LDFLAGS, so we wrap CC:
# compile-only steps pass through, every link step gets -static -no-pie.
cat > /work/cc-static <<'WRAP'
#!/bin/sh
for a in "$@"; do
	case "$a" in
		-c|-E|-S|-M|-MM) exec ccache gcc "$@" ;;
	esac
done
exec ccache gcc -static -no-pie "$@"
WRAP
chmod +x /work/cc-static

# Same thing without the -static injection: for projects whose configure
# probes dlopen() (BIND) and therefore must still be able to link dynamically.
cat > /work/cc-plain <<'WRAP'
#!/bin/sh
exec ccache gcc "$@"
WRAP
chmod +x /work/cc-plain
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
	# Static + unstripped is huge (OpenSSH ~15MB each). Strip; keeps ELF static.
	# NO_STRIP=1 keeps symbols for post-mortem debugging (dig-debug.yml).
	if [ "${NO_STRIP:-0}" = "1" ]; then
		echo "keeping symbols: $2"
	else
		strip --strip-all "$OUT/$2" 2>/dev/null || true
	fi
	if readelf -l "$OUT/$2" 2>/dev/null | grep -q 'INTERP'; then
		echo "FATAL: $2 became dynamic after strip" >&2
		exit 1
	fi
	echo "static: $2 ($(wc -c <"$OUT/$2") bytes)"
}

# CA bundle ships with the module; any group can produce it (it is tiny).
cp /etc/ssl/certs/ca-certificates.crt "$OUT/ca-certificates.crt"

# ---------------------------------------------------------------- jq 1.7.1
build_jq() {
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
}

# --------------------------------------------------------------- curl 8.14.1
build_curl() {
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
}

# ----------------------------------------------------- libpcap + tcpdump
build_tcpdump() {
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
}

# ---------------------------------------------------------------- libuv
# Alpine's libuv-static is the default. LIBUV_FROM_SOURCE=1 builds it here
# instead, which we need to (a) get debug symbols on Linux and (b) kill the
# io_uring backend: on Android kernels io_uring_setup() succeeds and libuv
# then crashes with a NULL+8 dereference, which takes BIND's dig down with it.
build_libuv() {
	stage libuv-from-source
	fetch https://dist.libuv.org/dist/v1.48.0/libuv-v1.48.0.tar.gz libuv.tar.gz
	rm -rf libuv-v1.48.0 && tar xzf libuv.tar.gz
	(
		cd libuv-v1.48.0
		if [ "${LIBUV_DISABLE_IO_URING:-0}" = "1" ]; then
			# Make the syscall wrapper itself bogus: every io_uring_setup()
			# returns -ENOSYS, so libuv takes its normal epoll fallback path.
			sed -i 's|__NR_io_uring_setup|(-1L)|g' src/unix/linux.c
			grep -c '(-1L)' src/unix/linux.c || true
		fi
		./configure --prefix=/usr --disable-shared --enable-static \
			CFLAGS="${LIBUV_CFLAGS:--O2}"
		make -j"$JOBS"
		make install
	)
}

# ----------------------------------------------------------------- BIND (dig)
build_dig() {
	stage bind-dig
	if [ "${LIBUV_FROM_SOURCE:-0}" = "1" ]; then
		build_libuv
	fi
	fetch https://downloads.isc.org/isc/bind9/9.18.50/bind-9.18.50.tar.xz bind.tar.xz
	rm -rf bind-9.18.50 && tar xf bind.tar.xz
	(
		cd bind-9.18.50
		# NOTE: BIND 的 configure 不能看见 -static，也不能用静态 CC 包装器：
		# 它的 libtool 探测会链接一个 dlopen 测试程序（"whether a program can dlopen
		# itself"），静态链接下必然失败。所以这里用 /work/cc-plain（普通 gcc +
		# ccache，不注入 -static）做 configure/编译，只在 make 链接阶段加 -all-static。
		#
		# 但光这样还不够：BIND 的 configure.ac 里有一条显式禁令——
		#   AS_IF([test "$enable_static" != "no" && test "$enable_developer" != "yes"],
		#         [AC_MSG_ERROR([Static linking is not supported ...])])
		# 也就是说它**根本不允许**静态构建（dig 其实不需要 dlopen）。
		# 唯一绕过开关是 --enable-developer，但那会连带打开 -Werror、内存跟踪等，
		# 反而更脆。所以直接把生成的 configure 里那行 as_fn_error 改成 no-op。
		sed -i 's|as_fn_error \$? "Static linking is not supported.*|:|' configure
		# NOTE: --without-jemalloc 是必须的。BIND 9.18 默认链自带 jemalloc
		# （strings dig 会看到 jemalloc_shim.h），在 musl 静态链接下 jemalloc 会在
		# 启动期 segfault（rc=139，与参数无关）。Alpine 官方打包 BIND 也关它。
		CC=/work/cc-plain CFLAGS="${DIG_CFLAGS:--O2}" ./configure --prefix=/usr --disable-shared --enable-static \
			--without-libxml2 --without-json-c --without-readline \
			--without-python --disable-linux-caps --without-cmocka \
			--without-jemalloc
		# dig needs libisc/libdns/libirs/libisccc built first.
		make -j"$JOBS" -C lib CC=/work/cc-plain
		# libtool links dig: -all-static is required to reach the compiler.
		make -j"$JOBS" -C bin/dig CC=/work/cc-plain LDFLAGS="-all-static"
	)
	DIG=bind-9.18.50/bin/dig/dig
	[ -f "$DIG" ] || DIG=bind-9.18.50/bin/dig/.libs/dig
	emit "$DIG" dig
}

# ------------------------------------------------------------- OpenSSH 9.9p2
build_openssh() {
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
}

echo "===== group: $GROUP / jobs: $JOBS ====="
case "$GROUP" in
	all)
		build_jq
		build_curl
		build_tcpdump
		build_dig
		build_openssh
		;;
	core)
		build_jq
		build_curl
		build_tcpdump
		;;
	bind) build_dig ;;
	openssh) build_openssh ;;
	*)
		echo "FATAL: unknown group '$GROUP' (all|core|bind|openssh)" >&2
		exit 2
		;;
esac

ccache -s || true

echo "--- static binaries in $OUT ---"
ls -l "$OUT"
