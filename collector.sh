#!/usr/bin/env bash
# ============================================================================
#  ServerPanel v4 · 远端采集器 (schema sp2)
#  零安装依赖：bash + jq + coreutils + procps + iproute2 (+ nvidia-smi 可选)
#  协议：stdout 每行一个 compact JSON；一行 = 一个样本
#  设计约束：任何一项采集失败 => 字段显式 null 并写入 errors[]，绝不降级成 0
#  用法：  PANEL_UNITS="ollama" PANEL_PATTERNS="opensquilla gateway run" \
#          bash collector.sh <interval_sec>        # 常驻流式
#          PANEL_ONCE=1 bash collector.sh          # 单样本（调试）
# ============================================================================
export LC_ALL=C.UTF-8   # P1-8：UTF-8 让中文命令行原样保留（C 会把非 ASCII 打成 ?）；C.UTF-8 数字仍用 C 约定，awk/sort 不受影响
export COLUMNS=8192
INTERVAL="${1:-3}"
PANEL_UNITS="${PANEL_UNITS:-}"
PANEL_PATTERNS="${PANEL_PATTERNS:-}"
ONCE="${PANEL_ONCE:-0}"

arr()  { local v="${1:-}"; if [ -n "$v" ] && printf '%s' "$v" | jq -e 'type=="array"' >/dev/null 2>&1; then printf '%s' "$v"; else printf '[]'; fi; }
# 与 arr() 同理但期望对象；忘了换用 obj 会把整个字段变成空默认值(procs 改形状时踩过)
obj()  { local v="${1:-}"; if [ -n "$v" ] && printf '%s' "$v" | jq -e 'type=="object"' >/dev/null 2>&1; then printf '%s' "$v"; else printf '{"total":0,"list":[]}'; fi; }
errs=""
fail() { errs="${errs}\"$(printf '%s' "${1:-unknown}" | tr -d '\n\r"\\')\","; }

# 环回地址判定。早期实现是 grep -v '::1' 子串匹配，实测会把
# [2001:db8::1]:443(全球单播) 与 [fe80::1]:22(链路本地) 一并误杀——只有 IPv4 能活下来。
# 这里只排除真正的 loopback：127/8 与 ::1。
is_loopback() {
  # 不做任何削位剖分，直接对 ss 输出的 "addr:port" 形态做前缀判定：
  # IPv4 环回是 127.x，IPv6 环回在 ss 里永远写为 [::1]:port。
  # 注意：单引号里的反斜杠是字面量，写 '\[::1\]' 会永远匹配不上(本轮踩过)。
  case "$1" in
    127.*|'[::1]'*|'::1'|localhost|localhost.*|localhost:*|'[localhost]:*') return 0 ;;
  esac
  return 1
}

# 外连管线。单独成函数是为了能用构造样本做单测：真实 established 连接不可控，
# 而列位错一位就会"成功"返回空数组，界面静默零数据。
# 关键事实：ss 带 `state established` 时不再输出 State 列(NF=4)，Local/Peer 在 $3/$4；
# 旧代码取 $4" "$5 使第二个字段为空，jq 的 capture 永不匹配 -> conns 恒为空。
conns_filter() {
  tail -n +2 | awk 'NF >= 4 {print $3" "$4}' \
    | while read -r l r; do is_loopback "$l" && continue; is_loopback "$r" && continue; printf '%s %s\n' "$l" "$r"; done \
    | sort | uniq -c | sort -rn | head -30 \
    | jq -R -s 'split("\n")|map(select(.!="")|capture("^\\s*(?<n>[0-9]+)\\s+(?<l>\\S+)\\s+(?<r>\\S+)$")|{n:(.n|tonumber),local:.l,remote:.r})' 2>/dev/null
}

