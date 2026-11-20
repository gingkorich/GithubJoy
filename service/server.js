'use strict';
/*
 * GitHub Joy - local service (M1 auth probe)
 * Node stdlib only. Binds 127.0.0.1. Node does not call the GitHub API:
 * auth state comes from `gh`; the Lists scope probe runs in PowerShell.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, execFile, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data');
const JOBS = path.join(DATA, 'jobs');
const PUB = path.join(__dirname, 'public');
const TOKEN_FILE = path.join(DATA, 'service-token');
const SERVICE_FILE = path.join(DATA, 'service.json');
const LLM_FILE = path.join(ROOT, 'llm.json');
const VERSION = '0.1.0-m1';

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : null;
};
const flag = (name) => args.includes(name);

function ensureDirs() {
  for (const d of [DATA, JOBS]) fs.mkdirSync(d, { recursive: true });
}

function readOrCreateToken() {
  ensureDirs();
  try {
    const t = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
    if (t) return t;
  } catch (_) { /* create below */ }
  const t = crypto.randomBytes(24).toString('hex');
  fs.writeFileSync(TOKEN_FILE, t, { mode: 0o600 });
  return t;
}

function writeJson(file, obj) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

function readJsonFile(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  } catch (_) {
    return fallback;
  }
}

function dashboard() {
  const st = readJsonFile(path.join(DATA, 'state.json'), {}) || {};
  const q = readJsonFile(path.join(DATA, 'queue.json'), { items: [] }) || { items: [] };
  const counts = { pending: 0, summarizing: 0, done: 0, failed: 0, moved: 0, gone: 0 };
  for (const it of (q.items || [])) {
    const s = String((it && it.status) || '');
    if (Object.prototype.hasOwnProperty.call(counts, s)) counts[s]++;
  }
  const ls = st.lastScan || null;
  return {
    scan: ls ? {
      lastAt: ls.at, added: ls.added, scanned: ls.scanned, durationMs: ls.durationMs,
      totalUnreadAfter: ls.totalUnreadAfter, runId: ls.runId,
    } : null,
    read: st.lastRead || null,
    queue: counts,
  };
}

/* ------------------------------------------------------------------ */
/* lists status (GitHub is the source of truth)                        */
/* ------------------------------------------------------------------ */

const listsCache = { at: 0, value: null, pending: null };

async function listsStatus() {
  const now = Date.now();
  if (listsCache.value && now - listsCache.at < 30000) return listsCache.value;
  if (listsCache.pending) return listsCache.pending;

  listsCache.pending = (async () => {
    const r = await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', path.join(ROOT, 'scripts', 'status.ps1')], 45000);
    let value = null;
    try {
      value = JSON.parse((r.stdout || '').trim());
    } catch (_) {
      value = { ok: false, error: 'status_probe_failed: ' + ((r.stderr || r.error || '').trim().slice(0, 200)) };
    }
    listsCache.value = value;
    listsCache.at = Date.now();
    listsCache.pending = null;
    return value;
  })();

  return listsCache.pending;
}

/* ------------------------------------------------------------------ */
/* llm config                                                          */
/* ------------------------------------------------------------------ */

function readLlm() {
  const o = readJsonFile(LLM_FILE, null) || {};
  return {
    baseUrl: String(o.base_url || ''),
    model: String(o.model || ''),
    apiKey: String(o.api_key || ''),
    timeoutSec: Number(o.timeout_sec || 60),
    maxRetries: Number(o.max_retries || 3),
  };
}

function maskKey(k) {
  if (!k) return null;
  if (k.length <= 8) return '****';
  return k.slice(0, 4) + '****' + k.slice(-4);
}

function llmView() {
  const c = readLlm();
  return {
    configured: !!(c.baseUrl && c.model && c.apiKey),
    baseUrl: c.baseUrl,
    model: c.model,
    timeoutSec: c.timeoutSec,
    maxRetries: c.maxRetries,
    keyMask: maskKey(c.apiKey),
  };
}

function applyLlmAcl() {
  try {
    const user = process.env.USERNAME || '';
    if (!user) return 'no_user';
    const r = spawnSync('icacls', [LLM_FILE, '/inheritance:r', '/grant:r', user + ':(F)'], { encoding: 'utf8' });
    return r.status === 0 ? null : 'acl_failed';
  } catch (_) {
    return 'acl_failed';
  }
}

