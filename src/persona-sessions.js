// 人格 ↔ 会话映射存档（C2 的第二步：上下文也按人格分开）。
//
// 为什么需要：`state/sessions.json` 只记「当前这个人格」的 QQ 会话 → DSH 会话映射。
// 切人格时如果直接把它删掉，切回来就只能新建会话，上下文全丢。
// 这里把「每个人格自己的映射 + 该人格会话用的 agentToken」写成
// `state/persona-sessions.json`，切换时一存一取。
//
// 本模块刻意只做**纯数据**（不读写文件、不认识 bridge 的全局变量），
// 这样 `scripts/test-persona-sessions.mjs` 能直接跑，不必起桥接。

/** 存档里每个会话必须同时有三样东西才能安全挂回。 */
export const ARCHIVE_FIELDS = ['sessions', 'policies', 'tokens'];

const KEY_RE = /^(group|private):\d+$/;

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** 只认 `group:<号>` / `private:<号>`，其余 key 一律当脏数据丢掉。 */
export function isConversationKey(key) {
  return typeof key === 'string' && KEY_RE.test(key);
}

export function emptyArchive() {
  return { sessions: {}, policies: {}, tokens: {} };
}

/**
 * 把磁盘上读到的内容洗成可用的形状。
 *
 * 为什么要洗：这份文件会在切换人格时被直接信任并写回 `state.sessions`，
 * 一条脏数据（手改、写一半、别的版本留下的旧结构）就会让桥接对着一个
 * 不存在的会话发消息。宁可丢掉，也不要带着错误的 sessionId 上线。
 */
export function normalizeArchive(raw) {
  const out = emptyArchive();
  if (!isPlainObject(raw)) return out;
  const sessions = isPlainObject(raw.sessions) ? raw.sessions : {};
  const policies = isPlainObject(raw.policies) ? raw.policies : {};
  const tokens = isPlainObject(raw.tokens) ? raw.tokens : {};
  for (const [key, sessionId] of Object.entries(sessions)) {
    if (!isConversationKey(key)) continue;
    if (typeof sessionId !== 'string' || sessionId === '') continue;
    out.sessions[key] = sessionId;
    out.policies[key] = typeof policies[key] === 'string' ? policies[key] : '';
    out.tokens[key] = typeof tokens[key] === 'string' ? tokens[key] : '';
  }
  return out;
}

/** 从桥接的实时状态里拍一张快照（`policies` 是 policy 字符串，`tokens` 是 agentToken）。 */
export function buildArchive({ sessions, policies, tokens } = {}) {
  return normalizeArchive({ sessions, policies, tokens });
}

export function isEmptyArchive(archive) {
  const a = normalizeArchive(archive);
  return Object.keys(a.sessions).length === 0;
}

export function archiveSummary(archive) {
  const a = normalizeArchive(archive);
  const keys = Object.keys(a.sessions);
  return {
    keys,
    count: keys.length,
    withToken: keys.filter((k) => a.tokens[k]).length,
  };
}

/**
 * 决定「目标人格的存档里，哪些会话可以挂回来」。
 *
 * 两道闸门：
 *   1. 这个 key 现在还被准入（白名单 + 当前模式）—— 被踢出白名单的群不该借存档复活；
 *   2. 存档时的 policy 必须与**此刻**重算的 policy 一致 —— policy 含 mode 与 preset，
 *      而 DSH 会话的 preset 是建会话时定死的。模式/preset 变了还硬挂回旧会话，
 *      提示词与工具面会和会话实际状态不一致；这种时候宁可让它重建。
 *
 * @param {object} archive  normalizeArchive 之后的存档
 * @param {(key: string) => string} policyOf  当前 policy 字符串
 * @param {(key: string) => boolean} [allowed]  当前是否准入，缺省视为允许
 */
export function planRestore(archive, policyOf, allowed = () => true) {
  const a = normalizeArchive(archive);
  const restore = [];
  const skipped = [];
  for (const [key, sessionId] of Object.entries(a.sessions)) {
    if (!allowed(key)) {
      skipped.push({ key, sessionId, reason: 'not-allowed' });
      continue;
    }
    const want = typeof policyOf === 'function' ? String(policyOf(key) ?? '') : '';
    const had = a.policies[key] ?? '';
    if (had !== want) {
      skipped.push({ key, sessionId, reason: 'policy-changed' });
      continue;
    }
    restore.push({ key, sessionId, token: a.tokens[key] || '' });
  }
  return { restore, skipped };
}
