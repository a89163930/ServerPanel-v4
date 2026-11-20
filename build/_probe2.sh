export LC_ALL=C
export COLUMNS=4096
UNITS="ollama opensquilla-gateway"
PATTERNS="opensquilla gateway run"

str() { if [ -z "$1" ]; then echo "null"; else printf '%s' "$1" | jq -Rs .; fi; }

GPU=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
GPU_ERR=""
[ -n "$GPU" ] || GPU_ERR=$(nvidia-smi 2>&1 | head -1 | tr -d '\n')

IFS=',' read -r G_UTIL G_MEMU G_MEMT G_TEMP G_POW <<EOF
$GPU
EOF

STAT=$(head -1 /proc/stat | tr -s ' ' | cut -d' ' -f2- | tr ' ' ',')
PROC=$(ps -eo pid=,user=,pcpu=,pmem=,etimes=,args= --sort=-pcpu -ww --no-headers 2>/dev/null \
 | tr -d '\000' | tr '\t' ' ' \
 | jq -R -s 'split("\n") | map(select(test("^[[:space:]]*[0-9]+[[:space:]]"))) | map(capture("^\\s*(?<pid>[0-9]+)\\s+(?<user>\\S+)\\s+(?<pcpu>[-0-9.]+)\\s+(?<pmem>[-0-9.]+)\\s+(?<etimes>[0-9]+)\\s+(?<cmd>.*)$") | {pid:(.pid|tonumber),user:.user,pcpu:(.pcpu|tonumber),pmem:(.pmem|tonumber),etimes:(.etimes|tonumber),cmd:.cmd}))')

GPUAPPS=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | jq -R -s 'split("\n") | map(select(.!="") | capture("^(?<pid>[0-9]+),\\s*(?<mem>[0-9]+)$") | {pid:(.pid|tonumber), memMiB:(.mem|tonumber)})')

DISK=$(df -B1 --local --output=source,size,used,target 2>/dev/null | tail -n +2 \
 | jq -R -s 'split("\n") | map(select(.!="") | capture("^\\s*(?<src>\\S+)\\s+(?<size>[0-9]+)\\s+(?<used>[0-9]+)\\s+(?<mp>.*)$") | select(.src|test("tmpfs|devtmpfs|overlay|squashfs")|not) | {src:.src,total:(.size|tonumber),used:(.used|tonumber),mp:(.mp|sub("^ +";"")|sub(" +$";""))})')

NET=$(awk 'NR>2 && $1!="lo:"{r+=$2;s+=$10} END{printf "%d,%d", r+0, s+0}' /proc/net/dev)
IFS=',' read -r RX TX <<EOF
$NET
EOF

SVS=$(for u in $UNITS; do
  a=$(systemctl is-active "$u" 2>/dev/null); e=$(systemctl is-enabled "$u" 2>/dev/null)
  printf '%s|%s|%s\n' "$u" "${a:-unknown}" "${e:-unknown}"
done | jq -R -s 'split("\n") | map(select(.!="") | split("|") | {unit:.[0], state:.[1], enabled:.[2]})')

PCS=$(for p in $PATTERNS; do
  if pgrep -f "$p" >/dev/null 2>&1; then s=running; else s=stopped; fi
  printf '%s|%s\n' "$p" "$s"
done | jq -R -s 'split("\n") | map(select(.!="") | split("|") | {pattern:.[0], state:.[1]})')

CONN=$(ss -tn state established 2>/dev/null | grep -v 127.0.0.1 | tail -n +2 | awk '{print $4" "$5}' | sort | uniq -c | sort -rn | head -20 \
 | jq -R -s 'split("\n") | map(select(.!="") | capture("^\\s*(?<n>[0-9]+)\\s+(?<l>\\S+)\\s+(?<r>\\S+)$") | {n:(.n|tonumber),local:.l,remote:.r})')

PORTS=$(ss -tlnH 2>/dev/null | awk '{print $4" "$5}' | grep -o '[0-9]*$' | sort -n -u | head -40 | jq -R -s 'split("\n")|map(select(.!="")|tonumber)')

jq -cn \
  --argjson ts "$(date +%s)" \
  --argjson gpuUtil "$(str "$G_UTIL" | jq -r 'if .==null then "null" else . end' 2>/dev/null || echo null)" \
  --arg     gpuErr "$GPU_ERR" \
  --argjson gputot "$(str "$G_MEMT")" \
  '{ts:$ts,
    gpu:{util:$gpuUtil, memUsedMiB:null, memTotalMiB:$gputot, temp:null, power:null, err:(if $gpuErr=="" then null else $gpuErr end)},
    cpuStat:$ARGS.positional[0],
    cores:(`nproc`|? // null)}' \
  --args "$STAT" 2>/dev/null || echo 'JQ-BUILD-FAILED'
echo "---PARTIAL-OK---"
printf 'gpu_raw=%s\nproc_count=%s\ndisk=%s\nsvs=%s\npcs=%s\nconn=%s\nports=%s\nstat=%s\n' \
  "$GPU" "$(printf '%s' "$PROC" | jq 'length')" "$(printf '%s' "$DISK" | jq -c .)" "$(printf '%s' "$SVS" | jq -c .)" \
  "$(printf '%s' "$PCS" | jq -c .)" "$(printf '%s' "$CONN" | jq -c .)" "$(printf '%s' "$PORTS" | jq -c .)" "$STAT"
