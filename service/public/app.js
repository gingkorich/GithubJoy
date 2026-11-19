'use strict';

const TOKEN = (document.querySelector('meta[name="joy-token"]') || {}).content || '';
const $ = (id) => document.getElementById(id);
let pollTimer = null;
let activeJob = null;

async function api(path, opts) {
  const o = Object.assign({ headers: {} }, opts || {});
  o.headers = Object.assign({}, o.headers);
  const isWrite = (o.method || 'GET').toUpperCase() !== 'GET';
  if (isWrite || o.auth) {
    o.headers['X-Joy-Token'] = TOKEN;
    if (isWrite) o.headers['Content-Type'] = 'application/json';
  }
  const res = await fetch(path, o);
  let body = null;
  try { body = await res.json(); } catch (_) { body = { error: 'non_json_response' }; }
  if (!res.ok) {
    const err = new Error(body.error || ('HTTP ' + res.status));
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

function setText(id, v) {
  const el = $(id);
  if (el) el.textContent = (v === null || v === undefined || v === '') ? '—' : String(v);
}

function fmtTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : d.toLocaleString();
}

function relTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  const s = Math.max(0, (Date.now() - d.getTime()) / 1000);
  if (s < 60) return Math.round(s) + ' 秒前';
  if (s < 3600) return Math.round(s / 60) + ' 分钟前';
  if (s < 86400) return Math.round(s / 3600) + ' 小时前';
  return Math.round(s / 86400) + ' 天前';
}

function renderStatus(s) {
  setText('svc', 'v' + s.service.version + ' @ ' + s.service.port);
  setText('node', s.service.node);
  setText('cwd', s.service.workDir);

  const n = s.network || {};
  setText('netProxy', n.proxy ? (n.proxy + '（' + (n.source === 'system' ? '系统代理' : '配置') + '）') : '直连');

  const sc = s.scan;
  if (sc) {
    const rel = relTime(sc.lastAt);
    setText('lastScan', fmtTime(sc.lastAt) + (rel ? '（' + rel + '）' : ''));
    setText('lastAdded', sc.added);
  } else {
    setText('lastScan', '尚未扫描');
    setText('lastAdded', '—');
  }
  setText('unreadCount', s.unread ? s.unread.count : '—');
  const q = s.queue || {};
  setText('queueStat',
    '待读 ' + (q.pending || 0) + ' / 完成 ' + (q.done || 0) +
    ' / 失败 ' + (q.failed || 0) + ' / 已读 ' + (q.moved || 0));

  const g = s.gh || {};
  const llm = s.llm || {};
  setText('llmState', llm.configured ? ('已配置（' + llm.model + '）') : '未配置');
  setText('ghInstalled', g.installed ? '已安装' : '未安装');
  setText('ghVersion', g.version);
  setText('ghAuth', g.auth ? '已登录' : '未登录');
  setText('ghLogin', g.login);
  setText('ghScopes', g.scopes);
  setText('ghError', g.error);

  const who = $('who');
  if (g.auth && g.login) {
    who.textContent = g.login;
    who.classList.add('on');
  } else {
    who.textContent = '未连接';
    who.classList.remove('on');
  }

  $('btnLogin').disabled = !!g.auth;
  $('btnLogout').disabled = !g.auth;
  $('btnScan').disabled = !!(s.job && s.job.state === 'running');

  if (s.job) renderJob(s.job);
}

function renderJob(j) {
  activeJob = j;
  $('jobCard').hidden = false;
  $('jobState').textContent = j.state;
  $('jobState').className = 'tag ' + j.state;
  $('jobKind').textContent = j.kind === 'scan' ? (j.dryRun ? '扫描·干跑' : '扫描') : 'gh 登录';
  $('codeLine').hidden = !(j.kind === 'gh-login' && j.code);
  setText('jobCode', j.code);

  let progress = '';
  if (j.state === 'running' && j.progress) {
    progress = '阶段 ' + j.progress.phase + '（' + (j.progress.done || 0) + '/' + (j.progress.total || 0) + '）';
  }
  if (j.result && j.kind === 'scan') {
    const r = j.result;
    progress = '扫描' + (r.dryRun ? '（干跑）' : '') + '：候选 ' + r.scanned + '，新增 ' + r.added +
      (r.ensured ? '，补回 ' + r.ensured : '') +
      '，star ' + (r.starred || 0) + (r.unreadCount != null ? '，unread ' + r.unreadCount + '→' + r.totalUnreadAfter : '');
  }
  setText('jobProgress', progress);

  const hint = $('jobHint');
  if (j.hintText) { hint.textContent = j.hintText; hint.hidden = false; } else { hint.hidden = true; }
  $('jobLog').textContent = (j.lines || []).join('\n');
  $('jobLog').scrollTop = $('jobLog').scrollHeight;
  $('btnCancel').hidden = j.state !== 'running';
  $('btnLogin').disabled = j.state === 'running' || $('btnLogin').disabled;
  $('btnScan').disabled = j.state === 'running';

  if (j.state === 'running') {
    if (!pollTimer) pollTimer = setInterval(refresh, 1000);
  } else if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
    refresh();
  }
}