function saveLlm(body) {
  const cur = readLlm();
  const baseUrl = String(body.baseUrl !== undefined ? body.baseUrl : cur.baseUrl).trim().replace(/\/+$/, '');
  const model = String(body.model !== undefined ? body.model : cur.model).trim();
  let apiKey = cur.apiKey;
  if (Object.prototype.hasOwnProperty.call(body, 'apiKey')) {
    const k = String(body.apiKey || '').trim();
    if (k) apiKey = k;
  }
  let timeoutSec = Number(body.timeoutSec !== undefined ? body.timeoutSec : cur.timeoutSec);
  if (!Number.isFinite(timeoutSec)) timeoutSec = 60;
  timeoutSec = Math.max(10, Math.min(300, Math.round(timeoutSec)));

  if (!/^https?:\/\//i.test(baseUrl)) {
    const e = new Error('base_url must start with http:// or https://');
    e.status = 400; throw e;
  }
  if (!model) {
    const e = new Error('model is required');
    e.status = 400; throw e;
  }
  if (!apiKey) {
    const e = new Error('api_key is required');
    e.status = 400; throw e;
  }

  // Windows: replacing a file requires delete permission, so fix ACL before the atomic rename.
  if (fs.existsSync(LLM_FILE)) applyLlmAcl();
  // temperature is optional: only send it when explicitly configured,
  // because router models (e.g. "auto") reject it with HTTP 400.
  const out = {
    base_url: baseUrl, api_key: apiKey, model,
    timeout_sec: timeoutSec, max_retries: cur.maxRetries || 3,
  };
  if (body.temperature !== undefined && body.temperature !== null && body.temperature !== '') {
    const t = Number(body.temperature);
    if (Number.isFinite(t)) out.temperature = t;
  }
  writeJson(LLM_FILE, out);

  const warning = applyLlmAcl();
  return { warning };
}

async function testLlm() {
  const c = readLlm();
  if (!c.baseUrl || !c.model || !c.apiKey) return { ok: false, error: 'not_configured' };
  const url = /\/chat\/completions$/i.test(c.baseUrl) ? c.baseUrl : c.baseUrl + '/chat/completions';
  const started = Date.now();
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + c.apiKey },
      body: JSON.stringify({
        model: c.model,
        messages: [{ role: 'user', content: 'ping' }],
        max_tokens: 1,
        // temperature intentionally omitted: some models (e.g. router models) reject it
      }),
      signal: AbortSignal.timeout(Math.min(c.timeoutSec, 30) * 1000),
    });
    const text = await res.text();
    const latencyMs = Date.now() - started;
    if (res.ok) return { ok: true, latencyMs, status: res.status, model: c.model };
    return { ok: false, latencyMs, status: res.status, error: text.slice(0, 300) };
  } catch (e) {
    return { ok: false, latencyMs: Date.now() - started, error: String((e && e.message) || e) };
  }
}

function stopService() {
  try {
    const info = JSON.parse(fs.readFileSync(SERVICE_FILE, 'utf8'));
    if (info && info.pid) {
      const r = spawnSync('taskkill', ['/PID', String(info.pid), '/T', '/F'], { encoding: 'utf8' });
      const msg = ((r.stdout || '') + (r.stderr || '')).trim();
      console.log('[joy] stop requested for pid ' + info.pid + (msg ? ': ' + msg : ''));
      return r.status === 0 ? 0 : 1;
    }
  } catch (_) { /* not running */ }
  console.log('[joy] service is not running');
  try { fs.unlinkSync(SERVICE_FILE); } catch (_) {}
  return 0;
}

if (flag('--stop')) process.exit(stopService());

const TOKEN = readOrCreateToken();
const STATES = ['8787', '8788', '8789', '8790'];
const PORT = Number(opt('--port') || 8787);
let ACTUAL_PORT = PORT;
const STARTED_AT = new Date().toISOString();

/* ------------------------------------------------------------------ */
/* config + proxy                                                      */
/* ------------------------------------------------------------------ */

function loadConfig() {
  for (const name of ['config.json', 'config.sample.json']) {
    try {
      const raw = fs.readFileSync(path.join(ROOT, name), 'utf8').replace(/^\uFEFF/, '');
      return JSON.parse(raw);
    } catch (_) { /* try next */ }
  }
  return {};
}

const CONFIG = loadConfig();
const NET = Object.assign({ proxy: '', autoDetect: true, noProxy: 'localhost,127.0.0.1' },
  (CONFIG && CONFIG.network) || {});

const proxyCache = { at: 0, proxy: null, source: 'none' };

