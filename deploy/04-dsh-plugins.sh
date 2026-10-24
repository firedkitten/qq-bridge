#!/usr/bin/env bash
# 04-dsh-plugins.sh —— 把 qq-mode-console / qq-agent-presets 两个插件装进服务器上的 DSH
#
# 为什么需要这一步：
#   DSH 的「设置命名空间」和「agent preset」都由插件提供。服务器上的 DSH 是新装的，
#   profile 里只有 @deepseek-ai/dsh-base + dsh-web-app，于是：
#     · 没有 qq-mode 命名空间 → 控制台切模式时写穿 DSH 会被拒：
#       settings/rejected: No configurable plugin entry "qq-mode"
#     · 没有 qq-chat-v2 预设 → 二代仿真模式没有对应的人格/协议层
#     · 没有 MCP 区块 → 所有 qq_* 工具（发消息/读消息/记忆/表情）都不存在
#   本脚本把仓库里的两个插件 link 进 $DSH_HOME/profile/web，跑一次 pnpm install，
#   再跑 scripts/setup-dsh.mjs 挂上三个 MCP server。
#
# 幂等：可重复执行。
# 用法：sudo -u qqbridge env HOME=/opt/qq-bridge DSH_HOME=/opt/qq-bridge/.dsh bash 04-dsh-plugins.sh

set -euo pipefail

REPO="${REPO:-/opt/qq-bridge}"
DSH_HOME_DIR="${DSH_HOME_DIR:-/opt/qq-bridge/.dsh}"
PROFILE="${DSH_PROFILE:-web}"
PNPM_REGISTRY="${PNPM_REGISTRY:-https://registry.npmmirror.com}"
OWNER="${OWNER:-qqbridge}"

PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE"
PLUGINS_DIR="$DSH_HOME_DIR/plugins"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$*"; }
die() { printf '\n\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "$PROFILE_DIR" ]] || die "找不到 profile 目录 $PROFILE_DIR（先跑一次 dsh web 让它生成 profile）"
[[ -d "$REPO/plugins/qq-mode-console" ]] || die "找不到 $REPO/plugins/qq-mode-console"
[[ -d "$REPO/plugins/qq-agent-presets" ]] || die "找不到 $REPO/plugins/qq-agent-presets"

say "1/4 建插件链接（$PLUGINS_DIR）"
mkdir -p "$PLUGINS_DIR"
for p in qq-mode-console qq-agent-presets; do
  ln -sfn "$REPO/plugins/$p" "$PLUGINS_DIR/$p"
  ok "$PLUGINS_DIR/$p -> $REPO/plugins/$p"
done

say "2/4 写 profile 依赖与 bundles（$PROFILE_DIR/package.json）"
node - "$PROFILE_DIR/package.json" "$PLUGINS_DIR" <<'NODE'
const fs = require('fs');
const [file, pluginsDir] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
const names = ['qq-mode-console', 'qq-agent-presets'];
pkg.dependencies = pkg.dependencies || {};
for (const n of names) {
  pkg.dependencies[n] = `link:${pluginsDir}/${n}`;
}
pkg.dsh = pkg.dsh || {};
pkg.dsh.profile = pkg.dsh.profile || {};
const bundles = Array.isArray(pkg.dsh.profile.bundles) ? pkg.dsh.profile.bundles : [];
for (const n of names) if (!bundles.includes(n)) bundles.push(n);
pkg.dsh.profile.bundles = bundles;
pkg.dsh.profile.patchReload = pkg.dsh.profile.patchReload || 'live';
fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
console.log('    ✓ bundles: ' + bundles.join(', '));
NODE

say "3/5 pnpm install（registry=$PNPM_REGISTRY）"
cd "$PROFILE_DIR"
if command -v dsh >/dev/null 2>&1; then
  dsh plugin --profile "$PROFILE" install --registry="$PNPM_REGISTRY" 2>&1 | tail -n 25
else
  die "PATH 里没有 dsh（先 ln -sf /usr/local/lib/nodejs/*/bin/dsh /usr/local/bin/dsh）"
fi

say "4/5 挂载三个 MCP server（scripts/setup-dsh.mjs）"
# 为什么必须单独跑这一步（2026-10-24 线上事故）：
#   QQ 工具（qq_send_message / qq_get_prompt / qq_mark_read …）全部由 mcp-snowluma 这个
#   MCP server 提供，而 MCP 条目写在 profile 的 cordis.patch.yml 里，由 setup-dsh.mjs 维护。
#   只装插件、不跑 setup-dsh 时 DSH 能起来、控制台也正常，但 agent 拿到的工具只有
#   ask_user_question / todo_write —— 表现就是「机器人收到消息但不回复，日志里说工具不在白名单」。
cd "$REPO"
if command -v node >/dev/null 2>&1; then
  DSH_HOME="$DSH_HOME_DIR" node scripts/setup-dsh.mjs "$PROFILE" 2>&1 | sed 's/^/    /'
  ok "MCP 条目已写入 $PROFILE_DIR/cordis.patch.yml"
else
  die "PATH 里没有 node"
fi

say "5/5 归属与校验"
if [[ "$(id -un)" == "root" && -n "$OWNER" ]]; then
  chown -R "$OWNER:$OWNER" "$DSH_HOME_DIR" 2>/dev/null || warn "chown 失败（可能当前不是 root）"
fi
[[ -d "$PROFILE_DIR/node_modules/qq-mode-console" ]] && ok "node_modules/qq-mode-console 已就位" || warn "node_modules/qq-mode-console 缺失"
[[ -d "$PROFILE_DIR/node_modules/qq-agent-presets" ]] && ok "node_modules/qq-agent-presets 已就位" || warn "node_modules/qq-agent-presets 缺失"
grep -q "qq-bridge MCP BEGIN" "$PROFILE_DIR/cordis.patch.yml" \
  && ok "cordis.patch.yml 已包含 MCP 区块" \
  || warn "cordis.patch.yml 缺少 MCP 区块（QQ 工具会全部不可用）"

printf '\n\033[1;32m完成。\033[0m 现在重启 DSH：\n\n'
printf '    systemctl restart dsh-web\n'
printf '    systemctl restart qq-bridge     # 让桥接重新读一次 settings.describe\n\n'
printf '然后控制台切一次模式，应不再出现「未能同步到 DSH 设置」的告警。\n'
printf '验证 QQ 工具真的挂上了：journalctl -u dsh-web -n 50 | grep snowluma-safe\n'
printf '（看到「当前桥接模式 reserved2：…改用带令牌的 v2 读工具」即正常）\n'
