#!/usr/bin/env python3
"""Recompute a documented selection of the paper's numbers from the raw data and check them.

Usage (from the repository root, Python >= 3.8, standard library only):
    python3 analysis/reproduce_paper_numbers.py

Each value is recomputed from the raw files (repeated runs in benchmarks/results/repeats/<RUN>/,
original single runs and platform runs in benchmarks/results/) and compared with the value
printed in the manuscript (hard-coded below as the expected value), after rounding to the
manuscript's precision. Exit status 0 = all selected values match.

Coverage: Tables 4-8 (means, SDs, paired ratios, speculative-decoding effects), the dense
cap decomposition and cap-80 result (Section 5.1), the KDA cross-instance statistics, the
original-run understatement, the 300 s / 600 s deadline results (Section 5.3), the Figure 2
bar heights and error bars, the transport-reset and deadline counts, the Table 9 success
rates, and the Section 6 concurrency-tuning and misconfiguration figures. Not covered:
P95 latencies, per-configuration SDs outside Tables 4-7, the cold-cache burst ranges, and
the gateway CPU/memory figures (recorded observations without raw telemetry).
"""
import glob
import json
import math
import os
import re
import statistics as st
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN = os.path.join(ROOT, "benchmarks", "results", "repeats", "20260928-153829")
ORIG = os.path.join(ROOT, "benchmarks", "results")

runs = {}
for f in glob.glob(os.path.join(RUN, "raw", "*-rep*.json")):
    m = re.match(r"([a-z]+)-(r\d(?:[a-z]\d+)?)-([a-z]+)-rep(\d+)\.json$", os.path.basename(f))
    with open(f) as fh:
        runs.setdefault((m[1], m[2], m[3]), {})[int(m[4])] = json.load(fh)

def tps(k, reps=None):
    d = runs[k]
    return [d[r]["tps"] for r in sorted(d) if reps is None or r in reps]

def ms(k, reps=None):
    x = tps(k, reps)
    return st.mean(x), st.stdev(x)

def pct(a, b):  # a relative to b, in percent
    return 100 * (a / b - 1)

def ratio_err(num, den):  # Figure 2(b): ratio of means and propagated dispersion (percentage points)
    (m2, s2), (m1, s1) = ms(num), ms(den)
    r = m2 / m1
    return 100 * (r - 1), 100 * r * math.sqrt((s2 / m2) ** 2 + (s1 / m1) ** 2)

def paired(model, rnd):
    a, b = runs[(model, rnd, "sglang")], runs[(model, rnd, "vllm")]
    p = [a[k]["tps"] / b[k]["tps"] for k in sorted(set(a) & set(b))]
    return st.mean(p), st.stdev(p)

def orig(name):
    with open(os.path.join(ORIG, name)) as fh:
        return json.load(fh)["tps"]

checks = []  # (label, computed, printed, decimals)
def check(label, value, printed, nd=0):
    checks.append((label, value, printed, nd))

# ---- Table 4 / 5 (dense)
for fw, (mu, sd) in {"sglang": (3882, 36), "vllm": (3541, 95)}.items():
    m, s = ms(("dense", "r1", fw)); check(f"dense R1 {fw} mean", m, mu); check(f"dense R1 {fw} SD", s, sd)
pm, ps = paired("dense", "r1"); check("dense paired S/V", pm, 1.097, 3); check("dense paired S/V SD", ps, 0.026, 3)
check("dense lead % (ratio of means)", pct(ms(("dense", "r1", "sglang"))[0], ms(("dense", "r1", "vllm"))[0]), 9.6, 1)
m, s = ms(("dense", "r1", "vllm"), reps={1, 2, 4, 5}); check("dense vLLM excl. rep3 mean", m, 3584); check("dense vLLM excl. rep3 SD", s, 13)
a, b = runs[("dense", "r1", "sglang")], runs[("dense", "r1", "vllm")]
p4 = [a[k]["tps"] / b[k]["tps"] for k in (1, 2, 4, 5)]
check("dense paired excl. rep3", st.mean(p4), 1.086, 3); check("dense paired excl. rep3 SD", st.stdev(p4), 0.011, 3)
check("cap 128->48, SGLang %", pct(ms(("dense", "r1c48", "sglang"))[0], ms(("dense", "r1", "sglang"))[0]), -47.3, 1)
check("cap 128->48, vLLM %", pct(ms(("dense", "r1c48", "vllm"))[0], ms(("dense", "r1", "vllm"))[0]), -45.9, 1)
check("EAGLE at equal cap 48 %", pct(ms(("dense", "r2", "sglang"))[0], ms(("dense", "r1c48", "sglang"))[0]), 14.8, 1)
check("dense SGLang R2 cap 80 vs R1 %", pct(ms(("dense", "r2c80", "sglang"))[0], ms(("dense", "r1", "sglang"))[0]), -34.1, 1)
pm, ps = paired("dense", "r1c48"); check("cap-48 plain control S/V", pm, 1.067, 3)

# ---- Table 6 (MoE)
check("MoE R1 SGLang mean", ms(("moe", "r1", "sglang"))[0], 3299); check("MoE R1 vLLM mean", ms(("moe", "r1", "vllm"))[0], 7921)
check("MoE vLLM advantage (x)", ms(("moe", "r1", "vllm"))[0] / ms(("moe", "r1", "sglang"))[0], 2.40, 2)
check("MoE vLLM vs SGLang best (x)", ms(("moe", "r1", "vllm"))[0] / ms(("moe", "r2", "sglang"))[0], 2.02, 2)
pm, ps = paired("moe", "r1"); check("MoE paired S/V", pm, 0.417, 3)