function normalizeProxy(v) {
  if (!v) return null;
  let s = String(v).trim();
  if (!s) return null;
  if (/^(https?|socks4|socks5|socks5h):\/\//i.test(s)) return s;
  if (s.includes('=')) {
    const pairs = {};
    s.split(';').filter(Boolean).forEach((kv) => {
      const i = kv.indexOf('=');
      if (i > 0) pairs[kv.slice(0, i).trim().toLowerCase()] = kv.slice(i + 1).trim();
    });
    return normalizeProxy(pairs.https || pairs.http || '');
  }
  return 'http://' + s;
}

function regValue(name) {
  const r = spawnSync('reg', ['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings',
    '/v', name], { encoding: 'utf8' });
  const out = ((r.stdout || '') + (r.stderr || '')).trim();
  if (r.status !== 0) return null;
  const m = out.match(new RegExp(name + '\\s+REG_\\w+\\s+(.+)$', 'm'));
  return m ? m[1].trim() : null;
}

function detectProxy() {
  if (Date.now() - proxyCache.at < 60000) return proxyCache;
  const configured = normalizeProxy(NET.proxy);
  if (configured) {
    proxyCache.proxy = configured; proxyCache.source = 'config'; proxyCache.at = Date.now();
    return proxyCache;
  }
  if (NET.autoDetect) {
    try {
      const enabled = regValue('ProxyEnable');
      const server = regValue('ProxyServer');
      if (String(enabled) === '0x1' && server) {
        const p = normalizeProxy(server);
        if (p) {
          proxyCache.proxy = p; proxyCache.source = 'system'; proxyCache.at = Date.now();
          return proxyCache;
        }
      }
    } catch (_) { /* ignore */ }
  }
  proxyCache.proxy = null; proxyCache.source = 'none'; proxyCache.at = Date.now();
  return proxyCache;
}

function childEnv(extra) {
  const env = Object.assign({}, process.env, extra || {});
  const p = detectProxy().proxy;
  if (p) {
    env.HTTPS_PROXY = p;
    env.HTTP_PROXY = p;
    env.ALL_PROXY = p;
    env.NO_PROXY = NET.noProxy || 'localhost,127.0.0.1';
    env.no_proxy = env.NO_PROXY;
  }
  return env;
}

/* ------------------------------------------------------------------ */
/* gh helpers                                                          */
/* ------------------------------------------------------------------ */

const statusCache = { at: 0, value: null };

function run(cmd, argv, timeoutMs, extraEnv) {
  return new Promise((resolve) => {
    execFile(cmd, argv, {
      timeout: timeoutMs || 15000, windowsHide: true, maxBuffer: 4 * 1024 * 1024,
      env: childEnv(extraEnv),
    }, (err, stdout, stderr) => {
      resolve({
        code: err && typeof err.code === 'number' ? err.code : (err ? 1 : 0),
        stdout: stdout || '',
        stderr: stderr || '',
        error: err ? String(err.message || err) : null,
      });
    });
  });
}

async function ghStatus() {
  const now = Date.now();
  if (statusCache.value && now - statusCache.at < 5000) return statusCache.value;

  const found = await run('where', ['gh'], 5000);
  const installed = found.code === 0 && found.stdout.trim().length > 0;
  let version = null;
  if (installed) {
    const v = await run('gh', ['--version'], 8000);
    const m = (v.stdout || '').match(/gh version\s+([^\s]+)/i);
    version = m ? m[1] : null;
  }

  const out = {
    installed, version, auth: false, login: null, scopes: null, tokenSource: 'none', error: null,
  };

  if (!installed) {
    out.error = 'gh_not_installed';
  } else {
    const s = await run('gh', ['auth', 'status', '--hostname', 'github.com', '--json', 'hosts'], 12000);
    if (s.code === 0) {
      try {
        const obj = JSON.parse(s.stdout);
        const hosts = obj.hosts && obj.hosts['github.com'];
        const entry = Array.isArray(hosts) ? (hosts.find((h) => h.active) || hosts[0]) : null;
        if (entry) {
          out.auth = entry.state === 'success';
          out.login = entry.login || null;
          out.scopes = entry.scopes || null;
          out.tokenSource = entry.tokenSource || 'gh';
        }
      } catch (e) {
        out.error = 'gh_status_parse_failed: ' + e.message;
      }
    } else {
      // exit 1 + "not logged in" is a normal state, not an error
      const msg = (s.stderr || s.stdout || '').trim();
      out.error = /not logged|not authenticated/i.test(msg) ? null : (msg || 'gh_status_failed');
    }
  }

  statusCache.at = now;
  statusCache.value = out;
  return out;
}

async function ghListsProbe() {
  const argv = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'scripts', 'probe-lists.ps1')];
  const p = detectProxy().proxy;
  if (p) argv.push('-Proxy', p);
  const r = await run('powershell.exe', argv, 30000);
  if (r.code !== 0 && !r.stdout.trim()) {
    return { ok: false, error: (r.stderr || r.error || 'probe_failed').trim() };
  }
  try {
    return JSON.parse(r.stdout.trim());
  } catch (e) {
    return { ok: false, error: 'probe_output_not_json: ' + r.stdout.slice(0, 300) };
  }
}

