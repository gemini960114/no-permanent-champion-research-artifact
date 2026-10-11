#!/usr/bin/env python3
"""Engine-log metrics of a repeated A/B run: speculative acceptance length and cap occupancy.

Usage: engine_log_metrics.py <run_dir>
Acceptance length (R2 rounds), as each engine reports it in its 10-second log lines:
  SGLang  "accept len" of decode-batch lines with #running-req >= half the round's cap
  vLLM    "Mean acceptance length" of SpecDecoding lines with accepted throughput >= 300 tok/s
Both filters keep the measured bursts and drop warm-up and idle intervals.
Cap occupancy (R1 rounds): among logging intervals with waiting requests, the share with
running requests >= 90% of the cap.
"""
import glob, os, re, statistics as st, sys

run = sys.argv[1]
logs = os.path.join(run, "engine_logs")
CAP_R1 = {"dense": 128, "moe": 256, "kda": 128}
CAP_R2_SGLANG = {"dense-r2": 48, "dense-r2c80": 80, "moe-r2": 256, "kda-r2": 128, "kda-r2t600": 128}

def q(v):
    a, _, c = st.quantiles(v, n=4)
    return f"median {st.median(v):.2f} (IQR {a:.2f}-{c:.2f}, n={len(v)})"

print("acceptance length")
for f in sorted(glob.glob(os.path.join(logs, "*-r2*"))):
    name = os.path.basename(f); model, rnd, fw = name.split("-")[:3]; t = open(f, errors="ignore").read()
    if fw == "sglang" and name.endswith(".err") and f"{model}-{rnd}" in CAP_R2_SGLANG:
        th = CAP_R2_SGLANG[f"{model}-{rnd}"] / 2
        v = [float(a) for r, a in re.findall(r"#running-req: (\d+),.*?accept len: ([0-9.]+)", t) if int(r) >= th]
    elif fw == "vllm" and name.endswith(".out"):
        v = [float(a) for a, acc in re.findall(r"Mean acceptance length: ([0-9.]+), Accepted throughput: ([0-9.]+)", t) if float(acc) >= 300]
    else:
        continue
    if len(v) >= 4:
        print(f"  {model:5s} {rnd:7s} {fw:6s} {q(v)}")

print("cap occupancy while requests wait (R1)")
for f in sorted(glob.glob(os.path.join(logs, "*-r1-*")) + glob.glob(os.path.join(logs, "*-r1i*"))):
    name = os.path.basename(f); model, rnd, fw = name.split("-")[:3]; t = open(f, errors="ignore").read()
    pat = r"#running-req: (\d+),.*?#queue-req: (\d+)" if fw == "sglang" else r"Running: (\d+) reqs, Waiting: (\d+) reqs"
    w = [(int(r), int(x)) for r, x in re.findall(pat, t) if int(x) > 0]
    if len(w) >= 4:
        full = sum(r >= 0.9 * CAP_R1[model] for r, _ in w)
        print(f"  {model:5s} {rnd:5s} {fw:6s} {100 * full / len(w):5.1f}% of {len(w)} intervals")
