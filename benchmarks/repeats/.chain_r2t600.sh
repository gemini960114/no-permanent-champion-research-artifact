#!/usr/bin/env bash
# 等尾段（kda r2 → dense r1c48，PID $1）結束；僅在最後以「全部完成」收尾時接跑 kda r2t600（client 上限 600 秒）
cd <repo>
while kill -0 "$1" 2>/dev/null; do sleep 30; done
if tail -3 ~/abrep.log | grep -q '🏁 全部完成'; then
    echo "=== chain r2t600 $(date '+%F %T')" >> ~/abrep.log
    exec benchmarks/repeats/run_ab_repeats.sh --run-id 20260928-153829 --models kda --rounds r2t600 --timeout 600 --exclude node-20 >> ~/abrep.log 2>&1
else
    echo "[$(date '+%F %T')] ⛔ 尾段未以「全部完成」結束，r2t600 未啟動" >> ~/abrep.log
fi
