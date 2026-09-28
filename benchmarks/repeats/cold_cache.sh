#!/usr/bin/env bash
# ==============================================================================
# cold_cache.sh — 冷／熱 TileLang JIT 快取對照（kda vLLM R1，單一變因）
#
# 用法：benchmarks/repeats/cold_cache.sh <RUN_ID> [重複次數，預設 3]
# 做法：每次重複都重新啟動 vLLM kda R1 引擎（參數同 conditions/kda-vllm-r1.env），
#       只把 TileLang 快取指到一個全新的空目錄（torch.compile 與 DeepGEMM 快取維持原狀），
#       不做 warm-up，先跑一次「冷」burst，冷卻後於同一引擎再跑一次「熱」burst。
#       兩者同一 instance、同一時段，唯一差異是 TileLang kernel 是否已編譯。
# 產出：<RUN_DIR>/cold_cache/{kda-r1-vllm-{cold,warm}-rep<k>.json/.jsonl.gz/.client.log,
#       jit_counts.tsv, engine logs, 快取目錄清單, 修改後 slurm 腳本 diff}
# ==============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO/benchmarks/repeats"
RUN_ID="${1:?需要 RUN_ID}"; REPS="${2:-3}"
RUN_DIR="$REPO/benchmarks/results/repeats/$RUN_ID"; OUT="$RUN_DIR/cold_cache"
VM_HOST="${VM_HOST:-client-vm}"; VM_PY="${VM_PY:-~/venv-bench/bin/python}"; VM_DIR="abrep/$RUN_ID"
EXCLUDE_NODES="${EXCLUDE_NODES:-node-20}"; COOLDOWN=60
ALIAS=abcold-kda-vllm; D="$REPO/engines/_abcold-kda-vllm"
CACHE_BASE="<cache>/abcold/$RUN_ID"
mkdir -p "$OUT"
log() { local m="[$(date '+%F %T')] $*"; echo "$m"; echo "$m" >> "$RUN_DIR/events.log"; }
vm() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 "$VM_HOST" "$@"; }
redact() { sed -E 's/^([A-Za-z_]*(_KEY|_TOKEN|SECRET[A-Za-z_]*|PASSWORD[A-Za-z_]*)=).*/\1<redacted>/'; }
JOB=""; trap '[ -n "$JOB" ] && scancel "$JOB" 2>/dev/null; rm -rf "$D"' EXIT

