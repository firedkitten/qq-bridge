# 人格记忆隔离（C2）

> 状态：✅ 已实现并在线上验证（2026-10-24）。
> 一句话：**切人格 = 换记忆 + 换上下文**。每个会话的三类轻量记忆按人格分开存，切到谁就装回谁的记忆，同时退役旧 DSH 会话。

---

## 1. 为什么要做

改造前，人格（`roles/*.md`）只是每条消息前拼的一段提示词：

- **轻量记忆按会话存**（`state/social-v2.json` → `conversations[<key>].{activeTopics,pendingThoughts,memberImpressions}`），跟人格无关；
- **对话上下文按会话存**（`state/sessions.json` → `sessionId`），同样跟人格无关；
- `POST /api/role` 只写 `state/current-role.json`，既不动会话映射，也不重置 DSH 会话。

结果就是：`/role 傲娇助手` 之后，傲娇助手会接着说「小鲸鱼」答应过的事、记得小鲸鱼听到的群友八卦 —— 人格只换了嘴，没换脑子。

## 2. 三个方案与被选中的 C2

| 方案 | 记忆 | 上下文 | 改动量 | 结论 |
| --- | --- | --- | --- | --- |
| C1 | 按人格分开 | 共享 | 小 | 半隔离：还是会串戏 |
| **C2** | **按人格分开** | **切人格时重置** | 中 | ✅ 采用 |
| B | 记忆 key 改成 `<人格>|<会话>` | 分开 | 大（动所有读写点与迁移） | 不必要 |

C2 的关键判断：**人格换掉的那一刻，「它之前聊到哪」这件事本身就不该继承**。旧对话不是删掉，而是在 DSH 侧归档（控制台「会话与审批」还能查到），只是不再挂在这个会话映射上。

## 3. 行为规格

### 3.1 一次切换做四件事

`switchPersona(nextRole)`（[src/bridge.js](../../src/bridge.js) 内，入口 `/api/role` 与 QQ 的 `/role` 共用）：

1. **存档旧人格**：把当前内存里的三类记忆写成 `state/persona-memory/<旧人格>.json`；
2. **换人格**：写 `state/current-role.json`（`mode` 保持原值 —— 静默/活跃是「说话的意愿」，不属于人格）；
3. **装载新人格**：读 `state/persona-memory/<新人格>.json` 并就地改写内存里的三类字段；没有存档 = 空白人格（**不会继承别人的记忆**）；
4. **重置上下文**：对所有会话调 `retireSession(key)` —— 删 `sessions.json` 映射、轮换 agentToken、停掉旧会话上还在跑的回合与定时器、退订事件流。下一条消息按当前 preset 新建会话。

日志一行交代结果：

```
控制台：人格切换 小鲸鱼 → 傲娇助手；装载记忆 1 个会话，重置 DSH 会话 1 个
```

### 3.2 运行中持续镜像

`saveSocialV2State()` 每次落盘后，顺手把当前人格的记忆写进它自己的存档文件（`writePersonaArchive(readRoleState().role, extractPersonaMemory(...))`）。

**为什么必须镜像**：存档是切换时唯一的记忆来源。如果只在「切走时」写一次，切换前最后几分钟新产生的记忆在崩溃或重启后就没地方找了。镜像让存档始终等于「当前人格此刻的记忆」。

### 3.3 边界与不变项

| 场景 | 行为 |
| --- | --- |
| 静默 / 活跃（`mode`） | 切换人格**不变** |
| 唤醒配置（`wakeConfig`）、最近消息队列、未读水位 | 仍按**会话**存，切人格不动（「这个群几点该闭嘴」不是人格属性） |
| 人格重命名 | 存档文件跟着改名（`state/persona-memory/<旧>.json` → `<新>.json`），否则重命名后看起来像失忆 |
| 删除人格 | 连带删存档；若删的正是当前人格，先走 `switchPersona(null)` 清上下文再删 |
| 没有人格（`null`） | 存档名 `_none.json` |
| 切到同一个人格 | 直接返回 `changed: false`，不重置任何东西（重复点不会白清上下文） |
| 存档里有、但内存里没有该会话状态对象 | 跳过并在日志里列出 key（无法凭空造完整会话状态），等该会话重新出现后才生效 |
| 人格名 | 走 `sanitizeRoleName`，`/`、`..` 等一律剔除，不会拼出越界路径 |

