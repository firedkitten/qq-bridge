#!/usr/bin/env bash
# 01-base.sh —— Ubuntu 22.04 基础环境：时区 / swap / Docker / Node 22 / fail2ban / ufw
# 幂等，可重复执行。用法： sudo bash 01-base.sh
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "请用 root 运行：sudo bash $0"; exit 1; }
command -v apt-get >/dev/null || { echo "不是 Debian/Ubuntu 系统，本脚本不适用"; exit 1; }

echo "== 0. 预检 =="
. /etc/os-release
echo "OS     : ${PRETTY_NAME}"
echo "内核   : $(uname -r)"
free -h | sed -n 1,2p
df -h / | tail -1

echo "== 1. 时区 -> Asia/Shanghai =="
timedatectl set-timezone Asia/Shanghai
date

echo "== 2. swap 4G（4 GiB 内存跑 QQ 容器 + Node，防 OOM） =="
if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-qqbridge.conf
sysctl -q -p /etc/sysctl.d/99-qqbridge.conf
free -h | sed -n 1,3p

echo "== 3. 软件包 =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg rsync git jq unzip xz-utils fail2ban

echo "== 4. Docker + 日志轮转 =="
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  # 国内直连 download.docker.com 会被 reset（实测 curl: (35) Connection reset by peer），
  # 优先走阿里云镜像站，失败才回退官方源。
  if curl -fsSL --max-time 25 https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
    DOCKER_REPO="https://mirrors.aliyun.com/docker-ce/linux/ubuntu"
    echo "   使用阿里云 docker-ce 镜像源"
  else
    curl -fsSL --max-time 25 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    DOCKER_REPO="https://download.docker.com/linux/ubuntu"
    echo "   回退官方 docker-ce 源"
  fi
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${DOCKER_REPO} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
mkdir -p /etc/docker
# registry-1.docker.io 在本机不可达，必须配镜像加速，否则 pull 任何镜像都会超时。
cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://dockerproxy.net"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
JSON
systemctl enable --now docker
systemctl restart docker
docker --version

echo "== 5. Node 22（qq-bridge 要求 >= 22.13.0） =="
need_node=1
if command -v node >/dev/null; then
  major=$(node -p 'process.versions.node.split(".")[0]')
  [[ ${major} -ge 22 ]] && need_node=0
fi
if [[ ${need_node} -eq 1 ]]; then
  # deb.nodesource.com 在国内时好时坏；改用阿里云 nodejs-release 官方二进制包，确定性最高。
  NV=$(curl -fsSL --max-time 25 https://mirrors.aliyun.com/nodejs-release/ 2>/dev/null \
        | grep -oE 'v22\.[0-9]+\.[0-9]+' | sort -uV | tail -1 || true)
  [[ -n ${NV:-} ]] || NV=v22.23.4
  echo "   安装 Node ${NV}（mirrors.aliyun.com）"
  if curl -fsSL --max-time 300 "https://mirrors.aliyun.com/nodejs-release/${NV}/node-${NV}-linux-x64.tar.xz" -o /tmp/node.tar.xz; then
    mkdir -p /usr/local/lib/nodejs
    tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs
    for b in node npm npx corepack; do
      [[ -e /usr/local/lib/nodejs/node-${NV}-linux-x64/bin/${b} ]] \
        && ln -sf /usr/local/lib/nodejs/node-${NV}-linux-x64/bin/${b} /usr/local/bin/${b}
    done
    rm -f /tmp/node.tar.xz
  else
    echo "   阿里云包下载失败，回退 deb.nodesource.com"
    curl -fsSL --max-time 60 https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi
  hash -r
fi
node -v && npm -v
npm config set registry https://registry.npmmirror.com >/dev/null 2>&1 || true
echo "npm registry: $(npm config get registry)"

echo "== 6. fail2ban（22 端口暴露在公网，挡爆破） =="
cat > /etc/fail2ban/jail.d/sshd.local <<'JAIL'
[sshd]
enabled = true
maxretry = 4
findtime = 10m
bantime = 1h
JAIL
systemctl enable --now fail2ban
fail2ban-client status sshd 2>/dev/null | sed -n 1,3p || true

echo "== 7. 本机防火墙兜底（云安全组才是第一道门） =="
if command -v ufw >/dev/null; then
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'ssh'
  ufw --force enable >/dev/null
  ufw status | head -8
fi

echo "== 完成：可以进 02-snowluma.sh =="
