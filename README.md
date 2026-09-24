# ksutools

KernelSU 模块：为 Android shell 补齐常用工具（Alpine musl 预编译 + 自编译 musl sshd）。

## 工具

`curl` `rsync` `jq` `sqlite3` `openssl` `dig` `zip` `bash` `zsh` `htop` `nano` `vim`
`ssh` `scp` `sshd` `sftp` `ssh-keygen` `ssh-add` `ssh-agent` `ssh-keyscan`

- shell：`bash` / `zsh`（内置 oh-my-zsh + zsh-autosuggestions / zsh-syntax-highlighting / zsh-completions / zsh-history-substring-search）
- sshd：端口 8022，仅密钥登录，密钥放在 `/data/adb/ksutools/home/root/.ssh/authorized_keys`

## 构建

依赖：Linux 主机 + Docker。生成的 `module/` 内容由脚本产出，不入库。

```sh
bash build/fetch-omz.sh     # 拉取 oh-my-zsh 与插件
bash build/build-sshd.sh    # 用 Alpine musl 编译 OpenSSH 9.9p2 (sshd/sshd-session/sftp-server)
bash build/assemble.sh      # 收集工具、依赖库、loader，patchelf，落地 module/
( cd module && zip -qr9 ../ksutools.zip . )
```

CI（`.github/workflows/build.yml`）在 push / tag / 手动触发时自动执行上述步骤，
上传 `ksutools-*.zip`；打 tag 时自动创建 Release。

## 安装

刷入 `ksutools-*.zip`（KernelSU / Magisk 模块管理器），重启后直接使用。
本模块仅提供 `system/` 内容，挂载由 meta-overlayfs 等 metamodule 负责。

## 说明

- 目标：Android 16 / kernel 6.1.x / arm64，页大小 4096。
- 所有 musl 二进制使用 `/system/lib64/ksutools/ld-musl-aarch64.so.1` 作为解释器。
- 配置目录 `/data/adb/ksutools`：sshd 主机密钥、`authorized_keys`、`resolv.conf` 等。
- 卸载保留数据：`touch /data/adb/ksutools/KEEP_ON_UNINSTALL`。
- 关闭 sshd 自启：`touch /data/adb/ksutools/no-autostart-sshd`。
- 关闭 oh-my-zsh：在 `~/.zshenv` 中 `export KSUTOOLS_NO_OMZ=1`。
