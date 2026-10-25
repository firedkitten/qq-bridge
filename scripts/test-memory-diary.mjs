#!/usr/bin/env node
// P3 角色记忆（长期事实 + 事件日记）桥接级集成测试：
//   1) 唤醒提示词里的注入顺序：人格内核 → 事件日记 → 长期事实；
//   2) 事实/日记按**角色**隔离，切角色不串味；
//   3) 控制台接口能增删查，删除后立刻从提示词里消失；
//   4) agent token（AI 自己）调不动这些管理接口。
//
// 运行：node scripts/test-memory-diary.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { bridgeHarness } from './audit-bridge-harness.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));

let failures = 0;
async function test(name, run) {
  try { await run(); console.log('PASS', name); }
  catch (error) { failures++; console.error('FAIL', name, '—', error?.stack ?? error); }
}

const ADMIN = { 'x-console-token': 'fixture-console-token' };
const ROLE_A = '小鲸鱼';
const ROLE_B = '傲娇助手';
// harness 的 ROOT 是临时目录，人格内核也要跟着拷进去（生产里读的是仓库里的同一份文件）。
const REAL_CORE = fs.readFileSync(path.join(root, 'qqbridge-tool/memory-diary/persona-core/小鲸鱼.md'), 'utf8');

function call(port, pathname, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(
      { host: '127.0.0.1', port, path: pathname, method, headers: { 'content-type': 'application/json', ...headers } },
      (response) => {
        let data = '';
        response.on('data', (chunk) => { data += chunk; });
        response.on('end', () => {
          let json = null;
          try { json = JSON.parse(data); } catch {}
          resolve({ status: response.statusCode, body: data, json, headers: response.headers });
        });
      }
    );
    request.on('error', reject);
    request.setTimeout(5000, () => request.destroy(new Error('request hung')));
    request.end(body === undefined ? undefined : JSON.stringify(body));
  });
}

async function withServer(h, run) {
  const server = h.startConsoleServer();
  if (!server.listening) await new Promise((resolve) => server.once('listening', resolve));
  try { await run(server.address().port); }
  finally { await new Promise((resolve) => server.close(resolve)); }
}

const factLine = (text, cat, role = ROLE_A, conv = '') =>
  JSON.stringify({ at: Date.now(), key: text.slice(0, 24), text, cat, role, conv });
const diaryLine = (text, role = ROLE_A, conv = '') => JSON.stringify({ at: Date.now(), text, role, conv });

function seedFiles(role, { facts = [], diary = [] } = {}) {
  const dir = `qqbridge-tool/memory-diary/state/${role}`;
  const files = {};
  // 每条可以是 [text, cat] 或 [text, cat, conv]；日记同理。
  if (facts.length) files[`${dir}/facts.jsonl`] = facts.map(([t, c, conv]) => factLine(t, c, role, conv)).join('\n') + '\n';
  if (diary.length) files[`${dir}/diary.jsonl`] = diary.map((item) => (Array.isArray(item) ? diaryLine(item[0], role, item[1]) : diaryLine(item, role))).join('\n') + '\n';
  return files;
}

// ── 1. 注入顺序 + 三个来源都在 ─────────────────────────────────────────────────
await test('唤醒提示词按「内核 → 日记 → 事实」排列，且三块都有内容', async () => {
  const h = await bridgeHarness({
    files: {
      'state/current-role.json': { role: ROLE_A, mode: 'active' },
      'qqbridge-tool/memory-diary/persona-core/小鲸鱼.md': REAL_CORE,
      ...seedFiles(ROLE_A, { facts: [['名字：小周', 'identity'], ['不吃辣', 'dislike']], diary: ['聊到周末去爬山'] })
    }
  });
  try {
    const prompt = h.buildWakePromptV2('group:456', 'question');
    const at = (needle) => {
      const i = prompt.indexOf(needle);
      assert.ok(i >= 0, `提示词里应有「${needle}」`);
      return i;
    };
    const core = at('【人格内核 · 始终遵守】');
    const diary = at('日记 · 记忆锚点');
    const facts = at('长期事实 · 用户画像');
    assert.ok(core < diary, '人格内核必须排在事件日记之前');
    assert.ok(diary < facts, '事件日记在长期事实之前');
    assert.ok(prompt.includes('小周') && prompt.includes('不吃辣'), '事实内容要进提示词');
    assert.ok(prompt.includes('聊到周末去爬山'), '日记内容要进提示词');

    // 内核要体现用户 m00193 的五点决定（称呼条件、懒/准、偶尔嘴硬、官方吉祥物）
    const coreBody = prompt.slice(core, core + 800);
    for (const [needle, why] of [
      ['称呼', '称呼规则'],
      ['情绪波动大时才叫', '「用户」只在高情绪时用'],
      ['平时懒得营业', '平时懒、正事准'],
      ['偶尔嘴硬否认', '大肥鱼称呼要偶尔嘴硬否认'],
      ['官方吉祥物', '被问是否官方吉祥物就打岔/自嘲']
    ]) assert.ok(coreBody.includes(needle), `人格内核应包含「${why}」`);
    assert.ok(!coreBody.includes('§'), '不得把文末分组标记漏进内核');
  } finally { await h.close(); }
});