# ---- Table 7 (KDA) and cross-instance
check("KDA R1 SGLang mean", ms(("kda", "r1", "sglang"))[0], 3687); check("KDA R1 vLLM mean", ms(("kda", "r1", "vllm"))[0], 4719)
pm, ps = paired("kda", "r1"); check("KDA paired S/V", pm, 0.782, 3); check("KDA paired S/V SD", ps, 0.037, 3)
inst = ["r1", "r1i1", "r1i2", "r1i3"]
ratios = [ms(("kda", r, "sglang"))[0] / ms(("kda", r, "vllm"))[0] for r in inst]
check("KDA four-pair ratio mean", st.mean(ratios), 0.767, 3); check("KDA four-pair ratio SD", st.mean(ratios) and st.stdev(ratios), 0.010, 3)
for fw, cv in {"sglang": 1.0, "vllm": 2.0}.items():
    means = [ms(("kda", r, fw))[0] for r in inst]
    check(f"KDA cross-instance CV {fw} %", 100 * st.stdev(means) / st.mean(means), cv, 1)
means_v = [ms(("kda", r, "vllm"))[0] for r in inst]
check("KDA warmed instance means (vLLM)", st.mean(means_v), 4866); check("KDA warmed instance means SD", st.stdev(means_v), 98)
check("KDA original vLLM understatement %", -pct(orig("bench_ab_vllm_glm53_r1.json"), ms(("kda", "r1", "vllm"))[0]), 39, 0)
check("KDA vLLM R2 600 s vs R1 %", pct(ms(("kda", "r2t600", "vllm"))[0], ms(("kda", "r1", "vllm"))[0]), -48.7, 1)
check("KDA SGLang R2 300 s vs R1 %", pct(ms(("kda", "r2", "sglang"))[0], ms(("kda", "r1", "sglang"))[0]), -8.8, 1)
check("KDA SGLang disabling MTP gain %", pct(ms(("kda", "r1", "sglang"))[0], ms(("kda", "r2", "sglang"))[0]), 9.7, 1)
done = sum(v["success_count"] for v in runs[("kda", "r2t600", "vllm")].values())
check("KDA 600 s completed requests", done, 4997)
check("KDA 300 s worst per-rep not completed %", 100 - min(v["success_rate"] for v in runs[("kda", "r2", "vllm")].values()), 10.5, 1)

# ---- Figure 2 coordinates (panel b), as plotted in paper.tex
fig_b = {("dense", "sglang", "r2"): (-39.5, 0.6), ("dense", "vllm", "r2"): (-6.7, 2.6),
         ("moe", "sglang", "r2"): (19.1, 4.6), ("moe", "vllm", "r2"): (-44.5, 1.9),
         ("kda", "sglang", "r2"): (-8.8, 2.4), ("kda", "vllm", "r2t600"): (-48.7, 2.2)}
for (mo, fw, rr), (y, e) in fig_b.items():
    v, err = ratio_err((mo, rr, fw), (mo, "r1", fw))
    check(f"Figure 2b {mo} {fw} bar", v, y, 1); check(f"Figure 2b {mo} {fw} error bar", err, e, 1)

# ---- request-level counts across all repeated runs (per-request JSONL)
import gzip
resets = timeouts_kda_r2_vllm = timeouts_elsewhere = 0
for f in glob.glob(os.path.join(RUN, "raw", "*-rep*.jsonl.gz")):
    in_kda_r2_vllm = os.path.basename(f).startswith("kda-r2-vllm-rep")
    with gzip.open(f, "rt") as fh:
        for line in fh:
            e = json.loads(line).get("error", "")
            resets += e.startswith("ReadError")
            if e.startswith("ReadTimeout"):
                if in_kda_r2_vllm:
                    timeouts_kda_r2_vllm += 1
                else:
                    timeouts_elsewhere += 1
check("transport resets (ReadError), all repeated runs", resets, 11)
check("deadline misses (ReadTimeout), KDA vLLM R2 300 s", timeouts_kda_r2_vllm, 205)
check("deadline misses (ReadTimeout), all other conditions", timeouts_elsewhere, 0)

# ---- Table 9 (single runs) and Section 6 (single runs)
def one(path):
    with open(os.path.join(ORIG, path)) as fh:
        return json.load(fh)
check("Table 9 initial mixed run success %", one("client_vm/bench_mixed_1500_r2.json")["success_rate"], 67.9, 1)
check("Table 9 after client fix success %", one("bench_mixed_1500_users_via_tunnel.json")["success_rate"], 91.8, 1)
check("Table 9 after limits.conf fix success %", one("bench_mixed_1500_users_sshd_fd_fixed.json")["success_rate"], 100.0, 1)
check("Table 9 after limits.conf fix tok/s", one("bench_mixed_1500_users_sshd_fd_fixed.json")["tps"], 8146)
check("Sec. 6 MoE cap 48->100 aggregate %", pct(one("bench_result_1000_users_mrr100.json")["tps"], one("bench_result_1000_users_mrr48.json")["tps"]), 29, 0)
check("Sec. 6 KDA cap 64->128 aggregate %", pct(one("bench_glm53_1000_users_cap128.json")["tps"], one("bench_glm53_1000_users_cap64.json")["tps"]), 32, 0)
check("Sec. 1/6 dense misconfiguration fix %", pct(orig("bench_ab_sglang_27b_r1.json"), one("bench_27b_500_users.json")["tps"]), 48, 0)

# ---- report
bad = 0
for label, v, p, nd in checks:
    ok = round(v, nd) == round(p, nd)
    bad += not ok
    print(f"{'OK ' if ok else 'BAD'}  {label:42s} computed {v:12.4f}   paper {p}")
print(f"\n{len(checks) - bad}/{len(checks)} selected values match the recorded manuscript expectations.")
sys.exit(1 if bad else 0)