vm_has_alias() {
    vm 'set -a; . ~/.env; set +a; curl -s -m 15 -H "Authorization: Bearer $LITELLM_API_KEY" "${LITELLM_BASE_URL%/}/v1/models"' | grep -q "\"$ALIAS\""
}
burst() {   # $1 輸出基名
    local name="$1"
    for t in 1 2 3; do vm_has_alias && break; sleep 10; done
    log "   ▶ $name（1000 併發 × 1000 筆 × max_tokens 800，timeout 300）"
    vm "cd ~ && rm -f $VM_DIR/$name.json $VM_DIR/$name.jsonl && BENCH_MODELS='$ALIAS' $VM_PY $VM_DIR/stress_test.py \
        -c 1000 -n 1000 --max-tokens 800 --timeout 300 --skip-check \
        --output-json $VM_DIR/$name.json --per-request-jsonl $VM_DIR/$name.jsonl" > "$OUT/$name.client.log" 2>&1
    if scp -q -o BatchMode=yes "$VM_HOST:$VM_DIR/$name.json" "$VM_HOST:$VM_DIR/$name.jsonl" "$OUT/" 2>/dev/null; then
        gzip -f "$OUT/$name.jsonl"
        log "     $(python3 -c "import json;d=json.load(open('$OUT/$name.json'));print(f\"success {d['success_rate']:.1f}% · {d['tps']:.0f} tok/s · P95 {d['p95_latency']:.1f}s\")")"
    else
        log "     ❌ 無結果檔（見 cold_cache/$name.client.log）"
    fi
}
jit_count() { cat "$D"/logs/*"$JOB"*.out 2>/dev/null | grep -c 'TileLang begins to compile'; }

vm "mkdir -p $VM_DIR" && scp -q -o BatchMode=yes "$REPO/benchmarks/stress_test.py" "$VM_HOST:$VM_DIR/stress_test.py"
printf "rep\tjob\tnode\tcache_dir\tjit_at_ready\tjit_after_cold\tjit_after_warm\n" > "$OUT/jit_counts.tsv"
log "🧊 冷／熱 TileLang 快取對照開始（kda vLLM R1，$REPS 次）"
for k in $(seq 1 "$REPS"); do
    cache="$CACHE_BASE/rep$k/tilelang"; rm -rf "$cache"; mkdir -p "$cache"
    rm -rf "$D"; rsync -a --exclude logs --exclude '*.log' "$REPO/engines/vllm-glm53-flash/" "$D/"
    for key in $(grep -vE '^\s*(#|$)' "$HERE/conditions/kda-vllm-r1.env" | cut -d= -f1) SPECULATIVE_CONFIG MODEL_ALIAS ALIAS_CLAIM; do
        sed -i -E "/^\s*#?\s*${key}=/d" "$D/config.env"
    done
    { echo ""; echo "# ---- cold_cache.sh 覆寫（run $RUN_ID，rep $k）----"; echo "MODEL_ALIAS=$ALIAS"; echo "ALIAS_CLAIM=isolated"
      grep -vE '^\s*(#|$)' "$HERE/conditions/kda-vllm-r1.env"; } >> "$D/config.env"
    chmod 600 "$D/config.env"
    cp "$D/vllm_server.slurm" "$OUT/.orig.slurm"
    sed -i -E "s/^#SBATCH --job-name=.*/#SBATCH --job-name=abcold_kda_vllm/" "$D/vllm_server.slurm"
    sed -i -E "/^#SBATCH --job-name=/a #SBATCH --exclude=${EXCLUDE_NODES}" "$D/vllm_server.slurm"
    # 唯一變因：TileLang 快取改指空目錄（其餘快取不變）
    sed -i -E "s|^(\s*export SINGULARITYENV_TILELANG_CACHE_DIR=).*|\1\"$cache\"|" "$D/vllm_server.slurm"
    [ "$k" -eq 1 ] && { redact < "$D/config.env" > "$OUT/config.env"; diff "$OUT/.orig.slurm" "$D/vllm_server.slurm" > "$OUT/slurm.diff"; }
    rm -f "$OUT/.orig.slurm"
    JOB=$(cd "$D" && ./submit_slurm.sh 2>&1 | grep -oE 'Submitted batch job [0-9]+' | grep -oE '[0-9]+')
    log "   🚀 rep $k：Job $JOB（TileLang 快取 $cache，空）"
    ready=false
    for _ in $(seq 1 180); do
        ep=$(ls "$REPO"/runtime/endpoints/*_"$JOB".env 2>/dev/null | head -1)
        if [ -n "$ep" ] && grep -q '^STATE=ready' "$ep"; then ready=true; break; fi
        squeue -h -j "$JOB" 2>/dev/null | grep -q . || break
        sleep 20
    done
    node=$(sacct -j "$JOB" -X -n -o NodeList | tr -d ' ')
    if [ "$ready" != true ]; then log "   ❌ rep $k 引擎未就緒（$node）"; scancel "$JOB"; JOB=""; continue; fi
    log "   ✅ READY @ $node"
    "$REPO/start_background.sh" >> "$RUN_DIR/gateway_restarts.log" 2>&1 || true
    j0=$(jit_count)
    burst "kda-r1-vllm-cold-rep$k"; j1=$(jit_count)
    sleep "$COOLDOWN"
    burst "kda-r1-vllm-warm-rep$k"; j2=$(jit_count)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$k" "$JOB" "$node" "$cache" "$j0" "$j1" "$j2" >> "$OUT/jit_counts.tsv"
    log "   🧮 rep $k TileLang 編譯次數：就緒時 $j0、冷 burst 後 $j1、熱 burst 後 $j2"
    scancel "$JOB"; sleep 15
    for f in "$D"/logs/*"$JOB"*; do [ -f "$f" ] && cp "$f" "$OUT/rep$k-$(basename "$f")" && sed -i -E 's/sk-[A-Za-z0-9_-]{16,}/sk-<redacted>/g; s/hf_[A-Za-z0-9]{20,}/hf_<redacted>/g' "$OUT/rep$k-$(basename "$f")"; done   # 遮蔽 api_key
    ( cd "$cache" && find . -type f | sort ) > "$OUT/rep$k-tilelang-cache-files.txt"
    JOB=""
done
"$REPO/start_background.sh" >> "$RUN_DIR/gateway_restarts.log" 2>&1 || true
log "🧊 冷／熱快取對照完成（結果：cold_cache/jit_counts.tsv）"
echo "🏁 cold_cache 完成"
