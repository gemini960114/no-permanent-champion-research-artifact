#!/bin/bash
# Follow-up to the TLS/tunnel runs: 4 paths interleaved, 2 reps each (same 1,500-user mixed workload, 300 s deadline)
#   tls-http1  VM -> Caddy TLS -> tunnel -> gateway, client HTTP/1.1
#   tls-http2  same, client HTTP/2 (harness default); VM :443 established connections sampled every 2 s
#   tunnel     VM -> plain tunnel endpoint -> gateway
#   bypass     login node -> gateway directly (no VM, no tunnel)
OUT=<repo>/benchmarks/results/tls_1500
REPO=<repo>
H=$OUT/stress_test_h1_diag.py          # stress_test.py with HTTP/2 controlled by BENCH_HTTP2 (default on)
vm() { ssh -o BatchMode=yes -o ServerAliveInterval=30 client-vm "$@"; }
scp -q $H client-vm:abrep/tls1500/stress_test_h1_diag.py
MODELS='glm5.3-flash,qwen3.8-flash,qwen3.8'
ARGS='-c 1500 -n 1500 --max-tokens 500 --timeout 300 --skip-check'
{ echo "followup_started=$(date -Iseconds) harness_diag_md5=$(md5sum $H | cut -d' ' -f1)"; echo "followup engines: $(squeue -u $USER -h -o '%i:%j:%N' | grep -v abrep | tr '\n' ' ')"; } >> $OUT/manifest.txt
run_vm() {  # $1 name $2 base-url $3 BENCH_HTTP2 $4 sample443(yes/no)
  local name=$1 url=$2 h2=$3 s=$4
  vm "cd ~ && set -a && . ~/.env && set +a && \
      ( vmstat -n 2 > abrep/tls1500/$name.vmstat & echo \$! > abrep/tls1500/vm.pid ) && \
      ( [ $s = yes ] && while :; do echo \"\$(date +%s) \$(ss -Htn state established '( sport = :443 )' | wc -l)\"; sleep 2; done > abrep/tls1500/$name.conn443 & echo \$! > abrep/tls1500/ss.pid ) ; \
      BENCH_HTTP2=$h2 BENCH_MODELS='$MODELS' ~/venv-bench/bin/python abrep/tls1500/stress_test_h1_diag.py --base-url $url $ARGS \
        --output-json abrep/tls1500/$name.json --per-request-jsonl abrep/tls1500/$name.jsonl > abrep/tls1500/$name.client.log 2>&1; \
      kill \$(cat abrep/tls1500/vm.pid) 2>/dev/null; [ $s = yes ] && kill \$(cat abrep/tls1500/ss.pid) 2>/dev/null; true"
  scp -q client-vm:"abrep/tls1500/$name.*" $OUT/ && gzip -f $OUT/$name.jsonl
}
run_bypass() {  # $1 name  (client on the login node, straight to the gateway)
  local name=$1 key
  key=$(vm 'grep -m1 "^LITELLM_API_KEY=" ~/.env | cut -d= -f2- | tr -d "\"'"'"'"')
  LITELLM_API_KEY="$key" BENCH_MODELS="$MODELS" $REPO/.venv/bin/python3 $H --base-url http://10.0.0.36:54921/v1 $ARGS \
    --output-json $OUT/$name.json --per-request-jsonl $OUT/$name.jsonl > $OUT/$name.client.log 2>&1
  gzip -f $OUT/$name.jsonl
}
for k in 2 3; do
  for path in tls-http1 tunnel bypass tls-http2; do
    name=mixed1500-$path-f$k; [ $path = tls-http1 ] && name=mixed1500-tls-http1-rep$k
    sleep 60; echo "$(date -Iseconds) start $name" >> $OUT/manifest.txt
    case $path in
      tls-http1) run_vm $name https://client-vm.biobank.org.tw/v1 0 no ;;
      tls-http2) run_vm $name https://client-vm.biobank.org.tw/v1 1 yes ;;
      tunnel)    run_vm $name '${LITELLM_BASE_URL%/}' 1 no ;;
      bypass)    run_bypass $name ;;
    esac
    python3 -c "import json;d=json.load(open('$OUT/$name.json'));print('$name', f\"success {d['success_rate']:.1f}% tps {d['tps']:.0f} p95 {d['p95_latency']:.1f}s\")" >> $OUT/manifest.txt
  done
done
echo "followup_finished=$(date -Iseconds)" >> $OUT/manifest.txt
