#!/usr/bin/env bash
# 續跑 kda r2（排除故障節點）→ 成功後接 dense r1c48 對照組
cd <repo>
# 節點排除改由 run_ab_repeats.sh --exclude 寫入 #SBATCH 指令
echo "=== resume kda r2 (exclude node-20) $(date '+%F %T')" >> ~/abrep.log
benchmarks/repeats/run_ab_repeats.sh --run-id 20260928-153829 --models kda --rounds r2 --exclude node-20 >> ~/abrep.log 2>&1 || { echo "[$(date '+%F %T')] ⛔ kda r2 續跑失敗，r1c48 未啟動" >> ~/abrep.log; exit 1; }
echo "=== chain r1c48 $(date '+%F %T')" >> ~/abrep.log
exec benchmarks/repeats/run_ab_repeats.sh --run-id 20260928-153829 --models dense --rounds r1c48 --exclude node-20 >> ~/abrep.log 2>&1