// ── 2. 按角色隔离 ──────────────────────────────────────────────────────────────
await test('事实与日记按角色隔离，切角色不串味', async () => {
  const h = await bridgeHarness({
    files: {
      'state/current-role.json': { role: ROLE_B, mode: 'active' },
      ...seedFiles(ROLE_A, { facts: [['名字：小周', 'identity']], diary: ['A 角色的日记'] }),
      ...seedFiles(ROLE_B, { facts: [['喜欢猫', 'preference']], diary: ['B 角色的日记'] })
    }
  });
  try {
    const prompt = h.buildWakePromptV2('group:456', 'question');
    assert.ok(prompt.includes('喜欢猫') && prompt.includes('B 角色的日记'), '当前角色自己的记忆要在');
    assert.ok(!prompt.includes('小周'), 'A 角色的事实不得串到 B 角色');
    assert.ok(!prompt.includes('A 角色的日记'), 'A 角色的日记不得串到 B 角色');
  } finally { await h.close(); }
});

// ── 3. 控制台接口：增 / 查 / 删，删除后立刻从提示词消失 ───────────────────────
await test('控制台接口能增删查长期事实，删除后提示词里不再出现', async () => {
  const h = await bridgeHarness({
    files: { 'state/current-role.json': { role: ROLE_A, mode: 'active' } }
  });
  try {
    await withServer(h, async (port) => {
      const added = await call(port, '/api/memory-diary/add', {
        method: 'POST', headers: ADMIN, body: { role: ROLE_A, store: 'facts', cat: 'identity', text: '养了只叫团子的猫' }
      });
      assert.equal(added.status, 200, `新增应成功，实际 ${added.status} ${added.body}`);
      assert.equal(added.json?.ok, true);

      const list = await call(port, `/api/memory-diary?role=${encodeURIComponent(ROLE_A)}`, { headers: ADMIN });
      assert.equal(list.status, 200);
      assert.ok(list.json?.facts?.some((f) => f.text.includes('团子')), '列表里应有刚加的事实');

      const prompt = h.buildWakePromptV2('group:456', 'question');
      assert.ok(prompt.includes('团子'), '新增事实要马上进提示词（不用重启）');

      const entry = list.json.facts.find((f) => f.text.includes('团子'));
      const removed = await call(port, '/api/memory-diary/delete', {
        method: 'POST', headers: ADMIN, body: { role: ROLE_A, store: 'facts', at: entry.at, text: entry.text }
      });
      assert.equal(removed.status, 200);
      assert.ok(removed.json?.removed >= 1, '应该删掉至少一条');

      const after = h.buildWakePromptV2('group:456', 'question');
      assert.ok(!after.includes('团子'), '删除后提示词不得再带这条事实');
    });
  } finally { await h.close(); }
});

