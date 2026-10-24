#!/usr/bin/env node
/**
 * QQ Bot 本地面板
 *   - 拉起 SSH 隧道（-N -L ...），窗口一关进程树一起走，服务端靠 ServerAlive 兜底断开
 *   - 提供 /api/status、/api/logs，全部通过 ssh 到服务器执行后回传
 *   - 托管 dashboard.html（只监听 127.0.0.1）
 *
 * 为什么不用 pipe 接子进程输出：Windows 沙箱/某些安全软件下管道会 EPERM，
 * 这里一律把子进程 stdout/stderr 重定向到临时文件再读，稳。
 */
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CFG = JSON.parse(fs.readFileSync(path.join(HERE, 'panel.config.json'), 'utf8'));
const KEY = path.resolve(HERE, CFG.key);
const KNOWN = path.join(HERE, '.known_hosts');
const RUNDIR = path.join(HERE, '.runtime');
const TMPDIR = path.join(RUNDIR, 'tmp');
for (const d of [RUNDIR, TMPDIR]) fs.mkdirSync(d, { recursive: true });

const SSH = process.env.SSH_EXE || 'ssh';
const TARGET = `${CFG.user}@${CFG.host}`;
const SSH_OPTS = [
  '-i', KEY,
  '-o', 'IdentitiesOnly=yes',
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', `UserKnownHostsFile=${KNOWN}`,
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=10'
];

// ---------------------------------------------------------------- 隧道

let tunnel = null;
let tunnelState = 'starting';   // starting | up | down
let tunnelSince = Date.now();
let tunnelNote = '';
let stopping = false;
let backoff = 2000;

function startTunnel() {
  if (stopping) return;
  const logPath = path.join(RUNDIR, 'tunnel.log');
  const fd = fs.openSync(logPath, 'a');
  fs.writeSync(fd, `\n=== ${new Date().toISOString()} 启动隧道 ===\n`);

  const args = [
    '-N',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'ExitOnForwardFailure=yes',
    ...SSH_OPTS,
    ...CFG.forwards.flatMap(([a, b]) => ['-L', `${a}:127.0.0.1:${b}`]),
    TARGET
  ];

  tunnelState = 'starting';
  tunnelSince = Date.now();
  tunnel = spawn(SSH, args, { stdio: ['ignore', fd, fd], windowsHide: true });
  fs.closeSync(fd);   // 子进程已持有句柄

  tunnel.on('error', (err) => {
    tunnelNote = String(err?.message ?? err);
    tunnelState = 'down';
  });

  tunnel.on('exit', (code) => {
    tunnel = null;
    if (stopping) return;
    tunnelState = 'down';
    tunnelNote = tailOf(logPath, 400) || `ssh 退出（code=${code}）`;
    // 退避重连：2s → 4s → 8s → 最多 30s
    const wait = backoff;
    backoff = Math.min(backoff * 2, 30000);
    setTimeout(() => {
      if (!stopping) startTunnel();
    }, wait);
  });
}

function tailOf(file, n) {
  try {
    const s = fs.readFileSync(file, 'utf8');
    return s.slice(-n).trim();
  } catch {
    return '';
  }
}

/** 轮询本地端口，确认隧道真的通了 */
async function waitTunnelUp(timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  const probe = (port) =>
    new Promise((resolve) => {
      const s = net.connect({ host: '127.0.0.1', port }, () => {
        s.destroy();
        resolve(true);
      });
      s.setTimeout(1200);
      s.on('timeout', () => { s.destroy(); resolve(false); });
      s.on('error', () => resolve(false));
    });
  while (Date.now() < deadline) {
    if (await probe(CFG.forwards[0][0])) return true;
    if (tunnelState === 'down' && tunnel === null) {
      // 正在退避重连，继续等
    }
    await new Promise((r) => setTimeout(r, 600));
  }
  return false;
}

// ---------------------------------------------------------------- 远端执行

