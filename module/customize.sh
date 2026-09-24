#!/system/bin/sh

ui_print "- KSU Tools (musl) v1.0.0"
ui_print "- NOTE: prebuilt musl binaries require a 4096-byte page size kernel"

KSUROOT=$MODPATH/system/lib64/ksutools

set_perm_recursive "$MODPATH/system/lib64/ksutools" 0 0 0755 0755
set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/system/etc" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/usr" 0 0 0755 0755
set_perm "$MODPATH/system/bin/.ksutools-wrapper" 0 0 0755

# Each command in system/bin is a symlink to the shared launcher.
TOOLS="curl rsync jq sqlite3 openssl dig zip bash zsh htop nano vim ssh scp sshd sftp ssh-keygen ssh-add ssh-agent ssh-keyscan"
for t in $TOOLS; do
	ln -sf .ksutools-wrapper "$MODPATH/system/bin/$t"
done

# Persistent runtime dir (host keys, config, home).
mkdir -p /data/adb/ksutools/etc/ssh
mkdir -p /data/adb/ksutools/var/empty
mkdir -p /data/adb/ksutools/home/root/.ssh
mkdir -p /data/adb/ksutools/home/shell
set_perm /data/adb/ksutools 0 0 0755
set_perm_recursive /data/adb/ksutools/var/empty 0 0 0700 0700
chmod 700 /data/adb/ksutools/var/empty

# Provision the bundled root public key for passwordless SSH login.
AUTH_KEY=/data/adb/ksutools/home/root/.ssh/authorized_keys
if [ -s "$MODPATH/system/etc/ksutools/authorized_keys" ]; then
	if [ ! -s "$AUTH_KEY" ]; then
		cp "$MODPATH/system/etc/ksutools/authorized_keys" "$AUTH_KEY"
	fi
fi
chmod 700 /data/adb/ksutools/home/root/.ssh
chmod 600 "$AUTH_KEY" 2>/dev/null

ui_print "- installed tools: $TOOLS"
