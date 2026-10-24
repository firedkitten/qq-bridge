#!/usr/bin/env bash
# 02-snowluma.sh —— 以 Docker 容器方式启动 SnowLuma（真 Linux QQ + Xvfb + noVNC）
#
# ⚠️ 必读
# SnowLuma 的 EULA §5.4 把「并入第三方安装包或 Docker 镜像」以及「通过自动化脚本部署」
# 列为需要事先取得书面授权的行为。所以这个脚本被设计成**必须由你本人手动确认后才运行**，
# 它不是无人值守流水线的一环。你执行它 = 你确认已阅读 EULA、并自行承担授权与合规责任。
#
# 用法：
#   sudo bash 02-snowluma.sh                       # 只打印提示，不执行
#   sudo bash 02-snowluma.sh --i-have-read-eula    # 真正启动
#
# 镜像/端口/数据目录以你选定的镜像文档为准；本脚本按社区常用约定写，先看一眼再用。
set -euo pipefail

if [[ "${1:-}" != "--i-have-read-eula" ]]; then
  cat <<'EOF'
本脚本会以 Docker 容器方式启动 SnowLuma。执行前请确认：

  1) 你已阅读 SnowLuma EULA，尤其 §5.4（Docker 镜像 / 自动化脚本部署需事先书面授权）；
  2) 你了解第三方镜像的风险；
  3) 这是你本人主动执行，不是自动化脚本在替你部署。

确认无误后重跑：
  sudo bash 02-snowluma.sh --i-have-read-eula
EOF
  exit 2
fi

command -v docker >/dev/null || { echo "docker 未安装，先跑 01-base.sh"; exit 1; }

echo "== 清理同名容器 =="
docker rm -f snowluma >/dev/null 2>&1 || true
# 三个宿主持久化目录：
#   data   → 容器 /app/data   SnowLuma 自己的配置（config/onebot_<QQ>.json、日志、WebUI）
#   config → 容器 /app/.config QQ 客户端的登录态/localStorage（HOME=/app，所以落在这里）
#   （程序本体 /app/runtime 是镜像内容，不要挂，否则升级镜像就乱了）
mkdir -p /opt/snowluma/data /opt/snowluma/config
chown -R 1000:1000 /opt/snowluma

echo "== 启动容器 =="
# seccomp/cap 是必须的：QQ 客户端有反调试 ptrace 行为，默认 seccomp 会直接杀掉它
# noVNC/远程桌面密码：VNC 协议只认前 8 个字符，所以固定用 8 位的 qqbridge
# （可用 SNOWLUMA_VNC_PASSWD=xxx 覆盖；不设置 VNC_PASSWD 则容器每次启动随机一个）
VNC_PW="${SNOWLUMA_VNC_PASSWD:-qqbridge}"
docker run -d \
  --name snowluma \
  --restart unless-stopped \
  --security-opt seccomp=unconfined \
  --cap-add=SYS_PTRACE \
  -e TZ=Asia/Shanghai \
  -e VNC_PASSWD="$VNC_PW" \
  -e SNOWLUMA_LOG_LEVEL=warn \
  -e SNOWLUMA_SCREEN=1280x720x24 \
  -v /opt/snowluma/data:/app/data \
  -v /opt/snowluma/config:/app/.config \
  -p 127.0.0.1:3000:3000 \
  -p 127.0.0.1:3001:3001 \
  -p 127.0.0.1:5099:5099 \
  -p 127.0.0.1:6081:6081 \
  motricseven7/snowluma:latest

sleep 6
docker ps --filter name=snowluma --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "---- 最近日志 ----"
docker logs --tail 25 snowluma 2>&1 || true

cat <<EOF

== 下一步：扫码绑定你的 QQ ==
1) 本机开隧道（见 deploy/tunnel.ps1），浏览器访问：
     http://127.0.0.1:6081/vnc.html?autoconnect=1      ← noVNC 看容器桌面
     http://127.0.0.1:5099                            ← SnowLuma WebUI
   noVNC 的远程桌面密码固定为：${VNC_PW}（用户名留空/随便填）
   若忘了：docker logs snowluma 2>&1 | grep -i "remote desktop password"
2) 在 noVNC 里点开 QQ 登录窗口的二维码，用手机 QQ 直接扫屏幕。
   ⚠️ 二维码 TTL 只有 60~70 秒，不要截屏转发，就在这个窗口里扫。
3) 登录成功后 SnowLuma 会在 /opt/snowluma/data/config/onebot_<你的QQ>.json 写 OneBot 配置，
   qq-bridge 会自动发现 token 并写回 config.json（config.json 里 accessToken 留空即可，
   但 snowluma.homeDir 必须是 /opt/snowluma/data）。
EOF
