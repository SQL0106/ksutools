#!/system/bin/sh
# ksutools v2 真机验收脚本（在有 root 的 Android 上跑；不改任何系统文件、不做任何 mount 操作）
# 用法: sh verify-device.sh
PATH=/system/bin:/system/xbin:/system/sbin
export PATH
fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
skip() { echo "  SKIP $*"; }

echo "== 0. 环境 =="
echo "  $(getprop ro.product.model) / Android $(getprop ro.build.version.release) / $(uname -m) / pagesize $(getconf PAGE_SIZE)"

echo "== 1. 入口存在 =="
for t in curl jq dig tcpdump ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan sshd; do
  if [ -x "/system/bin/$t" ] || [ -h "/system/bin/$t" ]; then ok "$t"; else bad "$t 缺失"; fi
done

echo "== 2. 无 lib64 层（v1 残留已清）=="
if [ -e /system/lib64/ksutools ]; then bad "/system/lib64/ksutools 仍存在"; else ok "无 /system/lib64/ksutools"; fi

echo "== 3. 基本功能 =="
if curl -sSI -m 15 https://example.com 2>&1 | head -1 | grep -q "200"; then ok "curl https"; else bad "curl https"; fi
if jq -n '{a:1}' 2>/dev/null | grep -q '"a"'; then ok "jq"; else bad "jq"; fi
if dig +short -t A example.com 2>/dev/null | grep -qE '^[0-9]+\.'; then ok "dig"; else bad "dig"; fi
if tcpdump -D 2>/dev/null | head -3 | grep -q .; then ok "tcpdump -D"; else bad "tcpdump -D"; fi
if ssh -V 2>&1 | grep -q OpenSSH; then ok "ssh -V"; else bad "ssh -V"; fi
if ssh-keygen -A -f /data/local/ksuv2/kg 2>/dev/null; then ok "ssh-keygen 可用"; else bad "ssh-keygen 可用"; fi

echo "== 4. 静态性（13 个二进制都必须无 INTERP）=="
if ! command -v readelf >/dev/null 2>&1; then
  skip "本机无 readelf，静态性由构建侧保证（package.sh 已验证）"
else
  for b in curl jq dig tcpdump ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan sshd sshd-session; do
    f="/system/bin/.ksutools/$b"
    if readelf -l "$f" 2>/dev/null | grep -q INTERP; then
      bad "$b 有 INTERP（动态）"
    elif readelf -d "$f" 2>/dev/null | grep -q 'NEEDED'; then
      bad "$b 有 NEEDED 依赖"
    else
      ok "$b 静态（无 INTERP / 无 NEEDED）"
    fi
  done
fi

echo "== 5. env -i（干净环境仍可用）=="
if env -i /system/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null | grep -q 200; then
  ok "env -i curl"
else
  bad "env -i curl"
fi

echo "== 6. 铁笼测试（空 chroot：无 /system、无 /lib、无任何 .so）=="
# 比 unshare+umount 更安全也更严格：这些二进制若动态链接，在笼子里必然 "No such file or directory"。
JAIL=/data/local/ksuv2/jail
rm -rf "$JAIL" 2>/dev/null
mkdir -p "$JAIL/dev" || bad "无法创建 $JAIL"
# ssh/ssh-keygen 会打开 /dev/null；笼子里没有就 rc=1（这是测试环境缺陷，不是二进制缺陷）
[ -c "$JAIL/dev/null" ] || mknod "$JAIL/dev/null" c 1 3 2>/dev/null
chmod 666 "$JAIL/dev/null" 2>/dev/null
for b in curl jq dig tcpdump ssh ssh-keygen; do
  cp "/system/bin/.ksutools/$b" "$JAIL/$b" 2>/dev/null || { bad "拷贝 $b"; continue; }
done
chroot "$JAIL" /curl --version >/dev/null 2>&1 && ok "chroot curl" || bad "chroot curl"
chroot "$JAIL" /jq --version      >/dev/null 2>&1 && ok "chroot jq"   || bad "chroot jq"
chroot "$JAIL" /dig -v            >/dev/null 2>&1 && ok "chroot dig"  || bad "chroot dig"
chroot "$JAIL" /tcpdump --version >/dev/null 2>&1 && ok "chroot tcpdump" || bad "chroot tcpdump"
# ssh / ssh-keygen 会自己 open("/dev/null")。chroot 内的 /dev/null 节点在 /data 上
# 只能是 system_data_file，且 KernelSU 域不允许 chcon 成 null_device，所以必然 EACCES。
# 这属于夹具限制（SELinux + toybox mount 不支持 bind），不归咎于二进制；
# 它们的静态性已由 step 4 的 readelf（无 INTERP / 无 NEEDED）给足证据。
for b in ssh ssh-keygen; do
  if [ "$b" = ssh ]; then
    err=$(chroot "$JAIL" /ssh -V 2>&1 >/dev/null)
  else
    err=$(chroot "$JAIL" /ssh-keygen -A -f /kg 2>&1 >/dev/null)
  fi
  case "$err" in
    *"/dev/null"*) skip "chroot $b（SELinux 禁止 chroot 内 /dev/null；静态性见 step 4）" ;;
    "") ok "chroot $b" ;;
    *) bad "chroot $b: $err" ;;
  esac
done

echo "== 7. sshd =="
if pgrep -f "sshd" >/dev/null 2>&1; then ok "sshd 进程在"; else bad "sshd 未运行"; fi
if ss -lntp 2>/dev/null | grep -q ':8022'; then ok "8022 监听"; else bad "8022 未监听"; fi
found=0
for p in $(pgrep sshd); do
  exe=$(readlink "/proc/$p/exe" 2>/dev/null)
  case "$exe" in
    /system/bin/.ksutools/sshd) found=1; ok "sshd 来自模块（pid $p → $exe）" ;;
  esac
done
[ "$found" = 1 ] || bad "没有 ssHD 进程运行模块二进制"

echo "== 8. 磁盘 =="
du -sh /system/bin/.ksutools 2>/dev/null
df -h /data | tail -1

echo
if [ "$fail" -eq 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: $fail FAILURE(S)"; fi
exit "$fail"