function sshCapture(script, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const tag = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const outF = path.join(TMPDIR, `${tag}.out`);
    const errF = path.join(TMPDIR, `${tag}.err`);
    const od = fs.openSync(outF, 'w');
    const ed = fs.openSync(errF, 'w');
    let done = false;
    const finish = (code, out, err) => {
      if (done) return;
      done = true;
      resolve({ code, out, err });
    };
    let child;
    try {
      // 整段脚本作为单个 argv 传过去，远端用 $SHELL -c 执行，不经过本地 shell，引号不会打架
      child = spawn(SSH, [...SSH_OPTS, TARGET, script], {
        stdio: ['ignore', od, ed],
        windowsHide: true
      });
    } catch (err) {
      try { fs.closeSync(od); fs.closeSync(ed); } catch {}
      return finish(-1, '', String(err?.message ?? err));
    }
    try { fs.closeSync(od); fs.closeSync(ed); } catch {}
    const timer = setTimeout(() => {
      try { child.kill(); } catch {}
    }, timeoutMs);
    child.on('error', (err) => {
      clearTimeout(timer);
      cleanup();
      finish(-1, '', String(err?.message ?? err));
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      let out = '';
      let err = '';
      try { out = fs.readFileSync(outF, 'utf8'); } catch {}
      try { err = fs.readFileSync(errF, 'utf8'); } catch {}
      cleanup();
      finish(code, out, err);
    });
    function cleanup() {
      for (const f of [outF, errF]) {
        try { fs.unlinkSync(f); } catch {}
      }
    }
  });
}

// ---------------------------------------------------------------- 远端脚本

const STATUS_SCRIPT = String.raw`
tok() {
  node -e 'const fs=require("fs"),d="/opt/snowluma/data/config";
    try{const f=fs.readdirSync(d).find(x=>/^onebot_\d+\.json$/.test(x))||"onebot.json";
    const j=JSON.parse(fs.readFileSync(d+"/"+f,"utf8"));
    console.log((j.networks&&j.networks.httpServers&&j.networks.httpServers[0].accessToken)||"")}catch(e){console.log("")}' 2>/dev/null
}
T=$(tok)
sec() { echo "@@$1"; }

sec host
echo "hostname=$(hostname)"
echo "os=$(. /etc/os-release 2>/dev/null && echo $PRETTY_NAME)"
echo "kernel=$(uname -r)"
echo "virt=$(systemd-detect-virt 2>/dev/null || echo none)"
sec load
uptime
sec cpu
echo "cores: $(nproc)"
grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//'
sec mem
free -m | sed -n '2p;3p'
sec disk
df -h / | tail -1
sec svc
for s in qq-bridge dsh-web snowluma-configperm.timer; do
  printf '%s\t%s\n' "$s" "$(systemctl is-active $s 2>/dev/null || echo unknown)"
done
sec docker
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo ""
sec bot
if [ -n "$T" ]; then
  curl -s --max-time 5 -X POST -H 'content-type: application/json' -H "Authorization: Bearer $T" -d '{}' http://127.0.0.1:3000/get_login_info
  echo
else
  echo '{"status":"failed","wording":"未找到 OneBot token"}'
fi
sec groups
if [ -n "$T" ]; then
  curl -s --max-time 5 -X POST -H 'content-type: application/json' -H "Authorization: Bearer $T" -d '{}' http://127.0.0.1:3000/get_group_list
  echo
else
  echo '{"status":"failed","data":[]}'
fi
sec ver
echo "node $(node -v 2>/dev/null)"
echo "docker $(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
sec end
`;

const LOG_SCRIPTS = {
  bridge: (n) => `journalctl -u qq-bridge -n ${n} --no-pager -o cat 2>/dev/null`,
  snowluma: (n) => `docker logs --tail ${n} snowluma 2>&1`,
  'sl-app': (n) => `tail -n ${n} /opt/snowluma/data/logs/snowluma-*.log 2>/dev/null | tail -n ${n}`,
  dsh: (n) => `journalctl -u dsh-web -n ${n} --no-pager -o cat 2>/dev/null`
};

// ---------------------------------------------------------------- 解析

