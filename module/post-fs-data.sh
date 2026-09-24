#!/system/bin/sh
# KernelSU post-fs-data: runs as root, before the module is mounted.
# Just make sure the persistent runtime tree exists with sane permissions.

KSUDATA=/data/adb/ksutools

mkdir -p "$KSUDATA/etc/ssh" "$KSUDATA/var/empty" "$KSUDATA/home/root" "$KSUDATA/home/shell" 2>/dev/null
chmod 700 "$KSUDATA/var/empty" 2>/dev/null
chmod 700 "$KSUDATA/etc/ssh" 2>/dev/null
