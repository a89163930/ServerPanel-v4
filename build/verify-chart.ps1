# DR-32 图表像素级校验：无头同源 iframe，断言每条曲线真的有像素，且像素可归属到该曲线。
# 用法: pwsh -File build/verify-chart.ps1    （需面板已在 48732 运行）
#
# 两个用实测换来的设计约束：
#  1) 期望颜色一律现场从 app.js 解析，绝不硬编码——硬编码与配色漂移时会静默失真。
#  2) 单靠「数某色像素」不可归属：橙色同时是 GPU℃ 曲线和右侧 y2 轴的颜色(#E8A33D)，
#     实测藏掉曲线后计数反而变大。因此温度必须做「点图例前/后」的同轮差分。
param([switch]$NoToggle)   # 跳过图例差分(仅当无头环境点不动时用)，会降级为纯计数校验
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$B = 'http://127.0.0.1:48732'
try { $null = Invoke-RestMethod "$B/api/boot" -TimeoutSec 6 } catch { 'BLOCKED 面板没起来，无法做像素校验'; exit 2 }

$jsSrc = [IO.File]::ReadAllText((Join-Path $root 'app.js'), [Text.UTF8Encoding]::new($false))
function Get-SeriesColor([string]$src, [string]$label) {
  $m = [regex]::Match($src, "label:\s*'" + [regex]::Escape($label) + "',\s*stroke:\s*'#([0-9A-Fa-f]{6})'")
  if (-not $m.Success) { return $null }
  $h = $m.Groups[1].Value
  return @([Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16))
}
$want = [ordered]@{ cpu = 'CPU %'; mem = '显存 %'; temp = 'GPU ℃'; rx = '下载 KB/s' }
$colors = [ordered]@{}; $miss = @()
foreach ($k in $want.Keys) {
  $c = Get-SeriesColor $jsSrc $want[$k]
  if ($c) { $colors[$k] = $c } else { $miss += "$k/$($want[$k])" }
}
if ($miss) { "FAIL 无法从 app.js 解析曲线颜色: $($miss -join ', ')（标签或 stroke 写法变了，门需同步）"; exit 1 }
# 同一张图内被测曲线必须异色，否则计数无法归属（本轮就是靠这条查出 ℃ 与右轴撞色）
$dup = @($colors.cpu, $colors.mem, $colors.temp) | ForEach-Object { $_ -join ',' } | Group-Object | Where-Object { $_.Count -gt 1 }
if ($dup) { "FAIL 主图这几条被测曲线同色，像素无法归属: $(($dup.Name) -join ' / ')"; exit 1 }

$html = @'
<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<div id="out">waiting</div><iframe id="fr" src="/#perf" style="width:1280px;height:900px;border:0"></iframe>
<script src="/vendor/_cv.js"></script></body></html>
'@
$js = @'
'use strict';
var out=[],COL=__COL__,NOTOG=__NOTOG__;
function log(k,v){out.push(k+'='+v);}
function px(cv,rgb){try{
 var w=cv.width,h=cv.height,d=cv.getContext('2d').getImageData(0,0,w,h).data,n=0,x0=60,x1=w-60;
 for(var y=0;y<h;y++){for(var x=x0;x<x1;x++){var i=(y*w+x)*4;
  if(d[i+3]>=100&&Math.abs(d[i]-rgb[0])<=14&&Math.abs(d[i+1]-rgb[1])<=14&&Math.abs(d[i+2]-rgb[2])<=14)n++;}}
 return n;}catch(e){return -1;}}
var tries=0,settled=false;
function measure(cm,cn){
 log('mainW',cm.width);log('netW',cn.width);
 log('cpuPx',px(cm,COL.cpu));log('memPx',px(cm,COL.mem));log('rxPx',px(cn,COL.rx));
 log('tempOnPx',px(cm,COL.temp));
 var btn=null,nodes=cm.ownerDocument.querySelectorAll('#legendMain .lg');
 nodes.forEach(function(b){ if((b.dataset.si||'')==='3') btn=b; });
 if(!btn){log('legendBtn','MISSING');return finish();}
 btn.click();
 setTimeout(function(){
   log('tempOffPx',px(cm,COL.temp));
   log('legendOff',(btn.className||'').indexOf('off')>=0?1:0);
   btn.click(); finish();
 },900);
}
function finish(){document.getElementById('out').textContent=out.join('|');document.title='done';}
function step(){var f=document.getElementById('fr'),doc;
 try{doc=f.contentDocument;}catch(e){log('iframe','ERR');return finish();}
 if(!doc)return retry();
 var cm=doc.querySelector('#chMain canvas'),cn=doc.querySelector('#chNet canvas');
 if(!cm||!cn||cm.width<100)return retry();
 if(!settled){settled=true;return setTimeout(step,2500);}
 if(NOTOG){log('mainW',cm.width);log('netW',cn.width);log('cpuPx',px(cm,COL.cpu));log('memPx',px(cm,COL.mem));log('rxPx',px(cn,COL.rx));log('tempOnPx',px(cm,COL.temp));log('tempOffPx','skip');return finish();}
 measure(cm,cn);}
