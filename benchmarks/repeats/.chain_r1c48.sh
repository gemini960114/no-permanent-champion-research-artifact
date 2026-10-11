#!/usr/bin/env bash
# 等主要補跑（PID $1）結束；僅在其最後一行為「全部完成」時接跑 dense r1c48 對照組
cd <repo>
while kill -0 "$1" 2>/dev/null; do sleep 60; done
if tail -3 ~/abrep.log | grep -q '🏁 全部完成'; then
    echo "=== chain r1c48 $(date '+%F %T')" >> ~/abrep.log
    exec benchmarks/repeats/run_ab_repeats.sh --run-id 20260928-153829 --models dense --rounds r1c48 >> ~/abrep.log 2>&1
else
    echo "[$(date '+%F %T')] ⛔ 主要補跑未以「全部完成」結束，r1c48 對照組未啟動" >> ~/abrep.log
fi
