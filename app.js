'use strict';
/* ============================================================================
   ServerPanel v4.1 前端 —— 按 docs/设计需求与评审-v4.1.md 重构表现层
   保留 v4 数据契约与安全模型（CSP script-src 'self'、无内联 onclick）。
   ========================================================================== */
const $ = id => document.getElementById(id);
const A = x => Array.isArray(x) ? x : (x == null ? [] : [x]);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const sleep = ms => new Promise(r => setTimeout(r, ms));

/* ---------- DR-01 线性 SVG 图标（16px stroke1.5 currentColor，替代全部 emoji） ---------- */
const P = {
  server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  chart: '<path d="M3 3v18h18"/><path d="M7 14l4-5 3 3 5-7"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 4 5.6 4 9s-1.5 6.4-4 9c-2.5-2.6-4-5.6-4-9s1.5-6.4 4-9z"/>',
  sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3"/><path d="M1 14h6M9 8h6M17 16h6"/>',
  bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
  cpu: '<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
  gpu: '<rect x="2" y="7" width="20" height="10" rx="2"/><circle cx="9" cy="12" r="3"/><path d="M16 10h3M16 14h3M6 17v3"/>',
  ram: '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10v4M10 10v4M14 10v4M18 10v4M6 18v2M12 18v2M18 18v2"/>',
  disk: '<rect x="2" y="13" width="20" height="7" rx="2"/><path d="M4 13l2-8h12l2 8"/><path d="M6 16.5h.01M10 16.5h.01"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',
  x: '<path d="M18 6L6 18M6 6l12 12"/>',
  plug: '<path d="M9 2v6M15 2v6"/><path d="M6 8h12v4a6 6 0 0 1-12 0z"/><path d="M12 18v4"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7"/>',
  file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
  alert: '<path d="M10.3 3.8L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.8a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>',
  clipboard: '<rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M9 12h6M9 16h6"/>',
  heart: '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.6l-1-1a5.5 5.5 0 0 0-7.8 7.8l1 1L12 21.2l7.8-7.8 1-1a5.5 5.5 0 0 0 0-7.8z"/>',
  play: '<path d="M6 4l14 8-14 8z"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
  kill: '<circle cx="12" cy="12" r="9"/><path d="M9 9l6 6M15 9l-6 6"/>',
  kill9: '<path d="M13 2L3 14h7l-1 8 11-13h-7z"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/>',
  check: '<path d="M20 6L9 17l-5-5"/>',
  inbox: '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.5 5h13L22 12v7a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-7z"/>',
  lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/>'
};
const icon = n => '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true">' + (P[n] || '') + '</svg>';
function hydrateIcons(root) { (root || document).querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); el.removeAttribute('data-icon'); }); }

/* ---------- 状态/徽章/空态（DR-01 双编码 / DR-10 / DR-11） ---------- */
const stHtml = (lv, tx) => '<span class="st ' + lv + '"><span class="sh"></span>' + esc(tx) + '</span>';
const pill = (lv, tx) => '<span class="pill ' + lv + '">' + esc(tx) + '</span>';
function emptyHtml(kind, title, desc, action) {
  const ic = kind === 'perm' ? 'lock' : (kind === 'nodata' ? 'refresh' : 'inbox');
  return '<div class="empty">' + icon(ic) + '<div class="e-t">' + esc(title) + '</div><div class="e-d">' + esc(desc || '') + '</div>' + (action || '') + '</div>';
}

/* ---------- 小工具 ---------- */
const GB = b => (b == null ? null : b / 1073741824);
function num(v, d = 0) { return v == null ? null : Number(Number(v).toFixed(d)); }
function vOr(v, suffix, d) { const n = num(v, d); return n == null ? '<span class="unk">无数据</span>' : n + (suffix ? '<small>' + suffix + '</small>' : ''); }
function fmtUp(s) { if (s == null) return '未知'; s = Math.floor(s); const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return (d ? d + '天' : '') + h + '小时' + m + '分'; }
function fmtKB(v) { if (v == null) return '—'; if (v > 1048576) return (v / 1048576).toFixed(1) + 'M/s'; if (v > 1024) return (v / 1024).toFixed(1) + 'K/s'; return Math.round(v) + 'B/s'; }
function basename(cmd) { const t = String(cmd || '').trim().split(/\s+/); const first = t[0] || ''; const b = first.split('/').pop() || first; return { base: b, args: t.slice(1).join(' ') }; }

/* 审计结果 → 可读徐章（DR-37 新增的 self_fail:* / rc=N 不能裸着给用户看） */
function auditPill(r) {
  const s = '' + (r || '');
  if (s === 'ok') return pill('ok', '成功');
  if (s === 'denied') return pill('bad', '已拒绝');
  const m = s.match(/^self_fail:(\w+)/);
  if (m) return pill('warn', '自报失败 ' + m[1]);
  if (/^rc=/.test(s)) return pill('warn', '远端 ' + s);
  return pill('warn', esc(s));
}

/* ---------- DR-14 Toast 栈 ---------- */
function toast(m, bad) {
  const box = $('toasts');
  const el = document.createElement('div');
  el.className = 'toast ' + (bad ? 'bad' : 'ok');
  el.innerHTML = icon(bad ? 'alert' : 'check') + '<span class="tx">' + esc(m) + '</span><button class="iconbtn" aria-label="关闭">' + icon('x') + '</button>';
  el.querySelector('button').onclick = () => el.remove();
  box.appendChild(el);
  while (box.children.length > 3) box.firstChild.remove();
  setTimeout(() => el.remove(), 4000);
}

/* ---------- DR-14/23 确认弹窗（焦点陷阱 + 真实命令/影响面） ---------- */
let _lastFocus = null;
function uiConfirm(title, msg, okText, danger) {
  return new Promise(res => {
    _lastFocus = document.activeElement;
    const w = $('mwrap'); $('mtitle').textContent = title; $('mbody').textContent = msg;
    const yes = $('myes'); yes.textContent = okText || '确认执行';
    yes.className = 'act ' + (danger ? 'danger solid' : 'danger');
    w.classList.add('on');
    const done = v => { w.classList.remove('on'); yes.onclick = null; $('mno').onclick = null; w.onclick = null; document.removeEventListener('keydown', key); if (_lastFocus) _lastFocus.focus(); res(v); };
    const key = e => {
      if (e.key === 'Escape') { e.preventDefault(); done(false); }
      if (e.key === 'Enter') { e.preventDefault(); done(true); }
      if (e.key === 'Tab') { const f = [ $('mno'), yes ]; const i = f.indexOf(document.activeElement); e.preventDefault(); f[(i + (e.shiftKey ? -1 : 1) + f.length) % f.length].focus(); }
    };
    yes.onclick = () => done(true); $('mno').onclick = () => done(false);
    w.onclick = e => { if (e.target === w) done(false); };
    document.addEventListener('keydown', key);
    $('mno').focus();
  });
}

/* ---------- 网络层 ---------- */
let TOKEN = null, BOOT = null, HOST = null, SNAP = null, STALE = false, AGE = 0, BACKEND_DOWN = false;
async function api(path, opt) { const o = Object.assign({ headers: {} }, opt || {}); o.headers['X-Panel-Token'] = TOKEN; if (o.body) o.headers['Content-Type'] = 'application/json'; return fetch(path, o); }
async function getJSON(path) { const r = await api(path); return await r.json(); }

/* ---------- 状态 ---------- */
let win = '15m', sortK = 'pcpu', sortAsc = false, page = 0;
const PAGE = 50; // DR-06
let uMain = null, uNet = null, uSpark = null;
const showState = loadShow(); // DR-19/25 localStorage
let fullPath = localStorage.getItem('sp_fullpath') === '1'; // DR-07
function loadShow() { try { const s = JSON.parse(localStorage.getItem('sp_show') || 'null'); if (s && s.main && s.net) return s; } catch (e) {} return { main: [true, true, true, true], net: [true, true, true] }; }
function saveShow() { localStorage.setItem('sp_show', JSON.stringify(showState)); }

