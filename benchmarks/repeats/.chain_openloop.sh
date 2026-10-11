#!/bin/bash
# Open-loop rounds after the TLS 1,500-user test: 3 reps each, 600 s client deadline, 300 s arrival span
cd "$(dirname "$(readlink -f "$0")")"
TLS=<repo>/benchmarks/results/tls_1500/manifest.txt
until grep -q '^finished=' "$TLS" 2>/dev/null; do sleep 30; done
RUN=20260929-openloop
EXC=node-20,node-26,node-29,node-30,node-32,node-39
./run_ab_repeats.sh --run-id $RUN --reps 3 --timeout 600 --exclude $EXC --models dense --rounds ol4.5,ol8 &&
./run_ab_repeats.sh --run-id $RUN --reps 3 --timeout 600 --exclude $EXC --models moe   --rounds ol3,ol6 &&
./run_ab_repeats.sh --run-id $RUN --reps 3 --timeout 600 --exclude $EXC --models kda   --rounds ol2.5,ol4.5
echo "chain_exit=$? at $(date -Iseconds)"
