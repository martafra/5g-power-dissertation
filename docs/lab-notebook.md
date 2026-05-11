# Lab Notebook

## 2026-04-30
- Environment: Ubuntu, Docker 29.4.1, kernel 6.8.0
- Cloned Open5GS: github.com/open5gs/open5gs
- Cloned srsRAN_Project: github.com/srsran/srsRAN_Project
  - Note: srsRAN Project rebranded to OCUDU (gitlab.com/ocudu/ocudu) in Dec 2025
  - Repo archived but still usable; ask supervisor about migration
- docker/docker-compose.split.yml already has CU-CP, CU-UP, DU as separate containers
- docker/open5gs/ has all-in-one Open5GS container with MongoDB
- Next step: build Open5GS container and test it standalone

## 2026-05-01
- Built Open5GS Docker image (v2.7.5) successfully
- Created Docker network and ran Open5GS 5GC - all NFs registering correctly
- WebUI accessible at localhost:9999
- Built srsRAN/gnb image with ZMQ support (modified Dockerfile to add 
  libzmq3-dev in builder stage and libzmq5 in runtime stage)
- Verified ZMQ linked correctly: libzmq.so.5 found in srsdu binary
- Moved Docker root to HDD (/mnt/hdd/docker) - 313GB available
- Added HDD to /etc/fstab for persistent mount on reboot
- Next step: create ZMQ config for DU and bring up full CU-CP + CU-UP + DU stack

## 2026-05-02
### Stack setup
- Full 5G SA stack running: Open5GS 5GC + CU-CP + CU-UP + DU (ru_dummy)
- testmode active: 1 simulated UE (rnti=0x44)
  - DL: ~58 Mbps, MCS=27, CQI=15, 0% errors
  - UL: ~24.7 Mbps, MCS=27, 0% errors

### Power measurement pipeline
- Scaphandre integrated in docker-compose (10.53.1.11:8080)
  - Volumes: /sys/class/powercap, /proc, /sys/fs/cgroup:ro
  - Correctly identifies srsdu process via exe path
- Prometheus integrated in docker-compose (10.53.1.12:9090)
  - Added to both ran and metrics networks
  - Scrapes Scaphandre every 5s with fallback_scrape_protocol: PrometheusText0.0.4
- Grafana dashboard "srsRAN + Power Consumption":
  - RAN metrics: DL/UL bitrate, BLER, MCS (InfluxDB via Telegraf)
  - DU power: scaph_process_power_consumption_microwatts{exe="/usr/local/bin/srsdu"} / 1000000
  - DU consuming ~5.5-7W under 1 UE synthetic load

### System maintenance
- Disabled clickhouse-server (was filling 25GB/day of syslog)
- Configured logrotate with size 200M limit for syslog
- Docker root dir moved to HDD (/mnt/hdd/docker, 313GB available)
- HDD mounted permanently via /etc/fstab

### Next steps
1. Test 1CU-2DU topology
2. Vary load (nof_ues) and measure power delta
3. Automate experiment scenarios with scripts

## 2026-05-02 (afternoon)
### 1CU-2DU topology
- Added du2 service to docker-compose.split.yml
- Created configs/du2_dummy.yml (pci=2, bind_addr=10.53.1.7, f1u=172.18.10.4)
- DU2 successfully connected to CU-CP: F1 Setup completed
- Both DU1 (pci=1) and DU2 (pci=2) running simultaneously
- Note: "Skipped slot" warnings appear under dual-DU load: expected on laptop hardware, not critical for power measurements
- Saved baseline logs before topology change:
  - docs/logs/du_1cu1du_*.log
  - docs/logs/power_1cu1du_*.json

### Next steps
1. Add testmode to DU2 and measure power delta vs 1DU
2. Vary nof_ues and measure power consumption
3. Automate experiment scenarios with scripts

## 2026-05-03
### 1CU-2DU topology: Telegraf fix
- Fixed ws_adapter.py to connect to multiple WebSocket endpoints (comma-separated WS_URL)
- Updated WS_URL in .env: 172.19.1.3:8001,172.19.1.9:8001
- Added metrics + remote_control sections to du2_compose_config in docker-compose.split.yml
- Rebuilt srsran/telegraf image to include updated ws_adapter.py
- Grafana now shows: 2 cells, 2 Active UEs, ~117 Mb/s DL total

### Power measurement experiments
- Removed invalid log.max_size config from DU configs (caused exit 110)
- Set all_level: warning in DU configs to reduce log verbosity
- Fixed disk full issue: du.log and du2.log were filling /dev/nvme0n1p5
  - Truncated logs manually, recovered 22GB
  - Added truncate_du_logs() to experiment script
- Fixed Prometheus query: replaced avg_over_time (included stale PIDs) with
  repeated instant sampling every 10s for 300s
- Fixed bash array syntax: IFS=, for passing samples to Python
- Ran 5-run experiment for both topologies, 7 scenarios each (1/2/4/8/16/64/96 UE/DU)