const MAIN_SERIES = [
  { label: 'CPU %', stroke: '#6D8DFF', width: 1.6, fill: 'rgba(109,141,255,.14)', scale: 'y' },
  { label: 'GPU %', stroke: '#35C88A', width: 1.6, fill: 'rgba(53,200,138,.12)', scale: 'y' },
  { label: '显存 %', stroke: '#8F6DFF', width: 1.6, scale: 'y' },
  { label: 'GPU ℃', stroke: '#E8A33D', width: 1.2, dash: [4, 3], scale: 'y2' }
];
const NET_SERIES = [
  { label: '下载 KB/s', stroke: '#35C88A', width: 1.6, fill: 'rgba(53,200,138,.12)', scale: 'y' },
  { label: '上传 KB/s', stroke: '#E8A33D', width: 1.6, scale: 'y' },
  { label: '负载', stroke: '#4CC3D9', width: 1.2, dash: [3, 3], scale: 'y2' }
];

/* ---------- 动作（异步 job，DR-14 就地反馈） ---------- */
async function runAct(body, outEl) {
  const out = outEl || $('svcOut');
  out.style.display = 'block'; out.textContent = '已提交，等待服务器响应…';
  let j;
  try { const r = await api('/api/action', { method: 'POST', body: JSON.stringify(body) }); j = await r.json(); }
  catch (e) { out.textContent = '提交失败: ' + e; toast('提交失败', true); return; }
  if (!j.id) { out.textContent = (j.error || '未受理'); toast('未受理', true); return; }
  for (let i = 0; i < 60; i++) {
    await sleep(600);
    let s; try { s = await getJSON('/api/action?id=' + j.id); } catch (e) { continue; }
    if (s.status === 'running') { out.textContent = '执行中… (' + (i * 0.6).toFixed(0) + 's)'; continue; }
    const head = s.status === 'denied' ? '已拒绝\n' : (s.ok ? '完成\n' : '未成功\n');
    // error 与远端原文都要显示：只留 error 会抹掉真正的失败输出，没法排障
    const det = [s.error, s.text].filter(Boolean).join('\n') || '(无输出)';
    out.textContent = head + det + (s.hint ? '\n\n提示: ' + s.hint : '');
    // toast 颜色必须跟 ok 走：以前用 status!=='done' 判，导致 done+ok=false（脚本自报失败）被渲染成绿色成功
    toast(s.status === 'denied' ? '操作被保护名单拒绝' : (s.ok ? '完成' : '操作未成功'), !s.ok);
    pollSnap(true); refreshStatus();
    return s;
  }
  out.textContent = '等待超时（36s），动作可能仍在服务器上执行，刷新看状态';
  return { status: 'timeout' };
}

/* ---------- 进程 ---------- */
function procs() { return A(SNAP && SNAP.procs); }
function filtered() {
  const f = ($('pFilter').value || '').trim().toLowerCase();
  let ps = procs();
  if (f) ps = ps.filter(p => ((p.cmd || '') + ' ' + (p.user || '') + ' ' + p.pid).toLowerCase().includes(f));
  ps = ps.slice().sort((a, b) => { const x = a[sortK], y = b[sortK]; const r = (typeof x === 'number' && typeof y === 'number') ? x - y : String(x).localeCompare(String(y)); return r * (sortAsc ? 1 : -1); });
  return ps;
}
function cmdCell(p) {
  const full = String(p.cmd || '');
  if (fullPath) return '<span class="cmd" title="' + esc(full) + '">' + esc(full.slice(0, 220)) + '</span>';
  const b = basename(full);
  return '<span class="cmd" title="' + esc(full) + '"><span class="base">' + esc(b.base) + '</span> ' + esc(b.args.slice(0, 160)) + '</span>';
}
function renderProcs() {
  const ps = filtered();
  const tot = (SNAP && SNAP.procTotal) || procs().length;
  const shown = procs().length;
  const pages = Math.max(1, Math.ceil(ps.length / PAGE));
  if (page >= pages) page = pages - 1; if (page < 0) page = 0;
  $('pMeta').textContent = '匹配 ' + ps.length + (tot > shown ? ' · 已截断 展示前 ' + shown + ' / 共 ' + tot : ' · 共 ' + tot);
  const rows = ps.slice(page * PAGE, page * PAGE + PAGE).map(p =>
    '<tr data-pid="' + p.pid + '"><td class="num">' + p.pid + '</td><td>' + esc(p.user) + '</td><td class="num">' + num(p.pcpu, 1) + '</td><td class="num">' + num(p.pmem, 1) +
    '</td><td class="num">' + fmtUp(p.etimes) + '</td><td>' + cmdCell(p) + '</td>' +
    '<td class="ops"><button class="mini" data-kill="' + p.pid + '" aria-label="结束进程 ' + p.pid + '">' + icon('kill') + '结束</button> <button class="mini danger" data-kill9="' + p.pid + '" aria-label="强杀进程 ' + p.pid + '" title="强制结束（SIGKILL）">' + icon('kill9') + '</button></td></tr>'
  ).join('');
  $('pTable').querySelector('tbody').innerHTML = rows || '<tr><td colspan="7">' + emptyHtml('none', '没有匹配的进程', '调整过滤条件试试') + '</td></tr>';
  $('pgInfo').textContent = '第 ' + (page + 1) + ' / ' + pages + ' 页';
  document.querySelectorAll('#pTable th').forEach(th => th.classList.toggle('sorted', th.dataset.k === sortK));
}

/* ---------- 阈值（DR-08/18 来自 config，不硬编码） ---------- */
function ruleFor(metric) { return A(BOOT && BOOT.alerts).find(r => r.metric === metric); }
function thr(metric) { const r = ruleFor(metric); return r ? Number(r.threshold) : null; }
function barClass(pct, metric) { const t = thr(metric); if (pct == null) return 'unk'; if (t != null && pct >= t) return 'bad'; if (t != null && pct >= t * 0.8) return 'warn'; return ''; }
function setBar(el, pct, metric) {
  const p = num(pct, 1);
  if (p == null) { el.style.width = '0%'; el.className = 'unk'; return; }
  el.style.width = Math.min(100, p) + '%'; el.className = barClass(p, metric);
}

/* ---------- 结论（DR-05 一句话+要点） ---------- */
function buildVerdict(m) {
  const g = m.gpu || {}, d = m.derived || {};
  const issues = [];
  const gpuFree = g.present && g.util != null && g.util < 30 && (d.gpuMemPct == null || d.gpuMemPct < 60);
  if (!g.present || g.util == null) issues.push({ lv: 'bad', tx: '读不到 GPU 指标，结论不可信', go: 'alarm' });
  else if (!gpuFree) issues.push({ lv: 'warn', tx: '显卡已在干活（利用率 ' + num(g.util, 0) + '% / 显存 ' + num(d.gpuMemPct, 0) + '%）', go: 'proc' });
  if (g.tempC != null && g.tempC > 78) issues.push({ lv: 'bad', tx: 'GPU 温度 ' + num(g.tempC, 0) + '°C 偏热', go: 'perf' });
  if (d.memPct != null && d.memPct >= 85) issues.push({ lv: 'warn', tx: '内存 ' + num(d.memPct, 0) + '% 偏高', go: 'proc' });
  const disks = A(m.disk).map(x => ({ mp: x.mp, pct: x.total ? x.used / x.total * 100 : null })).filter(x => x.pct != null).sort((a, b) => b.pct - a.pct);
  if (disks[0] && disks[0].pct >= 85) issues.push({ lv: 'warn', tx: '磁盘 ' + disks[0].mp + ' ' + num(disks[0].pct, 0) + '% 偏满', go: 'ov' });
  for (const a of A(m._activeAlerts)) issues.push({ lv: a.level === 'bad' ? 'bad' : 'warn', tx: a.text, go: 'alarm' });
  if (STALE) issues.unshift({ lv: 'bad', tx: '数据已停止更新（' + AGE + 's），采集链路可能断开', go: 'alarm' });
  issues.sort((a, b) => (a.lv === 'bad' ? 0 : 1) - (b.lv === 'bad' ? 0 : 1));
  const ok = issues.length === 0;
  const line = ok ? '一切正常，可以直接开新训练' : (gpuFree ? '可以开新训练，但有 ' + issues.length + ' 项需留意' : '暂不建议开新训练，先处理 ' + issues.length + ' 项异常');
  return { ok, line, issues: issues.slice(0, 3), gpuFree };
}