const SECTION_NAMES = ['host', 'load', 'cpu', 'mem', 'disk', 'svc', 'docker', 'bot', 'groups', 'ver', 'end'];
const SECTION_RE = new RegExp(`(${SECTION_NAMES.map((n) => '@@' + n).join('|')})`, 'g');

function parseSections(raw) {
  // curl 之类命令结尾不带换行，会把 "@@下一节" 粘在同一行末尾，先统一拆开
  const text = String(raw).replace(SECTION_RE, '\n$1\n');
  const out = {};
  let cur = null;
  for (const line of text.split(/\r?\n/)) {
    const m = /^@@(.+)$/.exec(line);
    if (m) {
      cur = m[1].trim();
      out[cur] = out[cur] ?? [];
      continue;
    }
    if (cur) out[cur].push(line);
  }
  for (const k of Object.keys(out)) out[k] = out[k].join('\n').trim();
  return out;
}

function prettyUptime(line) {
  const m = /up\s+(.+?),\s+\d+\s+users?,\s+load average:\s*(.+)$/.exec(line);
  return m ? { up: m[1], load: m[2] } : { up: '', load: '' };
}

function buildStatus(raw) {
  const s = parseSections(raw);
  const load = prettyUptime(s.load ?? '');
  const mem = (s.mem ?? '').split('\n').map((l) => l.trim().split(/\s+/));
  const memTotal = Number(mem[0]?.[1] ?? 0);
  const memUsed = Number(mem[0]?.[2] ?? 0);
  const swapTotal = Number(mem[1]?.[1] ?? 0);
  const swapUsed = Number(mem[1]?.[2] ?? 0);
  const disk = (s.disk ?? '').trim().split(/\s+/);

  const svcLines = (s.svc ?? '').split('\n').filter(Boolean);
  const services = svcLines.map((l) => {
    const [name, state] = l.split('\t');
    return { name, state: (state ?? '').trim() };
  });

  const docker = (s.docker ?? '')
    .split('\n')
    .filter(Boolean)
    .map((l) => {
      const [name, status, image] = l.split('\t');
      return { name, status, image };
    });

  let bot = null;
  try { bot = JSON.parse(s.bot ?? 'null'); } catch {}
  let groups = [];
  try {
    const g = JSON.parse(s.groups ?? 'null');
    groups = Array.isArray(g?.data) ? g.data : [];
  } catch {}

  const ver = (s.ver ?? '').split('\n').filter(Boolean);

  const hostFields = {};
  for (const line of (s.host ?? '').split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) hostFields[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }

  return {
    ok: true,
    at: new Date().toISOString(),
    host: {
      name: hostFields.hostname ?? '',
      os: hostFields.os ?? '',
      kernel: hostFields.kernel ?? '',
      virt: hostFields.virt ?? ''
    },
    uptime: load.up,
    load: load.load,
    cpu: { cores: (/cores:\s*(\d+)/.exec(s.cpu ?? '') ?? [])[1] ?? '?', model: (s.cpu ?? '').split('\n')[1] ?? '' },
    mem: { total: memTotal, used: memUsed, swapTotal, swapUsed },
    disk: { total: disk[1] ?? '', used: disk[2] ?? '', free: disk[3] ?? '', pct: disk[4] ?? '' },
    services,
    docker,
    bot: bot?.status === 'ok' ? bot.data : null,
    botError: bot && bot.status !== 'ok' ? (bot.wording ?? '未登录') : null,
    groups: groups.map((g) => ({ id: g.group_id, name: g.group_name, members: g.member_count, max: g.max_member_count })),
    versions: ver
  };
}

// ---------------------------------------------------------------- HTTP

const cache = new Map();
async function cached(key, ttl, fn) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < ttl) return hit.v;
  const v = await fn();
  cache.set(key, { t: Date.now(), v });
  return v;
}