### Results summary (mean ± std over 5 runs)
| UE/DU | 1CU-1DU       | 1CU-2DU (total) |
|-------|---------------|-----------------|
| 1     | 5.155 ±0.115W | 14.001 ±0.450W  |
| 2     | 5.045 ±0.073W | 13.850 ±0.338W  |
| 4     | 5.172 ±0.086W | 14.122 ±0.318W  |
| 8     | 5.706 ±0.215W | 15.264 ±0.150W  |
| 16    | 6.031 ±0.245W | 17.066 ±0.160W  |
| 64    | 6.681 ±0.112W | 19.176 ±0.086W  |
| 96    | 6.818 ±0.166W | 20.334 ±0.288W  |

### Key observations
- Fixed overhead of 2DU topology: ~8-9W regardless of load
- Both topologies scale similarly with UE count
- Saturation above 64 UE/DU
- Low std across runs confirms measurement reliability

### Next steps
1. Generate plots with error bars
2. Measure CU-CP and CU-UP power consumption separately
3. Automate topology teardown/bring-up for future experiments

## 2026-05-04 to 2026-05-07
### Matrix experiment design
- Extended experiment matrix to include 1CU-3DU topology
- Added du3 service to docker-compose.split.yml
- Created configs/du3_dummy.yml (pci=3, bind_addr=10.53.1.8, f1u=172.18.10.5)
- Designed full matrix: 3 topologies x 3 CQI values (5, 10, 15) x 5 UE counts (1, 4, 16, 96) x 5 runs = 225 experiments
- Written run_matrix_experiments.sh to automate full matrix collection
- Each experiment saves a JSON file in docs/logs/matrix/ with mean_W, std_W, topology, cqi, nof_ues, run
- Next steps:
  1. Run full matrix overnight
  2. Collect per-component breakdown for all topologies

## 2026-05-08
### Matrix experiments and per-component breakdown
- Matrix experiments completed: 225 JSON files in docs/logs/matrix/
- Written collect_power_breakdown.sh to measure per-component power consumption
  - Parameters: [topology] [samples] [interval_seconds]
  - Resolves PIDs dynamically via docker inspect
  - Saves CSV to docs/logs/ with timestamp, component, pid, microwatts, watts
  - Supports CU-CP, CU-UP, DU1, DU2, DU3, DU4, DU5
- Collected baseline breakdown for 1CU-1DU and 1CU-2DU (60 samples, 5s interval)
- Next steps:
  1. Add du4 and du5 to docker-compose
  2. Collect breakdown for 1CU-3DU and 1CU-4DU
  3. Update analysis notebook

## 2026-05-09
### Extended topology: du4 and du5
- Added du4 service to docker-compose.split.yml
  - configs/du4_dummy.yml: pci=4, bind_addr=10.53.1.9, f1u=172.18.10.6, metrics IP: 172.19.1.11
- Added du5 service to docker-compose.split.yml
  - configs/du5_dummy.yml: pci=5, bind_addr=10.53.1.10, f1u=172.18.10.7, metrics IP: 172.19.1.12
- Updated collect_power_breakdown.sh to support DU4 and DU5

### Thermal throttling observations
- Attempted 1CU-4DU breakdown with system already warm: CPU cores at 88-93°C (crit: 100°C)
- DU power ~12.5W per DU vs ~15.5W in 1CU-3DU: consistent with thermal throttling
- Attempted 1CU-5DU: one DU container always missing from summary
  - Cause: too many heavy processes starting simultaneously, one fails F1AP handshake with CU-CP
  - Workaround attempted: staged startup with 30s delay before du5; unreliable
  - Conclusion: laptop hardware not suitable for sustained 5+ DU workloads

### Final breakdown measurements
- All measurements repeated with system fully cooled (cores below 35°C) between topologies
- 1CU-4DU repeated twice: first run anomalous (DU1 at 11.99W vs ~15W for others)
  - Cause: DU1 not fully synchronised with CU-CP at measurement start
  - Second run confirmed consistent values across all 4 DUs
- Results (60 samples, 5s interval):

| Topology | CU-CP  | CU-UP  | DU mean per DU | Total   |
|----------|--------|--------|----------------|---------|
| 1CU-1DU  | 0.494W | 0.496W | 6.662W         | 7.652W  |
| 1CU-2DU  | 0.922W | 0.912W | 12.107W        | 26.048W |
| 1CU-3DU  | 0.680W | 0.675W | 12.407W        | 38.157W |
| 1CU-4DU  | 0.409W | 0.416W | 13.146W        | 53.818W |

### Key observations
- DU power is the dominant cost and scales consistently with topology
- CU-CP and CU-UP show non-monotonic variation across topologies
  - Absolute power below 1W: Scaphandre resolution insufficient to detect scaling trend
  - In test mode, CU-CP signalling load is minimal and nearly constant regardless of DU count
- Next steps:
  1. Rewrite analysis notebook with all current topology data (1CU-1/2/3/4DU)
  2. Implement multi-CU topologies
  3. Run matrix experiments for multi-CU topologies