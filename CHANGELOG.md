# 更新日志

本文件记录本 fork 的发布版本。版本号自本 fork 起算，与上游 `Derpyu520/qq-bridge` 的编号各自独立；
功能基线见每条版本下的「上游基线」说明。

---

## v0.1.3 — 2026-10-25

上游基线不变（`v0.2.1-r1`）。这一版是 v0.1.2 的补丁：修两个真实故障，加一层「档案留存」，再给一个搬数据的脚本。

### 修复

- **导出接口在中文角色名下 500**：`content-disposition` 只允许 ASCII，角色名直接拼进去会抛 `ERR_INVALID_CHAR`。改成 ASCII 兜底名 + RFC 5987 `filename*`，控制台优先解析 `filename*`，下载文件名里的中文照旧保留。
- **Windows 存的角色卡被截断**：`src/role-card.js` 按 `'\n'` 拆行，CRLF 文件每行都带 `\r`，v1 模式下每轮注入的正文比实际多一百多字符，卡尾会被预算切掉。改为 `split(/\r?\n/)`；同一张卡 6137 → 5953 字符，6000 的预算不再误伤。

### 新增

- **档案留存（`archive/`）**：`facts.jsonl` / `diary.jsonl` 会去重、会被删、超过 1MB 还会轮转，所以另开一个 append-only 底稿，按天记下 `write` / `delete` / `rotate` 每一次变更。只写不读，不参与注入、不占预算；主文件被误删或写坏时可以按天回查。
- **控制台「档案留存」面板**：按角色、天数看归档条目，可下载当天 JSONL。
- **`scripts/sync-memory.ps1`**：一条命令把服务器上的 `state/`、`memory-diary/state/`、`persona-core/` 拉成本地快照（`-Apply` 才覆盖，覆盖前自动备份），或反向推回服务器。

### 测试

- 新增 `scripts/test-archive.mjs`，`test-memory-diary.mjs` 增第 9、10 项（导出响应头、档案接口），共 10 项全过。

## v0.1.2 — 2026-10-25

上游基线不变（`v0.2.1-r1`）。这一版加入**人格记忆**：一个独立的四层记忆工具，以及它在桥接里的接线。

### 新增

