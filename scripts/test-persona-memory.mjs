// 人格记忆存档（src/persona-memory.js）单测。
// 纯函数，不启桥接、不连 DSH、不碰磁盘：node scripts/test-persona-memory.mjs
import {
  MEMORY_FIELDS,
  emptyMemory,
  normalizeMemory,
  isMemoryEmpty,
  extractMemory,
  applyMemory,
  missingKeys,
} from '../src/persona-memory.js';

let failed = 0;
function check(label, fn) {
  try { fn(); console.log(`  ✅ ${label}`); }
  catch (e) { console.log(`  ❌ ${label}: ${e?.message ?? e}`); failed += 1; }
}
function eq(actual, expected, what) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${what ?? '值'} 不一致：期望 ${b}，实际 ${a}`);
}

const conv = (over = {}) => ({
  wakeConfig: { mode: 'diving' },
  recentMessages: [],
  activeTopics: [],
  pendingThoughts: [],
  memberImpressions: {},
  ...over,
});

console.log('persona-memory 单测：\n');

check('MEMORY_FIELDS 覆盖三类记忆', () => {
  eq(MEMORY_FIELDS, ['activeTopics', 'pendingThoughts', 'memberImpressions'], 'MEMORY_FIELDS');
});

check('emptyMemory 每次返回独立对象（不会被就地改写串味）', () => {
  const a = emptyMemory();
  const b = emptyMemory();
  a.activeTopics.push({ text: 'x' });
  eq(b.activeTopics, [], 'b.activeTopics');
  if (a.memberImpressions === b.memberImpressions) throw new Error('memberImpressions 共享了引用');
});

check('normalizeMemory 容忍脏数据', () => {
  const m = normalizeMemory({
    activeTopics: 'not-an-array',
    pendingThoughts: null,
    memberImpressions: ['array-is-invalid'],
  });
  eq(m, { activeTopics: [], pendingThoughts: [], memberImpressions: {} }, 'normalizeMemory');
});

check('normalizeMemory 复制印象对象（不共享引用）', () => {
  const src = { memberImpressions: { 阿伟: { note: '话痨' } } };
  const m = normalizeMemory(src);
  m.memberImpressions['阿伟'].note = '改成别的';
  eq(src.memberImpressions['阿伟'].note, '话痨', '源对象');
});

check('extractMemory 只收非空记忆', () => {
  const conversations = new Map([
    ['private:1', conv({
      activeTopics: [{ text: '在聊搬家' }],
      pendingThoughts: [{ text: '想问它住哪', expiresAt: Date.now() + 3600_000 }],
      memberImpressions: { 暮岁: { note: '爱问药' } },
    })],
    ['group:2', conv()],
  ]);
  const archive = extractMemory(conversations);
  eq(Object.keys(archive), ['private:1'], '存档 key');
  eq(archive['private:1'].activeTopics, [{ text: '在聊搬家' }], 'activeTopics');
  eq(archive['private:1'].memberImpressions, { 暮岁: { note: '爱问药' } }, 'memberImpressions');
});

check('extractMemory 也接受普通对象（存档回读后的形态）', () => {
  const archive = extractMemory({ 'group:9': conv({ activeTopics: [{ text: 't' }] }) });
  eq(Object.keys(archive), ['group:9'], '存档 key');
});

check('applyMemory 装载目标人格、清空存档外的会话', () => {
  const conversations = new Map([
    ['private:1', conv({ activeTopics: [{ text: '小鲸鱼聊的事' }] })],
    ['group:2', conv({ activeTopics: [{ text: '小鲸鱼在群里聊的事' }] })],
  ]);
  const applied = applyMemory(conversations, {
    'private:1': { activeTopics: [{ text: '傲娇助手聊的事' }], pendingThoughts: [], memberImpressions: {} },
  });
  if (applied !== 2) throw new Error(`applied=${applied}，应为 2（两个会话都被改写）`);
  eq(conversations.get('private:1').activeTopics, [{ text: '傲娇助手聊的事' }], 'private:1.activeTopics');
  eq(conversations.get('group:2').activeTopics, [], 'group:2 无存档 → 应清空');
});

check('applyMemory 不碰会话状态里的其他字段', () => {
  const conversations = new Map([['private:1', conv({ wakeConfig: { mode: 'active' }, recentMessages: [{ text: 'hi' }] })]]);
  applyMemory(conversations, {});
  eq(conversations.get('private:1').wakeConfig, { mode: 'active' }, 'wakeConfig');
  eq(conversations.get('private:1').recentMessages, [{ text: 'hi' }], 'recentMessages');
});

check('extract → JSON → apply 往返一致', () => {
  const original = new Map([
    ['private:1', conv({
      activeTopics: [{ text: '话题A', lastMentionAt: 1 }],
      pendingThoughts: [{ text: '想法B', expiresAt: 9 }],
      memberImpressions: { 阿伟: { note: '话痨', updatedAt: 3 } },
    })],
  ]);
  const file = JSON.parse(JSON.stringify(extractMemory(original)));
  // 模拟「切到另一个人格」：内存被（切走时）清空，再装回来
  applyMemory(original, {});
  eq(original.get('private:1').activeTopics, [], '切换后应为空');
  applyMemory(original, file);
  eq(original.get('private:1').activeTopics, [{ text: '话题A', lastMentionAt: 1 }], '往返 activeTopics');
  eq(original.get('private:1').memberImpressions, { 阿伟: { note: '话痨', updatedAt: 3 } }, '往返成员印象');
});

check('missingKeys 找出「有存档但当前无会话」的 key', () => {
  const conversations = new Map([['private:1', conv()]]);
  eq(missingKeys(conversations, { 'private:1': {}, 'group:2': {} }), ['group:2'], 'missingKeys');
});

check('isMemoryEmpty 判定', () => {
  if (!isMemoryEmpty(conv())) throw new Error('空会话应为空记忆');
  if (isMemoryEmpty({ memberImpressions: { a: {} } })) throw new Error('有印象不应判定为空');
});

console.log('');
if (failed > 0) {
  console.log(`❌ ${failed} 项失败`);
  process.exit(1);
}
console.log('✅ 全部通过');
