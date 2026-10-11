#!/usr/bin/env python3
"""
aggregate.py — 彙整 run_ab_repeats.sh 的重複量測結果

用法：python3 benchmarks/repeats/aggregate.py benchmarks/results/repeats/<RUN_ID>
輸出：<RUN_DIR>/summary.csv（每條件一列）與 summary.md（論文用表格＋與原始單次量測對照）

統計：樣本標準差（n−1）；框架差距同時報「平均值比」與「逐 rep 配對比值的平均 ± SD」
（同一 rep 的兩框架背靠背執行，配對比值較能抵消時段漂移）。
成功率 < 100% 的 rep 為截尾量測（逾時請求不計 tokens），在表中以 † 標示。
"""
import csv
import glob
import json
import os
import re
import statistics
import sys

MODELS = ["dense", "moe", "kda"]
ROUNDS = ["r1", "r2", "r1c48", "r2t600"]   # r1c48：dense 對照組（不開投機解碼、cap 48）；r2t600：kda R2、client 上限 600 秒
FWS = ["sglang", "vllm"]
LABEL = {"dense": "Dense hybrid (Qwen3.8-27B)", "moe": "Ultra-sparse MoE (Qwen3.8-Flash-Next)",
         "kda": "KDA-hybrid MoE (GLM-5.3-Flash)"}
# 論文原始單次量測（benchmarks/results/bench_ab_*.json）
ORIGINAL = {
    ("dense", "r1", "sglang"): "bench_ab_sglang_27b_r1.json",
    ("dense", "r1", "vllm"): "bench_ab_vllm_27b_r1.json",
    ("dense", "r2", "sglang"): "bench_ab_sglang_27b_r2_eagle.json",
    ("dense", "r2", "vllm"): "bench_ab_vllm_27b_r2_mtp.json",
    ("moe", "r1", "sglang"): "bench_ab_sglang_flash_r1b_ple_gpu.json",
    ("moe", "r1", "vllm"): "bench_ab_vllm_flash_r1.json",
    ("moe", "r2", "sglang"): "bench_ab_sglang_flash_r2.json",
    ("moe", "r2", "vllm"): "bench_ab_vllm_flash_r2.json",
    ("kda", "r1", "sglang"): "bench_ab_sglang_glm53_r1.json",
    ("kda", "r1", "vllm"): "bench_ab_vllm_glm53_r1.json",
    ("kda", "r2", "sglang"): "bench_ab_sglang_glm53_r2.json",
    ("kda", "r2", "vllm"): "bench_ab_vllm_glm53_r2.json",
}


def mean_sd(xs):
    if not xs:
        return None, None
    return statistics.mean(xs), (statistics.stdev(xs) if len(xs) > 1 else 0.0)


def fmt(m, s, digits=0):
    if m is None:
        return "—"
    return f"{m:,.{digits}f} ± {s:,.{digits}f}"


