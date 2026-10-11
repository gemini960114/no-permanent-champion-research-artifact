# Release manifest

Every item of the internal platform repository considered for this release, with the decision and its reason. File counts refer to this release; `SHA256SUMS` lists every file.

## Included

| Path in this release | Source in internal repository | Files | Reason |
| :--- | :--- | ---: | :--- |
| `benchmarks/results/bench_ab_*.json` | same | 13 | Original single-run A/B measurements (Tables 4–7) |
| `benchmarks/results/bench_*.json` (other) | same | 10 | Single-run platform measurements cited in §5.5 and §6 |
| `benchmarks/results/ab_run_node_mapping.csv` | same | 1 | Placement of the original single runs (§4) |
| `benchmarks/results/client_vm/` | recovered from the benchmark client VM (2026-09-29) | 3 | Client-side summary of the initial 67.9% mixed run and client output of the next run (Table 9) |
| `benchmarks/results/repeats/20260928-153829/` | same, **including files ignored by the internal `.gitignore`** (`*.log`, `*.err`, `*.out`) | see `SHA256SUMS` | All evidence of the repeated measurements and controls: per-run and per-request data, client logs, warm-ups, manifest, events, job records, effective configurations, engine logs, cap probe, cold/warm control, image digests |
| `benchmarks/results/repeats/20260928-153829/original_run_logs/` | `engines/*/logs/` (ignored internally) | 20 | Engine logs of the original single runs cited in §5.1 and §5.3 |
| `benchmarks/results/repeats/20260929-openloop-direct/` | same, including ignored logs | 193 | Open-loop streaming round sent directly to the engines |
| `benchmarks/results/repeats/20260929-openloop/` | same, including ignored logs | 134 | Open-loop round through the gateway, stopped early |
| `benchmarks/results/repeats/20260929-openloop-direct-aborted/` | same | 21 | Aborted first direct attempt, kept for completeness |
| `benchmarks/results/repeats/openloop_*chain.log` | same (ignored internally) | 2 | Orchestration logs of the open-loop runs |
| `benchmarks/results/tls_1500/` | same, including ignored logs | 65 | 1,500-user entry-point and client-protocol runs |
| `benchmarks/stress_test.py` | same | 1 | Client harness |
| `benchmarks/repeats/` | same | 16 + 36 conditions | Orchestration, probes, aggregation, condition files; chain scripts record how phases were sequenced |
| `engines/KNOWN_GOOD.md` | same | 1 | Validated-configuration registry (§3) |
| `.agents/skills/{model-onboarding,concurrency-troubleshooting,debug-journaling}/` | same | — | Evaluation skills described in §3 |
| `skills-lock.json` | same | 1 | Content hashes of the third-party writing skills |
| `analysis/reproduce_paper_numbers.py` | new for this release | 1 | Recomputes and checks the paper's headline numbers |
| `README.md`, `MANIFEST.md`, `SHA256SUMS`, `.gitattributes`, `LICENSE`, `LICENSE-DATA` | new / `LICENSE` | 6 | Documentation, integrity, line-ending policy, licenses (citation metadata withheld in this anonymized copy) (MIT for code, CC BY 4.0 for data and documentation) |

## Excluded

| Internal item | Reason |
| :--- | :--- |
| `.git/` (development history) | This release is a curated snapshot; history is not needed for verification |
| Gateway and auth: `config.yaml`, `config.runtime.yaml`, `custom_auth.py`, `key_tool.py`, `api_keys.json*` | Internal operational code and credentials |
| Lifecycle and routing: `start*.sh`, `stop*.sh`, `start_models.sh`, `new_engine.sh`, `validate_engine.sh`, `healthcheck.sh`, `install.sh`, `lib/`, `scripts/`, `runtime/` | Platform deployment code; out of scope (result verification, not deployment reproduction) |
| `engines/<engine>/` except `KNOWN_GOOD.md` (Slurm templates, `config.env*`, pull and download scripts, logs) | Deployment code and secrets; the effective configuration of every measured condition is in `repeats/.../conditions/` (redacted) and the cited logs are in `original_run_logs/` |
| `benchmarks/README.md` | Internal connection guide (tunnel, hosts) |
| `docs/`, `client/`, `README*.md`, `CHANGELOG.md` | Internal operational documentation |
| `.env*`, `.litellm_node`, `.litellm.pid`, `litellm.log` | Secrets and runtime state |
| `.agents/skills/external-review-loop/` and other local workflow skills | Local authoring workflow, not part of the study |
| Third-party writing skills (academic-writing-skills, etc.) | Not redistributed; pinned in `skills-lock.json` |
| `paper/` (manuscript, revision notes, upload bundle) | Withheld in this anonymized copy |
| Agent-session logs | Not curated as a research record; contain unredacted deployment details |
| `tests/`, `.venv/`, `__pycache__/`, `.claude/`, `.roo/` | Tooling not needed for verification |
| Model checkpoints and container images | Size and licensing; identified in `weights.txt`, `images.txt`, `image_sha256.txt` |

## Redaction applied to every text file (including `*.jsonl.gz`)

| Original | Placeholder |
| :--- | :--- |
| Compute-node host names (full and short forms) | `node-01` … `node-42`, consistent across all files |
| Login-node host name | `login-01` |
| Private IP addresses | `10.0.0.x` (login), `10.0.1.x` (compute), consistent |
| Public IP address of the client VM | `client-vm` |
| Node numbers written without a host prefix in free text | the corresponding `node-NN` |
| Repository, model, container, cache, home, and work paths | `<repo>`, `<models>`, `<containers>`, `<cache>`, `<hf-cache>`, `<home>`, `<vm-home>`, `<work>`, `<envstack>` |
| User name, UID, Slurm account | `<user>`, `UID`, `<account>` |
| Client VM and login host names; portal host | `client-vm`, `<login-host>`, `<portal-host>` |
| API keys (`sk-…`), Hugging Face tokens (`hf_…`) | `sk-<redacted>`, `hf_<redacted>` |

Timestamps, job IDs, line endings, and all measured values are unchanged.
