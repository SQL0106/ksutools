# ksutools（KernelSU 模块：全静态命令行工具）

> 上层：`~/.config/opencode/AGENTS.md`（通法）、`~/AGENTS.md`（本机/目标机事实）。
> 本文件只写本仓库的构建与验证。

## 是什么
给 Android（KernelSU）提供**完全静态**的 musl 二进制：`curl jq dig tcpdump scp sftp ssh ssh-add ssh-agent ssh-keygen ssh-keyscan sshd` + `sshd-session`（13 个）。
安装在 `/system/bin/.ksutools/`，`/system/bin/` 下 12 个相对符号链接指向 `.ksutools-wrapper`。**没有** `/system/lib64/ksutools` 层（v1 的 loader/patchelf 方案已废弃）。

## 目录
- `build/build-static.sh <group>`：真正编译（在容器/CI 里跑）。
- `build/assemble.sh <group>`：本机入口包装（起容器）。
- `build/package.sh`：打 release zip。
- `build/patches/`：curl / BIND / OpenSSH 等的补丁。
- `build/{openssh-9.9p2,ssh-src,ssh-obj,sshd-out,alpine-rootfs,omz-src}`：源码与中间产物（勿手改）。
- `module/`：`module.prop`、`customize.sh`、`post-fs-data.sh`、`service.sh`、`uninstall.sh`、`system/`（overlay 树）。
- `.agent/verify-device.sh`：设备侧验收脚本，要求 `RESULT: ALL PASS`。
- `ksutools-v1.0.0.zip`：v1 遗留产物。

## 构建（**本机不编译，会掉电**）
- CI：`.github/workflows/build.yml`，`runs-on: ubuntu-24.04-arm` + ccache + 三组 matrix：`core`(jq/curl/tcpdump) / `bind`(dig) / `openssh`，末尾 `package` job 汇总验静态并打包。一轮约 2 分钟。
- 触发：`gh workflow run build.yml --ref main`；查结果 `gh run list -R SQL0106/ksutools`、日志 `gh run view --log`。
- 调试：`.github/workflows/dig-debug.yml`（带符号二进制）。

## 编译坑（改前必读）
- **curl**：Makefile 只认 `CURL_LDFLAGS_BIN` → 必须用 CC 包装器注入 `-static -no-pie`。
- **BIND(dig)**：configure 见 `-static` 直接 error，且 dlopen 探测需要动态链接 → 用不带 `-static` 的包装器，`-all-static` 只加到 `make -C bin/dig`；必须 `--without-jemalloc`；**静态下 `isc__initialize()`（ISC_CONSTRUCTOR）会被链接器丢弃 → 必须 `-Wl,--undefined=isc__initialize`**，否则 dig 启动即 `SIGSEGV si_addr=0x8`。
- **OpenSSH**：configure 见 `--with-ldflags=-static` 直接 error → 走补丁/包装器。
- 验收标准：二进制无 `INTERP`、无 `NEEDED`（`readelf -d`），`env -i` 下能跑，空 chroot 铁笼能跑。**不要用 `unshare -m` + `umount` 做铁笼**（会泄漏到宿主 ns，搞坏系统）。

## 安装到设备
- `/data/adb/ksu/bin/ksud module install <zip>`（**ksud 不在 PATH**）。
- 新模块先进 `/data/adb/modules_update/ksutools`，**重启后生效**；要立刻覆盖可 `mv` 到 `/data/adb/modules/ksutools`。v1 备份在 `/data/local/ksuv2/old-module-v1`。
- 设备 SSH：`ssh -i ~/.ssh/Keys/id_ed25519 -p 8022 root@192.168.1.100`（别名 `realme`）。

## 提交
- 一个动作一次提交，中文短信息；改完 `git add -A && git commit -m ... && git push`（SSH remote）。
