#!/bin/sh
set -eu

apk add --no-cache curl rsync jq sqlite openssl bind-tools zip bash zsh htop \
	nano vim openssh-client ncurses-terminfo-base ca-certificates patchelf >/dev/null

DEST=/mod/system/lib64/ksutools
rm -rf "$DEST"
mkdir -p "$DEST"

TOOLS="curl rsync jq sqlite3 openssl dig zip bash zsh htop nano vim ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan"

for t in $TOOLS; do
	src=""
	for d in /bin /usr/bin /sbin /usr/sbin; do
		if [ -e "$d/$t" ] && [ ! -d "$d/$t" ]; then
			src="$(readlink -f "$d/$t")"
			break
		fi
	done
	if [ -z "$src" ]; then
		echo "MISSING tool: $t" >&2
		exit 1
	fi
	cp -f "$src" "$DEST/$t"
done

for b in sshd sshd-session sftp-server; do
	cp -f "/work/sshd-out/$b" "$DEST/$b"
done

cp -f /lib/ld-musl-aarch64.so.1 "$DEST/"

for f in "$DEST"/*; do
	bn="$(basename "$f")"
	[ "$bn" = ld-musl-aarch64.so.1 ] && continue
	ldd "$f" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | while read -r L; do
		case "$L" in
			*ld-musl*) continue ;;
		esac
		SON="$(patchelf --print-soname "$L" 2>/dev/null || true)"
		[ -n "$SON" ] || SON="$(basename "$L")"
		cp -f "$L" "$DEST/$SON"
	done
done

for f in "$DEST"/*; do
	bn="$(basename "$f")"
	[ "$bn" = ld-musl-aarch64.so.1 ] && continue
	patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
	if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
		patchelf --set-interpreter /system/lib64/ksutools/ld-musl-aarch64.so.1 "$f"
	fi
done
chmod 0755 "$DEST"/*

cp -f /etc/ssl/certs/ca-certificates.crt /mod/system/etc/ssl/certs/
cp -f /etc/ssl/openssl.cnf /mod/system/etc/ssl/
rm -rf /mod/system/usr/lib/ossl-modules
mkdir -p /mod/system/usr/lib/ossl-modules
cp -a /usr/lib/ossl-modules/. /mod/system/usr/lib/ossl-modules/
rm -rf /mod/system/etc/terminfo
mkdir -p /mod/system/etc/terminfo
cp -a /etc/terminfo/. /mod/system/etc/terminfo/
cp -f /etc/ssh/ssh_config /mod/system/etc/ssh/

rm -rf /mod/system/usr/share/vim
mkdir -p /mod/system/usr/share
cp -a /usr/share/vim /mod/system/usr/share/vim

# zsh modules (/usr/lib/zsh) + completion functions (/usr/share/zsh)
rm -rf /mod/system/usr/lib/zsh /mod/system/usr/share/zsh
mkdir -p /mod/system/usr/lib
cp -a /usr/lib/zsh /mod/system/usr/lib/zsh
cp -a /usr/share/zsh /mod/system/usr/share/zsh

find /mod/system/usr/lib/zsh -name '*.so' | while read -r m; do
	ldd "$m" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | while read -r L; do
		case "$L" in
			*ld-musl*) continue ;;
		esac
		SON="$(patchelf --print-soname "$L" 2>/dev/null || true)"
		[ -n "$SON" ] || SON="$(basename "$L")"
		cp -f "$L" "$DEST/$SON"
	done
	patchelf --set-rpath /system/lib64/ksutools "$m" 2>/dev/null || true
done
chmod 0755 "$DEST"/*

echo "=== DEST listing ==="
ls -la "$DEST"
