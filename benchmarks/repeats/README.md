# A/B 重複量測（論文 Table 3–8 補跑）

`run_ab_repeats.sh` 將論文的 12 種 A/B 條件（3 模型 × 2 框架 × R1/R2）各重跑 N 次（預設 5），
並保留完整證據，供論文報告 mean ± SD。原始單次量測（`benchmarks/results/bench_ab_*.json`）不動。

## 執行

```bash
# 於 Gateway 部署節點（login-01）
benchmarks/repeats/run_ab_repeats.sh --dry-run          # 前置檢查＋計畫預覽，不派送 job
nohup benchmarks/repeats/run_ab_repeats.sh > ~/abrep.log 2>&1 &   # 正式執行（數小時）
benchmarks/repeats/run_ab_repeats.sh --run-id <ID>      # 中斷後續跑，已完成的 rep 自動略過
```

常用參數：`--models dense,moe,kda`、`--rounds r1,r2`、`--reps 5`、`--cooldown 60`、
`--account <計畫代號>`、`--no-sif-hash`。

## 做法

| 項目 | 做法 |
| :--- | :--- |
| 生產隔離 | 每個條件複製原引擎為 `engines/_abrep-<模型>-<框架>/`，`ALIAS_CLAIM=isolated`、別名 `abrep-<模型>-<框架>`；不碰生產引擎 |
| 條件 | `conditions/<模型>-<框架>-<r1\|r2>.env` 覆寫 cap 與投機解碼參數，取自原始戰報（`benchmarks/README.md`） |
| 同時段 | 同一 phase 兩框架同時在線；奇數 rep SGLang 先、偶數 rep vLLM 先 |
| 暖機 | 每框架先跑 64 筆 × 64 tokens 的 warm-up（存於 `warmup/`，不計入統計） |
| 路徑 | VM → 反向隧道 → Gateway → 引擎（與原始量測相同）；client 在 VM 上執行，金鑰不離開 VM |
| Gateway | 每個 phase 開始與結束各重啟一次（約 10 秒中斷） |

## 產出（`benchmarks/results/repeats/<RUN_ID>/`）

| 檔案 | 內容 |
| :--- | :--- |
| `manifest.txt` | git commit、harness md5（本機與 VM）、VM Python/httpx 版本、參數 |
| `images.txt` / `image_sha256.txt` | 容器映像路徑與 sha256 |
| `weights.txt` | 權重目錄的 JSON 檔 sha256 與 safetensors 大小／時間戳 |
| `conditions/*.config.env` | 每條件實際使用的 config（金鑰已遮蔽） |
| `raw/<模型>-<回合>-<框架>-rep<k>.json` | 每次壓測的 summary |
| `raw/*.jsonl.gz` | 逐筆明細：延遲、tokens、finish_reason、輸出 sha256 與字元數、錯誤 |
| `raw/*.client.log` | client 完整輸出 |
| `engine_logs/` | 引擎 Slurm stdout/stderr |
| `jobs.psv` | sacct：Job、節點、起訖時間、狀態、配置資源 |
| `events.log` | 全流程時間線 |
| `summary.csv` / `summary.md` | `aggregate.py` 彙整：mean ± SD、CV、配對比值、R2/R1 |
