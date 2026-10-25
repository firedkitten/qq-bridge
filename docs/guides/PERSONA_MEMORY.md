# 人格记忆与会话隔离（C2）

> 状态：✅ 已实现并在线上验证（2026-10-24，第二版）。
> 一句话：**切人格 = 换记忆 + 换会话池**。每个人格有自己的轻量记忆、自己的 DSH 会话映射、自己的会话令牌；切走时存下，切回来接回原对话。

---

## 1. 为什么要做

改造前，人格（`roles/*.md`）只是每条消息前拼的一段提示词：

- **轻量记忆按会话存**（`state/social-v2.json` → `conversations[<key>].{activeTopics,pendingThoughts,memberImpressions}`），跟人格无关；
- **对话上下文按会话存**（`state/sessions.json` → `sessionId`），同样跟人格无关；
- `POST /api/role` 只写 `state/current-role.json`，既不动会话映射，也不重置 DSH 会话。

结果就是：`/role 傲娇助手` 之后，傲娇助手会接着说「小鲸鱼」答应过的事、记得小鲸鱼听到的群友八卦 —— 人格只换了嘴，没换脑子。

## 2. 方案演进：C2 一版 → C2 二版

| 版本 | 记忆 | 会话上下文 | 切回来时 | 结论 |
| --- | --- | --- | --- | --- |
| C1 | 按人格分开 | 共享 | 接着别人的话头 | 半隔离，会串戏 |
| C2 一版 | 按人格分开 | 切人格即 `retireSession` 重建 | **空**（旧对话在 DSH 侧归档） | 隔离够彻底，但"换个称呼就失忆"过于粗暴 |
| **C2 二版（当前）** | **按人格分开** | **按人格分开，切走暂存、切回接回** | **原样接回** | ✅ 采用 |
| B | 记忆 key 改成 `<人格>|<会话>` | 分开 | 原样接回 | 效果接近，但要动所有读写点与迁移，改动最大 |

一版到二版的转折点是一个很具体的问题：「从人格 A 切到 B 再切回 A，A 应该从头开始，还是接回刚才那半句话？」

答案是后者 —— **人在换人设聊天时，忘掉的是「刚才聊到哪」以外的东西；而"刚才聊到哪"恰恰是人格的一部分**。所以：

- 记忆按人格分开（一版就有）；
- 会话映射也按人格分开，切人格是**换轨**而不是**清空**；
- 旧轨的会话不被归档、不被删、令牌不被轮换 —— 它们只是暂时不属于当前人格。

## 3. 行为规格

### 3.1 一次切换做五件事

`switchPersona(nextRole)`（[src/bridge.js](../../src/bridge.js) 内，入口 `/api/role` 与 QQ 的 `/role` 共用）：

1. **存档旧人格的记忆** → `state/persona-memory/<旧人格>.json`；
2. **存档旧人格的会话池** → `state/persona-sessions/<旧人格>.json`（会话映射 + 各会话的 `agentToken`）；
3. **换人格**：写 `state/current-role.json`（`mode` 保持原值 —— 静默/活跃是「说话的意愿」，不属于人格）；
4. **装载新人格**：读它的记忆存档就地改写内存三类字段；读它的会话存档逐条挂回 `state.sessions`、`state.sessionPolicies`、`state.agentToken`，并对每个会话 `api.events.follow(sessionId)`。没有存档 = 空白人格（**不会继承别人的记忆，也不会继承别人的对话**）；
5. **脱钩**：目标人格没接管的会话，逐个「脱钩」—— 退订事件流、清定时器与待发队列、停掉在跑的回合、删掉内存里的映射。**不** `archiveSession`、**不** 轮换令牌。

日志一行交代结果：

```
控制台：人格切换 小鲸鱼 → 傲娇助手；装载记忆 2 个会话，暂存 2 个会话映射，恢复 0 个上下文，脱钩 2 个
控制台：人格切换 傲娇助手 → 小鲸鱼；装载记忆 2 个会话，暂存 0 个会话映射，恢复 2 个上下文，脱钩 0 个
```

（有会话因为白名单或 preset 变化没挂回去时，日志会追加 `；1 个未挂回（group:<群号>:policy-changed）`。）

### 3.2 为什么不再用 retireSession