// ── 4. AI 自己（agent token）碰不到管理接口 ───────────────────────────────────
await test('agent token 既读不到也改不了记忆接口', async () => {
  const h = await bridgeHarness({ files: { 'state/current-role.json': { role: ROLE_A, mode: 'active' } } });
  try {
    h.setMode('reserved2');
    await withServer(h, async (port) => {
      const asAgent = { ...ADMIN, 'x-agent-token': 'fixture-agent-token', 'x-agent-call': '1' };
      const list = await call(port, `/api/memory-diary?role=${encodeURIComponent(ROLE_A)}`, { headers: asAgent });
      assert.equal(list.status, 403, 'agent token 读列表必须 403');
      const add = await call(port, '/api/memory-diary/add', {
        method: 'POST', headers: asAgent, body: { role: ROLE_A, store: 'facts', text: 'AI 想给自己加设定' }
      });
      assert.equal(add.status, 403, 'agent token 写事实必须 403');
    });
  } finally { await h.close(); }
});

// ── 5. 没有内核的角色：不崩、也不冒充人格 ─────────────────────────────────────
await test('没有 persona-core 的角色照常出提示词，只是不带人格内核', async () => {
  const h = await bridgeHarness({ files: { 'state/current-role.json': { role: '临时角色', mode: 'active' } } });
  try {
    const prompt = h.buildWakePromptV2('group:456', 'question');
    assert.ok(prompt.length > 100, '提示词应正常生成');
    assert.ok(!prompt.includes('【人格内核 · 始终遵守】'), '没有内核文件时不得凭空注入人格');
  } finally { await h.close(); }
});

// ── 6. 会话窗口隔离：A 窗口知道的事不得跑到 B 窗口 ────────────────────────────
await test('事实与日记按会话窗口隔离，不跨窗口串味', async () => {
  const h = await bridgeHarness({
    files: {
      'state/current-role.json': { role: ROLE_A, mode: 'active' },
      ...seedFiles(ROLE_A, {
        facts: [['家里养了只橘猫', 'relation', 'group:456'], ['生日是三月十七', 'identity', 'private:789']],
        diary: [['一起聊了整晚的猫', 'group:456'], ['她说最近睡不好', 'private:789']],
      }),
    },
  });
  try {
    const inGroup = h.buildWakePromptV2('group:456', 'question');
    assert.ok(inGroup.includes('家里养了只橘猫'), '群窗口要看到群窗口记的事');
    assert.ok(!inGroup.includes('生日是三月十七'), '另一个窗口的事实不得出现在群窗口');
    assert.ok(!inGroup.includes('她说最近睡不好'), '另一个窗口的日记不得出现在群窗口');

    const inPrivate = h.buildWakePromptV2('private:789', 'question');
    assert.ok(inPrivate.includes('生日是三月十七'), '单聊窗口要看到单聊记的事');
    assert.ok(!inPrivate.includes('家里养了只橘猫'), '群窗口的事实不得出现在单聊窗口');
  } finally { await h.close(); }
});

// ── 7. 新建人格自动生成内核；改卡后可一键重生成 ───────────────────────────────
await test('新建人格自动生成人格内核，更新接口按新角色卡重生成', async () => {
  const h = await bridgeHarness({ files: {} });
  try {
    await withServer(h, async (port) => {
      const card = [
        '# 角色卡：测试人格',
        '## 一、你是谁',
        '你是负责怼人的小猫，偶尔炸毛。',
        '## 二、说话方式',
        '一句话不超过十五个字。',
        '## 三、黑名单',
        '别说"亲爱的"这类黏糊话。',
      ].join('\n');
      const created = await call(port, '/api/roles/create', {
        method: 'POST', headers: ADMIN, body: { name: '测试人格', content: card },
      });
      assert.equal(created.status, 200, created.body);
      assert.ok(created.json?.core?.created, '新建人格时应当自动生成内核');

      const got = await call(port, '/api/persona-core?role=' + encodeURIComponent('测试人格'), { headers: ADMIN });
      assert.equal(got.status, 200, got.body);
      assert.equal(got.json.exists, true, '内核文件应当存在');
      assert.ok(got.json.body.includes('【身份】'), '内核应带身份分类');
      assert.ok(got.json.body.includes('不说：'), '禁区行要标明「不说」');
      assert.equal(got.json.stale, false, '刚生成的内核不该是过期状态');

      // 角色卡改了 → 内核标记过期；确认后再重生成
      const changed = card.replace('负责怼人的小猫', '负责撒娇的小猫');
      const updated = await call(port, '/api/roles/update', {
        method: 'POST', headers: ADMIN, body: { name: '测试人格', content: changed },
      });
      assert.equal(updated.status, 200, updated.body);

      const stale = await call(port, '/api/persona-core?role=' + encodeURIComponent('测试人格'), { headers: ADMIN });
      assert.equal(stale.json.stale, true, '角色卡改过之后内核应标记为过期');

      const blocked = await call(port, '/api/persona-core/update', {
        method: 'POST', headers: ADMIN, body: { role: '测试人格' },
      });
      assert.equal(blocked.status, 409, '不显式 force 时不得覆盖已有内核');

      const forced = await call(port, '/api/persona-core/update', {
        method: 'POST', headers: ADMIN, body: { role: '测试人格', force: true },
      });
      assert.equal(forced.status, 200, forced.body);
      assert.ok(forced.json.backup, '覆盖前应留一份备份');

      const after = await call(port, '/api/persona-core?role=' + encodeURIComponent('测试人格'), { headers: ADMIN });
      assert.ok(after.json.body.includes('撒娇'), '重生成的内核应当反映新角色卡');
      assert.equal(after.json.stale, false);
    });
  } finally { await h.close(); }
});