/* ------------------------------------------------------------------ */
/* jobs                                                                */
/* ------------------------------------------------------------------ */

const CODE_RE = /[A-Z0-9]{4}-[A-Z0-9]{4}/;
let job = null; // single job at a time
let pipeline = null; // {active, stage, jobId} for read -> render -> publish -> migrate

function pipelineView() {
  if (!pipeline) return null;
  return { active: !!pipeline.active, stage: pipeline.stage, jobId: pipeline.jobId };
}

async function advancePipeline(finished, res) {
  if (!pipeline || !pipeline.active || pipeline.jobId !== finished.id) return;

  if (finished.kind === 'read') {
    const ids = (res && res.items ? res.items : [])
      .filter((x) => x && x.status === 'done' && x.id)
      .map((x) => String(x.id));
    if (!ids.length) {
      pipeline.active = false;
      console.log('[joy] pipeline: read produced no summaries, stop');
      return;
    }
    const idsFile = path.join(JOBS, 'ids-' + stamp(new Date()) + '.txt');
    fs.writeFileSync(idsFile, ids.join('\n'), 'utf8');
    const r = await startScriptJob('render', 'render.ps1', ['-IdsFile', idsFile], 10 * 60 * 1000, { pipeline: true });
    if (r.busy) { pipeline.active = false; return; }
    pipeline.stage = 'render';
    pipeline.jobId = r.jobId;
    return;
  }

  if (finished.state !== 'succeeded') {
    pipeline.active = false;
    console.log('[joy] pipeline: ' + finished.kind + ' failed, stop');
    return;
  }

  if (finished.kind === 'render') {
    const r = await startScriptJob('publish', 'publish.ps1', [], 10 * 60 * 1000, { pipeline: true });
    if (r.busy) { pipeline.active = false; return; }
    pipeline.stage = 'publish';
    pipeline.jobId = r.jobId;
    return;
  }

  if (finished.kind === 'publish') {
    const r = await startScriptJob('migrate', 'migrate.ps1', [], 10 * 60 * 1000, { pipeline: true });
    if (r.busy) { pipeline.active = false; return; }
    pipeline.stage = 'migrate';
    pipeline.jobId = r.jobId;
    return;
  }

  if (finished.kind === 'migrate') {
    pipeline.active = false;
    console.log('[joy] pipeline: complete');
  }
}

function jobView(j, tail) {
  if (!j) return null;
  return {
    id: j.id, kind: j.kind, state: j.state,
    startedAt: j.startedAt, endedAt: j.endedAt,
    exitCode: j.exitCode, error: j.error, code: j.code,
    hint: j.hint || null, hintText: j.hintText || null,
    dryRun: !!j.dryRun,
    progress: j.progress || null,
    result: j.result || null,
    lines: tail ? j.lines.slice(-tail) : j.lines,
  };
}

function persistJob() {
  if (!job) return;
  writeJson(path.join(JOBS, job.id + '.json'), jobView(job));
}

function pushLine(chunk) {
  if (!job) return;
  String(chunk).split(/\r?\n/).forEach((line) => {
    if (!line) return;
    const s = line.trim();
    if (s.startsWith('{') && s.endsWith('}')) {
      try {
        const evt = JSON.parse(s);
        if (evt && evt.evt === 'progress') {
          job.progress = { phase: evt.phase, done: evt.done, total: evt.total };
          persistJob();
          return;
        }
        if (evt && evt.evt === 'result') {
          job.result = evt.result;
          persistJob();
          return;
        }
      } catch (_) { /* plain log line */ }
    }
    job.lines.push(line);
    if (job.lines.length > 500) job.lines.shift();
    const m = line.match(CODE_RE);
    if (m) job.code = m[0];
  });
  persistJob();
}