## 4. 数据结构

`state/persona-memory/<人格名>.json`：

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

- 只存**非空记忆**的会话（三项全空的会话不落存档，切回来自然是空的，行为一致而文件更小）；
- 只存三类记忆字段，不存 `wakeConfig` / `recentMessages` / 水位 —— 那些仍归 `social-v2.json`；
- 单会话上限与 `social-v2.json` 一致：话题/念头各 50 条、印象深拷贝；空值一律规范成 `[]` / `{}`。

## 5. 接口

| 接口 | 说明 |
| --- | --- |
| `POST /api/role` `{ "role": "小鲸鱼" }`（或 `{"role": null}`） | 切换/清除人格。回包：`{ ok, role, resetSessions, memoryConversations, archivedRole, changed }` |
| `GET /api/role-memory?role=<人格名>` | 只读查看某人格的存档（排查「这个人格到底记得什么」） |

控制台「人格与角色 → 设置/清除」会提示 `✅ 已切换到「X」，已重置 N 个会话上下文`；QQ 侧 `/role <名字>` 回 `已切换角色：X。（已重置 N 个会话上下文）`。

## 6. 代码与测试

| 位置 | 内容 |
| --- | --- |
| `src/persona-memory.js` | 纯函数模块：`normalizeMemory` / `extractMemory` / `applyMemory` / `missingKeys` / `isMemoryEmpty`（文件读写在 bridge，模块本身不碰磁盘，便于单测） |
| `src/bridge.js` | `PERSONA_MEMORY_DIR` 与 `readPersonaArchive` / `writePersonaArchive`；`switchPersona()`；`/api/role`、`/api/role-memory`；`saveSocialV2State` 里的镜像；人格重命名/删除的连带处理 |
| `public/console.html` | 切换/清除后的提示文案带重置数量 |
| `scripts/test-persona-memory.mjs` | 11 项单测：脏数据规范化、深拷贝隔离、只收非空、存档外会话清空、不碰其他字段、往返一致、`missingKeys` |

```bash
npm run test:persona-memory     # 纯函数单测（不需要桥接/DSH 在跑）
```

**真机往返验证（2026-10-24，<服务器公网IP>）**：先塞一条合成记忆（话题 + 印象），再走完整切换：

```
切 小鲸鱼 → 傲娇助手：{"resetSessions":1,"memoryConversations":1,"archivedRole":"小鲸鱼"}
  → 小鲸鱼.json 含合成记忆；线上记忆清空；sessions 映射清空
切 傲娇助手 → 小鲸鱼：{"resetSessions":0,"memoryConversations":1}
  → 线上记忆原样恢复（/api/role-memory 返回同一份）
清理合成数据 + 重启 → 存档重建为空、SnowLuma/DSH 重连正常
```

## 7. 运维手册

```bash
# 看某人格的记忆存档
python3 -m json.tool /opt/qq-bridge/state/persona-memory/傲娇助手.json

# 只清某个人格的记忆（人格本身保留）
rm /opt/qq-bridge/state/persona-memory/傲娇助手.json

# 回退到「人格共享记忆」的老行为
rm -rf /opt/qq-bridge/state/persona-memory     # 存档没了就不会再装回旧记忆
# 并把 switchPersona 的 4) retire 段注释掉（或把 /api/role 恢复成只写 current-role.json）
```

## 8. 已知限制

1. **切换人格一定重置上下文**（这是 C2 的定义，不是 bug）。想让某个人格保留旧对话，只能选 B 方案（记忆 key 带人格前缀）。
2. **切人格是全局动作**：人格存在 `current-role.json` 里，不区分群聊/私聊 —— 一次切换影响所有会话。
3. **两个桥接实例同时跑会互写存档**（同一个 state 目录）。迁移/双开时先停一个。
4. 存档只在 `saveSocialV2State()` 的节奏上更新；若进程被 `kill -9` 且恰好在保存窗口内，最后一条记忆可能没落盘（与 `social-v2.json` 同风险等级）。