// ── 8. 交接单（P4）：换会话前后，记忆靠交接单接住，且只读一次 ───────────────────
await test('生成交接单后新会话首次唤醒带上它，读一次即作废', async () => {
  const h = await bridgeHarness({
    files: {
      'state/current-role.json': { role: ROLE_A, mode: 'active' },
      ...seedFiles(ROLE_A, {
        facts: [['名字：小周', 'identity', 'private:789'], ['不吃辣', 'dislike', 'private:789']],
        diary: [['一起去吃了火锅', 'private:789'], ['聊到最近换了工作', 'private:789']],
      }),
    },
  });
  try {
    h.setMode('reserved2');
    await withServer(h, async (port) => {
      const rotated = await call(port, '/api/handoff/rotate', {
        method: 'POST', headers: ADMIN, body: { scope: 'private:789' },
      });
      assert.equal(rotated.status, 200, rotated.body);
      assert.equal(rotated.json.ok, true);
      assert.ok(rotated.json.file, '应返回交接单路径');
      assert.ok(fs.existsSync(path.join(h.temp, rotated.json.file)), '交接单文件应当真的落盘');

      const pending = await call(port, '/api/handoff?role=' + encodeURIComponent(ROLE_A) + '&scope=private:789', { headers: ADMIN });
      assert.equal(pending.status, 200, pending.body);
      assert.equal(pending.json.pending, true, '生成后应为待读状态');
      assert.equal(pending.json.autoAfterTurns, 0, '桥接绝不自动换会话：autoAfterTurns 恒为 0');
      assert.ok(Number(pending.json.remindAfterTurns) > 0, '应有提醒阈值（默认 40 轮）');
      assert.ok(pending.json.latest?.facts?.some((f) => String(f).includes('小周')) || JSON.stringify(pending.json.latest).includes('小周'), '交接单应带上这一窗的事实');

      const first = h.buildWakePromptV2('private:789', 'question');
      assert.ok(first.includes('【交接单'), '换会话后的第一次唤醒应注入交接单');
      assert.ok(first.includes('火锅'), '交接单里应写着这一窗发生过的事');

      const used = await call(port, '/api/handoff/use', { method: 'POST', headers: ADMIN, body: { role: ROLE_A } });
      assert.equal(used.status, 200, used.body);

      const second = h.buildWakePromptV2('private:789', 'question');
      assert.ok(!second.includes('【交接单'), '读过之后不得每轮重复注入');
      assert.ok(second.includes('名字：小周') || second.includes('小周'), '事实本身仍应照常注入');
    });
  } finally { await h.close(); }
});