`retireSession` 的语义是「**这个会话永远不要了**」：它会 `archiveSession` 掉 DSH 侧会话、轮换 `agentToken`、清掉一切痕迹。用它做人格切换，等于每次换称呼都把对方那半段对话烧掉。

二版换成一个更窄的 `detachSessionForPersona(key, sessionId)`：

| 动作 | `retireSession`（旧） | `detachSessionForPersona`（新） |
| --- | --- | --- |
| 删内存映射 | ✅ | ✅ |
| 退订事件流、清定时器、停在跑回合 | ✅ | ✅ |
| 归档 DSH 会话 | ✅ | ❌ 保留 |
| 轮换 agentToken | ✅ | ❌ 保留（按人格存） |

两者都保证：「除当前人格外，没有任何会话还在往它耳朵里喂消息」。

### 3.3 运行中持续镜像

`saveSocialV2State()` 每次落盘后，顺手把当前人格的记忆写进它自己的存档文件（`writePersonaArchive(readRoleState().role, extractPersonaMemory(...))`）。

**为什么必须镜像**：存档是切换时唯一的记忆来源。如果只在「切走时」写一次，切换前最后几分钟新产生的记忆在崩溃或重启后就没地方找了。镜像让存档始终等于「当前人格此刻的记忆」。

### 3.4 边界与不变项

| 场景 | 行为 |
| --- | --- |
| 静默 / 活跃（`mode`） | 切换人格**不变** |
| 唤醒配置（`wakeConfig`）、最近消息队列、未读水位 | 仍按**会话**存，切人格不动（「这个群几点该闭嘴」不是人格属性） |
| 被切走那一瞬间的会话 | 脱钩：停止收消息、停止思考，但 DSH 会话与会话令牌都保留 |
| 会话的 preset / mode 变了 | 存档里有、但 `sessionPolicy(key)` 与存档不一致 → 不硬挂，记一条 `policy-changed`，下次该会话按新策略新建（防止塞进一个 preset 不匹配的旧会话） |
| 会话已不在白名单 | 不挂回，记 `not-allowed`（人格存档保留，重新加白名单后还能接回） |
| DSH 侧会话已不存在 | `ensureSession` 探活返回 `not-found` 时照常新建，不会崩 |
| 人格重命名 | 记忆存档与会话存档都跟着改名，否则重命名后看起来像失忆 |
| 删除人格 | 连带删两份存档；若删的正是当前人格，先 `switchPersona(null)` |
| 没有人格（`null`） | 存档名 `_none.json` |
| 切到同一个人格 | 直接返回 `changed: false`，不脱钩、不重置（重复点不会白踢一次会话） |
| 存档里有、但内存里没有该会话状态对象 | 跳过并记日志（无法凭空造完整会话状态），等该会话重新出现后才生效 |
| 人格名 | 走 `sanitizeRoleName`，`/`、`..` 等一律剔除，不会拼出越界路径 |

## 4. 数据结构

### 4.1 `state/persona-memory/<人格名>.json`

```json
{
  "role": "小鲸鱼",
  "updatedAt": 1792832333719,
  "conversations": {
    "private:<你的QQ>": {
      "activeTopics": [{ "text": "在聊搬家", "addedAt": 1792832303979 }],
      "pendingThoughts": [],
      "memberImpressions": { "暮岁": { "note": "爱问药", "updatedAt": 1792832303979 } }
    }
  }
}
```

- 只存**非空记忆**的会话（三项全空的会话不落存档）；
- 只存三类记忆字段，不存 `wakeConfig` / `recentMessages` / 水位 —— 那些仍归 `social-v2.json`；
- 单会话上限与 `social-v2.json` 一致：话题/念头各 50 条、印象深拷贝；空值一律规范成 `[]` / `{}`。

### 4.2 `state/persona-sessions/<人格名>.json`

```json
{
  "role": "小鲸鱼",
  "updatedAt": 1792832333719,
  "sessions":      { "private:<你的QQ>": "session-c629e927-…", "group:<群号>": "session-1e91221c-…" },
  "policies":      { "private:<你的QQ>": "[\"reserved2\",\"qq-chat-v2\",null]" },
  "tokens":        { "private:<你的QQ>": "<48 字节十六进制>", "group:<群号>": "<32 字节十六进制>" }
}
```