async function refresh() {
  try {
    const s = await api('/api/status');
    renderStatus(s);
    const running = s.job && s.job.state === 'running';
    if (!running && pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  } catch (e) {
    $('who').textContent = '服务异常：' + e.message;
    $('who').classList.remove('on');
  }
}

$('btnLogin').addEventListener('click', async () => {
  try {
    $('btnLogin').disabled = true;
    const r = await api('/api/gh/login', { method: 'POST', body: '{}' });
    activeJob = { id: r.jobId, state: 'running', lines: [] };
    renderJob(activeJob);
    pollTimer = setInterval(refresh, 1000);
  } catch (e) {
    alert('发起登录失败：' + e.message + (e.status === 403 ? '\n请从 http://127.0.0.1:8787/ 打开本页。' : ''));
    $('btnLogin').disabled = false;
  }
});

$('btnScan').addEventListener('click', async () => {
  const dry = $('chkDry').checked;
  try {
    $('btnScan').disabled = true;
    const r = await api('/api/scan', { method: 'POST', body: JSON.stringify({ dryRun: dry }) });
    activeJob = { id: r.jobId, kind: 'scan', state: 'running', dryRun: dry, lines: [], progress: { phase: 'start', done: 0, total: 5 } };
    renderJob(activeJob);
    pollTimer = setInterval(refresh, 1000);
  } catch (e) {
    alert('发起扫描失败：' + e.message);
    $('btnScan').disabled = false;
  }
});

$('btnLogout').addEventListener('click', async () => {
  if (!confirm('确定退出 GitHub 登录？')) return;
  try {
    await api('/api/gh/logout', { method: 'POST', body: '{}' });
    await refresh();
  } catch (e) {
    alert('退出失败：' + e.message);
  }
});

$('btnCancel').addEventListener('click', async () => {
  if (!activeJob) return;
  try {
    await api('/api/jobs/' + activeJob.id + '/cancel', { method: 'POST', body: '{}' });
    await refresh();
  } catch (e) {
    alert('取消失败：' + e.message);
  }
});

$('btnProbe').addEventListener('click', async () => {
  const out = $('probeOut');
  out.textContent = '探测中…';
  try {
    const r = await api('/api/gh/lists', { auth: true });
    out.textContent = JSON.stringify(r, null, 2);
  } catch (e) {
    out.textContent = '探测失败：' + e.message;
  }
});

async function loadLlm() {
  try {
    const r = await api('/api/llm', { auth: true });
    const active = document.activeElement;
    if (active !== $('llmBase')) $('llmBase').value = r.baseUrl || '';
    if (active !== $('llmModel')) $('llmModel').value = r.model || '';
    if (active !== $('llmTimeout')) $('llmTimeout').value = r.timeoutSec || 60;
    $('llmKey').value = '';
    $('llmKey').placeholder = r.keyMask ? ('已保存 ' + r.keyMask + '，留空不修改') : 'sk-...';
    setText('llmState', r.configured ? ('已配置（' + r.model + '）') : '未配置');
  } catch (e) {
    setText('llmState', '读取失败：' + e.message);
  }
}

$('btnLlmSave').addEventListener('click', async () => {
  const body = {
    baseUrl: $('llmBase').value.trim(),
    model: $('llmModel').value.trim(),
    timeoutSec: Number($('llmTimeout').value || 60),
  };
  const k = $('llmKey').value.trim();
  if (k) body.apiKey = k;
  $('btnLlmSave').disabled = true;
  $('llmHint').className = 'hint';
  $('llmHint').textContent = '保存中…';
  try {
    const r = await api('/api/llm', { method: 'PUT', body: JSON.stringify(body) });
    $('llmKey').value = '';
    $('llmHint').textContent = '已保存' + (r.warning === 'acl_failed' ? '（警告：文件权限未收紧）' : '');
    await loadLlm();
    await refresh();
  } catch (e) {
    $('llmHint').textContent = '保存失败：' + e.message;
    $('llmHint').className = 'hint bad';
  } finally {
    $('btnLlmSave').disabled = false;
  }
});

$('btnLlmTest').addEventListener('click', async () => {
  $('btnLlmTest').disabled = true;
  $('llmHint').className = 'hint';
  $('llmHint').textContent = '测试中…';
  try {
    const r = await api('/api/llm/test', { method: 'POST', body: '{}' });
    if (r.ok) {
      $('llmHint').textContent = '连接成功：' + r.latencyMs + ' ms（' + r.model + '）';
      $('llmHint').className = 'hint ok';
    } else {
      $('llmHint').textContent = '连接失败：' + (r.error || ('HTTP ' + r.status));
      $('llmHint').className = 'hint bad';
    }
  } catch (e) {
    $('llmHint').textContent = '测试失败：' + e.message;
    $('llmHint').className = 'hint bad';
  } finally {
    $('btnLlmTest').disabled = false;
  }
});

refresh();
loadLlm();
setInterval(refresh, 3000);