**人格记忆工具 `qqbridge-tool/memory-diary/`**（独立仓库：[firedkitten/persona-memory-diary](https://github.com/firedkitten/persona-memory-diary)）

- 四层纯文件记忆：人格内核（每轮注入，≤600 字）、长期事实（每轮注入，≤300 字 / 6 条）、事件日记（最近 + 相关，≤400 字）、交接单（新会话只读一次，≤700 字）。JSONL / Markdown / JSON，无数据库、无向量库、不调用模型。
- **人格内核**：一个角色一个文件 `persona-core/<角色>.md`，`draft: true` 一行即可停用；`personaHash` 每轮可对账；从角色卡半自动生成草稿（只摘录原文，不编造），覆盖前自动备份旧版。
- **长期事实**：用句式规则从对方消息里抽取（名字 / 年龄 / 城市 / 偏好 / 雷点 / 关系 / 计划），上限 200 条，10 分钟去重窗口；注入时按「身份 > 雷点 > 喜好 > 关系 > 计划」排序。
- **事件日记**：JSONL 落盘，按会话窗口隔离，1 MB 轮转保留最新 3000 行，中文二元组检索。
- **交接单**：换会话前生成，注入时只读一次（投递成功才标记已读），同时原样归档成 Markdown。
- **只提醒、不自动换会话**：累计唤醒轮数达到 `handoff.remindAfterTurns`（默认 40）时，下一次唤醒前发一条管理员提醒，之后每 +40 轮补一条。没有任何自动切换路径。

**控制台「人格日记」页**

- 按人格、按会话窗口查看 / 补记 / 删除长期事实与事件日记，支持 JSON 导出与导入（导出即一份可迁移档案）。
- 人格编辑器新增「更新人格内核」「查看内核」；新建人格时自动生成内核草稿，角色卡改动后会提示内核已过期。

**其它**

- 新增单测：`scripts/test-memory-diary.mjs`、`test-handoff.mjs`、`test-persona-core.mjs`、`test-persona-draft.mjs`。
- 角色卡改名时同步重命名内核文件；删除角色不删记忆。

### 安装注意

本仓库不含 `qqbridge-tool/memory-diary/`（它是独立仓库，且其中 `persona-core/` 与 `state/` 属于用户数据）。克隆后补一步：

```bash
git clone https://github.com/firedkitten/persona-memory-diary.git qqbridge-tool/memory-diary
```

`src/bridge.js` 顶部是静态 import，缺目录会在启动时报 `ERR_MODULE_NOT_FOUND`。

### 文档

- `README.md` / `README.en.md`：新增「人格记忆」一节与安装步骤。
- `docs/FOLDER_MAP.md`：顶层布局补 `qqbridge-tool/memory-diary/`。
- `docs/guides/PERSONA_MEMORY.md`：补「四层长期记忆」与插件边界说明。

---

## v0.1.1 — 2026-10-24

上游基线不变（`v0.2.1-r1`）。这一版是**修 Bug**，没有新的运行时功能。

### 修复

- **面板：机器人头像一直不更新**。原来是 `renderStatus()` 里写死的 ，头像根本没请求过。
  现在按 `bot.user_id` 取真实头像，并且**不直连腾讯图床**，改由面板后端转发
  （新增 `GET /api/avatar?uin=<QQ>`：服务端代取 → 带 `max-age=3600` 返回，
  `uin` 只接受数字，失败返回 JSON 错误）。浏览器只跟 `127.0.0.1` 打交道，
  绕开第三方资源拦截 / 跨域 / 图床不可达；拉不到时退回 ，恢复后自动重建（原来失败一次会永久变 emoji）。
- **面板：改了机器人昵称不生效**。`get_login_info` 之前不带参数，拿到的是 SnowLuma
  **进程启动时的缓存**。现在带 `no_cache` 现取；群名称与人数同理（已在 v0.1.0 后的提交里修好）。

---

## v0.1.0 — 2026-10-24

本 fork 的首个发布版本。上游基线 `v0.2.1-r1`（适配 DeepSeek Harness `0.2.1-rc.2`）。

### 新增功能

**人格记忆与会话隔离（C2）**

- 切人格不再只是换一段提示词：三类轻量记忆（进行中的话题 / 想说未说的话 / 群友印象）与会话池
  （会话映射 + 会话令牌）都按人格分别存档在 `state/persona-memory/`、`state/persona-sessions/`。
- 切人格是「换轨」不是「清空」：各自人格的对话留在各自名下，**切回来接回原对话继续聊**；
  不属于当前人格的会话全部脱钩（退事件流、清定时器、停在跑回合），但不归档、不轮换令牌。
- 挂回前过两道闸门（是否仍在白名单、`sessionPolicy` 是否变化），不满足就不硬塞旧会话。
- 新增 `src/persona-memory.js`、`src/persona-sessions.js` 两个纯函数模块，配套 11 + 31 项单测。

**云端部署套件（`deploy/`）**

- `01-base.sh`：时区、swap、Docker、Node 22、fail2ban、ufw 一键就绪（幂等）。
- `02-snowluma.sh`：SnowLuma 容器化运行，显式数据卷、固定 noVNC 密码、日志轮转；
  启动前要求阅读 SnowLuma EULA（不代用户接受）。
- `03-bridge.sh`：安装桥接到 `/opt/qq-bridge`、写 Linux 版 `config.json`、装 systemd 单元。
- `04-dsh-plugins.sh`：把 `qq-mode` 命名空间、人格预设、三个 MCP server 接通到 DSH，
  并校验 `cordis.patch.yml` 里的 MCP 区块（缺了会出现「所有 qq_* 工具都不在白名单」）。
- `dsh-web.service`、`qq-bridge.service`、`snowluma-configperm.timer`、`tunnel.ps1`；
  `nginx-hexo.conf`（同机跑 Hexo 用的 nginx 站点样板）自 v0.1.0 后改为**本机专用、不入库**。

**本地管理面板（`deploy/panel/`）**

- 一个批处理：起 SSH 隧道 + 本地仪表盘，关窗即断隧道，并在桌面生成快捷方式。
- 面板聚合三个入口（桥接控制台 / SnowLuma WebUI / noVNC 扫码），展示服务器信息与资源占用、
  systemd 服务状态、机器人信息与群列表、四个来源的运行日志。

**备份与迁移**

- `06-export.sh`（服务器侧打包 `config.json` / `state` / `roles` / 人格预设，附 sha256 清单）
- `07-import-local.ps1`（本地解包、自动改回本机路径、重建预设 patch）

**控制台**

- 新增「重启 DSH」按钮与 `POST /api/dsh/restart`（systemd 或直接进程两种部署都能用）。
- 人格切换的提示改为「已接回 N 个会话上下文 / M 个人格会话已暂存」。

### 修复与加固

- 人格预设改动不生效：源 `agent.cordis.yml` 改了但 DSH 读的是生成的 `presets/*.patch.yml`，
  现在 `scripts/build-agent-preset-patches.mjs --check` 可自检，部署脚本会提示重建。
- MCP 未挂载导致的工具全拒：部署脚本内置 `cordis.patch.yml` 校验并给出验证命令。
- 隐私：`.gitignore` 补充私钥/凭据/真实数据/安装包等规则，示例配置改用占位符，
  新增 `npm run privacy-scan` 与 `.gitattributes`（脚本强制 LF，避免 `bash\r` 报错）。

### 升级注意

- `state/` 下新增 `persona-sessions/`；从旧版升级后，第一次切人格会为当前人格建立会话池。
- 同一 QQ 号同一时刻只能有一个 SnowLuma 实例在线，本地与云端互顶会导致「能连上但收不到消息」。
- 运行环境：Node ≥ 22.13、DSH ≥ 0.2.1、SnowLuma（其 EULA 禁止随第三方安装包或镜像分发，需自行获取）。

---

## 上游版本

本 fork 之前的历史（`v0.2.1-r1` 及更早）由上游维护，见
[Derpyu520/qq-bridge 的 Releases](https://github.com/Derpyu520/qq-bridge/releases)。