async function startLogin() {
  if (job && job.state === 'running') return { busy: true, jobId: job.id };

  const id = 'login-' + new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 14);
  job = {
    id, kind: 'gh-login', state: 'running',
    startedAt: new Date().toISOString(), endedAt: null,
    exitCode: null, error: null, code: null, lines: [],
  };
  persistJob();

  const child = spawn('gh', ['auth', 'login', '--hostname', 'github.com',
    '--git-protocol', 'https', '--web', '--scopes', 'user'], {
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, env: childEnv(),
  });
  job.pid = child.pid;

  child.stdout.on('data', pushLine);
  child.stderr.on('data', pushLine);

  // Some gh versions wait for Enter; nudge once if no device code appeared.
  const nudge = setTimeout(() => {
    if (job && job.state === 'running' && !job.code) {
      try { child.stdin.write('\r\n'); } catch (_) {}
    }
  }, 4000);

  const timer = setTimeout(() => {
    if (job && job.state === 'running') {
      job.error = 'timeout_300s';
      try { execFile('taskkill', ['/PID', String(child.pid), '/T', '/F'], () => {}); } catch (_) {}
    }
  }, 300000);

  child.on('close', (code) => {
    clearTimeout(timer); clearTimeout(nudge);
    if (!job || job.state !== 'running') return;
    job.endedAt = new Date().toISOString();
    job.exitCode = code;
    if (!job.error && code !== 0) job.error = 'gh_exit_' + code;
    job.state = code === 0 ? 'succeeded' : 'failed';
    if (job.state === 'failed') {
      const text = job.lines.join('\n');
      if (/failed to authenticate via web browser|connection attempt failed|wsarecv|i\/o timeout|proxyconnect/i.test(text)) {
        job.hint = 'network';
        job.hintText = 'GitHub 直连失败：请在 config.json 的 network.proxy 填写代理（如 http://127.0.0.1:10808），或确认系统代理已开启（见 RUNBOOK 6.11）。';
      }
    }
    statusCache.value = null; listsCache.value = null; listsCache.at = 0;
    persistJob();
  });

  return { jobId: id };
}

function cancelJob(id) {
  if (!job || job.id !== id || job.state !== 'running') return false;
  job.error = 'cancelled_by_user';
  try { execFile('taskkill', ['/PID', String(job.pid), '/T', '/F'], () => {}); } catch (_) {}
  job.state = 'cancelled';
  job.endedAt = new Date().toISOString();
  persistJob();
  return true;
}

const pad2 = (n) => String(n).padStart(2, '0');
function stamp(d) {
  return '' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
    '-' + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds());
}
function dateOnly(d) {
  return '' + d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

async function startScan(dryRun) {
  if (job && job.state === 'running') return { busy: true, jobId: job.id };

  const now = new Date();
  const id = 'scan-' + stamp(now);
  job = {
    id, kind: 'scan', state: 'running',
    startedAt: now.toISOString(), endedAt: null,
    exitCode: null, error: null, progress: { phase: 'start', done: 0, total: 5 },
    result: null, lines: [], dryRun: !!dryRun,
  };
  persistJob();

  const resultFile = path.join(JOBS, id + '.result.json');
  const argv = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'scripts', 'scan.ps1'),
    '-JsonOut', resultFile, '-LogFile', path.join(ROOT, 'logs', 'scan-' + dateOnly(now) + '.log')];
  if (dryRun) argv.push('-DryRun');

  const child = spawn('powershell.exe', argv, {
    stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, env: childEnv(),
  });
  job.pid = child.pid;
  child.stdout.on('data', pushLine);
  child.stderr.on('data', pushLine);

  const timer = setTimeout(() => {
    if (job && job.state === 'running') {
      job.error = 'timeout_1800s';
      try { execFile('taskkill', ['/PID', String(child.pid), '/T', '/F'], () => {}); } catch (_) {}
    }
  }, 30 * 60 * 1000);

  child.on('close', (code) => {
    clearTimeout(timer);
    if (!job || job.state !== 'running') return;
    job.endedAt = new Date().toISOString();
    job.exitCode = code;
    const res = readJsonFile(resultFile, null);
    if (res) {
      job.result = res;
      if (res.error) job.error = String(res.error);
      if (res.hint) job.hintText = String(res.hint);
    }
    if (code !== 0 && !job.error) job.error = 'exit_' + code;
    job.state = (code === 0 && !(res && res.ok === false)) ? 'succeeded' : 'failed';
    statusCache.value = null; listsCache.value = null; listsCache.at = 0;
    persistJob();
  });

  return { jobId: id };
}

