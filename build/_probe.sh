echo "== os"; grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null
echo "== awk"; (awk --version 2>/dev/null || awk -W version 2>&1) | head -1
echo "== sed"; sed --version 2>/dev/null | head -1
echo "== bins"
for b in nvidia-smi ps ss free df awk sed tr base64 jq python3 systemctl who lsof nc ip; do
  printf '  %-12s ' "$b"; command -v "$b" >/dev/null 2>&1 && command -v "$b" || echo MISSING
done
echo "== gpu"
nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>&1 | head -3
echo "== gpuapps"
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>&1 | head -5
echo "== proccount"; ps -eo pid --no-headers | wc -l
echo "== etimes"; ps -eo pid,etimes --no-headers | head -2
echo "== sudon"; sudo -n true 2>&1 | head -1
echo "== sysctl"; systemctl is-enabled ollama 2>&1; systemctl is-active ollama 2>&1
echo "== ssver"; ss -V 2>&1 | head -1
echo "== host"; hostname; uname -r
echo "== cntrl"; printf 'a\tb"c\\d\ne' | sed 's/[[:cntrl:]]/ /g' | od -c | head -2