// ── 9. 导出接口：中文角色名不得让响应头变非法（回归：曾 500） ─────────────────
await test('导出接口在中文角色名下可用，响应头保持 ASCII', async () => {
  const h = await bridgeHarness({
    files: {
      'state/current-role.json': { role: ROLE_A, mode: 'active' },
      ...seedFiles(ROLE_A, { facts: [['名字：小周', 'identity']], diary: ['一起给猫起了名字'] }),
    },
  });
  try {
    await withServer(h, async (port) => {
      const one = await call(port, '/api/memory-diary/export?role=' + encodeURIComponent(ROLE_A), { headers: ADMIN });
      assert.equal(one.status, 200, `单个角色导出应 200，实际 ${one.status} ${one.body}`);
      const parsed = JSON.parse(one.body);
      assert.ok(parsed.roles?.[ROLE_A], '导出内容里应有该角色');
      assert.ok(parsed.roles[ROLE_A].facts.length >= 1, '导出应带上事实');

      const disp = String(one.headers['content-disposition'] ?? '');
      assert.ok(disp.includes('filename='), `应给出下载文件名，实际 ${JSON.stringify(disp)}`);
      assert.ok(/^[\x20-\x7e]+$/.test(disp), `content-disposition 必须是纯 ASCII，实际 ${JSON.stringify(disp)}`);
      assert.ok(disp.includes("filename*=UTF-8''"), '应附带 RFC 5987 的 filename* 以还原中文名');

      const all = await call(port, '/api/memory-diary/export', { headers: ADMIN });
      assert.equal(all.status, 200, `全量导出也应 200，实际 ${all.status} ${all.body}`);
    });
  } finally { await h.close(); }
});

// ── 10. 档案留存接口：只读、按天可查、删除条目可回溯 ────────────────────────
await test('档案接口能列出按天归档的写入与删除记录', async () => {
  const h = await bridgeHarness({
    files: { 'state/current-role.json': { role: ROLE_A, mode: 'active' } },
  });
  try {
    await withServer(h, async (port) => {
      const added = await call(port, '/api/memory-diary/add', {
        method: 'POST',
        headers: ADMIN,
        body: { role: ROLE_A, store: 'diary', kind: 'event', text: '一起给猫起了名字', scope: 'private:1' },
      });
      assert.equal(added.status, 200, `写日记应成功，实际 ${added.status} ${added.body}`);

      const list = await call(port, '/api/memory-diary/archive?role=' + encodeURIComponent(ROLE_A) + '&kind=diary', { headers: ADMIN });
      assert.equal(list.status, 200, `档案列表应 200，实际 ${list.status} ${list.body}`);
      const lr = JSON.parse(list.body);
      assert.ok(Array.isArray(lr.days) && lr.days.length >= 1, '应至少有一天档案');
      assert.ok(lr.stats.entries >= 1, '档案统计应有条目');

      const day = lr.days[0];
      const one = await call(
        port,
        `/api/memory-diary/archive?role=${encodeURIComponent(ROLE_A)}&kind=diary&date=${day.date}`,
        { headers: ADMIN },
      );
      const or = JSON.parse(one.body);
      assert.ok(or.entries.length >= 1, '该天应有条目');
      assert.ok(or.entries.some((e) => e.action === 'write' && e.text.includes('猫')), '应留档写入');

      // 删除后再看：工作文件里没了，档案里多一条 delete。
      const del = await call(port, '/api/memory-diary/delete', {
        method: 'POST',
        headers: ADMIN,
        body: { role: ROLE_A, store: 'diary', at: or.entries[0].at, text: '一起给猫起了名字', scope: 'private:1' },
      });
      assert.equal(del.status, 200, `删除应成功，实际 ${del.status} ${del.body}`);
      const after = JSON.parse((await call(
        port,
        `/api/memory-diary/archive?role=${encodeURIComponent(ROLE_A)}&kind=diary&date=${day.date}`,
        { headers: ADMIN },
      )).body);
      assert.ok(after.entries.some((e) => e.action === 'delete'), '删除动作也要留档');

      // agent token 读不到档案（与控制台鉴权一致）
      const denied = await call(port, '/api/memory-diary/archive?role=' + encodeURIComponent(ROLE_A), {
        headers: { 'x-agent-token': 'whatever' },
      });
      assert.ok([401, 403].includes(denied.status), `agent token 应被拒，实际 ${denied.status}`);
    });
  } finally { await h.close(); }
});

if (failures) {
  console.error(`\n失败 ${failures} 项`);
  process.exitCode = 1;
} else {
  console.log('\n全部通过');
}
