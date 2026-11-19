# app.js 呈现单元单测（node 直接执行抠出来的真实代码，不靠浏览器）
# 1) auditPill：action.ps1 的审计结果值 -> 可读徐章（ok/denied/self_fail:MARK/rc=N）
# 2) 采集健康卡片渲染：collectorHash / 断线痕迹 / 字段缺失时不抛错 / 远端来源文本必须转义
# 之所以用「抠函数体」而不是起浏览器：这些是纯字符串装配，最容易在数据形状变化时静默抛错，
# 而 E2E 只测 API 层——上几轮就出现过 API 全绿但渲染路径会炸的情况。
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tmp = Join-Path $env:TEMP 'zzapprender.js'
@'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
let bad = 0;
const OK = (n, d) => console.log('PASS  ' + n + (d ? '  ' + d : ''));
const NO = (n, d) => { bad++; console.log('FAIL  ' + n + (d ? '  ' + d : '')); };

// 共用桩
const pill = (lv, tx) => '<span class="pill ' + lv + '">' + tx + '</span>';
const stHtml = (lv, tx) => '<span class="st ' + lv + '">' + tx + '</span>';
const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

'--- 1. auditPill ---';
const m1 = src.match(/function auditPill\(r\)[\s\S]*?\n\}/);
if (!m1) NO('抠不到 auditPill');
else {
  eval(m1[0]);
  const cases = [
    ['ok', '成功'], ['denied', '已拒绝'],
    ['self_fail:FAIL', '自报失败 FAIL'], ['self_fail:WARN', '自报失败 WARN'],
    ['rc=255', '远端 rc=255'],
  ];
  for (const [inp, want] of cases) {
    const got = auditPill(inp);
    if (!got.includes(want)) NO('auditPill(' + inp + ')', got);
    else OK('auditPill ' + JSON.stringify(inp), '-> ' + got.replace(/<[^>]+>/g, ''));
  }
  const x = auditPill('<img src=x onerror=alert(1)>');
  if (x.includes('<img')) NO('未知结果串未转义', x); else OK('未知结果串已转义');
}

'--- 2. 采集健康卡片 ---';
const m2 = src.match(/A\(s\.hosts\)\.map\(h => \{([\s\S]*?)\n {2}\}\)\.join\(''\)/);
if (!m2) NO('抠不到 agentHealth 渲染体');
else {
  const render = new Function('h', 'stHtml', 'pill', 'esc', m2[1]);
  const run = h => render(h, stHtml, pill, esc);

  let out;
  try {
    out = run({ running: true, samples: 12, restarts: 2, ageSec: 3, collectorHash: '74b85daf8dbd', lastDropAt: '2026-11-18T09:29:38', lastDropWhy: 'ssh 退出 rc=1' });
  } catch (e) { out = null; NO('渲染抛错', e.message); }
  if (out) {
    if (out.includes('采集器 74b85daf8dbd')) OK('显示生效的采集器版本'); else NO('未显示 collectorHash', out.slice(0, 160));
    if (out.includes('最近 09:29:38')) OK('显示断线时刻'); else NO('未显示断线时刻');
    if (out.includes('ssh 退出 rc=1')) OK('显示断线原因'); else NO('未显示断线原因');
    if (out.includes('会话正常')) OK('运行态文案'); else NO('运行态文案缺失');
    const subs = (out.match(/class="sub"/g) || []).length;
    if (subs === 2) OK('副信息块数量正确(采集器+断线各一)', 'sub=' + subs); else NO('副信息块数量异常', 'sub=' + subs);
  }

  // 字段缺失（老 agent 没写 collectorHash / 从未断线）不得抛错、不得出现 undefined
  try {
    const o2 = run({ running: false, exitReason: 'idle_heartbeat_lost', samples: 0, restarts: 0, ageSec: null });
    if (o2.includes('undefined')) NO('字段缺失时渲染出 undefined', o2.slice(0, 200));
    else if (o2.includes('null')) NO('未采集到时延迟字面量直出 null', o2.slice(0, 200));
    else if (o2.includes('上次随面板退出')) OK('字段缺失时安全降级(无 undefined / 无裸 null)');
    else NO('缺少退出原因文案', o2.slice(0, 200));
    if (o2.includes('采集器')) NO('无 hash 时不应出现采集器行'); else OK('无 hash 时不渲染采集器行');
  } catch (e) { NO('字段缺失时渲染抛错', e.message); }

  // 远端来源文本必须转义（lastDropWhy 来自 ssh stderr，属不可信输入）
  try {
    const o3 = run({ running: true, samples: 1, restarts: 1, ageSec: 1, lastDropAt: '2026-11-18T09:29:38', lastDropWhy: '<img src=x onerror=alert(1)>' });
    if (o3.includes('<img')) NO('断线原因未转义，存在注入面', o3.slice(0, 200)); else OK('断线原因已转义');
  } catch (e) { NO('转义用例渲染抛错', e.message); }
}

console.log('--- app.js 呈现单元: ' + (bad ? bad + ' 个失败' : '全部通过') + ' ---');
process.exit(bad ? 1 : 0);
'@ | Set-Content -LiteralPath $tmp -Encoding UTF8
& node $tmp (Join-Path $root 'app.js')
exit $LASTEXITCODE
