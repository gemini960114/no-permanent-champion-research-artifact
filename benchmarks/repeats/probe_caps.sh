#!/usr/bin/env bash
# ==============================================================================
# probe_caps.sh — 探測 SGLang dense R2（EAGLE 3/1/4）在單張 H200 上可啟動的最大 cap
#
# 用法：benchmarks/repeats/probe_caps.sh <RUN_ID> [cap...]    預設 cap：64 80 96 112
# 做法：每個 cap 複製 engines/sglang-qwen-27b 為 engines/_abprobe-c<cap>/，套用
#       conditions/dense-sglang-r2.env 後覆寫 MAX_RUNNING_REQUESTS=<cap>、
#       MAX_MAMBA_CACHE_SIZE=<cap×5>（官方公式），ALIAS_CLAIM=isolated；同時派送、
#       只檢查能否就緒（不壓測、不重啟 Gateway），記錄生效 cap 與 KV 容量後取消。
# 產出：<RUN_DIR>/cap_probe/{results.tsv, c<cap>.err/.out, c<cap>.config.env}
#       results.tsv 最後一行 max_feasible_cap=<cap>（全部失敗則為 none）
# ==============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO/benchmarks/repeats"
RUN_ID="${1:?需要 RUN_ID}"; shift
CAPS=("${@:-64 80 96 112}"); [ $# -eq 0 ] && CAPS=(64 80 96 112)
EXCLUDE_NODES="${EXCLUDE_NODES:-node-20}"
OUT="$REPO/benchmarks/results/repeats/$RUN_ID/cap_probe"
mkdir -p "$OUT"
log() { local m="[$(date '+%F %T')] $*"; echo "$m"; echo "$m" >> "$REPO/benchmarks/results/repeats/$RUN_ID/events.log"; }
redact() { sed -E 's/^([A-Za-z_]*(_KEY|_TOKEN|SECRET[A-Za-z_]*|PASSWORD[A-Za-z_]*)=).*/\1<redacted>/'; }

declare -A JOB
log "🔎 cap 探測開始：SGLang dense R2 EAGLE，cap ${CAPS[*]}"
for c in "${CAPS[@]}"; do
    d="$REPO/engines/_abprobe-c$c"; rm -rf "$d"
    rsync -a --exclude logs --exclude '*.log' "$REPO/engines/sglang-qwen-27b/" "$d/"
    for k in MAX_RUNNING_REQUESTS MAX_MAMBA_CACHE_SIZE SPECULATIVE_ALGORITHM SPECULATIVE_NUM_STEPS SPECULATIVE_EAGLE_TOPK SPECULATIVE_NUM_DRAFT_TOKENS MODEL_ALIAS ALIAS_CLAIM; do
        sed -i -E "/^\s*#?\s*${k}=/d" "$d/config.env"
    done
    {
        echo ""; echo "# ---- probe_caps.sh 覆寫（run $RUN_ID，cap $c）----"
        echo "MODEL_ALIAS=abprobe-c$c"; echo "ALIAS_CLAIM=isolated"
        grep -vE '^\s*(#|$)' "$HERE/conditions/dense-sglang-r2.env" | grep -vE '^(MAX_RUNNING_REQUESTS|MAX_MAMBA_CACHE_SIZE)='
        echo "MAX_RUNNING_REQUESTS=$c"; echo "MAX_MAMBA_CACHE_SIZE=$((c * 5))"
    } >> "$d/config.env"
    chmod 600 "$d/config.env"
    redact < "$d/config.env" > "$OUT/c$c.config.env"
    sed -i -E "s/^#SBATCH --job-name=.*/#SBATCH --job-name=abprobe_c$c/" "$d/sglang_server.slurm"
    [ -n "$EXCLUDE_NODES" ] && sed -i -E "/^#SBATCH --job-name=/a #SBATCH --exclude=${EXCLUDE_NODES}" "$d/sglang_server.slurm"
    JOB[$c]=$(cd "$d" && ./submit_slurm.sh 2>&1 | grep -oE 'Submitted batch job [0-9]+' | grep -oE '[0-9]+')
    log "   🚀 cap $c → Job ${JOB[$c]}"
done
trap 'for c in "${CAPS[@]}"; do scancel "${JOB[$c]}" 2>/dev/null; done' EXIT

printf "cap\tjob\tnode\tresult\teffective_max_running_requests\tmax_total_num_tokens\tavailable_gpu_mem\terror\n" > "$OUT/results.tsv"
declare -A DONE; max=none
for _ in $(seq 1 180); do            # 最多 60 分鐘（20 秒 × 180）
    left=0
    for c in "${CAPS[@]}"; do
        [ -n "${DONE[$c]:-}" ] && continue
        j="${JOB[$c]}"; d="$REPO/engines/_abprobe-c$c"
        ep=$(ls "$REPO"/runtime/endpoints/*_"$j".env 2>/dev/null | head -1)
        res=""
        if [ -n "$ep" ] && grep -q '^STATE=ready' "$ep"; then res=ready
        elif ! squeue -h -j "$j" 2>/dev/null | grep -q .; then res=failed; fi
        if [ -z "$res" ]; then left=1; continue; fi
        [ "$res" = ready ] && scancel "$j" 2>/dev/null && sleep 5
        err=$(ls "$d"/logs/*"$j"*.err 2>/dev/null | head -1); outf=$(ls "$d"/logs/*"$j"*.out 2>/dev/null | head -1)
        [ -n "$err" ] && cp "$err" "$OUT/c$c.err"; [ -n "$outf" ] && cp "$outf" "$OUT/c$c.out"
        for x in "$OUT/c$c.err" "$OUT/c$c.out"; do [ -f "$x" ] && sed -i -E 's/sk-[A-Za-z0-9_-]{16,}/sk-<redacted>/g; s/hf_[A-Za-z0-9]{20,}/hf_<redacted>/g' "$x"; done   # 遮蔽 server_args 內的 api_key
        line=$(grep -m1 -oE "max_total_num_tokens=[0-9]+.*max_running_requests=[0-9]+.*available_gpu_mem=[0-9.]+ GB" "$OUT/c$c.err" 2>/dev/null)
        eff=$(echo "$line" | grep -oE "max_running_requests=[0-9]+" | cut -d= -f2)
        tok=$(echo "$line" | grep -oE "max_total_num_tokens=[0-9]+" | cut -d= -f2)
        mem=$(echo "$line" | grep -oE "available_gpu_mem=[0-9.]+" | cut -d= -f2)
        emsg=$(grep -m1 -E "^(ValueError|RuntimeError|torch.OutOfMemoryError|.*Error:)" "$OUT/c$c.err" 2>/dev/null | cut -c1-160)
        node=$(sacct -j "$j" -X -n -o NodeList | tr -d ' ')
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$c" "$j" "$node" "$res" "${eff:-}" "${tok:-}" "${mem:-}" "${emsg:-}" >> "$OUT/results.tsv"
        log "   $([ "$res" = ready ] && echo ✅ || echo ❌) cap $c：$res（生效 cap ${eff:-?}、KV ${tok:-?} tokens）${emsg:+ — $emsg}"
        if [ "$res" = ready ] && [ "${eff:-0}" = "$c" ] && { [ "$max" = none ] || [ "$c" -gt "$max" ]; }; then max=$c; fi
        DONE[$c]=1
    done
    [ "$left" -eq 0 ] && break
    sleep 20
done
echo "max_feasible_cap=$max" >> "$OUT/results.tsv"
for c in "${CAPS[@]}"; do rm -rf "$REPO/engines/_abprobe-c$c"; done
log "🔎 cap 探測完成：最大可行 cap = $max"