async function startRead(opts) {
  const rawN = (opts.n === undefined || opts.n === null || opts.n === '') ? 5 : opts.n;
  const n = Number(rawN);
  if (!Number.isInteger(n) || n < 1 || n > 20) return { error: 'bad_n' };
  if (job && job.state === 'running') return { busy: true, jobId: job.id };

  const now = new Date();
  const id = 'read-' + stamp(now);
  job = {
    id, kind: 'read', state: 'running',
    startedAt: now.toISOString(), endedAt: null,
    exitCode: null, error: null, progress: { phase: 'start', done: 0, total: n },
    result: null, lines: [],
    options: { n, lite: !!opts.lite, noWrite: !!opts.noWrite, dryRun: !!opts.dryRun },
  };
  persistJob();

  const resultFile = path.join(JOBS, id + '.result.json');
  const argv = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'scripts', 'read.ps1'),
    '-N', String(n), '-JsonOut', resultFile,
    '-LogFile', path.join(ROOT, 'logs', 'read-' + stamp(now) + '.log')];
  if (opts.dryRun) argv.push('-DryRun');
  if (opts.noWrite) argv.push('-NoWrite');
  if (opts.lite) argv.push('-Lite');

  const child = spawn('powershell.exe', argv, {
    stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, env: childEnv(),
  });
  job.pid = child.pid;
  child.stdout.on('data', pushLine);
  child.stderr.on('data', pushLine);

  const timer = setTimeout(() => {
    if (job && job.state === 'running') {
      job.error = 'timeout_3600s';
      try { execFile('taskkill', ['/PID', String(child.pid), '/T', '/F'], () => {}); } catch (_) {}
    }
  }, 60 * 60 * 1000);

  child.on('close', (code) => {
    clearTimeout(timer);
    if (!job || job.state !== 'running') return;
    job.endedAt = new Date().toISOString();
    job.exitCode = code;
    const res = readJsonFile(resultFile, null);
    if (res) {
      job.result = res;
      if (res.error) job.error = String(res.error);
      if (res.hint) job.hintText = String(res.hint);
    }
    if (code !== 0 && !job.error) job.error = 'exit_' + code;
    job.state = (code === 0 && !(res && res.ok === false)) ? 'succeeded' : 'failed';
    statusCache.value = null; listsCache.value = null; listsCache.at = 0;
    persistJob();
    advancePipeline(job, res).catch((e) => {
      console.log('[joy] pipeline error: ' + (e && e.message ? e.message : e));
      if (pipeline) pipeline.active = false;
    });
  });

  return { jobId: id };
}