function send(res, code, body, type = 'application/json; charset=utf-8') {
  res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store' });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${CFG.panelPort}`);
  try {
    if (url.pathname === '/' || url.pathname === '/index.html') {
      const html = fs.readFileSync(path.join(HERE, 'dashboard.html'));
      return send(res, 200, html, 'text/html; charset=utf-8');
    }

    if (url.pathname === '/api/ping') {
      return send(res, 200, JSON.stringify({ ok: true, tunnel: tunnelState, uptimeMs: Date.now() - tunnelSince }));
    }

    if (url.pathname === '/api/status') {
      const data = await cached('status', 4000, async () => {
        const r = await sshCapture(STATUS_SCRIPT, 22000);
        if (r.code !== 0 && !r.out.includes('@@host')) {
          return { ok: false, error: (r.err || '').trim() || `ssh 退出码 ${r.code}`, tunnel: tunnelState, at: new Date().toISOString() };
        }
        try {
          return { ...buildStatus(r.out), tunnel: tunnelState };
        } catch (err) {
          return { ok: false, error: `解析失败：${err?.message ?? err}`, tunnel: tunnelState };
        }
      });
      return send(res, 200, JSON.stringify(data));
    }

    if (url.pathname === '/api/logs') {
      const src = url.searchParams.get('src') ?? 'bridge';
      const n = Math.min(Math.max(Number(url.searchParams.get('n') ?? 200), 20), 800);
      const fn = LOG_SCRIPTS[src];
      if (!fn) return send(res, 400, JSON.stringify({ ok: false, error: `未知日志源 ${src}` }));
      const data = await cached(`log:${src}:${n}`, 2000, async () => {
        const r = await sshCapture(fn(n), 15000);
        return { ok: r.code === 0 || !!r.out, src, text: r.out || r.err || '', at: new Date().toISOString() };
      });
      return send(res, 200, JSON.stringify(data));
    }

    if (url.pathname === '/api/config') {
      return send(res, 200, JSON.stringify({
        consoleToken: CFG.consoleToken,
        vncPassword: CFG.vncPassword,
        botQQ: CFG.botQQ,
        host: CFG.host,
        ports: Object.fromEntries(CFG.forwards)
      }));
    }

    send(res, 404, JSON.stringify({ ok: false, error: 'not found' }));
  } catch (err) {
    send(res, 500, JSON.stringify({ ok: false, error: String(err?.message ?? err) }));
  }
});

// ---------------------------------------------------------------- 生命周期

function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`\n[panel] 收到 ${signal}，正在断开隧道…`);
  if (tunnel) {
    try { tunnel.kill('SIGTERM'); } catch {}
  }
  setTimeout(() => process.exit(0), 400);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGHUP', () => shutdown('SIGHUP'));
process.on('SIGBREAK', () => shutdown('SIGBREAK'));
process.on('exit', () => {
  if (tunnel) { try { tunnel.kill('SIGKILL'); } catch {} }
});

const PORT = CFG.panelPort;
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[panel] 端口 ${PORT} 已被占用，请改 panel.config.json 里的 panelPort`);
  } else {
    console.error('[panel] HTTP 服务出错：', err);
  }
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', async () => {
  console.log(`[panel] 管理面板：http://127.0.0.1:${PORT}`);
  console.log(`[panel] 正在建立 SSH 隧道 → ${TARGET}`);
  startTunnel();
  const up = await waitTunnelUp();
  if (up) {
    tunnelState = 'up';
    backoff = 2000;
    console.log('[panel] 隧道已就绪（3100 / 5099 / 6081 / 3380）');
  } else {
    console.log('[panel] 隧道还没通，面板仍会可用；后台会继续重连');
    console.log(`[panel] 细节看 ${path.join(RUNDIR, 'tunnel.log')}`);
  }
  // 隧道就绪（或等待超时）后再开浏览器，避免首屏全是"连接中"
  if (!process.argv.includes('--no-open')) {
    try {
      const url = `http://127.0.0.1:${PORT}/`;
      spawn(process.env.ComSpec || 'cmd', ['/c', 'start', '', url], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true
      }).unref();
    } catch {}
  }
  console.log('[panel] 关闭这个窗口（或 Ctrl+C）即可断开隧道。');
});
