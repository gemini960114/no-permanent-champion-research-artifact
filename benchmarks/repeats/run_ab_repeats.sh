#!/usr/bin/env bash
# ==============================================================================
# run_ab_repeats.sh — SGLang vs vLLM A/B 重複量測（論文 Table 3–8 補跑，保留完整證據）
#
# 用法（於 Gateway 部署節點執行，現為 login-01）：
#   benchmarks/repeats/run_ab_repeats.sh --dry-run                 只做前置檢查與計畫預覽
#   benchmarks/repeats/run_ab_repeats.sh                           全部 3 模型 × R1/R2 × 5 次
#   benchmarks/repeats/run_ab_repeats.sh --models dense --reps 3   只跑 27B
#   benchmarks/repeats/run_ab_repeats.sh --run-id <既有ID>          續跑（已有結果的 rep 自動略過）
#
# 設計（對應論文 Section 4 的 fairness controls）：
#   • 不碰生產引擎：每個條件從 engines/<原引擎> 複製一份 engines/_abrep-<模型>-<框架>/，
#     套用 conditions/<模型>-<框架>-<r1|r2>.env 覆寫，ALIAS_CLAIM=isolated、
#     MODEL_ALIAS=abrep-<模型>-<框架>——只註冊後綴別名，不搶生產正名。
#   • 同一 phase（模型×回合）兩框架同時在線，交錯執行：奇數 rep SGLang 先、偶數 rep vLLM 先，
#     抵消時間漂移；每個框架先跑一次小型 warm-up（另存，不計入）。
#   • 壓測路徑同原始量測：VM → 反向隧道 → Gateway → 引擎（client 經 ssh 在 VM 上執行，
#     API 金鑰只留在 VM 的 ~/.env，不經過本機）。
#   • 證據：manifest（git commit、harness md5、SIF/權重指紋）、每條件的遮蔽後 config、
#     每次壓測的 summary JSON＋逐筆 JSONL、client 輸出、引擎 Slurm log、sacct 節點紀錄、
#     events.log 時間線；最後由 aggregate.py 產出 mean ± SD。
#
# 注意：每個 phase 開始與結束各重啟 Gateway 一次（約 10 秒中斷，生產使用者會短暫受影響）。
# ==============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO/benchmarks/repeats"
cd "$REPO"

# ------------------------------------------------------------------------------
# 參數
# ------------------------------------------------------------------------------
REPS=5
MODELS="dense,moe,kda"
ROUNDS="r1,r2"
RUN_ID=""
DRY_RUN=false
SIF_HASH=true
COOLDOWN=60
ACCOUNT=""
VM_HOST="${VM_HOST:-client-vm}"
VM_PY="${VM_PY:-~/venv-bench/bin/python}"
CLIENT_TIMEOUT=300                           # client 等待上限（秒）；--timeout 覆寫
PENDING_TIMEOUT="${PENDING_TIMEOUT:-21600}"   # Slurm 排隊上限（秒），預設 6 小時
WARMUP_N=64
EXCLUDE_NODES="${EXCLUDE_NODES:-}"          # 例：node-20（故障節點，逗號分隔）

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --reps) REPS="$2"; shift 2 ;;
        --models) MODELS="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --cooldown) COOLDOWN="$2"; shift 2 ;;
        --account) ACCOUNT="$2"; shift 2 ;;
        --exclude) EXCLUDE_NODES="$2"; shift 2 ;;
        --timeout) CLIENT_TIMEOUT="$2"; shift 2 ;;
        --no-sif-hash) SIF_HASH=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "未知參數: $1" >&2; usage ;;
    esac
done

# 模型 → 工作量（concurrency total max_tokens，同論文 Table 3）與原引擎目錄
declare -A WORKLOAD=( [dense]="500 500 500" [moe]="1000 1000 800" [kda]="1000 1000 800" )
declare -A BASE_ENGINE=(
    [dense:sglang]=sglang-qwen-27b    [dense:vllm]=vllm-qwen27b
    [moe:sglang]=sglang-qwen-flash    [moe:vllm]=vllm-flash-next
    [kda:sglang]=sglang-glm53-flash   [kda:vllm]=vllm-glm53-flash
)
FRAMEWORKS=(sglang vllm)

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="$REPO/benchmarks/results/repeats/$RUN_ID"
VM_DIR="abrep/$RUN_ID"          # 相對於 VM 的 home
ACTIVE_JOBS=()