function retry(){if(++tries>50){log('timeout',1);return finish();}setTimeout(step,400);}
setTimeout(step,1500);
'@
$jsonCols = '{' + (($colors.Keys | ForEach-Object { $_ + ':[' + ($colors[$_] -join ',') + ']' }) -join ',') + '}'
$js = $js.Replace('__COL__', $jsonCols).Replace('__NOTOG__', $(if ($NoToggle) { 'true' } else { 'false' }))
Set-Content -LiteralPath (Join-Path $root 'vendor\_cv.html') -Value $html -Encoding UTF8
Set-Content -LiteralPath (Join-Path $root 'vendor\_cv.js') -Value $js -Encoding UTF8

$edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe','C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { 'BLOCKED 找不到 Edge，无法做像素校验'; exit 2 }
$ud = Join-Path $env:TEMP ('cvprof' + (Get-Random))   # 一次性 profile：避免复用已运行的 Edge，也避免泄漏
$o = Join-Path $root 'log\verify-chart.html'
Remove-Item $o -ErrorAction SilentlyContinue
try {
  Start-Process $edge -ArgumentList @('--headless=new','--disable-gpu','--no-first-run','--no-proxy-server',"--user-data-dir=$ud",'--window-size=1280,1060','--virtual-time-budget=30000','--dump-dom',"$B/vendor/_cv.html") -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError (Join-Path $root 'log\verify-chart.err')
  for ($i=0;$i -lt 25;$i++){ Start-Sleep -Seconds 2; if ((Get-Item $o -ErrorAction SilentlyContinue).Length -gt 300){break} }
  Start-Sleep -Seconds 2
  $t = Get-Content $o -Raw -Encoding UTF8
  $m = [regex]::Match($t,'id="out"[^>]*>(.*?)</div>')
  $kv = @{}; foreach($p in ($m.Groups[1].Value -split '\|')){ $k,$v = $p -split '=',2; $kv[$k]=$v }
  $fail = 0
  if ($kv['timeout']) { $fail++; 'FAIL 验证页超时：图表始终没出画布' }
  foreach($k in 'mainW','netW'){ if([int]$kv[$k] -le 0){ $fail++; "FAIL $k=$($kv[$k])（画布未成尺寸）" } }
  $minPx = @{ cpu = 200; mem = 200; rx = 200; temp = 200 }
  foreach($k in 'cpu','mem','rx'){ $v=[int]$kv[$k+'Px']; if ($v -lt $minPx[$k]) { $fail++; "FAIL $k 像素=$v(<$($minPx[$k])) 该曲线可能没画出来" } }
  $on = [int]$kv['tempOnPx']
  if ($on -lt $minPx.temp) { $fail++; "FAIL temp 像素=$on(<$($minPx.temp)) 温度曲线可能没画出来" }
  if ('' + $kv['tempOffPx'] -ne 'skip') {
    $off = [int]$kv['tempOffPx']
    # 真正的归属证明：点掉图例后这些像素必须显著消失，否则说明数到的不是这条曲线
    if ('' + $kv['legendOff'] -ne '1') { $fail++; 'FAIL 点图例后未进入 off 态（DR-19 图例开关失效）' }
    if (($on - $off) -lt 120) { $fail++; "FAIL 温度像素不可归属: 点前=$on 点后=$off 差仅$($on-$off)（同色轴/带污染了计数）" }
  }
  if ($fail -eq 0) { "PASS 图表像素校验 main=$($kv.mainW) cpu=$($kv.cpuPx) mem=$($kv.memPx) rx=$($kv.rxPx) temp=$on→$($kv.tempOffPx)(图例关)" }
  exit $fail
} finally {
  Remove-Item (Join-Path $root 'vendor\_cv.html'),(Join-Path $root 'vendor\_cv.js') -Force -ErrorAction SilentlyContinue
  Remove-Item $ud -Recurse -Force -ErrorAction SilentlyContinue   # 实测曾泄漏 3 个目录/35MB
}
