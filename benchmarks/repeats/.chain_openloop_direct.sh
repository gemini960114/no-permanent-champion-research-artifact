#!/bin/bash
# Open-loop rounds measured directly against the engines (client on the login node; no VM, tunnel, or gateway):
# 3 reps each, 600 s client deadline, 300 s arrival span. The gateway-path run 20260929-openloop is kept as
# evidence of the gateway's single-worker streaming ceiling.
cd "$(dirname "$(readlink -f "$0")")"
RUN=20260929-openloop-direct
EXC=node-20,node-26,node-29,node-30,node-32,node-39
./run_ab_repeats.sh --direct --run-id $RUN --reps 3 --timeout 600 --exclude $EXC --models dense --rounds ol4.5,ol8 &&
./run_ab_repeats.sh --direct --run-id $RUN --reps 3 --timeout 600 --exclude $EXC --models moe   --rounds ol3,ol6 &&
./run_ab_repeats.sh --direct --run-id $RUN --reps 3 --timeout 600 --exclude $EXC --models kda   --rounds ol2.5,ol4.5
echo "chain_exit=$? at $(date -Iseconds)"