log() { local m="[$(date '+%F %T')] $*"; echo "$m"; [ -d "$RUN_DIR" ] && echo "$m" >> "$RUN_DIR/events.log"; }
die() { log "❌ $*"; exit 1; }
vm() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 "$VM_HOST" "$@"; }
engine_dir() { echo "$REPO/engines/_abrep-$1-$2"; }
alias_of() { echo "abrep-$1-$2"; }

cleanup() {
    local j
    for j in "${ACTIVE_JOBS[@]:-}"; do
        [ -n "$j" ] && scancel "$j" 2>/dev/null && log "🧹 中止時取消 Job $j"
    done
}
trap cleanup EXIT
trap 'log "⚠️ 收到中斷訊號"; exit 130' INT TERM

# ------------------------------------------------------------------------------
# 前置檢查
# ------------------------------------------------------------------------------
preflight() {
    local node rec m fw r f
    node="$(hostname -s)"; rec="$(cat "$REPO/.litellm_node" 2>/dev/null || true)"
    [ -z "$rec" ] || [ "$rec" = "$node" ] || die "Gateway 記錄於 $rec，請在該節點執行（本機 $node）"
    [[ "$REPS" =~ ^[1-9][0-9]*$ ]] || die "--reps 必須為正整數"
    for m in ${MODELS//,/ }; do
        [ -n "${WORKLOAD[$m]:-}" ] || die "未知模型鍵 $m（可用：dense moe kda）"
        for fw in "${FRAMEWORKS[@]}"; do
            [ -f "$REPO/engines/${BASE_ENGINE[$m:$fw]}/config.env" ] || die "缺少 engines/${BASE_ENGINE[$m:$fw]}/config.env"
            for r in ${ROUNDS//,/ }; do
                f="$HERE/conditions/$m-$fw-$r.env"
                [ -f "$f" ] || die "缺少條件檔 $f"
            done
        done
    done
    vm 'test -f ~/.env && grep -q "^LITELLM_API_KEY=" ~/.env' || die "VM $VM_HOST 無法連線或缺 ~/.env 的 LITELLM_API_KEY"
    vm "$VM_PY -c 'import httpx, rich, tqdm'" || die "VM 上 $VM_PY 缺少 httpx/rich/tqdm"
    if squeue -h -u "$(id -un)" -o '%j' | grep -q '^abrep_'; then
        die "已有 abrep_* job 在運行（squeue -u $(id -un)），請先確認或 scancel"
    fi
    log "✅ 前置檢查通過（節點 $node、VM $VM_HOST、模型 $MODELS、回合 $ROUNDS、每條件 $REPS 次）"
}

# 只遮蔽機密值（*_KEY、*_TOKEN、*SECRET*、*PASSWORD*）；NUM_DRAFT_TOKENS、API_KEY_ENV 等參數保留原值
redact() { sed -E 's/^([A-Za-z_]*(_KEY|_TOKEN|SECRET[A-Za-z_]*|PASSWORD[A-Za-z_]*)=).*/\1<redacted>/'; }

write_manifest() {
    local m fw sif mp
    {
        echo "run_id=$RUN_ID"
        echo "started_at=$(date -Iseconds)"
        echo "login_node=$(hostname -s)"
        echo "git_commit=$(git -C "$REPO" rev-parse HEAD)"
        echo "git_dirty_files=$(git -C "$REPO" status --porcelain | wc -l)"
        echo "reps=$REPS models=$MODELS rounds=$ROUNDS cooldown_s=$COOLDOWN client_timeout_s=$CLIENT_TIMEOUT warmup_n=$WARMUP_N"
        echo "order_policy=odd rep: sglang→vllm; even rep: vllm→sglang"
        echo "harness_md5_local=$(md5sum "$REPO/benchmarks/stress_test.py" | cut -d' ' -f1)"
        echo "harness_md5_vm=$(vm "md5sum $VM_DIR/stress_test.py" | cut -d' ' -f1)"
        echo "vm_python=$(vm "$VM_PY -c 'import sys,httpx;print(sys.version.split()[0], \"httpx\", httpx.__version__)'")"
        echo "vm_ulimit_n=$(vm 'ulimit -n')"
    } > "$RUN_DIR/manifest.txt"
    # 映像與權重指紋（映像 sha256 於背景計算，完成後寫入 image_sha256.txt）
    : > "$RUN_DIR/images.txt"; : > "$RUN_DIR/weights.txt"
    for m in ${MODELS//,/ }; do
        for fw in "${FRAMEWORKS[@]}"; do
            sif=$(grep -m1 '^SIF_PATH=' "$REPO/engines/${BASE_ENGINE[$m:$fw]}/config.env" | cut -d= -f2-)
            grep -qxF "$sif" "$RUN_DIR/images.txt" || echo "$sif" >> "$RUN_DIR/images.txt"
        done
    done
    if [ "$SIF_HASH" = true ] && [ "$DRY_RUN" = false ]; then
        ( while read -r sif; do
              [ -f "$sif" ] && sha256sum "$sif"
          done < "$RUN_DIR/images.txt" > "$RUN_DIR/image_sha256.txt" 2>&1 ) &
        log "🔏 背景計算 SIF sha256 → image_sha256.txt"
    fi
    for mp in <models>/Qwen3.8-27B <models>/Qwen3.8-Flash-Next-FP8 <models>/GLM-5.3-Flash; do
        [ -d "$mp" ] || continue
        echo "## $mp" >> "$RUN_DIR/weights.txt"
        ( cd "$mp" && sha256sum ./*.json 2>/dev/null; ls -l --time-style=full-iso ./*.safetensors 2>/dev/null | awk '{print $5, $6, $7, $9}' ) >> "$RUN_DIR/weights.txt"
    done
}

# ------------------------------------------------------------------------------
# 引擎：準備 → 派送 → 等就緒 → 關閉
# ------------------------------------------------------------------------------
prepare_engine() {   # $1 模型 $2 框架 $3 回合
    local m="$1" fw="$2" r="$3" base dest cond keys k slurm
    base="$REPO/engines/${BASE_ENGINE[$m:$fw]}"; dest="$(engine_dir "$m" "$fw")"; cond="$HERE/conditions/$m-$fw-$r.env"
    rm -rf "$dest"
    rsync -a --exclude logs --exclude '*.log' "$base/" "$dest/"
    # 覆寫：移除條件檔所列 key、所有 SPECULATIVE_*、別名宣告（含註解版本），再附加條件
    keys=$(grep -vE '^\s*(#|$)' "$cond" | cut -d= -f1 | sort -u)
    for k in $keys SPECULATIVE_ALGORITHM SPECULATIVE_NUM_STEPS SPECULATIVE_EAGLE_TOPK SPECULATIVE_NUM_DRAFT_TOKENS SPECULATIVE_CONFIG MODEL_ALIAS ALIAS_CLAIM; do
        sed -i -E "/^\s*#?\s*${k}=/d" "$dest/config.env"
    done
    {
        echo ""
        echo "# ---- run_ab_repeats.sh 覆寫（run $RUN_ID，條件 $m-$fw-$r）----"
        echo "MODEL_ALIAS=$(alias_of "$m" "$fw")"
        echo "ALIAS_CLAIM=isolated"
        grep -vE '^\s*(#|$)' "$cond"
    } >> "$dest/config.env"
    chmod 600 "$dest/config.env"
    slurm=$(ls "$dest"/*_server.slurm | head -1)
    sed -i -E "s/^#SBATCH --job-name=.*/#SBATCH --job-name=abrep_${m}_${fw}/" "$slurm"
    # 排除故障節點（本叢集 Slurm 不支援 SBATCH_EXCLUDE 環境變數，改寫入腳本指令）
    [ -n "$EXCLUDE_NODES" ] && sed -i -E "/^#SBATCH --job-name=/a #SBATCH --exclude=${EXCLUDE_NODES}" "$slurm"
    mkdir -p "$RUN_DIR/conditions"
    redact < "$dest/config.env" > "$RUN_DIR/conditions/$m-$fw-$r.config.env"
}

submit_engine() {   # 輸出 Job ID
    local dest="$1" out
    if [ -n "$ACCOUNT" ]; then out=$(cd "$dest" && ./submit_slurm.sh -a "$ACCOUNT" 2>&1)
    else out=$(cd "$dest" && ./submit_slurm.sh 2>&1); fi
    echo "$out" | grep -oE 'Submitted batch job [0-9]+' | grep -oE '[0-9]+' | head -1
}

wait_ready() {   # $1 Job ID $2 引擎目錄
    local job="$1" dest="$2" health waited=0 ep started=""
    health=$(grep -m1 '^HEALTH_TIMEOUT=' "$dest/config.env" | cut -d= -f2); health="${health:-1800}"
    while :; do
        ep=$(ls "$REPO"/runtime/endpoints/*_"$job".env 2>/dev/null | head -1)
        if [ -n "$ep" ] && grep -q '^STATE=ready' "$ep"; then
            log "   ✅ Job $job READY @ $(grep '^NODE_HOSTNAME=' "$ep" | cut -d= -f2):$(grep '^PORT=' "$ep" | cut -d= -f2)"
            return 0
        fi
        local st; st=$(squeue -h -j "$job" -o '%T' 2>/dev/null)
        [ -z "$st" ] && { log "   ❌ Job $job 已結束且未就緒（見 $dest/logs/）"; return 1; }
        if [ "$st" = RUNNING ] && [ -z "$started" ]; then started=$waited; fi
        if [ -z "$started" ] && [ "$waited" -ge "$PENDING_TIMEOUT" ]; then log "   ❌ Job $job 排隊逾時"; return 1; fi
        if [ -n "$started" ] && [ $((waited - started)) -ge $((health + 600)) ]; then log "   ❌ Job $job 啟動逾時"; return 1; fi
        sleep 20; waited=$((waited + 20))
    done
}

restart_gateway() {
    log "🔄 重啟 Gateway（重新產生路由；約 10 秒中斷）"
    "$REPO/start_background.sh" >> "$RUN_DIR/gateway_restarts.log" 2>&1 \
        || log "   ⚠️ start_background.sh 回傳非 0（可能是實測模型失敗），改以 VM 端別名檢查為準"
}

vm_has_aliases() {   # 參數：要確認的別名
    local listing a
    listing=$(vm 'set -a; . ~/.env; set +a; curl -s -m 15 -H "Authorization: Bearer $LITELLM_API_KEY" "${LITELLM_BASE_URL%/}/v1/models"')
    for a in "$@"; do
        echo "$listing" | grep -q "\"$a\"" || return 1
    done
}

stop_engines() {   # 參數：Job ID…
    local j
    for j in "$@"; do scancel "$j" 2>/dev/null; done
    for _ in $(seq 1 60); do
        squeue -h -j "$(IFS=,; echo "$*")" 2>/dev/null | grep -q . || break
        sleep 5
    done
    ACTIVE_JOBS=()
}

collect_engine_evidence() {   # $1 模型 $2 回合 然後 Job ID…
    local m="$1" r="$2" fw j dest; shift 2
    mkdir -p "$RUN_DIR/engine_logs"
    for fw in "${FRAMEWORKS[@]}"; do
        dest="$(engine_dir "$m" "$fw")"
        for j in "$@"; do
            for f in "$dest"/logs/*"$j"*; do
                # SGLang 會把 server_args（含明文 api_key）寫進 log——複製後立即遮蔽
                [ -f "$f" ] && cp "$f" "$RUN_DIR/engine_logs/$m-$r-$fw-$(basename "$f")" \
                    && sed -i -E 's/sk-[A-Za-z0-9_-]{16,}/sk-<redacted>/g; s/hf_[A-Za-z0-9]{20,}/hf_<redacted>/g' "$RUN_DIR/engine_logs/$m-$r-$fw-$(basename "$f")"
            done
        done
    done
    sacct -j "$(IFS=,; echo "$*")" -X -P -o JobID,JobName,NodeList,Start,End,State,AllocTRES \
        | tail -n +2 | sed "s/^/$m,$r|/" >> "$RUN_DIR/jobs.psv"
}

# ------------------------------------------------------------------------------
# 壓測（在 VM 上執行，結果拉回本機）
# ------------------------------------------------------------------------------
burst() {   # $1 別名 $2 輸出基名 $3 concurrency $4 total $5 max_tokens $6 子目錄
    local alias="$1" name="$2" c="$3" n="$4" mt="$5" sub="$6" rc attempt try
    mkdir -p "$RUN_DIR/$sub"
    for attempt in 1 2; do
        # 前置檢查改用 /v1/models（不探測上游，毫秒級）；harness 內建 /health 會逐一探測所有模型含 Portal，偶發 >10 秒逾時
        for try in 1 2 3; do vm_has_aliases "$alias" && break; sleep 10; done
        log "   ▶ $name（$alias，${c} 併發 × ${n} 筆 × max_tokens ${mt}$([ "$attempt" -gt 1 ] && echo "，重試 #$attempt")）"
        vm "cd ~ && rm -f $VM_DIR/$name.json $VM_DIR/$name.jsonl && BENCH_MODELS='$alias' $VM_PY $VM_DIR/stress_test.py \
            -c $c -n $n --max-tokens $mt --timeout $CLIENT_TIMEOUT --skip-check \
            --output-json $VM_DIR/$name.json --per-request-jsonl $VM_DIR/$name.jsonl" \
            > "$RUN_DIR/$sub/$name.client.log" 2>&1
        rc=$?
        vm "test -f $VM_DIR/$name.json" && break
        log "     ⚠️ 無結果檔（client rc=$rc），$([ "$attempt" -lt 2 ] && echo "${COOLDOWN} 秒後重試" || echo "放棄")"
        [ "$attempt" -lt 2 ] && sleep "$COOLDOWN"
    done
    if scp -q -o BatchMode=yes "$VM_HOST:$VM_DIR/$name.json" "$VM_HOST:$VM_DIR/$name.jsonl" "$RUN_DIR/$sub/" 2>/dev/null; then
        gzip -f "$RUN_DIR/$sub/$name.jsonl"
        log "     $(python3 -c "import json;d=json.load(open('$RUN_DIR/$sub/$name.json'));print(f\"success {d['success_rate']:.1f}% · {d['tps']:.0f} tok/s · P95 {d['p95_latency']:.1f}s · tokens {d['total_tokens']}\")")"
    else
        log "     ❌ 無結果檔（client rc=$rc，見 $sub/$name.client.log）"
    fi
}

run_phase() {   # $1 模型 $2 回合
    local m="$1" r="$2" fw k first second c n mt jobs=() dest job done_all=true
    read -r c n mt <<< "${WORKLOAD[$m]}"
    for k in $(seq 1 "$REPS"); do
        for fw in "${FRAMEWORKS[@]}"; do
            [ -f "$RUN_DIR/raw/$m-$r-$fw-rep$k.json" ] || done_all=false
        done
    done
    if [ "$done_all" = true ]; then log "⏭️  $m/$r 已完成，略過"; return 0; fi

    log "════ Phase $m / $r ════"
    for fw in "${FRAMEWORKS[@]}"; do
        prepare_engine "$m" "$fw" "$r"
        if [ "$DRY_RUN" = true ]; then
            log "   [dry-run] $(cd "$(engine_dir "$m" "$fw")" && ./submit_slurm.sh --dry-run 2>&1 | tail -1)"
            continue
        fi
        job=$(submit_engine "$(engine_dir "$m" "$fw")")
        [ -n "$job" ] || die "$m-$fw 派送失敗"
        jobs+=("$job"); ACTIVE_JOBS+=("$job")
        log "   🚀 $m-$fw-$r 派送 Job $job"
    done
    [ "$DRY_RUN" = true ] && return 0

    local i=0 ok=true
    for fw in "${FRAMEWORKS[@]}"; do
        wait_ready "${jobs[$i]}" "$(engine_dir "$m" "$fw")" || ok=false
        i=$((i + 1))
    done
    if [ "$ok" = true ]; then
        restart_gateway
        vm_has_aliases "$(alias_of "$m" sglang)" "$(alias_of "$m" vllm)" || { log "   ❌ Gateway 未列出 abrep 別名"; ok=false; }
    fi
    if [ "$ok" = true ]; then
        for fw in "${FRAMEWORKS[@]}"; do
            [ -f "$RUN_DIR/warmup/$m-$r-$fw-warmup.json" ] || burst "$(alias_of "$m" "$fw")" "$m-$r-$fw-warmup" 64 "$WARMUP_N" 64 warmup
        done
        for k in $(seq 1 "$REPS"); do
            if [ $((k % 2)) -eq 1 ]; then first=sglang; second=vllm; else first=vllm; second=sglang; fi
            for fw in "$first" "$second"; do
                [ -f "$RUN_DIR/raw/$m-$r-$fw-rep$k.json" ] && continue
                sleep "$COOLDOWN"
                burst "$(alias_of "$m" "$fw")" "$m-$r-$fw-rep$k" "$c" "$n" "$mt" raw
            done
        done
    fi
    stop_engines "${jobs[@]}"
    collect_engine_evidence "$m" "$r" "${jobs[@]}"
    [ "$ok" = true ] || die "Phase $m/$r 失敗（引擎未就緒或路由缺失）；可用 --run-id $RUN_ID 續跑"
    log "✅ Phase $m / $r 完成"
}

# ------------------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------------------
mkdir -p "$RUN_DIR"
log "▶ run_ab_repeats.sh 開始（run $RUN_ID$([ "$DRY_RUN" = true ] && echo '，dry-run')）"
preflight
vm "mkdir -p $VM_DIR" && scp -q -o BatchMode=yes "$REPO/benchmarks/stress_test.py" "$VM_HOST:$VM_DIR/stress_test.py" \
    || die "無法將 harness 複製到 VM"
if [ -f "$RUN_DIR/manifest.txt" ]; then
    # 續跑：記錄本次腳本與條件檔版本，供追溯中途修正
    echo "resumed_at=$(date -Iseconds) models=$MODELS rounds=$ROUNDS client_timeout_s=$CLIENT_TIMEOUT exclude=${EXCLUDE_NODES:-none} git_commit=$(git -C "$REPO" rev-parse --short HEAD) script_md5=$(md5sum "$0" | cut -d' ' -f1) conditions_md5=$(cat "$HERE"/conditions/*.env | md5sum | cut -d' ' -f1)" >> "$RUN_DIR/manifest.txt"
    log "↩️  續跑既有 run（已記錄於 manifest.txt）"
else
    write_manifest
    echo "script_md5=$(md5sum "$0" | cut -d' ' -f1) conditions_md5=$(cat "$HERE"/conditions/*.env | md5sum | cut -d' ' -f1)" >> "$RUN_DIR/manifest.txt"
fi

for m in ${MODELS//,/ }; do
    for r in ${ROUNDS//,/ }; do
        run_phase "$m" "$r"
    done
done

for fw in "${FRAMEWORKS[@]}"; do
    for m in dense moe kda; do rm -rf "$(engine_dir "$m" "$fw")"; done
done
if [ "$DRY_RUN" = true ]; then
    log "✅ dry-run 完成（未派送任何 job）；預覽目錄 $RUN_DIR 可刪除"
    exit 0
fi
restart_gateway   # 移除 abrep 別名
wait
python3 "$HERE/aggregate.py" "$RUN_DIR" && log "📊 彙整完成：$RUN_DIR/summary.md"
log "🏁 全部完成"
