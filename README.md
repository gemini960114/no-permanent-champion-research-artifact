# No Permanent Champion — research artifact (v1.0, submission)

Experimental materials for the paper **"No Permanent Champion: A Deployment Study of SGLang and vLLM across Dense, Ultra-Sparse MoE, and KDA-Hybrid Architectures on H200 GPUs"** (Chuang, Lin, and Huang, 2026).

This repository is a **curated snapshot** of the data, scripts, configurations, and redacted execution logs behind the paper. It supports **result verification and re-analysis**. It is **not** a deployment package: the serving platform's gateway, engine-lifecycle, and routing code, the model checkpoints, and the container images are not included (see [What is not included](#what-is-not-included)).

## Verify the paper's numbers

Requires Python ≥ 3.8 and the standard library only:

```bash
python3 analysis/reproduce_paper_numbers.py            # selected values vs. the manuscript; exit 0 = all match
python3 benchmarks/repeats/aggregate.py benchmarks/results/repeats/20260928-153829
                                                       # regenerates summary.md / summary.csv for the run
```

`reproduce_paper_numbers.py` recomputes a documented selection of the paper's numbers from the raw files and compares each with the value printed in the manuscript (hard-coded in the script as the expected value; the script does not parse the paper). The selection covers Tables 4–8, the §5.1 cap decomposition, the §5.3 cross-instance, original-run, and deadline results, the Figure 2 bar heights and error bars, the transport-reset and deadline-miss counts, the Table 9 success rates, and the §6 concurrency-tuning and misconfiguration figures. It does not cover P95 latencies, the cold-cache burst ranges, or the gateway CPU/memory figures (see *Evidence levels*). Figure 2 is drawn with TikZ/pgfplots in `paper/paper.tex` from the checked values.

## Repository layout

| Path | Contents | Paper |
| :--- | :--- | :--- |
| `paper/` | Manuscript (`paper.md`, `paper.tex`, `refs.bib`) and compiled `paper.pdf` | — |
| `benchmarks/results/bench_ab_*.json` | Original single-run A/B measurements (2026-09-27, no warm-up) | Tables 4–7, "original single run" |
| `benchmarks/results/bench_*.json` (others) | Single-run platform measurements: mixed 1,500-user load, concurrency-cap tuning | §5.5, §6 |
| `benchmarks/results/ab_run_node_mapping.csv` | Job-to-node placement of the original single runs | §4 |
| `benchmarks/results/client_vm/` | Client-side records of the mixed 1,500-user runs recovered from the benchmark VM, including the initial 67.9% run | §5.5, Table 9 |
| `benchmarks/results/repeats/20260928-153829/` | Repeated measurements (2026-09-28/29) — see below | §4–§5 |
| `benchmarks/stress_test.py` | Client harness (httpx load generator; per-run summary and per-request JSONL) | §4 |
| `benchmarks/repeats/` | Orchestration (`run_ab_repeats.sh`), cap probe (`probe_caps.sh`), cold/warm JIT control (`cold_cache.sh`), aggregation (`aggregate.py`), and condition files | §4, §5.1, §5.3 |
| `engines/KNOWN_GOOD.md` | Registry of validated engine configurations (image × weights × flags) | §3 |
| `.agents/skills/` | Evaluation skills: model-onboarding, concurrency-troubleshooting, debug-journaling | §3 |
| `skills-lock.json` | Content hashes of the third-party manuscript-writing skills (not redistributed) | AI-Use Disclosure |
| `analysis/` | `reproduce_paper_numbers.py` | all |

### The repeated-measurement run (`benchmarks/results/repeats/20260928-153829/`)

| Path | Contents |
| :--- | :--- |
| `raw/<model>-<round>-<framework>-rep<k>.json` | Per-burst summary: throughput, latency percentiles, success counts, tokens |
| `raw/*.jsonl.gz` | Per-request records: start time, latency, tokens, finish reason, output fingerprint (SHA-256 and length; no text), error |
| `raw/*.client.log`, `warmup/` | Client output of every burst; warm-up bursts (excluded from statistics) |
| `summary.md`, `summary.csv` | Aggregated tables (mean ± SD, paired ratios, speculative-decoding effects, cap decomposition, order effects) |
| `manifest.txt` | Protocol parameters, harness hashes, and every mid-run deviation with its cause |
| `events.log` | Timeline of every engine start, gateway restart, burst, and result |
| `jobs.psv` | Slurm job records (job, node, start/end, state, allocated resources) |
| `conditions/*.config.env` | Effective engine configuration of every condition (secrets redacted) |
| `engine_logs/` | Engine stdout/stderr of every job, including failed starts |
| `original_run_logs/` | Engine logs of the original single runs cited in §5.1 and §5.3 (e.g. runtime TileLang compilation) |
| `cap_probe/` | SGLang dense EAGLE cap-feasibility sweep (`results.tsv` and per-cap logs) |
| `cold_cache/` | Cold/warm TileLang-cache control (`jit_counts.tsv`, bursts, engine logs) |
| `images.txt`, `image_sha256.txt`, `weights.txt` | Container image names with SHA-256, and weight-file listings |

Rounds: `r1` plain; `r2` speculative decoding; `r1c48` dense plain control at cap 48; `r2c80` dense SGLang EAGLE at cap 80; `r2t600` KDA R2 with a 600 s client deadline; `r1i1`–`r1i3` three further KDA R1 engine-instance pairs.

## Protocol summary