emit() {
  # 每个样本的错误集必须独立：顶层只清一次会让 fail() 累积的字符串永久残留，
  # errors[] 会逐周期增长(实测 1,2,3,...)，把快照撑大并让界面长期假红。
  # bash 的 local 是动态作用域，故 emit 内部的 fail() 写的就是这个局部变量。
  local errs=""

  # Linux 单个命令行参数长度上限 128KB (MAX_ARG_STRLEN)，大数组必须走临时文件而不是 --argjson
  TD=$(mktemp -d /tmp/sp.XXXXXX) || TD="/tmp/sp.$$"; mkdir -p "$TD" 2>/dev/null
  # ---------- GPU（P1-9 多卡：gpus[] 数组，gpu 保留第一张兼容） ----------
  gpu_csv=$(nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,uuid --format=csv,noheader,nounits 2>/dev/null)
  gpus_json="[]"
  if [ -n "$gpu_csv" ]; then
    gpus_json=$(printf '%s\n' "$gpu_csv" | jq -R -s 'split("\n")|map(select(.!="")|capture("^\\s*(?<idx>[0-9]+),\\s*(?<name>.*?),\\s*(?<util>[0-9]+),\\s*(?<used>[0-9]+),\\s*(?<tot>[0-9]+),\\s*(?<temp>[0-9]+),\\s*(?<pow>[0-9.]+),\\s*(?<uuid>\\S+)\\s*$")|{index:(.idx|tonumber),name:.name,util:(.util|tonumber),memUsedMiB:(.used|tonumber),memTotalMiB:(.tot|tonumber),tempC:(.temp|tonumber),powerW:(.pow|tonumber),uuid:.uuid})' 2>/dev/null)
    [ -n "$gpus_json" ] || gpus_json="[]"
  else
    e=$(nvidia-smi 2>&1 | head -1 | cut -c1-100 | tr -d '\n\r')
    fail "gpu:${e:-no_output}"
  fi
  gpu_apps_all=$(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null \
    | jq -R -s 'split("\n")|map(select(.!="")|capture("^\\s*(?<pid>[0-9]+),\\s*(?<mem>[0-9]+),\\s*(?<uuid>\\S+)\\s*$")|{pid:(.pid|tonumber),memMiB:(.mem|tonumber),uuid:.uuid})' 2>/dev/null)
  [ -n "$gpu_apps_all" ] || gpu_apps_all="[]"
  # 进程按 gpu_uuid 挂到各卡
  gpus_json=$(jq -cn --argjson g "$gpus_json" --argjson a "$gpu_apps_all" '($a|group_by(.uuid)|map({(.[0].uuid):.})|add // {}) as $by | $g|map(. + {procs:($by[.uuid] // []|map({pid,memMiB}))})' 2>/dev/null)
  [ -n "$gpus_json" ] || gpus_json="[]"

  # ---------- CPU / 内存 / 负载 ----------
  cpu_stat=$(head -1 /proc/stat | tr -s ' ' | cut -d' ' -f2-)
  cores=$(nproc 2>/dev/null)
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
  upt=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
  mem=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{printf "%d %d %d %d", t*1024,(t-a)*1024,st*1024,(st-sf)*1024}' /proc/meminfo 2>/dev/null)
  [ -n "$mem" ] || fail meminfo

  # ---------- 磁盘（真实挂载，排除 tmpfs/loop/overlay） ----------
  disk=$(df -B1 --local --output=source,size,used,avail,target 2>/dev/null | tail -n +2 \
    | jq -R -s 'split("\n")|map(select(.!="")|capture("^\\s*(?<src>\\S+)\\s+(?<size>[0-9]+)\\s+(?<used>[0-9]+)\\s+(?<avail>[0-9]+)\\s+(?<mp>\\S.*)$")|select(.src|test("^(tmpfs|devtmpfs|none|overlay|/dev/loop)")|not)|select(.mp|test("^/(sys|proc|run)")|not)|{src:.src,total:(.size|tonumber),used:(.used|tonumber),avail:(.avail|tonumber),mp:(.mp|sub("^\\s+";"")|sub("\\s+$";""))})' 2>/dev/null)
  [ -n "$disk" ] || fail disk

  # ---------- 网络累计 ----------
  net=$(awk 'NR>2 && $1!="lo:"{gsub(/:/,"",$1); r+=$2; s+=$10} END{printf "%d %d", r+0, s+0}' /proc/net/dev 2>/dev/null)

  # ---------- 进程（全量，不截断到 Top N；单条命令限长，总量上限保护） ----------
  procs=$(ps -eo pid=,user=,pcpu=,pmem=,etimes=,args= --sort=-pcpu -ww --no-headers 2>/dev/null \
    | tr -d '\000' | tr '\t' ' ' \
    | jq -R -s 'split("\n")|map(select(test("^[[:space:]]*[0-9]+[[:space:]]"))|capture("^\\s*(?<pid>[0-9]+)\\s+(?<user>\\S+)\\s+(?<pcpu>[-0-9.]+)\\s+(?<pmem>[-0-9.]+)\\s+(?<etimes>[0-9]+)\\s*(?<cmd>.*)$")|{pid:(.pid|tonumber),user:.user,pcpu:(.pcpu|tonumber? // 0),pmem:(.pmem|tonumber? // 0),etimes:(.etimes|tonumber? // 0),cmd:(.cmd[0:400])}) as $all | {total:($all|length), list:($all[0:1500])}' 2>/dev/null)
  [ -n "$procs" ] || fail ps
  # DR-29：真实进程总数（procs 截断到 1500，标题口径需对齐）
  # procTotal 与 procCount 必须同源于上面那一次 ps：另开一次 ps 会让两个数来自不同时刻
  # (实测出现过 procTotal 488 < procCount 489 的跳变)，还白多一次 fork。总数已放在 procs.total。
  proc_total=""
  # DR-27：是否 root（ss -tlnp 非 root 拿不到端口归属，需区分「无权限」与「无进程」）
  is_root=$(id -u 2>/dev/null || echo 1)

  users=$(who 2>/dev/null | awk '{c[$1]++}END{for(u in c)printf "%s %d\n",u,c[u]}' \
    | jq -R -s 'split("\n")|map(select(.!="")|capture("^(?<u>\\S+) (?<n>[0-9]+)$")|{user:.u,n:(.n|tonumber)})' 2>/dev/null)

  conns=$(ss -tn state established 2>/dev/null | conns_filter)

  # ---------- 监听端口 + 归属进程 ----------
  ports_json=$(ss -tlnpH 2>/dev/null | awk '{p=""; for(i=5;i<=NF;i++) if($i ~ /^users:/) p=$i; print $4" "p}' | sort -u \
    | jq -R -s 'split("\n")|map(select(.!="")|capture("^(?<addr>\\S+)\\s*(?<own>.*)$")|{addr:.addr, proc:(.own|if test("\"") then (capture("\"(?<p>[^\"]+)\"")|.p) else null end)})|group_by(.addr)|map({addr:.[0].addr,procs:(map(.proc|select(.!=null))|unique)})|{total:length, list:.[0:80]}' 2>/dev/null)

  # ---------- systemd 服务 ----------
  svcs=$(for u in $PANEL_UNITS; do
    a=$(systemctl is-active "$u" 2>/dev/null); e2=$(systemctl is-enabled "$u" 2>/dev/null)
    printf '%s|%s|%s\n' "$u" "${a:-unknown}" "${e2:-unknown}"
  done | jq -R -s 'split("\n")|map(select(.!="")|split("|")|{unit:.[0],state:.[1],enabled:.[2]})' 2>/dev/null)

  # ---------- 非 systemd 服务（pgrep 模式匹配，PANEL_PATTERNS 每行一条，可含空格） ----------
  ptn=$(while IFS= read -r p; do
    [ -z "$p" ] && continue
    n=$(pgrep -f -- "$p" 2>/dev/null | wc -l | tr -d ' ')
    printf '%s\t%s\n' "$p" "${n:-0}"
  done <<< "$PANEL_PATTERNS" \
    | jq -R -s 'split("\n")|map(select(.!="")|capture("^(?<p>.*)\\t(?<n>[0-9]+)$")|{pattern:.p,n:(.n|tonumber),state:(if (.n|tonumber)>0 then "running" else "stopped" end)})' 2>/dev/null)

  tofile() { printf '%s' "$(arr "$2")" > "$TD/$1"; }
  # procs 不再是裸数组而是 {total,list}，arr() 只认数组，必须单独写（并带形状兜底）
  printf '%s' "${procs:-}" | jq -c 'if (type=="object" and (.list|type)=="array") then {total:(.total//(.list|length)), list:.list} else {total:0, list:[]} end' > "$TD/procs"

  jq -cn \
    --argjson ts "$(date +%s)" \
    --arg     host "$(hostname 2>/dev/null)" \
    --arg     isroot "$is_root" \
    --argjson gpus "$(arr "$gpus_json")" \
    --argjson gapps "$(arr "$gpu_apps_all")" \
    --arg     cpu_stat "$cpu_stat" --arg cores "$cores" --arg load "$load" \
    --arg     upt "$upt" --arg mem "$mem" \
    --argjson disk "$(arr "$disk")" --arg net "$net" \
    --slurpfile procsF "$TD/procs" --argjson users "$(arr "$users")" \
    --argjson conns "$(arr "$conns")" --argjson portsO "$(obj "$ports_json")" \
    --argjson svcs "$(arr "$svcs")" --argjson ptn "$(arr "$ptn")" \
    --argjson errs "[${errs%,}]" \
    'def num: if . == "" or . == null then null else (. | tonumber?) end;
     ($cpu_stat | split(" ") | map(tonumber?)) as $cs |
     ($load | split(" ") | map(tonumber?)) as $ld |
     ($mem  | split(" ") | map(tonumber?)) as $mm |
     ($net  | split(" ") | map(tonumber?)) as $nn |
      (($gapps // []) | map({(.pid|tostring): .memMiB}) | add // {}) as $gpum |
      (($procsF[0].list) // []) as $pl |
      ($pl | map(. + {gpuMemMiB: ($gpum[.pid|tostring] // null)})) as $procs |
     (($procsF[0].total) // 0) as $ptrue |
     ($gpus[0] // {}) as $g0 |
     {schema:"sp2", ts:$ts, host:$host, errors:$errs,
      gpu:{present:(($gpus|length)>0), name:($g0.name // ""),
           util:($g0.util // null), memUsedMiB:($g0.memUsedMiB // null), memTotalMiB:($g0.memTotalMiB // null),
           tempC:($g0.tempC // null), powerW:($g0.powerW // null), procs:($g0.procs // [])},
      gpus:$gpus,
      cpu:{stat:$cs, cores:($cores|num), load1:$ld[0], load5:$ld[1], load15:$ld[2]},
      mem:{total:$mm[0], used:$mm[1], swapTotal:$mm[2], swapUsed:$mm[3]},
      disk:$disk, net:{rx:$nn[0], tx:$nn[1]}, uptimeSec:($upt|num),
      procs:$procs, procCount:($procs|length), procTotal:$ptrue, isRoot:(($isroot|tonumber)==0),
      users:$users, conns:$conns, ports:$portsO.list, portsTotal:($portsO.total // 0),
      services:$svcs, patterns:$ptn }'
  local rc=$?            # 必须在 rm 之前取：否则 rm 的退出码会盖掉 jq 的 EPIPE
  rm -rf "$TD" 2>/dev/null
  return $rc
}

if [ "${PANEL_LIB:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi   # 单测用 source 接缝：只取函数，不起采集循环
if [ "$ONCE" = "1" ]; then emit; exit 0; fi
# 关键：写 stdout 失败（本地 ssh 被杀、管道断开）必须立即退出。
# 写成 `emit || fail emit` 会把 EPIPE 吞掉，导致远端以 INTERVAL 频率永久空转，污染服务器。
trap 'exit 0' PIPE
while :; do
  emit || exit 1
  sleep "$INTERVAL" || exit 1
done
