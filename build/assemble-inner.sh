#!/bin/sh
# Assemble the module payload from the static build. Runs inside the arm64
# Alpine container; /work is build/, /mod is module/.
set -eu

MOD=/mod
KSDIR="$MOD/system/bin/.ksutools"

mkdir -p "$KSDIR" "$MOD/system/etc/ssl/certs" "$MOD/system/etc/ssh"

sh /work/build-static.sh

# User-invokable commands (symlinked to the launcher) plus sshd helpers.
for t in curl jq dig tcpdump \
	ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan \
	sshd sshd-session; do
	cp "/work/static-out/$t" "$KSDIR/$t"
	chmod 0755 "$KSDIR/$t"
done

# CA bundle for curl/ssh (overlaid at /system/etc/ssl/certs).
cp /etc/ssl/certs/ca-certificates.crt "$MOD/system/etc/ssl/certs/ca-certificates.crt"

ls -l "$KSDIR"
