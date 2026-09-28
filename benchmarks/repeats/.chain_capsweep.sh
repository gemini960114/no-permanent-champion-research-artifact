#!/usr/bin/env bash
# 等 r2t600（PID $1）以「全部完成」結束 → cap 探測 → 以最大可行 cap 跑 dense R2 配對 5 次（round r2c<cap>）
cd <repo>
RUN=20260928-153829; C=benchmarks/repeats/conditions
while kill -0 "$1" 2>/dev/null; do sleep 30; done
tail -3 ~/abrep.log | grep -q '🏁 全部完成' || { echo "[$(date '+%F %T')] ⛔ r2t600 未以「全部完成」結束，cap 掃描未啟動" >> ~/abrep.log; exit 1; }
echo "=== chain cap probe $(date '+%F %T')" >> ~/abrep.log
benchmarks/repeats/probe_caps.sh $RUN 64 80 96 112 >> ~/abrep.log 2>&1
max=$(grep -oE '^max_feasible_cap=.*' benchmarks/results/repeats/$RUN/cap_probe/results.tsv | cut -d= -f2)
if [ -z "$max" ] || [ "$max" = none ]; then echo "[$(date '+%F %T')] ⛔ 無可行 cap > 48，不跑量測（48 已為 R2 主條件）" >> ~/abrep.log; exit 0; fi
{ echo "# 27B dense｜SGLang｜R2 EAGLE 3/1/4，cap $max（probe_caps.sh 探得之最大可行值），mamba cache $((max*5))"
  grep -vE '^\s*#|^(MAX_RUNNING_REQUESTS|MAX_MAMBA_CACHE_SIZE)=' $C/dense-sglang-r2.env; echo "MAX_RUNNING_REQUESTS=$max"; echo "MAX_MAMBA_CACHE_SIZE=$((max*5))"; } > $C/dense-sglang-r2c$max.env
{ echo "# 27B dense｜vLLM｜R2 MTP×3，cap 128（與 dense-vllm-r2 相同；同時段配對參照）"; grep -vE '^\s*#' $C/dense-vllm-r2.env; } > $C/dense-vllm-r2c$max.env
echo "=== chain cap sweep r2c$max $(date '+%F %T')" >> ~/abrep.log
exec benchmarks/repeats/run_ab_repeats.sh --run-id $RUN --models dense --rounds r2c$max --exclude node-20 >> ~/abrep.log 2>&1
