#!/usr/bin/env bash
# kda R1 instance 間變異：3 對全新 instance × 各 2 次（交錯），排除故障節點
cd <repo>
echo "=== kda instance variance $(date '+%F %T')" >> ~/abrep.log
for i in 1 2 3; do
    benchmarks/repeats/run_ab_repeats.sh --run-id 20260928-153829 --models kda --rounds r1i$i --reps 2 --exclude node-20,node-26,node-29,node-30 >> ~/abrep.log 2>&1 \
        || { echo "[$(date '+%F %T')] ⛔ r1i$i 失敗，停止" >> ~/abrep.log; exit 1; }
done
echo "[$(date '+%F %T')] 🏁 instance 變異量測全部完成" >> ~/abrep.log
