# 来源与衍生改动说明（NOTICE）

## 1. 本仓库与上游的关系

本仓库是基于 **[Derpyu520/qq-bridge](https://github.com/Derpyu520/qq-bridge)** 的原始代码 **fork（派生）** 而来，在其之上做了改动。

- 上游地址：`https://github.com/Derpyu520/qq-bridge`
- 派生的基线提交：`a49877f chore: probe-tools 跑完自清理工作区与临时目录`
- 本文档所在的提交起，本仓库的代码 = 上游基线 + 下文第 3 节的改动

上游代码的版权与许可仍归原作者；本仓库只对**下文列出的改动部分**负责。若上游更新，合并时请以上游为准，并注意本仓库的改动可能与新版本冲突（尤其 `src/bridge.js`、`public/console.html` 两个文件改动较多）。

## 2. 不随本仓库分发的内容

以下内容**有意未纳入版本控制**，因此克隆本仓库后不能直接跑起来，需自行准备（`deploy/` 下的脚本只有通用部分入库）：

| 内容 | 原因 |
|---|---|
| SnowLuma 运行时（`SnowLuma-v2.1.1-win-x64/`） | 体积 100 MB+、内含第三方二进制；且 SnowLuma EULA §5.4 禁止随第三方分发 |
| `config.json`、`state/`、`roles/*.md` 的个人内容 | 含QQ 号、令牌、聊天数据 |
| `deploy/panel/panel.config.json`、`deploy/*.cmd`、`*.pem` | 含服务器 IP、私钥路径、控制台令牌 |
| `deploy/README.md`、`deploy/nginx-hexo.conf`、`docs/本机部署与运维笔记.md`、`docs/云端部署选型与厂商对比.md` | 记录的是机器和服务器的具体环境（路径、端口、备案细节），不入库 |
| 部署留痕 / 会话总结类文档 | 内含明文凭据 |

本仓库内的脚本一律使用占位符（`<服务器公网IP>`、`<控制台访问令牌>`、`<机器人QQ>` 等），填自己的值即可。

## 3. 相对上游的改动清单

### 3.1 人格记忆隔离（C2）

| 文件 | 改动 |
|---|---|
| `src/persona-memory.js` | **新增**。纯函数模块：`extractMemory` / `applyMemory` / `normalizeMemory` / `missingKeys` / `isMemoryEmpty`，只处理三类字段（话题、待说未说、群友印象） |
| `scripts/test-persona-memory.mjs` | **新增**。11 项断言的单测 |
| `src/persona-sessions.js` | **新增**。纯数据模块：`buildArchive` / `normalizeArchive` / `planRestore` / `archiveSummary`，负责人格↔会话映射与令牌的快照与还原 |
| `scripts/test-persona-sessions.mjs` | **新增**。31 项断言的单测（key 校验、脏数据兜底、还原两道闸门） |
| `src/bridge.js` | 新增 `switchPersona()`（存档旧人格记忆与会话 → 写 `current-role.json` → 装载新人格记忆与会话 → 把目标人格未接管的老会话「脱钩」但**不归档**）；新增 `capturePersonaSessions` / `restorePersonaSessions` / `detachSessionForPersona`；`/api/role` 与 QQ `/role` 命令改走它；新增只读接口 `GET /api/role-memory?role=`；`saveSocialV2State()` 末尾镜像写入人格存档；人格重命名/删除时连带维护存档文件 |
| `public/console.html` | 切换人格后显示「已接回 N 个会话上下文 / M 个人格会话已暂存」并刷新列表 |
| `package.json` | 新增 `test:persona-memory`、`test:persona-sessions` 脚本 |
| `docs/guides/PERSONA_MEMORY.md` | **新增**。方案取舍（C1/C2/B）、行为规格、存档结构、接口、运维手册 |

上游行为：换人格只换提示词，记忆与上下文都按会话共享。本仓库的行为：**记忆和会话映射都按人格分开存**，切人格是「换轨」而不是「清空」—— 各自的对话留在各自人格名下，切回来接回原会话继续聊；正在切换的那一刻不属于目标人格的会话全部脱钩（停回合、退事件流），但不归档、不删。这是本仓库相对上游的**行为性不兼容**：同一条消息在两个人格下会落到两个不同的 DSH 会话。

### 3.2 云端部署套件（`deploy/`）

上游没有部署脚本，以下全部为**新增**：

| 文件 | 作用 |
|---|---|
| `deploy/01-base.sh` | 服务器基础环境：时区、swap、Docker（阿里云源，含镜像加速与日志轮转）、Node 22（二进制包）、fail2ban、ufw |
| `deploy/02-snowluma.sh` | 用官方镜像起 SnowLuma 容器（带 EULA 确认开关；数据卷挂 `/app/data` 与 `/app/.config`） |
| `deploy/03-bridge.sh` | 装桥接（rsync + npm + systemd + sudoers 白名单） |
| `deploy/04-dsh-plugins.sh` | 把本仓库 `plugins/` 挂进 DSH profile，并**挂载三个 MCP server**（漏这一步会导致所有 `qq_*` 工具不存在） |
| `deploy/06-export.sh` / `deploy/07-import-local.ps1` | 把服务器上的状态打包回本地 |
| `deploy/dsh-web.service`、`deploy/qq-bridge.service` | 两个 systemd 单元 |
| `deploy/config.linux.json` | Linux 版配置模板（已去 Windows 专属字段） |
| `deploy/tunnel.ps1` | 本地开 SSH 隧道（服务器/私钥/用户名走参数或环境变量，不写死） |
| `deploy/panel/` | 本地管理面板：先起 SSH 隧道，再用浏览器看服务状态、日志、三个入口（控制台 / SnowLuma WebUI / noVNC） |

### 3.3 其它

- `public/console.html` + `src/bridge.js`：新增「重启 DSH」按钮与 `POST /api/dsh/restart`（systemd 单元可通过 `QQ_BRIDGE_DSH_UNIT` 覆盖）。
- `.gitattributes`：固定 `*.sh` / `*.service` / `*.conf` 为 LF（否则在 Windows 上检出成 CRLF，scp 到 Linux 后 `bash` 直接报 `bad interpreter`）。

## 4. 安全与合规

- SnowLuma 的使用须遵守其 EULA；`deploy/02-snowluma.sh` 默认拒绝执行，需显式加 `--i-have-read-eula` 确认。
- 桥接默认只监听 `127.0.0.1`，对外只开 SSH，其余端口一律走隧道。
- 提交前请跑 `npm run privacy-scan`，把自己的真实标识写进 `scripts/privacy-rules.json`。