- 只收 `/^(group|private):\d+$/` 形式的 key，脏 key 一律丢弃；
- `tokens` 就是各会话的 `agentToken`：**令牌按人格存**，切到哪个人格就装回哪份，互不通用；
- 切回时若某条没带令牌（老存档），会现生成一枚并回写存档（日志里 `minted`）。

> 这两个文件都在 `state/` 下，`scripts/privacy-scan.mjs` 已把 `state/` 整体列入 `denyFiles`，不会误提交；容器/备份脚本（`deploy/06-export.sh`）会一并打包。

## 5. 接口

| 接口 | 说明 |
| --- | --- |
| `POST /api/role` `{ "role": "小鲸鱼" }`（或 `{"role": null}`） | 切换/清除人格。回包：`{ ok, role, resetSessions, restoredSessions, keptSessions, memoryConversations, archivedRole, changed }`。`resetSessions` 保留字段名兼容，语义已变为「脱钩数」 |
| `GET /api/role-memory?role=<人格名>` | 只读查看某人格的记忆存档 |
| QQ `/role <名字>` | 同一个 `switchPersona`。回 `已切换角色：X。（已接回 N 个会话上下文）` 或 `（本会话首次建立，N 个旧会话已暂存）` |

控制台「人格与角色 → 设置/清除」提示：`✅ 已切换到「X」，已接回 N 个会话上下文` / `，M 个人格会话已暂存（切回来可继续）`。

## 6. 代码与测试

| 位置 | 内容 |
| --- | --- |
| `src/persona-memory.js` | 纯函数：`normalizeMemory` / `extractMemory` / `applyMemory` / `missingKeys` / `isMemoryEmpty` |
| `src/persona-sessions.js` | 纯函数：`buildArchive` / `normalizeArchive` / `planRestore` / `archiveSummary` / `isConversationKey` |
| `src/bridge.js` | `PERSONA_MEMORY_DIR` / `PERSONA_SESSIONS_DIR` 与四个读写 helper；`switchPersona()`；`capturePersonaSessions()` / `restorePersonaSessions()` / `detachSessionForPersona()`；`/api/role`、`/api/role-memory`；`saveSocialV2State` 里的镜像；人格重命名/删除的连带处理 |
| `public/console.html` | 切换/清除后的提示文案带「接回 / 暂存」数量 |
| `scripts/test-persona-memory.mjs` | 11 项单测 |
| `scripts/test-persona-sessions.mjs` | 31 项单测：key 校验、脏数据兜底、快照、还原的两道闸门（白名单 / policy 变化） |

```bash
npm run test:persona-memory      # 记忆纯函数单测（不需要桥接/DSH 在跑）
npm run test:persona-sessions    # 会话存档纯函数单测
```

**真机验证（2026-10-24 18:18，<服务器公网IP>）**：服务器上本来就有两个活跃会话（私聊 + 一个群）。

```
切换前 sessions.json:
  private:<你的QQ> → session-c629e927-11f4-4e94-9ba2-61ad81c7a033
  group:<群号>     → session-1e91221c-8bcd-462a-bfa5-42aeb687bf9a

切 小鲸鱼 → 傲娇助手: resetSessions:2  restoredSessions:0  keptSessions:2
  → sessions.json 变空；persona-sessions/小鲸鱼.json 里有 2 条映射 + 2 枚令牌
  → 日志：暂存 2 个会话映射，恢复 0 个上下文，脱钩 2 个

切 傲娇助手 → 小鲸鱼: resetSessions:0  restoredSessions:2  keptSessions:0
  → 两个 sessionId 与切换前**逐字符相同**（没有新建会话）
  → 日志：暂存 0 个会话映射，恢复 2 个上下文，脱钩 0 个
```

## 7. 运维手册

```bash
# 看某人格的记忆存档 / 会话池
python3 -m json.tool /opt/qq-bridge/state/persona-memory/傲娇助手.json
python3 -m json.tool /opt/qq-bridge/state/persona-sessions/傲娇助手.json

# 只清某个人格的记忆（人格本身与会话池保留 → 切回来还是同一段对话，但忘了细节）
rm /opt/qq-bridge/state/persona-memory/傲娇助手.json

# 只清某个人格的会话池（→ 切回来是新会话，但记忆还在）
rm /opt/qq-bridge/state/persona-sessions/傲娇助手.json

# 回退到「人格共享记忆 + 共享上下文」的老行为（上游行为）
rm -rf /opt/qq-bridge/state/persona-memory /opt/qq-bridge/state/persona-sessions
# 再把 switchPersona 改成只写 current-role.json（或让 /api/role 直接 writeRoleState）
```

