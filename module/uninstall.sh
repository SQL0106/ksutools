#!/system/bin/sh
# Remove persistent runtime data on uninstall, unless the keep marker exists.

KSUDATA=/data/adb/ksutools

if [ -e "$KSUDATA/KEEP_ON_UNINSTALL" ]; then
	exit 0
fi

umount /system/etc/resolv.conf 2>/dev/null
rm -rf "$KSUDATA"