def main(run_dir):
    results_dir = os.path.abspath(os.path.join(run_dir, "..", ".."))
    runs = {}   # (model, round, fw) -> {rep: summary}
    for path in glob.glob(os.path.join(run_dir, "raw", "*.json")):
        mt = re.match(r"([a-z]+)-(r\d(?:[a-z]\d+)?)-([a-z]+)-rep(\d+)\.json$", os.path.basename(path))
        if not mt:
            continue
        m, r, fw, k = mt.group(1), mt.group(2), mt.group(3), int(mt.group(4))
        with open(path, encoding="utf-8") as f:
            runs.setdefault((m, r, fw), {})[k] = json.load(f)

    # 回合依資料動態決定：r1、r2 在前，其餘對照組（r1c48、r2t600、r2c<cap>…）依名稱排序
    found = sorted({r for (_, r, _) in runs})
    rounds = [r for r in ROUNDS if r in found] + [r for r in found if r not in ROUNDS]
    rows = []
    for m in MODELS:
        for r in rounds:
            for fw in FWS:
                reps = runs.get((m, r, fw), {})
                if not reps:
                    continue
                tps = [d["tps"] for d in reps.values()]
                p95 = [d["p95_latency"] for d in reps.values()]
                succ = [d["success_rate"] for d in reps.values()]
                tok = [d["total_tokens"] for d in reps.values()]
                tm, ts = mean_sd(tps)
                orig = None
                op = os.path.join(results_dir, ORIGINAL.get((m, r, fw), "-"))
                if os.path.exists(op):
                    with open(op, encoding="utf-8") as f:
                        orig = json.load(f)["tps"]
                rows.append({
                    "model": m, "round": r, "framework": fw, "n": len(reps),
                    "tps_mean": tm, "tps_sd": ts,
                    "tps_cv_pct": 100 * ts / tm if tm else None,
                    "tps_min": min(tps), "tps_max": max(tps),
                    "p95_mean": statistics.mean(p95), "p95_sd": mean_sd(p95)[1],
                    "success_mean": statistics.mean(succ), "success_min": min(succ),
                    "censored_reps": sum(1 for s in succ if s < 100),
                    "tokens_mean": round(statistics.mean(tok)),
                    "original_single_run_tps": round(orig, 1) if orig else None,
                    "reps_tps": ";".join(f"{k}:{reps[k]['tps']:.1f}" for k in sorted(reps)),
                })

    with open(os.path.join(run_dir, "summary.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["model"])
        w.writeheader()
        w.writerows([{k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()} for r in rows])

    idx = {(x["model"], x["round"], x["framework"]): x for x in rows}
    out = [f"# A/B 重複量測彙整（{os.path.basename(os.path.normpath(run_dir))}）", "",
           "數值為 mean ± SD（樣本標準差）；† = 至少一個 rep 成功率 < 100%（截尾量測）。", "",
           "## 各條件吞吐（tok/s）", "",
           "| 模型 | 回合 | 框架 | n | 吞吐 mean ± SD | CV | 範圍 | P95 (s) | 成功率 (min) | 原始單次 |",
           "| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: | ---: |"]
    for x in rows:
        dag = " †" if x["censored_reps"] else ""
        out.append(f"| {x['model']} | {x['round']} | {x['framework']} | {x['n']} | "
                   f"{fmt(x['tps_mean'], x['tps_sd'])}{dag} | {x['tps_cv_pct']:.2f}% | "
                   f"{x['tps_min']:,.0f}–{x['tps_max']:,.0f} | {x['p95_mean']:.1f} ± {x['p95_sd']:.1f} | "
                   f"{x['success_min']:.1f}% | {x['original_single_run_tps'] or '—'} |")

    out += ["", "## 框架差距（SGLang ÷ vLLM）", "",
            "| 模型 | 回合 | 平均值比 | 逐 rep 配對比 mean ± SD | 領先方 |", "| :--- | :--- | ---: | ---: | :--- |"]
    for m in MODELS:
        for r in rounds:
            a, b = runs.get((m, r, "sglang"), {}), runs.get((m, r, "vllm"), {})
            if not a or not b:
                continue
            ratio = idx[(m, r, "sglang")]["tps_mean"] / idx[(m, r, "vllm")]["tps_mean"]
            paired = [a[k]["tps"] / b[k]["tps"] for k in sorted(set(a) & set(b))]
            pm, ps = mean_sd(paired)
            lead = "SGLang" if ratio > 1 else "vLLM"
            out.append(f"| {LABEL[m]} | {r} | {ratio:.3f} | {pm:.3f} ± {ps:.3f} (n={len(paired)}) | {lead} |")

    out += ["", "## 投機解碼效果（R2 ÷ R1，同框架）", "",
            "| 模型 | 框架 | R2/R1 | 變化 |", "| :--- | :--- | ---: | ---: |"]
    for m in MODELS:
        for fw in FWS:
            r1 = idx.get((m, "r1", fw))
            for rr in [r for r in rounds if r.startswith("r2")]:
                tag = "" if rr == "r2" else f"（{rr}）"
                r2 = idx.get((m, rr, fw))
                if r1 and r2:
                    q = r2["tps_mean"] / r1["tps_mean"]
                    cen = " †" if r2["censored_reps"] else ""
                    out.append(f"| {LABEL[m]} | {fw}{tag} | {q:.3f}{cen} | {100 * (q - 1):+.1f}% |")

    # 順序效應：交錯設計下（奇數 rep SGLang 先、偶數 rep vLLM 先），比較同框架「先跑」與「後跑」的平均吞吐
    out += ["", "## 順序效應（交錯設計驗證）", "",
            "奇數 rep SGLang 先、偶數 rep vLLM 先；差異＝後跑平均 ÷ 先跑平均 − 1。", "",
            "| 模型 | 回合 | 框架 | 先跑 (n) | 後跑 (n) | 差異 |", "| :--- | :--- | :--- | ---: | ---: | ---: |"]
    for m in MODELS:
        for r in rounds:
            for fw in FWS:
                reps = runs.get((m, r, fw), {})
                first = [d["tps"] for k, d in reps.items() if (k % 2 == 1) == (fw == "sglang")]
                second = [d["tps"] for k, d in reps.items() if (k % 2 == 1) != (fw == "sglang")]
                if first and second:
                    f_, s_ = statistics.mean(first), statistics.mean(second)
                    out.append(f"| {m} | {r} | {fw} | {f_:,.0f} ({len(first)}) | {s_:,.0f} ({len(second)}) | {100 * (s_ / f_ - 1):+.1f}% |")

    # dense 對照組：拆解 SGLang R2 的變化＝cap 效果 × 投機解碼效果
    s1, s48, s2 = idx.get(("dense", "r1", "sglang")), idx.get(("dense", "r1c48", "sglang")), idx.get(("dense", "r2", "sglang"))
    if s1 and s48 and s2:
        cap = s48["tps_mean"] / s1["tps_mean"]
        spec = s2["tps_mean"] / s48["tps_mean"]
        out += ["", "## Dense SGLang R2 拆解（cap-48 對照組）", "",
                "| 比較 | 比值 | 變化 |", "| :--- | ---: | ---: |",
                f"| cap 128→48（R1-cap48 ÷ R1） | {cap:.3f} | {100 * (cap - 1):+.1f}% |",
                f"| EAGLE 本身（R2 ÷ R1-cap48，同 cap 48） | {spec:.3f} | {100 * (spec - 1):+.1f}% |",
                f"| 合計（R2 ÷ R1） | {cap * spec:.3f} | {100 * (cap * spec - 1):+.1f}% |"]

    with open(os.path.join(run_dir, "summary.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
