#!/usr/bin/env bash
# 03-bridge.sh —— 把 qq-bridge 装成 systemd 服务（/opt/qq-bridge）
# 用法： sudo bash 03-bridge.sh /root/qq-bridge
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
SRC="${1:-/root/qq-bridge}"
[[ -f "${SRC}/package.json" ]] || { echo "找不到 ${SRC}/package.json，参数应为代码目录"; exit 1; }

echo "== 1. 服务账号 =="
id -u qqbridge >/dev/null 2>&1 || useradd --system --home-dir /opt/qq-bridge --shell /usr/sbin/nologin qqbridge
mkdir -p /opt/qq-bridge

echo "== 2. 同步代码 =="
# state/ 是运行期数据（会话、日志、控制台令牌），绝不能被 --delete 抹掉
rsync -a --delete \
  --exclude '.git' --exclude 'node_modules' --exclude 'state' --exclude 'logs' \
  "${SRC}/" /opt/qq-bridge/

echo "== 3. 安装依赖（会跑 postinstall 修 @snowluma/sdk 的 ESM 问题） =="
cd /opt/qq-bridge
if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

echo "== 4. config.json =="
if [ ! -f config.json ]; then
  cp "${SRC}/deploy/config.linux.json" config.json
  echo "已写入 Linux 版 config.json（已去掉 launcherPath/homeDir，accessToken 留空待自动发现）"
else
  echo "config.json 已存在，保留不动"
fi

mkdir -p state
chown -R qqbridge:qqbridge /opt/qq-bridge
chmod 700 /opt/qq-bridge/state

echo "== 5. systemd =="
install -m 0644 "${SRC}/deploy/qq-bridge.service" /etc/systemd/system/qq-bridge.service
# 控制台「重启 DSH」按钮需要 qqbridge 能重启 dsh-web：只授权这一个单元的 restart/is-active。
# （unit 里必须没有 NoNewPrivileges=true，否则 sudo 会报 "The no new privileges flag is set"。）
echo 'qqbridge ALL=(root) NOPASSWD: /usr/bin/systemctl restart dsh-web, /usr/bin/systemctl is-active dsh-web' > /etc/sudoers.d/qq-bridge-dsh
chmod 0440 /etc/sudoers.d/qq-bridge-dsh
visudo -c -f /etc/sudoers.d/qq-bridge-dsh || echo "!! sudoers 校验失败，请手动修复 /etc/sudoers.d/qq-bridge-dsh"
systemctl daemon-reload
systemctl enable --now qq-bridge
sleep 4

systemctl --no-pager status qq-bridge | head -16 || true
echo "---- 最近日志 ----"
journalctl -u qq-bridge -n 40 --no-pager || true

cat <<'EOF'

== 常用命令 ==
  systemctl restart qq-bridge
  systemctl stop qq-bridge
  journalctl -u qq-bridge -f
  tail -f /opt/qq-bridge/state/bridge.log
EOF
