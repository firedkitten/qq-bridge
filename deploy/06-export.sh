#!/usr/bin/env bash
# 06-export.sh —— 服务器端：打包「换机器还认」的 qq-bridge 数据。
#
# 用法：
#   bash 06-export.sh                 # 输出 /root/qqbot-backup-<时间戳>.zip（+.tgz）
#   bash 06-export.sh /tmp/out        # 指定输出目录
#   QQBRIDGE_DIR=/srv/bot bash 06-export.sh   # 仓库不在 /opt/qq-bridge 时
#
# 为什么主产物是 zip 而不是 tgz：
#   仓库里有中文文件名（roles/小鲸鱼.md 等）。Linux 的 GNU tar 写出的 UTF-8 长文件名，
#   在 Windows 自带的 bsdtar 3.8.9 上解包会报
#   “Invalid empty pathname: Unknown error” 并把这类文件整条丢掉（实测）。
#   Info-ZIP 会把非 ASCII 名标 UTF-8 位，Windows 的 Expand-Archive / .NET ZipFile 读它才对。
#   tgz 仍然一起打，给「在 Linux 上恢复」或长期归档用。
#
# 收什么：config.json（配置）、state/（唤醒计数/角色/预设备份）、roles/（角色卡）、
#         dsh/agent-presets/（仿真提示词源，桥接生成 patch 的输入）。
# 不收什么：
#   node_modules/          本地重装即可
#   .git/                  本地仓库本来就有
#   .dsh/.credentials      DeepSeek 账号凭据，本地已有同一份，不该在机器间复制
#   /opt/snowluma/*        Linux QQ 登录态（约 398 MB），Windows 客户端不认，必须重新扫码
#   plugins/**/presets/    生成的 patch，本地跑 scripts/build-agent-preset-patches.mjs 重建
set -euo pipefail

SRC="${QQBRIDGE_DIR:-/opt/qq-bridge}"
OUT_DIR="${1:-/root}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="qqbot-backup-$STAMP"
ZIP="$OUT_DIR/$NAME.zip"
TGZ="$OUT_DIR/$NAME.tgz"

[ -d "$SRC" ] || { echo "找不到仓库目录：$SRC（可用 QQBRIDGE_DIR 指定）" >&2; exit 1; }
command -v zip >/dev/null || { echo "缺 zip：apt-get install -y zip" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# 只收确实存在的项，缺一个不至于整包失败（比如从没用过 roles/）。
KEEP=(config.json state roles dsh/agent-presets)
EXIST=()
for p in "${KEEP[@]}"; do
  [ -e "$SRC/$p" ] && EXIST+=("$p")
done
[ ${#EXIST[@]} -gt 0 ] || { echo "$SRC 里没有可打包的内容" >&2; exit 1; }

EXCLUDES=(-x 'state/bridge.lock' -x 'state/bridge.log' -x '*.tmp')

echo "== 打包 =="
( cd "$SRC" && zip -qrX "$ZIP" "${EXIST[@]}" "${EXCLUDES[@]}" )
# GNU tar 的 --exclude 必须写在文件参数之前，否则只对后续参数生效（会静默失效）。
tar -czf "$TGZ" \
  --exclude='state/bridge.lock' \
  --exclude='state/bridge.log' \
  --exclude='*.tmp' \
  -C "$SRC" "${EXIST[@]}"

# 校验：zip 里必须有 config.json，否则本地导入会把半包当全包。
if ! zipinfo -1 "$ZIP" | grep -x 'config.json' >/dev/null; then
  echo "!! 归档里没有 config.json，先确认 $SRC 是否为仓库根" >&2
  exit 2
fi

# 清单：逐文件 sha256 + 环境版本，回本地后对得上才敢覆盖。
MANIFEST="$OUT_DIR/$NAME.sha256"
{
  echo "# qqbot backup $STAMP"
  echo "# host: $(hostname)  src: $SRC"
  echo "# kernel: $(uname -sr)"
  echo "# node: $(node -v 2>/dev/null || echo none)  docker: $(docker --version 2>/dev/null || echo none)"
  echo "# files: $(zipinfo -1 "$ZIP" | grep -vc '/$' || true)"
  echo "# zip: $(sha256sum "$ZIP" | cut -d' ' -f1)"
  echo "# tgz: $(sha256sum "$TGZ" | cut -d' ' -f1)"
  ( cd "$SRC" && find "${EXIST[@]}" -type f \
      ! -name 'bridge.lock' ! -name 'bridge.log' ! -name '*.tmp' -print0 \
    | sort -z | xargs -0 sha256sum )
} > "$MANIFEST"

echo "   归档：$ZIP（$(du -h "$ZIP" | cut -f1)）"
echo "   兼容：$TGZ（$(du -h "$TGZ" | cut -f1)，给 Linux 恢复用，Windows 解包会丢中文名）"
echo "   清单：$MANIFEST"
echo "   内容："
zipinfo -1 "$ZIP" | sed 's/^/     /' | head -40

cat <<EOF

== 下一步 ==
本地拉取（在本地仓库根目录执行，私钥换成你自己的）：
  scp -i E:\\qq-bridge\\id_ed25519 root@<服务器公网IP>:$ZIP .
  scp -i E:\\qq-bridge\\id_ed25519 root@<服务器公网IP>:$MANIFEST .

然后本地导入（会自动改好 config.json 里的 Windows 路径）：
  powershell -ExecutionPolicy Bypass -File deploy\\07-import-local.ps1 -Archive $(basename "$ZIP")

提醒：QQ 登录态不随包迁移，本地 SnowLuma 需要重新扫码。
EOF
