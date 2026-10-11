#!/usr/bin/env python3
"""GPU-hours of a repeated A/B run: sum over jobs of (End - Start) x allocated GPUs.

Usage: gpu_hours.py <run_dir>
  slurm_accounting.psv  every Slurm allocation of the campaign (sacct -X, so job steps are not
                        double-counted): probes, cold-cache control, failed and aborted starts included
  jobs.psv              the jobs the orchestration recorded (30 jobs, including some FAILED attempts)
Per-model cost counts the R1+R2 attempts that produced the reported measurements: an attempt is the
pair of engine jobs started together for one round; attempts in which either job FAILED are excluded.
"""
import re, sys, os, collections
from datetime import datetime as D

def gpuh(start, end, tres):
    m = re.search(r"gres/gpu=(\d+)", tres)
    return (D.fromisoformat(end) - D.fromisoformat(start)).total_seconds() / 3600 * (int(m.group(1)) if m else 0)

run = sys.argv[1]
acc = [l.rstrip("\n").split("|") for l in open(os.path.join(run, "slurm_accounting.psv"))][1:]
acc = [r for r in acc if r[3] not in ("Unknown", "None") and r[4] not in ("Unknown", "None")]
print(f"campaign (slurm_accounting.psv): {len(acc)} jobs, {sum(gpuh(r[3], r[4], r[6]) for r in acc):.1f} GPU-hours")

jobs = [l.rstrip("\n").split("|") for l in open(os.path.join(run, "jobs.psv"))]
print(f"recorded (jobs.psv): {len(jobs)} jobs, {sum(gpuh(r[4], r[5], r[7]) for r in jobs):.1f} GPU-hours")

attempts = collections.defaultdict(list)          # (round, start minute) -> jobs
for r in jobs:
    attempts[(r[0], r[4][:16])].append(r)
cost = collections.defaultdict(float)
for (rnd, _), js in attempts.items():
    model, rd = rnd.split(",")
    if rd not in ("r1", "r2") or any(j[6].startswith("FAILED") for j in js):
        continue
    cost[model] += sum(gpuh(j[4], j[5], j[7]) for j in js)
for m in ("dense", "moe", "kda"):
    print(f"R1+R2 measurement cost {m}: {cost[m]:.2f} GPU-hours")