async function startScriptJob(kind, scriptName, scriptArgs, timeoutMs, options) {
  if (job && job.state === 'running') return { busy: true, jobId: job.id };

  const now = new Date();
  const id = kind + '-' + stamp(now);
  job = {
    id, kind, state: 'running',
    startedAt: now.toISOString(), endedAt: null,
    exitCode: null, error: null, progress: { phase: 'start', done: 0, total: 0 },
    result: null, lines: [], options: options || {},
  };
  persistJob();

  const resultFile = path.join(JOBS, id + '.result.json');
  const argv = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'scripts', scriptName),
    '-JsonOut', resultFile, '-LogFile', path.join(ROOT, 'logs', kind + '-' + stamp(now) + '.log')]
    .concat(scriptArgs || []);

  const child = spawn('powershell.exe', argv, {
    stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, env: childEnv(),
  });
  job.pid = child.pid;
  child.stdout.on('data', pushLine);
  child.stderr.on('data', pushLine);

  const timer = setTimeout(() => {
    if (job && job.state === 'running') {
      job.error = 'timeout_' + Math.round(timeoutMs / 1000) + 's';
      try { execFile('taskkill', ['/PID', String(child.pid), '/T', '/F'], () => {}); } catch (_) {}
    }
  }, timeoutMs);

  child.on('close', (code) => {
    clearTimeout(timer);
    if (!job || job.state !== 'running') return;
    job.endedAt = new Date().toISOString();
    job.exitCode = code;
    const res = readJsonFile(resultFile, null);
    if (res) {
      job.result = res;
      if (res.error) job.error = String(res.error);
      if (res.hint) job.hintText = String(res.hint);
    }
    if (code !== 0 && !job.error) job.error = 'exit_' + code;
    job.state = (code === 0 && !(res && res.ok === false)) ? 'succeeded' : 'failed';
    statusCache.value = null; listsCache.value = null; listsCache.at = 0;
    persistJob();
    advancePipeline(job, res).catch((e) => {
      console.log('[joy] pipeline error: ' + (e && e.message ? e.message : e));
      if (pipeline) pipeline.active = false;
    });
  });

  return { jobId: id };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 65536) { reject(new Error('body_too_large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

/* ------------------------------------------------------------------ */
/* http helpers                                                        */
/* ------------------------------------------------------------------ */

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; form-action 'none'; base-uri 'none'";

function send(res, code, body, headers) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(String(body), 'utf8');
  res.writeHead(code, Object.assign({
    'Content-Type': 'text/plain; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
  }, headers || {}));
  res.end(buf);
}

function sendJson(res, code, obj) {
  send(res, code, JSON.stringify(obj), {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
}

function hostOk(req) {
  const h = String(req.headers.host || '').toLowerCase();
  return h === '127.0.0.1:' + ACTUAL_PORT || h === 'localhost:' + ACTUAL_PORT;
}

function tokenOk(req) {
  const got = Buffer.from(String(req.headers['x-joy-token'] || ''), 'utf8');
  const want = Buffer.from(TOKEN, 'utf8');
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

function originOk(req) {
  const o = req.headers.origin;
  if (!o) return true;
  return o === 'http://127.0.0.1:' + ACTUAL_PORT || o === 'http://localhost:' + ACTUAL_PORT;
}

function serveStatic(res, name) {
  const file = path.join(PUB, name);
  const ext = path.extname(file).toLowerCase();
  if (!MIME[ext]) return send(res, 404, 'not found');
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, 'not found');
    if (ext === '.html') {
      const html = buf.toString('utf8').replace(/__JOY_TOKEN__/g, TOKEN);
      return send(res, 200, html, {
        'Content-Type': MIME[ext],
        'Content-Security-Policy': CSP,
        'Cache-Control': 'no-store',
      });
    }
    send(res, 200, buf, { 'Content-Type': MIME[ext], 'Cache-Control': 'no-store' });
  });
}

/* ------------------------------------------------------------------ */
/* routes                                                              */
/* ------------------------------------------------------------------ */

const server = http.createServer(async (req, res) => {
  try {
    if (!hostOk(req)) return sendJson(res, 403, { error: 'bad_host' });
    if (!originOk(req)) return sendJson(res, 403, { error: 'bad_origin' });

    const url = new URL(req.url, 'http://' + (req.headers.host || '127.0.0.1'));
    const p = url.pathname;

    if (req.method === 'GET' && (p === '/' || p === '/index.html')) return serveStatic(res, 'index.html');
    if (req.method === 'GET' && (p === '/app.js' || p === '/style.css')) return serveStatic(res, p.slice(1));

    if (p === '/api/status' && req.method === 'GET') {
      const lists = await listsStatus();
      return sendJson(res, 200, {
        service: {
          version: VERSION, port: ACTUAL_PORT, startedAt: STARTED_AT,
          workDir: ROOT, node: process.version,
        },
        gh: await ghStatus(),
        network: (() => {
          const d = detectProxy();
          return { proxy: d.proxy, source: d.source, autoDetect: !!NET.autoDetect };
        })(),
        ...dashboard(),
        unread: (lists && lists.ok && lists.unread)
          ? { count: lists.unread.count, refreshedAt: lists.at, source: 'github' }
          : null,
        readCount: (lists && lists.read) ? lists.read.count : null,
        lists: lists || null,
        llm: llmView(),
        pipeline: pipelineView(),
        job: jobView(job, 50),
      });
    }

    // Read-only job polling is allowed without the token (same trust level as /api/status).
    const mJob = p.match(/^\/api\/jobs\/([A-Za-z0-9._-]+)$/);
    if (mJob && req.method === 'GET') {
      if (!job || job.id !== mJob[1]) return sendJson(res, 404, { error: 'job_not_found' });
      return sendJson(res, 200, jobView(job, Number(url.searchParams.get('tail') || 200)));
    }

    // Remaining endpoints are actions: require the local token.
    if (!tokenOk(req)) return sendJson(res, 403, { error: 'bad_token' });

    if (p === '/api/read' && req.method === 'POST') {
      let body = {};
      try {
        const raw = await readBody(req);
        body = raw && raw.trim() ? JSON.parse(raw) : {};
      } catch (_) { /* empty body is fine */ }
      const r = await startRead(body);
      if (r.error === 'bad_n') return sendJson(res, 400, { error: 'n must be 1-20' });
      if (r.busy) return sendJson(res, 409, { error: 'busy', jobId: r.jobId });
      pipeline = { active: true, stage: 'read', jobId: r.jobId };
      return sendJson(res, 202, { jobId: r.jobId, pipeline: pipelineView() });
    }

    if (p === '/api/llm' && req.method === 'GET') {
      return sendJson(res, 200, llmView());
    }

    if (p === '/api/llm' && req.method === 'PUT') {
      let body = {};
      try {
        const raw = await readBody(req);
        body = raw && raw.trim() ? JSON.parse(raw) : {};
      } catch (_) {
        return sendJson(res, 400, { error: 'invalid_json' });
      }
      try {
        const r = saveLlm(body);
        return sendJson(res, 200, Object.assign({ ok: true, warning: r.warning }, llmView()));
      } catch (e) {
        return sendJson(res, e.status || 400, { error: String(e.message || e) });
      }
    }

    if (p === '/api/llm/test' && req.method === 'POST') {
      return sendJson(res, 200, await testLlm());
    }

    if (p === '/api/render' && req.method === 'POST') {
      let body = {};
      try {
        const raw = await readBody(req);
        body = raw && raw.trim() ? JSON.parse(raw) : {};
      } catch (_) { /* empty body */ }
      const args = [];
      const n = Number(body.n);
      if (Number.isFinite(n) && n > 0) args.push('-N', String(Math.min(20, Math.round(n))));
      if (body.onlyId) args.push('-OnlyId', String(body.onlyId));
      const r = await startScriptJob('render', 'render.ps1', args, 10 * 60 * 1000, body);
      if (r.busy) return sendJson(res, 409, { error: 'busy', jobId: r.jobId });
      return sendJson(res, 202, { jobId: r.jobId });
    }

    if (p === '/api/publish' && req.method === 'POST') {
      let body = {};
      try {
        const raw = await readBody(req);
        body = raw && raw.trim() ? JSON.parse(raw) : {};
      } catch (_) { /* empty body */ }
      const args = [];
      if (body.dryRun) args.push('-DryRun');
      if (body.noPush) args.push('-NoPush');
      const r = await startScriptJob('publish', 'publish.ps1', args, 10 * 60 * 1000, body);
      if (r.busy) return sendJson(res, 409, { error: 'busy', jobId: r.jobId });
      return sendJson(res, 202, { jobId: r.jobId });
    }

    if (p === '/api/migrate' && req.method === 'POST') {
      let body = {};
      try {
        const raw = await readBody(req);
        body = raw && raw.trim() ? JSON.parse(raw) : {};
      } catch (_) { /* empty body */ }
      const args = [];
      if (body.dryRun) args.push('-DryRun');
      const r = await startScriptJob('migrate', 'migrate.ps1', args, 10 * 60 * 1000, body);
      if (r.busy) return sendJson(res, 409, { error: 'busy', jobId: r.jobId });
      return sendJson(res, 202, { jobId: r.jobId });
    }

    if (p === '/api/scan' && req.method === 'POST') {
      let body = {};
      try {
        const raw = await readBody(req);
        if (raw && raw.trim()) body = JSON.parse(raw);
      } catch (_) { /* empty body is fine */ }
      const r = await startScan(!!body.dryRun);
      if (r.busy) return sendJson(res, 409, { error: 'busy', jobId: r.jobId });
      pipeline = null;
      return sendJson(res, 202, { jobId: r.jobId });
    }

    if (p === '/api/gh/login' && req.method === 'POST') {
      const r = await startLogin();
      if (r.busy) return sendJson(res, 409, { error: 'busy', jobId: r.jobId });
      return sendJson(res, 202, { jobId: r.jobId });
    }

    if (p === '/api/gh/logout' && req.method === 'POST') {
      const r = await run('gh', ['auth', 'logout', '--hostname', 'github.com'], 20000);
      statusCache.value = null; listsCache.value = null; listsCache.at = 0;
      if (r.code !== 0) {
        return sendJson(res, 500, { error: (r.stderr || r.stdout || 'logout_failed').trim() });
      }
      return sendJson(res, 200, { ok: true });
    }

    if (p === '/api/gh/lists' && req.method === 'GET') {
      return sendJson(res, 200, await ghListsProbe());
    }

    const mCancel = p.match(/^\/api\/jobs\/([A-Za-z0-9._-]+)\/cancel$/);
    if (mCancel && req.method === 'POST') {
      const ok = cancelJob(mCancel[1]);
      return sendJson(res, ok ? 200 : 409, ok ? { ok: true } : { error: 'not_running' });
    }

    sendJson(res, 404, { error: 'not_found' });
  } catch (e) {
    sendJson(res, 500, { error: String((e && e.message) || e) });
  }
});

/* ------------------------------------------------------------------ */
/* lifecycle                                                           */
/* ------------------------------------------------------------------ */

process.on('SIGINT', () => {
  if (job && job.state === 'running' && job.pid) {
    try { execFile('taskkill', ['/PID', String(job.pid), '/T', '/F'], () => {}); } catch (_) {}
  }
  try { fs.unlinkSync(SERVICE_FILE); } catch (_) {}
  process.exit(0);
});

function listen(port, remaining) {
  server.once('error', (e) => {
    if (e.code === 'EADDRINUSE' && remaining.length) return listen(remaining[0], remaining.slice(1));
    console.error('[joy] listen failed: ' + e.message);
    process.exit(4);
  });
  server.listen(port, '127.0.0.1', () => {
    ACTUAL_PORT = Number(port);
    ensureDirs();
    writeJson(SERVICE_FILE, {
      pid: process.pid, port: ACTUAL_PORT, startedAt: STARTED_AT, version: VERSION,
    });
    const url = 'http://127.0.0.1:' + port + '/';
    console.log('[joy] GitHub Joy M1 running: ' + url);
    console.log('[joy] workDir: ' + ROOT);
    if (!flag('--no-open')) {
      execFile('cmd', ['/c', 'start', '', url], { windowsHide: true }, () => {});
    }
  });
}

if (!STATES.includes(String(PORT))) {
  console.error('[joy] port must be one of ' + STATES.join('/') + ', got ' + PORT);
  process.exit(4);
}
listen(PORT, STATES.filter((p) => p !== String(PORT)));