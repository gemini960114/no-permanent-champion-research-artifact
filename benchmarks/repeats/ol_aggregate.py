#!/usr/bin/env python3
"""Aggregate open-loop rounds (ol<req/s>) of a repeated A/B run.

Usage: ol_aggregate.py <run_dir>
Reads raw/<model>-ol<rate>-<framework>-rep<k>.json (+ .jsonl.gz) and prints, per model, arrival rate
and framework, mean ± sample SD over repetitions of: completion rate, output throughput, TTFT P50/P95,
TPOT P50/P95, and end-to-end latency P95. Writes ol_summary.csv next to the raw directory.
"""
import collections, csv, glob, gzip, json, os, re, statistics as st, sys

run = sys.argv[1]
rows = collections.defaultdict(list)
for f in sorted(glob.glob(os.path.join(run, "raw", "*-ol*-rep*.json"))):
    m = re.match(r"(\w+)-ol([0-9.]+)-(sglang|vllm)-rep(\d+)\.json$", os.path.basename(f))
    if not m:
        continue
    d = json.load(open(f))
    rows[(m.group(1), float(m.group(2)), m.group(3))].append(d)

METRICS = [("success_rate", "completion %", 1), ("tps", "tok/s", 0), ("ttft_p50", "TTFT P50 s", 2),
           ("ttft_p95", "TTFT P95 s", 2), ("tpot_p50", "TPOT P50 ms", 1), ("tpot_p95", "TPOT P95 ms", 1),
           ("p95_latency", "E2E P95 s", 1)]

def fmt(vals, nd, scale=1.0):
    vals = [v * scale for v in vals if v is not None]
    if not vals:
        return "—"
    sd = st.stdev(vals) if len(vals) > 1 else 0.0
    return f"{st.mean(vals):,.{nd}f} ± {sd:,.{nd}f}"

out = []
print(f"{'model':6s} {'rate':>5s} {'fw':6s} n  " + "  ".join(f"{label:>18s}" for _, label, _ in METRICS))
for (model, rate, fw), ds in sorted(rows.items()):
    cells = []
    rec = {"model": model, "arrival_rate": rate, "framework": fw, "n": len(ds)}
    for key, label, nd in METRICS:
        scale = 1000.0 if key.startswith("tpot") else 1.0
        vals = [d.get(key) for d in ds]
        cells.append(fmt(vals, nd, scale))
        good = [v * scale for v in vals if v is not None]
        rec[key + "_mean"] = st.mean(good) if good else ""
        rec[key + "_sd"] = (st.stdev(good) if len(good) > 1 else 0.0) if good else ""
    out.append(rec)
    print(f"{model:6s} {rate:5.1f} {fw:6s} {len(ds)}  " + "  ".join(f"{c:>18s}" for c in cells))

if out:
    with open(os.path.join(run, "ol_summary.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out[0].keys()))
        w.writeheader(); w.writerows(out)