- Same local checkpoint for both frameworks; engine parameters derived from each framework's official per-model documentation, with the overrides recorded in `benchmarks/repeats/conditions/`.
- Both engines online together as isolated copies; five bursts per main configuration and two per additional KDA instance pair (`r1i1`–`r1i3`); leading framework swapped every repetition (odd: SGLang first, even: vLLM first).
- Warm-up of 64 concurrent requests × max_tokens 64 before measurement; 60 s cooldown between bursts.
- Workloads: dense 500 requests × max_tokens 500; MoE and KDA 1,000 × 800; five fixed short prompts at temperature 0.7.
- Client request deadline 300 s (600 s in `r2t600`); gateway upstream timeout 600 s; the benchmark key has no rate limit.

## Known exceptions (also disclosed in the paper)

- **Dense vLLM R1 rep3** was re-run on a fresh engine instance after a client-side failure and did not receive the client warm-up (3,372 tok/s, 5.9% below the other four). The paper reports a sensitivity analysis excluding it.
- **Dense SGLang R2** runs at cap 48, set explicitly: EAGLE cannot allocate KV cache at cap 128. The sweep found cap 80 feasible and 96, 112, and 128 not; caps 81–95 were not tested.
- **KDA vLLM R2 at 300 s**: 0–10.5% of requests per repetition were not completed within the client deadline. At 600 s, 4,997 of 5,000 completed; the other three were early transport resets.
- **Transport resets**: 11 requests across all repeated runs were lost about 1.5 s after submission, before any response.
- **Cold/warm JIT control**: confirmed that runtime-JIT warnings occur only in a first burst without warm-up, but did not isolate their throughput cost, and did not reproduce the original run's cache state.
- **Excluded nodes**: several compute nodes were excluded after hardware or runtime faults; see `manifest.txt`.

## Evidence levels

| Level | Items |
| :--- | :--- |
| Raw records, recomputable | All repeated measurements and controls; the original single-run A/B measurements; the Table 9 mixed runs (including the initial 67.9% run, `client_vm/`); the §6 concurrency-tuning and misconfiguration runs |
| Raw logs, inspectable | Engine logs of the repeated runs and of the original single runs cited in §5.1 and §5.3 (e.g. runtime TileLang compilation, cache sizes); cap-probe and cold-cache logs |
| Recorded observations only | Gateway CPU and memory figures (Table 1, §5.5), noted in the operations log at the time; no raw telemetry was retained |

`manifest.txt` records historical identifiers of the internal execution environment (internal commit, harness MD5); they refer to that environment. The released files are identified by `SHA256SUMS`, and redacted files differ from their internal originals.

## Redaction

Host names, network addresses, account and user identifiers, file-system paths, API keys, and tokens are replaced by placeholders. Compute nodes are mapped consistently (`node-01` … `node-31`) across all files, so that same-node and different-node placements and the event timeline remain traceable; timestamps are unchanged. Placeholders include `<repo>`, `<models>`, `<containers>`, `<cache>`, `<work>`, `<account>`, `<user>`, `client-vm`, and `login-01`.

## What is not included

| Not included | Reason |
| :--- | :--- |
| Platform code: LiteLLM gateway configuration, authentication, engine-lifecycle and routing scripts, engine Slurm templates | Internal operational code; not needed to verify or re-analyse the results. The orchestration scripts here reference it and are provided as a record of the procedure, not as a turnkey deployment |
| Development history of the internal platform repository | Not needed for verification; this repository is a snapshot |
| Agent-session logs | Not curated as a research record; contain unredacted deployment details |
| Operational documents (network access, tunnel, TLS, key management) | Internal and security-sensitive |
| Model checkpoints and container images | Size and licensing; identified by name, file listing, and (for images) SHA-256 in `images.txt` / `image_sha256.txt` |
| Third-party manuscript-writing skills | Not redistributed; pinned by content hash in `skills-lock.json` |

`MANIFEST.md` lists every included and excluded item with its reason, and `SHA256SUMS` covers every file.

## License

| Path | License |
| :--- | :--- |
| Code: `analysis/`, `benchmarks/stress_test.py`, `benchmarks/repeats/` (except `conditions/`), and every executable script elsewhere, including `.agents/skills/*/scripts/` | MIT (`LICENSE`) |
| Data, logs, configurations, and documentation: `benchmarks/results/`, `benchmarks/repeats/conditions/`, `engines/KNOWN_GOOD.md`, the skill instructions and documentation in `.agents/skills/` (`SKILL.md`, `README.md`), `README.md`, `MANIFEST.md` | CC BY 4.0 (`LICENSE-DATA`) |
| `paper/` | © 2026 the authors; not covered by the repository licenses |
| Third-party software output within logs | Remains under the respective projects' licenses |

Where a path matches both rows, executable scripts are MIT and everything else is CC BY 4.0.

## Citation

Please cite both the paper and the artifact version you used. `CITATION.cff` describes this artifact, so GitHub's "Cite this repository" produces the artifact citation; the paper is listed there under `references`.

- **Artifact:** Chao-Chun Chuang, Po-Hsiang Lin, and Liang-Hsun Huang. *No Permanent Champion: research artifact*, version 1.0, 2026. https://github.com/gemini960114/no-permanent-champion-research-artifact (DOI to be added on archiving)
- **Paper:** Chao-Chun Chuang, Po-Hsiang Lin, and Liang-Hsun Huang. *No Permanent Champion: A Deployment Study of SGLang and vLLM across Dense, Ultra-Sparse MoE, and KDA-Hybrid Architectures on H200 GPUs*, 2026.
