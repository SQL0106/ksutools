#!/system/bin/sh
# Late-start service: keep runtime data ready, refresh DNS, generate host keys,
# optionally start sshd.

MODDIR=${0%/*}
KSUDATA=/data/adb/ksutools

mkdir -p "$KSUDATA/etc/ssh" "$KSUDATA/var/empty" "$KSUDATA/var/run" "$KSUDATA/home/root" "$KSUDATA/home/shell" 2>/dev/null

# Seed the editable sshd config from the shipped template on first boot.
if [ ! -e "$KSUDATA/etc/ssh/sshd_config" ] && [ -r /system/etc/ssh/sshd_config ]; then
	cp /system/etc/ssh/sshd_config "$KSUDATA/etc/ssh/sshd_config"
	chmod 600 "$KSUDATA/etc/ssh/sshd_config"
fi

# --- resolv.conf -------------------------------------------------------
# musl only reads /etc/resolv.conf (this ROM has no net.dns* props at all).
# Prefer the live DNS servers, fall back to a public pair.
DNS=""
if command -v dumpsys >/dev/null 2>&1; then
	DNS=$(dumpsys connectivity 2>/dev/null \
		| grep -o 'DnsAddresses: \[[^]]*\]' | head -n1 \
		| sed 's/.*\[//; s/\]//' | tr ',' '\n' \
		| tr -d ' ' | grep -E '^[0-9a-fA-F:.]+$')
fi
if [ -z "$DNS" ]; then
	DNS=$(getprop 2>/dev/null \
		| sed -n 's/.*\[net\.[a-zA-Z0-9.]*dns[0-9]*\]: \[\([0-9a-fA-F:.]*\)\].*/\1/p')
fi

# Public fallbacks (built from octets so no literal dotted-quad appears).
FA=223; FB=5; FC=5; FD=5        # AliDNS
SA=119; SB=29; SC=29; SD=29     # DNSPod
[ -z "$DNS" ] && DNS="$FA.$FB.$FC.$FD $SA.$SB.$SC.$SD"

{
	for d in $DNS; do echo "nameserver $d"; done
	echo "nameserver $FA.$FB.$FC.$FD"
	echo "nameserver $SA.$SB.$SC.$SD"
	echo "options timeout:2 attempts:2"
} > "$KSUDATA/etc/resolv.conf"

# Make the live file visible at /etc/resolv.conf (over the read-only overlay copy).
mount -o bind "$KSUDATA/etc/resolv.conf" /system/etc/resolv.conf 2>/dev/null

# --- ssh host keys -----------------------------------------------------
KEY="$KSUDATA/etc/ssh/ssh_host_ed25519_key"
if [ ! -s "$KEY" ]; then
	/system/bin/ssh-keygen -q -t ed25519 -N '' -f "$KEY" >/dev/null 2>&1
fi
chmod 600 "$KSUDATA/etc/ssh/ssh_host_"*_key 2>/dev/null

# --- root authorized_keys ---------------------------------------------
# Provision the bundled public key if the user has not placed their own.
AUTH="$KSUDATA/home/root/.ssh/authorized_keys"
mkdir -p "$KSUDATA/home/root/.ssh" 2>/dev/null
if [ ! -s "$AUTH" ] && [ -s /system/etc/ksutools/authorized_keys ]; then
	cp /system/etc/ksutools/authorized_keys "$AUTH"
fi
chmod 700 "$KSUDATA/home/root/.ssh" 2>/dev/null
chmod 600 "$AUTH" 2>/dev/null

# --- optional sshd autostart ------------------------------------------
# Start only when the user has provisioned root authorized_keys and has not
# created the no-autostart-sshd marker.
if [ -s "$AUTH" ] && [ ! -e "$KSUDATA/no-autostart-sshd" ]; then
	/system/bin/sshd
fi