两份存档都在 `state/` 里，`deploy/06-export.sh` 打包时一起带走，迁移到另一台机器可直接接上。

## 8. 已知限制

1. **会话数量随人格数增长**：每个用过的人格都有自己的 DSH 会话（私聊 N 个、群聊 N 个），磁盘与 DSH 侧会话列表会变长。清理用 `rm state/persona-sessions/<人格>.json`。
2. **会话的 preset 在建会话时固定**：所以切回时若 preset/mode 已变，宁可不挂（记 `policy-changed`）也不硬塞 —— 表现为该会话来一次「新会话」。
3. **切人格是全局动作**：人格存在 `current-role.json`，不区分群聊/私聊，一次切换影响所有会话。
4. **同一时刻只有一个「正在听」的会话集合**：被切走的那批会话是脱钩状态，QQ 上发消息会走**当前**人格的会话池（若当前人格还没在这个会话说过话，就新建一个属于它自己的会话）。
5. **两个桥接实例同时跑会互写存档**（同一个 state 目录）。迁移/双开时先停一个。
6. 存档只在 `saveSocialV2State()` / 切换时更新；进程被 `kill -9` 且恰在保存窗口内，最后一条记忆可能没落盘（与 `social-v2.json` 同风险等级）。

## 9. 四层长期记忆（v0.1.2 新增）

C2 解决的是「切人格不串记忆」，但没解决另一件事：**长对话本身会把角色磨掉**——上下文截断、多次压缩摘要之后，最早的设定最先消失，模型的默认腔调一点点回流。

v0.1.2 起，桥接接了一个独立工具 `persona-memory-diary`（源码在 `qqbridge-tool/memory-diary/`，也可单独克隆到别处用），把「不能丢的东西」外置成有固定预算的文件，每次唤醒按预算重新注入：

| 层 | 文件 | 注入预算 | 谁维护 |
| --- | --- | --- | --- |
| 人格内核 | `persona-core/<角色>.md` | ≤600 字，每轮 | 人写，或从角色卡自动生成草稿 |
| 长期事实 | `state/<角色>/facts.jsonl` | ≤300 字 / 6 条 | 句式规则从对方消息里自动抽取，可在控制台补记 |
| 事件日记 | `state/<角色>/diary.jsonl` | ≤400 字（最近 6 + 相关 3） | 角色「记一笔」时双写，可在控制台补记 |
| 交接单 | `state/<角色>/handoff.json` | ≤700 字，新会话只读一次 | 控制台手动生成 |
| 档案留存 | `state/<角色>/archive/<日期>.jsonl` | 不注入 | 自动：每次写入/删除/轮转都追加 |

几条边界，避免和 C2 混淆：

- **C2 的记忆是「会话状态」**（话题、念头、印象、DSH 会话映射），跟着人格走；**这几层是「档案」**，跟着角色名走。两者互不覆盖。
- **档案只写不读**：`facts.jsonl` / `diary.jsonl` 会去重、会被删、超过 1MB 会轮转，`archive/` 把每一次变更按天留痕；它不参与注入、不占预算，只在主文件被误删或写坏时用来回查（控制台「档案留存」可看、可下载）。

`src/bridge.js` 顶部是静态 import，所以这份工具必须放到位才能启动；不需要这套记忆时，删掉对应的 import 与调用点即可。
- **按会话窗口隔离**：每条事实/日记带 `conv`，注入时只取「本窗口 + 无窗口归属的通用条目」，同一个人格的两个窗口各记各的。
- **不自动换会话**：上下文将满只发提醒（`handoff.remindAfterTurns`，默认 40 轮），换不换由人决定；交接单在下一个会话里只读一次，投递成功才标记已读。
- **数据可迁移**：全是纯文本，`rsync` 或控制台导出即一份档案；`persona-core/` 与 `state/` 都不入库。`scripts/sync-memory.ps1` 能把服务器上的 `state/`、`memory-diary/state/`、`persona-core/` 拉成本地快照（`-Apply` 才覆盖，覆盖前自动备份），`-Direction push` 反向推回。

`src/bridge.js` 顶部是静态 import，所以这份工具必须放到位才能启动；不需要这套记忆时，删掉对应的 import 与调用点即可。
