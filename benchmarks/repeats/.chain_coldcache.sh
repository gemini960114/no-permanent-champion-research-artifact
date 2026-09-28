#!/usr/bin/env bash
# 等 cap 掃描（PID $1）結束；以「全部完成」或「無可行 cap」收尾時接跑冷／熱 TileLang 快取對照
cd <repo>
while kill -0 "$1" 2>/dev/null; do sleep 30; done
if tail -3 ~/abrep.log | grep -qE '🏁 全部完成|無可行 cap'; then
    echo "=== chain cold cache $(date '+%F %T')" >> ~/abrep.log
    exec benchmarks/repeats/cold_cache.sh 20260928-153829 3 >> ~/abrep.log 2>&1
else
    echo "[$(date '+%F %T')] ⛔ cap 掃描未正常結束，冷快取對照未啟動" >> ~/abrep.log
fi