/* ---------- 渲染 ---------- */
function cardRefresh(id) { const c = $(id); if (!c) return; c.classList.remove('skel'); c.classList.add('refreshing'); setTimeout(() => c.classList.remove('refreshing'), 500); }
function render(m) {
  SNAP = m;
  const g = m.gpu || {}, c = m.cpu || {}, mm = m.mem || {}, d = m.derived || {};
  const gpus = A(m.gpus); const multi = gpus.length > 1;
  // GPU 主卡（DR-04）
  $('gpuMain').classList.remove('skel');
  $('gpuName').textContent = g.present ? (g.name || 'GPU') + (multi ? '（' + gpus.length + ' 卡）' : '') : '无 GPU';
  $('gpuSt').innerHTML = g.present ? stHtml(g.util != null && g.util < 30 ? 'ok' : 'warn', g.util != null && g.util < 30 ? '空闲' : '忙碌') : stHtml('idle', '不可用');
  $('gUtil').innerHTML = vOr(g.util, '%', 0);
  const gu = g.memUsedMiB == null ? null : g.memUsedMiB / 1024, gt = g.memTotalMiB == null ? null : g.memTotalMiB / 1024;
  $('gMem').innerHTML = gu == null ? '<span class="unk">无数据</span>' : gu.toFixed(1) + '<small>/ ' + (gt ? gt.toFixed(0) : '?') + 'G</small>';
  $('gTemp').innerHTML = vOr(g.tempC, '°C', 0);
  $('gPow').innerHTML = vOr(g.powerW, 'W', 0);
  const gp = multi ? gpus.flatMap(x => A(x.procs)) : A(g.procs);
  const freeG = gt != null && gu != null ? (gt - gu) : null;
  $('gpuVerdict').innerHTML = (g.present && g.util != null && g.util < 30 && (d.gpuMemPct == null || d.gpuMemPct < 60))
    ? icon('check') + '<span>能直接开新训练 · 显存剩 ' + (freeG != null ? freeG.toFixed(1) + 'G' : '?') + ' · ' + (gp.length ? '当前 ' + gp.length + ' 个进程占用' : '当前无人占用') + '</span>'
    : icon('alert') + '<span>谨慎开新任务 · ' + (gp.length ? '显存被 ' + gp.length + ' 个进程占着' : '显卡忙碌') + ' · 剩 ' + (freeG != null ? freeG.toFixed(1) + 'G' : '?') + '</span>';
  // 四辅卡（DR-09/16 统一格式）
  cardRefresh('c-cpu'); $('cpuV').innerHTML = vOr(d.cpuPct, '%', 0); $('cpuD').textContent = c.cores ? c.cores + ' 核 · 负载 ' + num(c.load1, 2) : '核数未知'; setBar($('cpuB'), d.cpuPct, 'cpu.pct'); $('cpuSt').innerHTML = stHtml(d.cpuPct != null && d.cpuPct < 85 ? 'ok' : 'warn', d.cpuPct != null && d.cpuPct < 85 ? '正常' : '偏高');
  cardRefresh('c-mem'); $('memV').innerHTML = mm.total == null ? '<span class="unk">无数据</span>' : GB(mm.used).toFixed(1) + '<small>/ ' + GB(mm.total).toFixed(0) + 'G</small>'; $('memD').textContent = '占比 ' + num(d.memPct, 0) + '% · 交换 ' + GB(mm.swapUsed || 0).toFixed(1) + 'G'; setBar($('memB'), d.memPct, 'mem.pct'); $('memSt').innerHTML = stHtml(d.memPct != null && d.memPct < 85 ? 'ok' : 'warn', d.memPct != null && d.memPct < 85 ? '正常' : '偏高');
  const disks = A(m.disk).map(x => ({ mp: x.mp, src: x.src, total: x.total, used: x.used, avail: x.avail, pct: x.total ? x.used / x.total * 100 : null })).filter(x => x.pct != null).sort((a, b) => b.pct - a.pct);
  cardRefresh('c-disk');
  if (disks[0]) { $('diskV').innerHTML = num(disks[0].pct, 0) + '<small>%</small>'; $('diskD').textContent = disks[0].mp + ' · 剩 ' + GB(disks[0].avail).toFixed(0) + 'G'; setBar($('diskB'), disks[0].pct, 'disk.maxPct'); $('diskSt').innerHTML = stHtml(disks[0].pct < 85 ? 'ok' : 'warn', disks[0].pct < 85 ? '正常' : '偏满'); }
  else { $('diskV').innerHTML = '<span class="unk">无数据</span>'; $('diskD').textContent = ''; setBar($('diskB'), null); $('diskSt').innerHTML = stHtml('idle', '无'); }
  cardRefresh('c-net'); $('netV').innerHTML = fmtKB(d.rxRateBps) + '<small>↓</small> ' + fmtKB(d.txRateBps) + '<small>↑</small>'; $('netD').textContent = '累计 ↓' + (m.net ? GB(m.net.rx).toFixed(1) + 'G' : '—') + ' · ' + A(m.users).map(u => u.user + '×' + u.n).join(', '); $('netSt').innerHTML = stHtml('ok', '活跃');
  // 结论（DR-05）
  const v = buildVerdict(m);
  $('verdict').innerHTML = (v.ok ? icon('check') : icon('alert')) + '<span>' + esc(v.line) + '</span>' + (v.ok ? '<span class="mut" style="margin-left:auto;font-weight:400;font-size:11px">检查于 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false }) + '</span>' : '');
  $('verdictPts').innerHTML = v.issues.map(it => '<div class="pt">' + stHtml(it.lv, it.lv === 'bad' ? '严重' : '预警') + '<span>' + esc(it.tx) + '</span><button class="mini go" data-go="' + it.go + '">查看</button></div>').join('');
  // 占显存 / Top8（DR-11 空态）
  const pm = {}; for (const p of procs()) pm[p.pid] = p;
  $('gpuProcMeta').textContent = gp.length ? gp.length + ' 个' : '';
  $('gpuProcs').innerHTML = gp.length ? gp.map(p => { const o = pm[p.pid] || {}; return '<div class="kv"><b>' + esc((o.cmd || ('pid ' + p.pid)).slice(0, 110)) + '</b><span class="num">PID ' + p.pid + ' · ' + (p.memMiB / 1024).toFixed(1) + 'G</span></div>'; }).join('')
    : (STALE ? emptyHtml('nodata', '尚未开始采集', '采集链路断开，等待恢复') : emptyHtml('none', '当前没有占显存的进程', '显存空闲，可以放心开训练'));
  $('topMeta').textContent = '共 ' + ((m.procTotal) || procs().length) + ' 进程';
  $('topProcs').innerHTML = procs().slice(0, 8).map(p => '<div class="kv"><b>' + esc(basename(p.cmd).base + ' ' + basename(p.cmd).args.slice(0, 60)) + '</b><span class="num">' + esc(p.user) + ' · ' + num(p.pcpu, 0) + '%</span></div>').join('') || emptyHtml('none', '暂无进程数据', '');
  // 挂载（DR-08 降序+阈值分段）
  $('diskList').innerHTML = disks.length ? disks.map(x => {
    const t = thr('disk.maxPct'); const ticks = t != null ? '<span class="tick" style="left:' + Math.min(100, t) + '%"></span>' : '';
    return '<div class="mount-row"><div class="mp">' + esc(x.mp) + '<small>' + esc(x.src) + '</small></div><div class="bar">' + ticks + '<i class="' + barClass(x.pct, 'disk.maxPct') + '" style="width:' + Math.min(100, x.pct) + '%"></i></div><div class="pct num">' + num(x.pct, 1) + '%</div></div>';
  }).join('') : emptyHtml('nodata', '尚未开始采集', '');
  // 网络页（DR-27 权限区分）
  const ports = A(m.ports);
  // 采集器对监听端口有 80 条上限：被截断时必须说出来，不能让用户把“前 80”当成全部（与 DR-29 进程口径同类）
  $('portMeta').textContent = (m.portsTotal != null && m.portsTotal > ports.length)
    ? ('显示前 ' + ports.length + ' / 共 ' + m.portsTotal + ' 个')
    : (ports.length + ' 个');
  $('portList').innerHTML = ports.length ? ports.map(x => '<div class="kv"><b class="num">' + esc(x.addr) + '</b><span>' + (A(x.procs).length ? x.procs.map(esc).join(', ') : (m.isRoot === false ? '<span class="mut">需 root 查看归属</span>' : '<span class="mut">无进程</span>')) + '</span></div>').join('') : emptyHtml('none', '没有监听端口', '');
  const cn = A(m.conns);
  $('connMeta').textContent = cn.length + ' 组';
  $('connList').innerHTML = cn.length ? cn.map(x => '<div class="kv"><b class="num">' + esc(x.remote) + '</b><span class="num">×' + x.n + ' 本地 ' + esc(x.local) + '</span></div>').join('') : emptyHtml('none', '当前没有外部连接', '采集器已过滤回环连接');
  $('userList').innerHTML = A(m.users).map(u => '<div class="kv"><b>' + esc(u.user) + '</b><span class="num">' + u.n + ' 个会话</span></div>').join('') || emptyHtml('none', '无登录会话', '');
  renderSvc(m);
  renderProcs();
}

function renderSvc(m) {
  const h = BOOT.hosts.find(x => x.id === HOST); if (!h) return;
  const svcs = {}; for (const s of A(m.services)) svcs[s.unit] = s; for (const p of A(m.patterns)) svcs[p.pattern] = p;
  $('svcList').innerHTML = A(h.services).map(s => {
    const st = svcs[s.matchKey] || {};
    const on = (s.kind === 'systemd') ? st.state === 'active' : st.state === 'running';
    const lv = on ? (s.warnIfActive ? 'warn' : 'ok') : 'idle';
    const txt = on ? (s.warnIfActive ? '运行中需关注' : '运行中') : '未运行';
    return '<div class="svc"><span class="nm">' + icon(s.kind === 'systemd' ? 'server' : 'play') + esc(s.label) + '</span>' + pill(lv, txt) +
      '<span class="desc">' + esc(s.desc || '') + (s.kind === 'systemd' && st.enabled ? ' · 开机自启: ' + esc(st.enabled) : '') + '</span>' +
      '<button class="mini" data-svcstart="' + esc(s.id) + '"' + (on ? ' disabled' : '') + '>' + icon('play') + '启动</button>' +
      '<button class="mini danger" data-svcstop="' + esc(s.id) + '"' + (!on ? ' disabled' : '') + '>' + icon('stop') + '停止</button>' +
      (s.hasLog ? '<button class="mini" data-svclog="' + esc(s.id) + '">' + icon('file') + '日志</button>' : '') + '</div>';
  }).join('') || emptyHtml('none', '这台主机没配置可管理的服务', '');
}

/* ---------- DR-16/17/18 图表 ---------- */
function chartHeight() { const vh = window.innerHeight; return Math.max(260, Math.floor((Math.max(560, vh - 330) - 24) / 2)); }
function axisVals(fmt) { return (u, ticks) => ticks.map(fmt); }
function mkChart(el, series, opts) {
  const cores = (SNAP && SNAP.cpu && SNAP.cpu.cores) || 8;
  const scales = { x: { time: true }, y: { range: opts.yRange || null, auto: !opts.yRange }, y2: { range: opts.y2Range || null, auto: !opts.y2Range } };
  const axes = [
    { stroke: '#6B7789', grid: { show: false }, values: axisVals(t => new Date(t * 1000).toLocaleTimeString('zh-CN', { hour12: false, hour: '2-digit', minute: '2-digit' })) }, // DR-20 只留水平网格
    { stroke: opts.yColor || '#98A4B8', grid: { stroke: '#222A38', width: 1 }, size: 46, values: axisVals(v => v == null ? '' : (Math.abs(v) >= 1000 ? (v / 1000).toFixed(1) + 'k' : Math.round(v * 10) / 10)), label: opts.yLabel },
    { stroke: opts.y2Color || '#98A4B8', side: 1, grid: { show: false }, size: 46, values: axisVals(v => v == null ? '' : Math.round(v * 10) / 10), label: opts.y2Label }
  ];
  const u = new uPlot({
    width: el.clientWidth || 600, height: chartHeight(),
    pxAlign: false, cursor: { points: { show: true, size: 7, width: 2 }, one: false, drag: { x: false, set: false, y: false } },
    legend: { show: false }, scales, axes,
    series: [{ label: '时间' }].concat(series),
    hooks: { draw: [uu => drawThresholds(uu, opts)] }
  }, [[], []], el);
  return u;
}
function drawThresholds(u, opts) {
  const bands = opts.bands || [];
  const ctx = u.ctx; if (!ctx) return;
  for (const b of bands) {
    const sc = u.scales[b.scale]; if (!sc || sc.min == null) continue;
    if (b.value < sc.min || b.value > sc.max) continue;
    const y = u.valToPos(b.value, b.scale, true);
    ctx.save(); ctx.strokeStyle = b.color; ctx.setLineDash([5, 4]); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(u.bbox.left, y); ctx.lineTo(u.bbox.left + u.bbox.width, y); ctx.stroke();
    ctx.setLineDash([]); ctx.fillStyle = b.color; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
    ctx.fillText(b.label, u.bbox.left + u.bbox.width - 4, y - 3); ctx.restore();
  }
}
function mainBands() {
  const b = [];
  const tm = thr('gpu.tempC'); if (tm != null) b.push({ scale: 'y2', value: tm, color: '#E5484D', label: '温度 ' + tm + '°C' });
  const gm = thr('gpu.memPct'); if (gm != null) b.push({ scale: 'y', value: gm, color: '#8F6DFF', label: '显存 ' + gm + '%' });   // 与“显存 %”曲线同色：阈值带本就是在标这条线；之的 #E8A33D 与 GPU℃ 曲线/右轴同色，图上分不清谁是谁
  return b;
}
function ensureCharts() {
  if (uMain) return;
  uMain = mkChart($('chMain'), MAIN_SERIES, { yRange: [0, 100], yLabel: '%', y2Range: [0, 100], y2Label: '°C', y2Color: '#E8A33D', bands: mainBands() });
  const cores = (SNAP && SNAP.cpu && SNAP.cpu.cores) || 8;
  uNet = mkChart($('chNet'), NET_SERIES, { yLabel: 'KB/s', y2Range: [0, cores], y2Label: '负载', y2Color: '#4CC3D9' });
  MAIN_SERIES.forEach((s, i) => uMain.setSeries(i + 1, { show: showState.main[i] }));
  NET_SERIES.forEach((s, i) => uNet.setSeries(i + 1, { show: showState.net[i] }));
  [$('chMain'), $('chNet')].forEach((box, i) => box.addEventListener('click', () => {
    const u = i === 0 ? uMain : uNet; const idx = u.cursor.idx;
    if (idx == null || !u.data[0][idx]) return;
    forensic(Math.round(u.data[0][idx]));
  }));
}
function sizeCharts() { if (!uMain) return; const h = chartHeight(); uMain.setSize({ width: $('chMain').clientWidth, height: h }); uNet.setSize({ width: $('chNet').clientWidth, height: h }); }
async function refreshChart() {
  let h; try { h = await getJSON('/api/history?host=' + HOST + '&window=' + win); } catch (e) { return; }
  if (!h.ok) { $('histMeta').textContent = '暂无历史（刚启动）'; return; }
  const pts = A(h.points);
  if (pts.length < 2) { $('histMeta').textContent = '历史点不足'; return; }
  const t = pts.map(p => p[0]);
  const col = i => pts.map(p => p[i] == null ? null : p[i]);
  const data = [t, col(1), col(2), col(3), col(8)];
  const data2 = [t, col(6), col(7), col(5)];
  const visible = $('t-perf').classList.contains('on');
  if (visible) ensureCharts();
  if (uMain) { uMain.setData(data); uNet.setData(data2); }
  // sparkline（DR-04）
  if (!uSpark && $('spark').clientWidth) {
    uSpark = new uPlot({ width: $('spark').clientWidth, height: 60, pxAlign: false, cursor: { show: false }, legend: { show: false }, scales: { x: { time: true }, y: { range: [0, 100] } }, axes: [{ show: false }, { show: false }], series: [{}, { stroke: '#6D8DFF', width: 1.5, fill: 'rgba(109,141,255,.14)' }] }, [[], []], $('spark'));
  }
  if (uSpark) uSpark.setData([t, col(2)]);
  const span = (pts[pts.length - 1][0] - pts[0][0]) / 60;
  $('histMeta').textContent = h.tier + ' 档 · ' + pts.length + ' 点 · 覆盖 ' + span.toFixed(0) + ' 分钟';
}
async function forensic(t) {
  const box = $('forensic'); box.classList.add('on'); $('forensicBody').textContent = '正在翻 ' + new Date(t * 1000).toLocaleString('zh-CN', { hour12: false }) + ' 的历史记录…';
  let r; try { r = await getJSON('/api/forensics?host=' + HOST + '&t=' + t); } catch (e) { $('forensicBody').textContent = '查询失败'; return; }
  if (!r.ok) { $('forensicBody').textContent = '那个时间点没有历史存档（' + (r.note || r.error || '未知') + '）'; return; }
  const m = r.match; const L = [new Date(m.t * 1000).toLocaleString('zh-CN', { hour12: false }) + '（最近存档，误差 ' + r.deltaSec + 's）',
    'CPU ' + (m.cpu == null ? '?' : m.cpu + '%') + ' · GPU ' + (m.gpu == null ? '?' : m.gpu + '%') + ' · 显存 ' + (m.gmem == null ? '?' : m.gmem + 'MiB') + ' · 下载 ' + (m.rx == null ? '?' : m.rx.toFixed(0) + 'KB/s')];
  const gpl = A(m.gproc);
  L.push(gpl.length ? '当时占显存：' + gpl.map(x => (x.c || 'pid' + x.pid).slice(0, 60) + ' [' + x.m + 'MiB]').join(' ;; ') : '当时没有进程占显存');
  const tl = A(m.top);
  if (tl.length) L.push('当时 CPU Top5：' + tl.map(x => x.u + ' ' + x.c + '% ' + String(x.k).slice(0, 42)).join(' ;; '));
  $('forensicBody').textContent = L.join('\n');
}

/* ---------- 图例（DR-19 localStorage） ---------- */
function buildLegend(elId, key, defs, hint) {
  $(elId).innerHTML = defs.map((s, i) => '<button type="button" class="lg' + (showState[key][i] ? '' : ' off') + '" data-chart="' + key + '" data-si="' + i + '" aria-label="显示/隐藏 ' + esc(s.label) + '"><i style="background:' + s.stroke + '"></i><span class="lb">' + esc(s.label) + '</span></button>').join('') + (hint || '');
}

/* ---------- 状态/告警/审计/健康（DR-13/15/26） ---------- */
function renderBanner() {
  const b = $('banner');
  if (BACKEND_DOWN) { b.className = 'on bad'; b.id = 'banner'; $('bannerIcon').innerHTML = icon('alert'); $('bannerTx').textContent = '面板后端无响应 · 距上次更新 ' + AGE + 's · 请检查面板进程'; b.classList.add('on', 'bad'); }
  else if (STALE) { b.className = 'on warn'; $('bannerIcon').innerHTML = icon('alert'); $('bannerTx').textContent = 'SSH 采集链路断开 · 距上次更新 ' + AGE + 's · 显示最后已知值'; b.classList.add('on', 'warn'); }
  else { b.classList.remove('on', 'warn', 'bad'); }
}
async function refreshStatus() {
  let s; try { s = await getJSON('/api/status'); BACKEND_DOWN = false; } catch (e) { BACKEND_DOWN = true; renderBanner(); return; }
  const me = (s.hosts || []).find(h => h.id === HOST) || {};
  const hd = $('hostDot'); if (hd) hd.className = 'hdot ' + (me.fresh ? 'ok' : (me.running ? 'warn' : 'bad'));
  if ($('hwrap').classList.contains('on')) refreshHostList();   // 管理弹窗开着时同步状态
  const act = A(s.activeAlerts);
  if (SNAP) SNAP._activeAlerts = act;
  $('alertChipTx').textContent = '规则 ' + A(BOOT.alerts).length + ' 条 · 触发 ' + act.length;
  $('alertChip').style.borderColor = act.length ? 'var(--warn)' : '';
  // 健康 4 块（DR-15）
  $('agentHealth').innerHTML = A(s.hosts).map(h => {
    const st = h.running ? stHtml('ok', '会话正常') : (String(h.exitReason || '').indexOf('idle') === 0 ? stHtml('idle', '上次随面板退出') : stHtml('bad', '会话断开'));
    return '<div class="hb"><span class="t-label">状态</span><div>' + st + '</div>' + (h.collectorHash ? '<div class="sub">采集器 ' + esc(h.collectorHash) + '</div>' : '') + '</div>' +
      '<div class="hb"><span class="t-label">样本数</span><div class="n num">' + h.samples + '</div></div>' +
      '<div class="hb"><span class="t-label">重连次数</span><div class="n num">' + h.restarts + '</div>' +
      (h.restarts > 0 && h.lastDropAt ? '<div class="sub">最近 ' + esc(String(h.lastDropAt).slice(11)) + (h.lastDropWhy ? '<br>' + esc(h.lastDropWhy) : '') + '</div>' : '') + '</div>' +
      '<div class="hb"><span class="t-label">延迟</span><div class="n num">' + (h.ageSec == null ? '—' : h.ageSec + 's') + '</div></div>';
  }).join('') || emptyHtml('nodata', '尚未开始采集', '');
  $('hdrSub').textContent = (BOOT.hosts.find(h => h.id === HOST) || {}).label + ' · ' + ((BOOT.hosts.find(h => h.id === HOST) || {}).sub || '') + ' · ' + (me.sshHost || '') + ' · 运行 ' + fmtUp(SNAP && SNAP.uptimeSec) + (me.err ? ' · ' + me.err : '');
  // 规则表（DR-26）
  const deadIds = new Set(A(me.deadRules).map(d => '' + d.id));
  $('ruleMeta').textContent = A(BOOT.alerts).length + ' 条';
  $('ruleList').innerHTML = A(BOOT.alerts).map(r => '<div class="kv"><b>' + esc(r.metric) + ' ' + esc(r.op) + ' <span class="num">' + r.threshold + '</span></b><span>' + (deadIds.has(r.id) ? pill('bad', '不会触发·指标不存在') : '') + pill(r.level === 'bad' ? 'bad' : 'warn', r.level === 'bad' ? '严重' : '预警') + ' <span class="mut">' + esc(r.text) + '</span></span></div>').join('') || emptyHtml('none', '未配置告警规则', '');
  // 告警记录（DR-15 结构化）
  let a; try { a = await getJSON('/api/alerts'); } catch (e) { return; }
  $('alMeta').textContent = A(a.events).length + ' 条';
  $('alertList').innerHTML = A(a.events).length ? A(a.events).slice().reverse().map(e => '<div class="arow"><span class="tm">' + esc(e.ts) + '</span>' + pill(e.level === 'bad' ? 'bad' : 'warn', e.level === 'bad' ? '严重' : '预警') + '<span class="x">[' + esc(e.host) + '] ' + esc(e.rule) + ' ' + esc(e.text) + '</span><span>' + (e.state === 'fired' ? pill('warn', '触发') : pill('ok', '恢复')) + '</span><button class="mini" data-locate="' + esc(e.ts) + '">定位</button></div>').join('')
    : emptyHtml('none', '当前没有触发的告警', '系统正在按 ' + A(BOOT.alerts).length + ' 条规则持续监测');
  // 审计（DR-15 结构化）
  let u; try { u = await getJSON('/api/audit'); } catch (e) { return; }
  // 过滤必须是可见的：默认隐藏测试产生的记录，但要把隐藏条数告诉用户，不默默掉数据
  if ($('auditMeta')) $('auditMeta').textContent = (u.hiddenTest ? '已隐藏 ' + u.hiddenTest + ' 条测试记录(?all=1 可查)' : '');
  $('auditList').innerHTML = A(u.events).length ? A(u.events).slice().reverse().map(e => '<div class="arow"><span class="tm">' + esc(e.ts) + '</span><span>' + esc(e.host) + '</span><span class="x">' + icon(e.act && e.act.indexOf('kill') === 0 ? 'kill' : 'sliders') + ' ' + esc(e.act) + (e.pid ? ' pid ' + e.pid : '') + (e.svc ? ' ' + esc(e.svc) : '') + '</span><span>' + auditPill(e.result) + '</span><span></span>' + (e.out ? '<details><summary>输出</summary><pre>' + esc(String(e.out).slice(0, 400)) + '</pre></details>' : '') + '</div>').join('')
    : emptyHtml('none', '还没有执行过任何动作', '');
  renderBanner();
}

/* ---------- 轮询 ---------- */
let failN = 0;
async function pollSnap(force) {
  if (document.hidden && !force) return;
  try {
    const r = await api('/api/snapshot?host=' + HOST);
    const j = await r.json();
    if (!j.ok && j.error) { STALE = true; cardStale(true); $('lastSync').textContent = '等待数据…'; renderBanner(); return; }
    if (!j.derived) j.derived = {};
    STALE = r.headers.get('X-Sample-Stale') === '1';
    const a = parseInt(r.headers.get('X-Sample-Age'), 10); AGE = isNaN(a) ? 0 : a;
    BACKEND_DOWN = false;
    render(j); failN = 0;
    cardStale(STALE);
    $('lastSync').textContent = STALE ? '数据陈旧' : '已同步 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false });
    $('liveDot').className = 'st ' + (STALE ? 'warn' : 'ok');
    renderBanner();
  } catch (e) {
    failN++; BACKEND_DOWN = true; $('liveDot').className = 'st bad'; $('lastSync').textContent = failN > 2 ? '后端无响应' : '同步中…'; renderBanner();
  }
}
function cardStale(on) { document.querySelectorAll('.card').forEach(c => c.classList.toggle('stale', !!on)); }

/* ---------- 事件绑定 ---------- */
function bind() {
  const navBtns = Array.from(document.querySelectorAll('#nav button'));
  function activate(b) {
    navBtns.forEach(x => { x.classList.remove('on'); x.setAttribute('aria-selected', 'false'); });
    document.querySelectorAll('section.tab').forEach(x => x.classList.remove('on'));
    b.classList.add('on'); b.setAttribute('aria-selected', 'true'); $('t-' + b.dataset.t).classList.add('on');
    if (b.dataset.t === 'perf') { ensureCharts(); sizeCharts(); refreshChart(); }
    if (b.dataset.t === 'alarm') refreshStatus();
  }
  navBtns.forEach(b => b.onclick = () => activate(b));
  $('nav').addEventListener('keydown', e => {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    const i = navBtns.indexOf(document.activeElement); if (i < 0) return;
    e.preventDefault(); const n = navBtns[(i + (e.key === 'ArrowRight' ? 1 : -1) + navBtns.length) % navBtns.length]; n.focus(); activate(n);
  });
  document.querySelectorAll('[data-w]').forEach(b => b.onclick = () => { document.querySelectorAll('[data-w]').forEach(x => x.classList.remove('on')); b.classList.add('on'); win = b.dataset.w; refreshChart(); });
  ['legendMain', 'legendNet'].forEach(id => $(id).addEventListener('click', e => {
    const b = e.target.closest('button.lg'); if (!b) return;
    const key = b.dataset.chart, si = Number(b.dataset.si);
    showState[key][si] = !showState[key][si]; saveShow();
    b.classList.toggle('off', !showState[key][si]);
    const u = key === 'main' ? uMain : uNet; if (u) u.setSeries(si + 1, { show: showState[key][si] });
  }));
  $('pFilter').addEventListener('input', () => { page = 0; renderProcs(); });
  $('fullPathToggle').onclick = () => { fullPath = !fullPath; localStorage.setItem('sp_fullpath', fullPath ? '1' : '0'); $('fullPathToggle').classList.toggle('on', fullPath); renderProcs(); };
  document.querySelectorAll('#pTable th[data-k]').forEach(th => th.onclick = () => { const k = th.dataset.k; if (sortK === k) sortAsc = !sortAsc; else { sortK = k; sortAsc = false; } renderProcs(); });
  document.querySelector('[data-pg=prev]').onclick = () => { if (page > 0) { page--; renderProcs(); } };
  document.querySelector('[data-pg=next]').onclick = () => { page++; renderProcs(); };
  // 结论要点跳转
  $('verdictPts').addEventListener('click', e => { const b = e.target.closest('[data-go]'); if (!b) return; const t = b.dataset.go; const nb = document.querySelector('#nav button[data-t="' + t + '"]'); if (nb) nb.click(); });
  // 服务动作（DR-14 真实命令/影响面）
  $('svcList').addEventListener('click', async e => {
    const b = e.target.closest('button'); if (!b) return;
    const id = b.dataset.svcstart || b.dataset.svcstop || b.dataset.svclog; if (!id) return;
    const h = BOOT.hosts.find(x => x.id === HOST); const s = (h.services || []).find(y => y.id === id);
    if (b.dataset.svcstart) {
      const cmd = s.kind === 'systemd' ? ('systemctl ' + (s.allowEnable ? 'enable --now ' : 'start ') + s.unit) : s.startCmd;
      if (!await uiConfirm('启动 ' + s.label, '将执行：' + cmd + '\n\n影响：' + (s.desc || '') + '\n可逆：是（可停止）', '启动')) return;
      runAct({ host: HOST, act: 'svc_start', svc: id });
    } else if (b.dataset.svcstop) {
      const cmd = s.kind === 'systemd' ? ('systemctl stop ' + s.unit) : s.stopCmd;
      if (!await uiConfirm('停止 ' + s.label, '将执行：' + cmd + '\n\n影响：' + (s.confirmStop || '停止后相关功能立即不可用。') + '\n可逆：是（可再启动，不影响开机自启）', '仍然停止', true)) return;
      runAct({ host: HOST, act: 'svc_stop', svc: id });
    } else { runAct({ host: HOST, act: 'svc_log', svc: id }); }
  });
  // 进程 kill（DR-14 就地反馈，不跳页）
  $('pTable').querySelector('tbody').addEventListener('click', async e => {
    const b = e.target.closest('button[data-kill],button[data-kill9]'); if (!b) return;
    const force = !!b.dataset.kill9;
    const pid = Number(b.dataset.kill || b.dataset.kill9);
    const p = procs().find(x => x.pid === pid) || {};
    const ok = await uiConfirm((force ? '强制结束 ' : '结束任务 ') + 'PID ' + pid,
      '将执行：' + (force ? 'kill -9 ' : 'kill -TERM ') + pid + '\n命令：' + (p.cmd || '(未知)') + '\n用户 ' + (p.user || '?') + ' · CPU ' + num(p.pcpu, 1) + '% · 已运行 ' + fmtUp(p.etimes) + '\n\n可逆：否。若是训练任务，请确认 checkpoint 已保存。', force ? '发送 SIGKILL' : '发送 SIGTERM', true);
    if (!ok) return;
    const tr = b.closest('tr'); const ops = tr.querySelector('.ops');
    ops.innerHTML = pill('warn', '执行中');
    const s = await runAct({ host: HOST, act: force ? 'kill9' : 'kill', pid }, $('svcOut'));
    const lv = !s ? 'bad' : (s.status === 'denied' ? 'bad' : (s.ok ? 'ok' : 'warn'));
    ops.innerHTML = pill(lv, !s ? '失败' : (s.status === 'denied' ? '已拒绝' : (s.ok ? '已结束' : '未结束')));
    const res = document.createElement('tr'); res.innerHTML = '<td colspan="7"><details open><summary class="mut">结果</summary><pre style="background:var(--bg-sunken);border-radius:6px;padding:8px;font-size:11px;white-space:pre-wrap">' + esc([s && s.error, s && s.text].filter(Boolean).join('\n') || '无输出') + '</pre></details></td>';
    tr.after(res);
  });
  $('alertChip').onclick = () => document.querySelector('#nav button[data-t=alarm]').click();
  $('bannerRetry').onclick = () => { pollSnap(true); refreshStatus(); refreshChart(); };
  $('forensicClose').onclick = () => $('forensic').classList.remove('on');
  $('svcOut').addEventListener('click', () => { });
  document.querySelector('[data-a=clear]').onclick = () => { $('svcOut').textContent = '(暂无执行结果)'; };
  $('hostSel') && ($('hostSel').onchange = () => switchHost($('hostSel').value));
  // 主机管理弹窗
  $('hclose').onclick = closeHostMgr;
  $('hwrap').onclick = e => { if (e.target === $('hwrap')) closeHostMgr(); };
  $('hfTest').onclick = hmTest;
  $('hfSave').onclick = hmSave;
  $('hfCancel').onclick = hmFormReset;
  $('hlist').addEventListener('click', async e => {
    const b = e.target.closest('[data-hact]'); if (!b) return;
    const id = b.dataset.hid, act = b.dataset.hact;
    const h = HM.hosts.find(x => x.id === id); if (!h) return;
    if (act === 'edit') { hmFormEdit(h); return; }
    if (act === 'toggle') {
      const r = await api('/api/hosts', { method: 'POST', body: JSON.stringify({ op: 'update', id, enabled: !h.enabled }) });
      const j = await r.json();
      if (!j.ok) { toast(j.error || '操作失败', true); return; }
      toast(h.enabled ? '已停用 ' + h.label : '已启用 ' + h.label);
      await afterHostChange();
      return;
    }
    if (act === 'del') {
      if (!await uiConfirm('删除主机 ' + h.label, '将停止该主机的采集并从配置中移除（' + h.sshHost + '）。\n历史数据文件保留。\n此操作不可逆（需重新添加）。', '删除', true)) return;
      const r = await api('/api/hosts', { method: 'POST', body: JSON.stringify({ op: 'remove', id }) });
      const j = await r.json();
      if (!j.ok) { toast(j.error || '删除失败', true); return; }
      toast('已删除 ' + h.label);
      await afterHostChange();
    }
  });
  window.addEventListener('resize', () => { sizeCharts(); if (uSpark) uSpark.setSize({ width: $('spark').clientWidth, height: 60 }); });
  const hh = (location.hash || '').replace('#', '');
  if (hh) { const b = document.querySelector('#nav button[data-t="' + hh + '"]'); if (b) setTimeout(() => b.click(), 300); }
}
function switchHost(id) {
  HOST = id; SNAP = null; page = 0;
  if (uMain) { uMain.setData([[], []]); uNet.setData([[], []]); }
  api('/api/hosts', { method: 'POST', body: JSON.stringify({ op: 'setActive', id }) }).catch(() => { });   // 持久化选择，重启后保留
  pollSnap(true); refreshChart(); refreshStatus();
}

/* ---------- 主机选择器（DR-21）+ 管理入口 ---------- */
function renderHostBox() {
  const hs = A(BOOT.hosts);
  let html;
  if (hs.length === 0) html = '<span class="host-tag">' + icon('server') + '无主机</span>';
  else if (hs.length === 1) html = '<span class="host-tag"><span class="hdot n" id="hostDot"></span>' + esc(hs[0].label) + '</span>';
  else html = '<select id="hostSel" aria-label="切换主机">' + hs.map(h => '<option value="' + esc(h.id) + '"' + (h.id === HOST ? ' selected' : '') + '>' + esc(h.label) + '</option>').join('') + '</select>';
  html += '<button id="hostManage" class="iconbtn" aria-label="主机管理" title="添加 / 管理服务器">' + icon('sliders') + '</button>';
  $('hostBox').innerHTML = html;
  if ($('hostSel')) $('hostSel').onchange = () => switchHost($('hostSel').value);
  $('hostManage').onclick = openHostMgr;
}

/* ---------- 主机管理（界面添加/编辑/启停/删除 + 连接测试，免改配置文件） ---------- */
let HM = { hosts: [], editId: null };
let _hmFocus = null, _hmKey = null, _hlistHtml = null;
function hmStatus(h) {
  if (!h.enabled) return ['n', '已禁用'];
  if (h.running && h.fresh) return ['ok', '已连接'];
  if (h.running) return ['warn', '连接中/陈旧'];
  return ['bad', '未连接'];
}
async function refreshHostList() {
  let r; try { r = await getJSON('/api/hosts'); } catch (e) { return; }
  if (!r.ok) return;
  HM.hosts = A(r.hosts);
  const html = HM.hosts.length ? HM.hosts.map(h => {
    const st = hmStatus(h);
    return '<div class="hrow">' +
      '<span class="hdot ' + st[0] + '"></span>' +
      '<div class="hi"><div class="hl">' + esc(h.label) + pill(st[0] === 'n' ? 'info' : st[0], st[1]) + '</div>' +
      '<div class="hs">' + esc(h.sshHost) + ' · 每 ' + h.intervalSec + 's' + (h.err ? ' · ' + esc(String(h.err).slice(0, 80)) : '') + '</div></div>' +
      '<div class="hops">' +
      '<button class="mini" data-hact="edit" data-hid="' + esc(h.id) + '">编辑</button>' +
      '<button class="mini" data-hact="toggle" data-hid="' + esc(h.id) + '">' + (h.enabled ? '停用' : '启用') + '</button>' +
      '<button class="mini" data-hact="del" data-hid="' + esc(h.id) + '">删除</button>' +
      '</div></div>';
  }).join('') : emptyHtml('none', '还没有服务器', '在下方填写信息添加第一台');
  // 状态未变化就不重建 DOM：否则每轮询周期会抢走焦点、重置滚动，行内按钮也来不及点
  if (html === _hlistHtml) return;
  _hlistHtml = html;
  $('hlist').innerHTML = html;
}
function openHostMgr() {
  _hmFocus = document.activeElement;
  $('hwrap').classList.add('on');
  refreshHostList();
  _hmKey = e => {
    if ($('mwrap').classList.contains('on')) return;   // 确认弹窗在上层时让它处理
    if (e.key === 'Escape') { e.preventDefault(); closeHostMgr(); }
    if (e.key === 'Tab') {
      const f = Array.from($('hwrap').querySelectorAll('button,input,select,summary')).filter(x => !x.disabled && x.offsetParent !== null);
      if (!f.length) return;
      const i = f.indexOf(document.activeElement);
      e.preventDefault(); f[(i + (e.shiftKey ? -1 : 1) + f.length) % f.length].focus();
    }
  };
  document.addEventListener('keydown', _hmKey);
  $('hfLabel').focus();
}
function closeHostMgr() {
  $('hwrap').classList.remove('on');
  if (_hmKey) document.removeEventListener('keydown', _hmKey);
  _hmKey = null;
  if (_hmFocus && _hmFocus.focus) _hmFocus.focus();
}
function hmFormReset() {
  HM.editId = null;
  $('hfTitle').textContent = '添加服务器'; $('hfSave').textContent = '添加';
  $('hfLabel').value = ''; $('hfSsh').value = ''; $('hfInterval').value = '3'; $('hfSub').value = '';
  $('hfEnabled').checked = true;
  $('hfOut').hidden = true; $('hfOut').textContent = ''; $('hfErr').textContent = '';
}
function hmFormEdit(h) {
  HM.editId = h.id;
  $('hfTitle').textContent = '编辑 ' + h.label; $('hfSave').textContent = '保存修改';
  $('hfLabel').value = h.label; $('hfSsh').value = h.sshHost; $('hfInterval').value = h.intervalSec; $('hfSub').value = h.sub || '';
  $('hfEnabled').checked = !!h.enabled;
  $('hfOut').hidden = true; $('hfErr').textContent = '';
  $('hfLabel').focus();
}
function hmGenId(ssh) {
  const host = ssh.split('@').pop();
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  let base = m ? 'host-' + m[4] : (host.toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 24) || 'host');
  let id = base, n = 2;
  const taken = new Set(HM.hosts.map(h => h.id));
  while (taken.has(id)) { id = base + '-' + n; n++; }
  return id;
}
async function hmTest() {
  const ssh = $('hfSsh').value.trim();
  $('hfErr').textContent = '';
  if (!/^(?!-)[A-Za-z0-9_.@-]{1,128}$/.test(ssh)) { $('hfErr').textContent = 'SSH 目标格式非法：只允许字母/数字/_ . @ -（别名或 user@IP），不能以 - 开头'; return; }
  const out = $('hfOut'); out.hidden = false; out.textContent = '正在测试连接 ' + ssh + ' …（最长 18s）';
  $('hfTest').disabled = true;
  try {
    const r = await api('/api/action', { method: 'POST', body: JSON.stringify({ act: 'sshTest', sshHost: ssh }) });
    const j = await r.json();
    if (!j.id) { out.textContent = '未受理: ' + (j.error || ''); return; }
    for (let i = 0; i < 35; i++) {
      await sleep(600);
      let s; try { s = await getJSON('/api/action?id=' + j.id); } catch (e) { continue; }
      if (s.status === 'running') { out.textContent = '正在测试连接 ' + ssh + ' … (' + Math.round(i * 0.6) + 's)'; continue; }
      if (s.ok) { out.textContent = '连接成功\n' + (s.text || ''); toast('连接成功'); }
      else { out.textContent = '连接失败\n' + (s.error || s.text || '') + (s.hint ? '\n\n' + s.hint : ''); toast('连接失败', true); }
      return;
    }
    out.textContent = '测试超时，动作可能仍在执行';
  } finally { $('hfTest').disabled = false; }
}
async function hmSave() {
  const label = $('hfLabel').value.trim(), ssh = $('hfSsh').value.trim();
  const iv = parseInt($('hfInterval').value, 10);
  $('hfErr').textContent = '';
  if (!label) { $('hfErr').textContent = '请填写显示名'; return; }
  if (!/^(?!-)[A-Za-z0-9_.@-]{1,128}$/.test(ssh)) { $('hfErr').textContent = 'SSH 目标格式非法：只允许字母/数字/_ . @ -（别名或 user@IP），不能以 - 开头'; return; }
  if (!(iv >= 1 && iv <= 300)) { $('hfErr').textContent = '采集间隔需 1-300 秒'; return; }
  const body = HM.editId
    ? { op: 'update', id: HM.editId, label, sshHost: ssh, intervalSec: iv, sub: $('hfSub').value.trim(), enabled: $('hfEnabled').checked }
    : { op: 'add', id: hmGenId(ssh), label, sshHost: ssh, intervalSec: iv, sub: $('hfSub').value.trim(), enabled: $('hfEnabled').checked };
  $('hfSave').disabled = true;
  try {
    const r = await api('/api/hosts', { method: 'POST', body: JSON.stringify(body) });
    const j = await r.json();
    if (!j.ok) { $('hfErr').textContent = j.error || '保存失败'; return; }
    toast(HM.editId ? '已保存' : '已添加，采集自动开始');
    await afterHostChange();
    hmFormReset();
  } finally { $('hfSave').disabled = false; }
}
async function afterHostChange() {
  try { BOOT = await getJSON('/api/boot'); TOKEN = BOOT.token; } catch (e) { return; }
  const hs = A(BOOT.hosts);
  if (!hs.find(h => h.id === HOST)) {
    HOST = BOOT.active || (hs[0] && hs[0].id) || null; SNAP = null;
    if (uMain) { uMain.setData([[], []]); uNet.setData([[], []]); }
  }
  renderHostBox();
  await refreshHostList();
  pollSnap(true); refreshChart(); refreshStatus();
}

/* ---------- 启动 ---------- */
(async function boot() {
  hydrateIcons();
  let b;
  try { b = await fetch('/api/boot'); BOOT = await b.json(); }
  catch (e) { $('hdrSub').textContent = '面板后端没起来：' + e; BACKEND_DOWN = true; renderBanner(); return; }
  if (!BOOT.ok) { $('hdrSub').textContent = BOOT.error; return; }
  TOKEN = BOOT.token; HOST = BOOT.active;
  renderHostBox();
  $('fullPathToggle').classList.toggle('on', fullPath);
  const bh = BOOT.hosts.find(h => h.id === HOST);
  $('hdrSub').textContent = bh ? bh.label + ' · ' + (bh.sub || '') : '还没有主机 · 点右上角「主机管理」添加服务器';
  buildLegend('legendMain', 'main', MAIN_SERIES, '<span class="mut">· 点图例开关曲线 · 点图上某点取证</span>');
  buildLegend('legendNet', 'net', NET_SERIES, '');
  bind();
  await pollSnap(true);
  refreshChart(); refreshStatus();
  setInterval(pollSnap, 3000);
  setInterval(refreshChart, 8000);
  setInterval(refreshStatus, 6000);
})();