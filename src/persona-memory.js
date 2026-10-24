// 人格（角色）记忆存档：把「轻量记忆」的三类字段按人格分开存。
//
// 背景（为什么需要这个模块）：
//   qq-bridge 的轻量记忆（activeTopics / pendingThoughts / memberImpressions）原本只按
//   **会话** 存（`socialV2.conversations.get('private:1000000002')`），人格只是每条消息前
//   拼的一段提示词，切人格不换记忆 —— 于是「傲娇助手」会记得「小鲸鱼」答应过的事。
//
//   这里只做两件纯逻辑的事：
//     · extractMemory(conversations)  ← 把当前内存里的三类记忆抽成一个可存档的普通对象
//     · applyMemory(conversations, archive) ← 把某个人格的存档装回内存
//   文件读写由调用方（bridge.js）负责，这样本模块可以被 scripts/test-persona-memory.mjs
//   直接单测，不需要启动整条桥接链路。

/** 记忆字段名的唯一真相，改这里等于改全部。 */
export const MEMORY_FIELDS = Object.freeze(['activeTopics', 'pendingThoughts', 'memberImpressions']);

/** 单个会话的记忆上限，与 saveSocialV2State 里的 slice(-50) 保持一致。 */
const MAX_ENTRIES = 50;

/**
 * 深拷贝一个「只含 JSON 值」的对象。
 * 这些记忆本来就要落成 JSON 文件，所以用 JSON 往返最稳；失败时退回 structuredClone。
 */
function cloneJson(value) {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch {
    return typeof structuredClone === 'function' ? structuredClone(value) : { ...value };
  }
}

/** 空记忆。每次返回新对象，避免共享引用被就地改写。 */
export function emptyMemory() {
  return { activeTopics: [], pendingThoughts: [], memberImpressions: {} };
}

/**
 * 把任意来源的对象规范化成 `{ activeTopics, pendingThoughts, memberImpressions }`。
 * 容忍脏数据：数组缺省为空数组，印象必须是普通对象（不能是数组 / null）。
 */
export function normalizeMemory(raw = {}) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const impressions = src.memberImpressions;
  return {
    activeTopics: Array.isArray(src.activeTopics) ? src.activeTopics.slice(-MAX_ENTRIES) : [],
    pendingThoughts: Array.isArray(src.pendingThoughts) ? src.pendingThoughts.slice(-MAX_ENTRIES) : [],
    // 深拷贝：印象是 `{ 昵称: { note, updatedAt, ... } }`，浅拷贝会让存档与内存共享
    // 内层对象 —— 切人格后改一个人的印象，会连带把上一个人格的存档也改掉。
    memberImpressions: impressions && typeof impressions === 'object' && !Array.isArray(impressions)
      ? cloneJson(impressions)
      : {}
  };
}

/** 记忆是否为空（三项都为空的会话不必存档，能把存档文件压得很小）。 */
export function isMemoryEmpty(memory) {
  const m = normalizeMemory(memory);
  return m.activeTopics.length === 0
    && m.pendingThoughts.length === 0
    && Object.keys(m.memberImpressions).length === 0;
}

/**
 * 从会话状态 Map（key -> state）里抽出三类记忆。
 * 只收非空记忆：空会话不进存档，切回来时自然是空的，行为一致而文件更小。
 */
export function extractMemory(conversations) {
  const out = Object.create(null);
  if (!conversations) return out;
  const entries = conversations instanceof Map ? conversations.entries() : Object.entries(conversations);
  for (const [key, st] of entries) {
    if (!st || typeof st !== 'object') continue;
    const memory = normalizeMemory(st);
    if (isMemoryEmpty(memory)) continue;
    out[key] = memory;
  }
  return out;
}

/**
 * 把某个人格的存档装回会话状态（就地改写）。
 *
 * 只处理**已存在**的会话：人格 A 有记忆、但当前内存里没有这个会话的状态对象时，
 * 没法凭空造一个完整会话状态（那需要 bridge 内的状态工厂），所以跳过并让调用方计数。
 * 返回被改写的会话数。
 */
export function applyMemory(conversations, archive = {}) {
  if (!conversations) return 0;
  const src = archive && typeof archive === 'object' ? archive : {};
  const entries = conversations instanceof Map ? conversations.entries() : Object.entries(conversations);
  let applied = 0;
  for (const [key, st] of entries) {
    if (!st || typeof st !== 'object') continue;
    const memory = normalizeMemory(src[key]);
    st.activeTopics = memory.activeTopics;
    st.pendingThoughts = memory.pendingThoughts;
    st.memberImpressions = memory.memberImpressions;
    applied += 1;
  }
  return applied;
}

/**
 * 存档里存在、但当前内存里没有对应会话的 key。
 * 调用方可以据此打日志（说明这些记忆这次没能装回，等会话重新出现才生效）。
 */
export function missingKeys(conversations, archive = {}) {
  if (!conversations) return [];
  const src = archive && typeof archive === 'object' ? archive : {};
  const has = new Set(conversations instanceof Map ? [...conversations.keys()] : Object.keys(conversations));
  return Object.keys(src).filter((key) => !has.has(key));
}
