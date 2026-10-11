# Client-VM records of the mixed 1,500-user runs (§5.5, Table 9)

Recovered on 2026-09-29 from the benchmark client VM's home directory, where the harness wrote them; they had not been copied into the repository at the time.

| File | Original modification time (UTC+8) | Content |
| :--- | :--- | :--- |
| `bench_mixed_1500_r2.json` | 2026-09-26 22:57:13 | Summary of the **initial** mixed run: 1,018 of 1,500 requests succeeded (67.9%). The success count matches the client file-descriptor exhaustion at about 1,020 open sockets (Table 9, row 1). The file name is the harness output name used on the VM |
| `bench_mixed_final.log` | 2026-09-26 22:58:35 | Client output of the next run (after the client fd fix), whose summary is `../bench_mixed_1500_users_via_tunnel.json` (91.8%) |

Gateway CPU and memory figures in the paper (Table 1, §5.5) are observations recorded in the operations log at the time; no raw telemetry was retained.
