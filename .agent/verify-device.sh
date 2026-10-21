#!/system/bin/sh
# ksutools v2 真机验收脚本（在有 root 的 Android 上跑；不改任何系统文件）
# 用法: sh /data/adb/ksutools/verify-device.sh  或  scp 后 sh verify-device.sh
PATH=/system/bin:/system/xbin:/system/sbin
export PATH
fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }

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

echo "== 4. 静态性（无解释器即不依赖 musl loader）=="
for b in curl jq dig tcpdump; do
  if readelf -l "/system/bin/.ksutools/$b" 2>/dev/null | grep -q INTERP; then
    bad "$b 有 INTERP（动态）"
  else
    ok "$b 静态"
  fi
done

echo "== 5. env -i（干净环境仍可用）=="
if env -i /system/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null | grep -q 200; then
  ok "env -i curl"
else
  bad "env -i curl"
fi

echo "== 6. 陌生 namespace（关键回归）=="
# 在挂载 namespace 里卸掉 /system 的 overlay 后执行；成功即证明不依赖 /system/lib64
if command -v unshare >/dev/null 2>&1; then
  if unshare -m sh -c 'umount -l /system/lib64 2>/dev/null; umount -l /system/usr 2>/dev/null; /system/bin/curl -sS -m 15 -o /dev/null -w "%{http_code}" https://example.com' 2>/dev/null | grep -q 200; then
    ok "命名空间内 curl"
  else
    bad "命名空间内 curl"
  fi
else
  echo "  SKIP 无 unshare（用 busybox 再试）"
  BB=/data/adb/box_bll/bin/busybox
  if [ -x "$BB" ] && "$BB" unshare -m sh -c 'umount -l /system/lib64 2>/dev/null; /system/bin/curl -sS -m 15 -o /dev/null -w "%{http_code}" https://example.com' 2>/dev/null | grep -q 200; then
    ok "命名空间内 curl (busybox)"
  else
    bad "命名空间内 curl (busybox)"
  fi
fi

echo "== 7. sshd =="
if pgrep -f "sshd" >/dev/null 2>&1; then ok "sshd 进程在"; else bad "sshd 未运行"; fi
if ss -lntp 2>/dev/null | grep -q ':8022'; then ok "8022 监听"; else bad "8022 未监听"; fi

echo "== 8. 磁盘 =="
du -sh /system/bin/.ksutools 2>/dev/null
df -h /data | tail -1

echo
if [ "$fail" -eq 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: $fail FAILURE(S)"; fi
exit "$fail"
