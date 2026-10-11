#!/bin/bash
# 1,500-user mixed load: TLS front end vs. plain tunnel endpoint, interleaved, 3 each
OUT=<repo>/benchmarks/results/tls_1500
REPO=<repo>
vm() { ssh -o BatchMode=yes -o ServerAliveInterval=30 client-vm "$@"; }
vm 'mkdir -p ~/abrep/tls1500' && scp -q $REPO/benchmarks/stress_test.py client-vm:abrep/tls1500/stress_test.py
{ echo "started=$(date -Iseconds)"; echo "harness_md5=$(md5sum $REPO/benchmarks/stress_test.py | cut -d' ' -f1)";
  echo "workload=1500 concurrent x 1500 requests x max_tokens 500; models glm5.3-flash,qwen3.8-flash,qwen3.8 round-robin; client timeout 300 s";
  echo "engines: $(squeue -u $USER -h -o '%i:%j:%N' | tr '\n' ' ')";
  echo "vm_ulimit_n=$(vm 'ulimit -n') vm_nproc=$(vm nproc)"; } > $OUT/manifest.txt
for k in 1 2 3; do
  for path in tls tunnel; do
    [ $path = tls ] && url=https://client-vm.biobank.org.tw/v1 || url='${LITELLM_BASE_URL%/}'
    name=mixed1500-$path-rep$k
    sleep 60
    echo "$(date -Iseconds) start $name" >> $OUT/manifest.txt
    vm "cd ~ && set -a && . ~/.env && set +a && (vmstat -n 2 > abrep/tls1500/$name.vmstat & echo \$! > abrep/tls1500/vmstat.pid) && \
        BENCH_MODELS='glm5.3-flash,qwen3.8-flash,qwen3.8' ~/venv-bench/bin/python abrep/tls1500/stress_test.py \
        --base-url $url -c 1500 -n 1500 --max-tokens 500 --timeout 300 --skip-check \
        --output-json abrep/tls1500/$name.json --per-request-jsonl abrep/tls1500/$name.jsonl > abrep/tls1500/$name.client.log 2>&1; \
        kill \$(cat abrep/tls1500/vmstat.pid)"
    scp -q client-vm:"abrep/tls1500/$name.*" $OUT/ && gzip -f $OUT/$name.jsonl
    python3 -c "import json;d=json.load(open('$OUT/$name.json'));print('$name', f\"success {d['success_rate']:.1f}% tps {d['tps']:.0f} p95 {d['p95_latency']:.1f}s\")" >> $OUT/manifest.txt
  done
done
echo "finished=$(date -Iseconds)" >> $OUT/manifest.txt
