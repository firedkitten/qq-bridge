// 人格会话存档的单元测试（纯数据，不需要 DSH / QQ / 磁盘）。
//
//   node scripts/test-persona-sessions.mjs
//
// 覆盖的是「哪些会话能安全挂回」这条判断，以及脏数据兜底 —— 这两种错都不会当场崩，
// 只会在切人格后表现为「上下文莫名其妙变了」，所以必须有断言盯着。

import {
  emptyArchive,
  normalizeArchive,
  buildArchive,
  isEmptyArchive,
  archiveSummary,
  planRestore,
  isConversationKey,
} from '../src/persona-sessions.js';

let pass = 0;
let fail = 0;

function ok(name, cond, extra = '') {
  if (cond) {
    pass += 1;
    console.log(`  ✅ ${name}`);
  } else {
    fail += 1;
    console.log(`  ❌ ${name}${extra ? ` —— ${extra}` : ''}`);
  }
}

function eq(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  ok(name, a === e, `实际 ${a} / 期望 ${e}`);
}

console.log('\n== emptyArchive ==');
eq('三项都是空对象', emptyArchive(), { sessions: {}, policies: {}, tokens: {} });

console.log('\n== isConversationKey ==');
ok('private:123 合法', isConversationKey('private:123'));
ok('group:456 合法', isConversationKey('group:456'));
ok('缺前缀不合法', !isConversationKey('123456'));
ok('前缀不对不合法', !isConversationKey('user:123'));
ok('含字母的号不合法', !isConversationKey('group:12a'));
ok('非字符串不合法', !isConversationKey(123));

console.log('\n== normalizeArchive：脏数据兜底 ==');
eq('非对象 → 空存档', normalizeArchive('nope'), { sessions: {}, policies: {}, tokens: {} });
eq('null → 空存档', normalizeArchive(null), { sessions: {}, policies: {}, tokens: {} });
{
  const got = normalizeArchive({
    sessions: {
      'private:1': 'session-a',
      'group:2': '',            // 空 sessionId：丢
      'user:3': 'session-c',    // 非法 key：丢
      'group:4': 42,            // 非字符串：丢
    },
    policies: { 'private:1': '["reserved2","qq-chat-v2",null]' },
    tokens: { 'private:1': 'tok-a', 'group:2': 'tok-b' },
  });
  eq('只留下合法的 private:1', Object.keys(got.sessions), ['private:1']);
  eq('policy 带过来', got.policies['private:1'], '["reserved2","qq-chat-v2",null]');
  eq('token 带过来', got.tokens['private:1'], 'tok-a');
  eq('被丢掉的会话不残留 policy', got.policies['group:2'], undefined);
  eq('被丢掉的会话不残留 token', got.tokens['group:2'], undefined);
}
{
  const got = normalizeArchive({ sessions: { 'private:1': 's1' }, policies: 'bad', tokens: [] });
  eq('policies 不是对象 → 空串', got.policies['private:1'], '');
  eq('tokens 不是对象 → 空串', got.tokens['private:1'], '');
}

console.log('\n== buildArchive：从实时状态拍快照 ==');
{
  const live = {
    sessions: { 'private:1': 'session-a', 'group:2': 'session-b' },
    policies: { 'private:1': 'p1', 'group:2': 'p2' },
    tokens: { 'private:1': 't1' }, // group:2 还没发过令牌
  };
  const a = buildArchive(live);
  eq('两个会话都在', Object.keys(a.sessions).sort(), ['group:2', 'private:1']);
  eq('缺令牌的补空串', a.tokens['group:2'], '');
  ok('archiveSummary.withToken 只数有令牌的', archiveSummary(a).withToken === 1);
  ok('archiveSummary.count 正确', archiveSummary(a).count === 2);
  ok('非空存档', !isEmptyArchive(a));
  ok('空存档判空', isEmptyArchive(emptyArchive()));
  ok('脏存档判空', isEmptyArchive({ sessions: { 'bad-key': 'x' } }));
}

console.log('\n== planRestore：哪些能挂回 ==');
{
  const archive = buildArchive({
    sessions: { 'private:1': 's1', 'group:2': 's2', 'group:3': 's3' },
    policies: { 'private:1': 'p1', 'group:2': 'p2', 'group:3': 'p3' },
    tokens: { 'private:1': 't1' },
  });
  const policyOf = (key) => ({ 'private:1': 'p1', 'group:2': 'p2', 'group:3': 'p3-new' })[key] ?? '';
  const allowed = (key) => key !== 'group:2';
  const { restore, skipped } = planRestore(archive, policyOf, allowed);
  eq('只挂回 policy 未变且准入的', restore.map((r) => r.key), ['private:1']);
  eq('挂回时带上该人格的令牌', restore[0].token, 't1');
  eq('被拒绝的按原因分开记录', skipped.map((s) => `${s.key}:${s.reason}`).sort(), ['group:2:not-allowed', 'group:3:policy-changed']);
}
{
  const archive = buildArchive({ sessions: { 'private:1': 's1' }, policies: { 'private:1': 'p1' } });
  const { restore } = planRestore(archive, () => 'p1');
  eq('policy 一致就挂回', restore.length, 1);
  const r2 = planRestore(archive, () => 'p1', undefined).restore;
  eq('allowed 缺省视为允许', r2.length, 1);
  eq('没有令牌时给空串', r2[0].token, '');
}
{
  // 存档里 policy 是空串（老数据/脏数据），当前也算空串时才允许挂回
  const archive = normalizeArchive({ sessions: { 'private:9': 's9' } });
  eq('老存档（无 policy）在 policy 也算空时挂回', planRestore(archive, () => '').restore.length, 1);
  eq('老存档在 policy 非空时跳过', planRestore(archive, () => 'p').restore.length, 0);
}

console.log(`\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail === 0 ? 0 : 1);
