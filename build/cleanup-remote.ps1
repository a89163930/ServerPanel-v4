# 清理本面板遗留在服务器上的采集循环（只认我们自己的特征，不碰任何别的进程）
$ErrorActionPreference = 'Continue'
$script = @'
MARK="ZXhwb3J0IFBBTkVMX1VOSVRTPSJvbGxhbWEi"     # base64("export PANEL_UNITS=ollama") —— 只有本面板的命令行含这段
echo "== 清理前 =="
ps -eo pid,ppid,etimes,args --no-headers | grep -F "$MARK" | grep -v grep | awk '{print "  wrapper "$1" ppid="$2" age="$3"s"}'
ps -eo pid,ppid,args --no-headers | awk '$0 ~ /bash -s -- 3$/ {print "  loop    "$1" ppid="$2}'
# 1) 我们的 bash -c 包装进程
W=$(pgrep -f "$MARK" | tr '\n' ' ')
# 2) 采集循环本体：命令行恰为 "bash -s -- 3"，且父进程是我们的包装进程或已被 init 收养(孤儿)
L=$(ps -eo pid=,ppid=,args= --no-headers | awk '$0 ~ /bash -s -- 3$/ {p=$1; pp=$2; if (pp==1) print p}')
for p in $W $L; do
  cmd=$(ps -o args= -p "$p" 2>/dev/null)          # 不要截断：之前 cut -c1-40 把特征切掉了，导致一个都没杀
  [ -z "$cmd" ] && continue
  case "$cmd" in
    *"$MARK"*)          kill -TERM "$p" 2>/dev/null && echo "  TERM $p (wrapper)";;
    *base64\ -d\ \|\ bash*) kill -TERM "$p" 2>/dev/null && echo "  TERM $p (pipe)";;
    *"bash -s -- 3")    kill -TERM "$p" 2>/dev/null && echo "  TERM $p (loop)";;
    *) echo "  SKIP $p 特征不符: $(echo "$cmd" | cut -c1-50)";;
  esac
done
sleep 1
for p in $W $L; do
  cmd=$(ps -o args= -p "$p" 2>/dev/null); [ -z "$cmd" ] && continue
  kill -KILL "$p" 2>/dev/null && echo "  KILL $p (TERM 未生效)"
done
sleep 1
echo "== 清理后 =="
n=$(ps -eo args --no-headers | grep -cE "$MARK|bash -s -- 3$" || true)
echo "  残留匹配数 = $n"
echo "== 负载对照 =="
cat /proc/loadavg
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script -replace "`r`n", "`n")))
& ssh -o BatchMode=yes -o ConnectTimeout=10 Linux_3090 "echo $b64 | base64 -d | bash" 2>&1 | Out-String
