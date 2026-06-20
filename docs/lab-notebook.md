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

## 2026-05-11
### Breakdown measurements: final validated runs
- Repeated all breakdown measurements with system fully cooled between topologies (cores below 35°C)
- CU-CP shows non-monotonic behaviour across topologies: 0.494W, 0.922W, 0.680W, 0.409W
  - Likely due to low absolute power (<1W) relative to Scaphandre measurement resolution
  - In test mode, CU-CP signalling load is minimal and nearly constant regardless of DU count
- 1CU-4DU first run anomalous: DU1 at 11.99W vs ~15W for others
  - Cause: DU1 not fully synchronised with CU-CP at measurement start
  - Repeated and confirmed consistent values across all 4 DUs
- Final validated files:
  - docs/logs/breakdown_1cu1du_20260510_071356.csv
  - docs/logs/breakdown_1cu2du_20260510_121914.csv
  - docs/logs/breakdown_1cu3du_20260510_125725.csv
  - docs/logs/breakdown_1cu4du_20260510_161647.csv

### Analysis notebook rewrite
- Rewrote power_analysis.ipynb from scratch with dynamic topology handling
  - Part 1: per-component breakdown (stacked bar per topology)
  - Part 2: matrix analysis (power vs UEs, topology comparison, W per UE, marginal cost,
    heatmap, boxplot run variability, fixed vs dynamic overhead, LaTeX summary table)
  - All topology lists and colour palettes generated dynamically from available data
  - Adding new topologies requires only dropping JSON files in docs/logs/matrix/

### Repository setup
- Initialised Git repository and created public GitHub repo: github.com/martafra/5g-power-dissertation
  - Includes README, .gitignore, scripts/, analysis/, docs/lab-notebook.md
  - docs/logs/ excluded from version control
- Submitted CloudLab account request for bare-metal experiments
  - Required to overcome thermal throttling observed at 4+ DU on local hardware
  - Planned use: matrix experiments for 1CU-4DU and multi-CU topologies
- Next steps:
  1. Await CloudLab approval and run matrix experiments for 1CU-4DU
  2. Implement multi-CU topologies (2CU-2DU, 2CU-4DU)
  3. Run matrix experiments for multi-CU topologies
  4. Write Design and Implementation chapters
  5. Write Evaluation chapter with full comparison

  ## 2026-05-13
### 2CU-2DU topology implementation and matrix experiments
- Added cu-cp2, cu-up2, du-b services to docker-compose.split.yml
  - CU-CP2: 10.53.1.14 (ran), metrics 172.19.1.13
  - CU-UP2: 10.53.1.15 (ran), 172.18.10.8 (f1u)
  - du-b: 10.53.1.16 (ran), 172.18.10.9 (f1u), metrics 172.19.1.14
  - Note: 10.53.1.11 already in use by Scaphandre, caused initial IP conflict
- Created configs/du_b_dummy.yml and configs/testmode_b.yml
- Updated collect_power_breakdown.sh to support cu_cp2, cu_up2, du_b
- Written scripts/start_2cu2du.sh: staged container startup with temperature check
- Written scripts/run_matrix_2cu2du.sh: matrix experiments for 2CU-2DU topology
- Verified 2CU-2DU topology: du-b connected to cu-cp2 on 10.53.1.14:38472

### Breakdown measurement: 2CU-2DU baseline
- Collected at thermal steady state (cores ~38°C)
- Results (60 samples, 5s interval):
  - cu_cp:  mean=0.891W std=0.063W
  - cu_cp2: mean=0.896W std=0.063W
  - cu_up:  mean=0.897W std=0.064W
  - cu_up2: mean=0.892W std=0.063W
  - du1:    mean=12.038W std=0.827W
  - du_b:   mean=12.012W std=0.937W
  - Total:  ~27.6W
- Both CU-DU groups are symmetric, confirming correct isolation

### Matrix experiments: 2CU-2DU
- 75 experiments completed (3 CQI x 5 UE x 5 runs)
- Results summary (CQI=15):
  - 1 UE:  19.12W, 4 UE: 19.60W, 16 UE: 25.55W, 64 UE: 27.62W, 96 UE: 28.41W
- Fixed overhead of second CU-DU group: ~7W at low load, increasing to ~13W at 96 UE
- std consistently below 0.15W across all runs: no thermal throttling observed

### CloudLab setup
- Requested and received CloudLab account approval
- Created profile 5g-power-research: single d6515 node (32-core AMD EPYC, 128GB RAM)
  - Ubuntu 22.04, Docker pre-installed via startup script
  - Hardware type selected to avoid thermal throttling observed on local testbed
- Experiment martafra-305578 scheduled for 13 May 2026 13:00, expires 14 May 05:00
- Next steps:
  1. Configure CloudLab node: clone repo, build Docker images
  2. Run matrix experiments for 1CU-4DU and 2CU-2DU on CloudLab
  3. Implement 2CU-4DU topology
  4. Write Design and Implementation chapters
## 2026-05-16
### CloudLab experiments: 1CU-NDU matrix and breakdown
- Matrix experiments completed on CloudLab (AMD EPYC 7452, 64 logical cores, 125GB RAM)
  - 600 JSON files: 8 topologies (1CU-1DU to 1CU-8DU) x 3 CQI x 5 UE x 5 runs
  - All 600 runs valid, no thermal throttling observed
- Breakdown collected from single 1CU-8DU run (60 samples, 5s interval):
  - cu_cp: 0.219W, cu_up: 0.204W (fixed overhead: 0.423W total)
  - du1-du5: 3.18-3.32W each (linear scaling)
  - du6: 2.395W, du7: 1.271W, du8: 1.246W (CU scheduler saturation above 5 DU)
  - Per-topology totals derived by component summation (breakdown_by_topology.csv)
- Analysis notebook updated with full 8-topology dataset
- Multi-CU topology 2CU-2DU: breakdown + matrix completed (75 experiments)
- Extended CloudLab experiment to 2026-05-23

## 2026-05-17
### Multi-CU topologies: 2CU-4DU, 2CU-6DU, 2CU-8DU
- 2CU-4DU: breakdown + matrix completed (75 experiments)
  - cu overhead: 0.60W total, DU mean: 2.62W/DU, total: ~11.1W
- 2CU-6DU: breakdown + matrix completed (75 experiments)
  - cu overhead: 0.73W total, DU mean: 3.07W/DU, total: ~19.1W
- 2CU-8DU: breakdown + matrix completed (75 experiments)
  - cu overhead: 1.00W total, DU mean: 3.99W/DU, total: ~34.8W
- docker-compose.split.yml updated: IP conflicts resolved, du6-du8 IPs reassigned
- collect_power_breakdown scripts created for each topology

## 2026-05-18
### Multi-CU topologies: 3CU-3DU, 3CU-6DU, 4CU-4DU
- 3CU-3DU: breakdown + matrix completed (75 experiments)
  - cu overhead: 0.85W total, DU mean: 2.26W/DU, total: ~7.6W
- 3CU-6DU: breakdown + matrix completed (75 experiments)
  - cu overhead: 1.36W total, DU mean: 3.49W/DU, total: ~26.6W
- 4CU-4DU: breakdown + matrix completed (75 experiments)
  - cu overhead: 1.32W total, DU mean: 2.70W/DU, total: ~11.9W
- Key finding: centralised CU architectures are more energy-efficient than distributed ones
  at equivalent DU counts. At 6 DU, 3CU topology consumes ~6W more than 1CU at 96 UEs.
- Analysis notebook updated with all multi-CU topologies and centralised vs distributed comparison


## 2026-05-21
### Manual and automatic scaling implementation
- Implemented scale.sh: dynamic CU-DU topology scaler using docker run with generated configs
  - Parameters: --cu, --du, --warn-threshold, --scaledown-threshold, --cqi, --ues, --monitor
  - Auto-starts Scaphandre, Prometheus and 5GC if not running
  - Allocates IPs dynamically from predefined pools
  - Generates configs from templates at runtime (configs/templates/)
  - Measures power via Scaphandre before and after each transition
  - Monitoring loop: samples power every N seconds and prints warnings
- Implemented autoscale.sh: threshold-based automatic CU-DU scaler
  - Monitors per-DU power consumption via Scaphandre
  - Scales up after K consecutive samples above high threshold
  - Scales down after K consecutive samples below low threshold
  - Cooldown period prevents flapping
- Implemented load_generator.sh: varies nof_ues in testmode configs and restarts DUs
- Implemented teardown.sh: stops all srsRAN containers, optionally stops full stack
- Created config templates: cu_cp.yml.template, cu_up.yml.template, du.yml.template, testmode.yml.template
- Updated docker-compose.yml: networks set to external: true
- Tested full autoscaling cycle: 1CU→2CU→3CU (scale-up) and 3CU→2CU (scale-down)
- Note: in testmode power difference between 1 UE and 96 UE is small (~0.5W);
  autoscaler thresholds must be calibrated to topology-level consumption


## 2026-05-22
### Flask API and React UI
- Implemented api/app.py: Flask REST API for platform control
  - GET /api/status: topology, power, container list, process states
  - POST /api/scale: trigger topology transition
  - POST /api/teardown: stop RAN containers
  - POST /api/autoscale/start|stop: control autoscaler daemon
  - POST /api/load/start|stop: control load generator
  - GET /api/metrics/history: recent scaling events from logs
  - GET /api/metrics/breakdown: per-container power consumption
- React UI (Vite + Recharts + Axios):
  - Real-time power chart (total and per-DU)
  - Per-component power breakdown with bar chart
  - Manual scaling controls
  - Autoscaler configuration and toggle
  - Load generator configuration and toggle
  - Scaling event log
- Accessible via SSH tunnel: ssh -L 5000:localhost:5000 martafra@amd006.utah.cloudlab.us

## 2026-06-10

### ZMQ setup - local development (laptop)

- compiled srsRAN_4G from source with ZMQ enabled (`-DENABLE_ZEROMQ=ON -DENABLE_EXPORT=ON`)
- confirmed `libsrsran_rf_zmq.so` active in srsUE
- compiled srsRAN Project (release_25_04) with ZMQ enabled
- confirmed `libzmq.so.5` linked in `gnb` binary
- key finding: ZMQ + srsUE only works with **10 MHz** (`channel_bandwidth_MHz: 10`, `srate: 11.52e6`); 20 MHz causes persistent `PBCH-MIB: CRC failed`
- key finding: `coreset0_index: 12` is incompatible with 10 MHz; must use `coreset0_index: 6`
- key finding: srsUE requires `ssb_nr_arfcn` removed from config to correctly find SSB
- applied two patches to `srsRAN_4G/lib/src/phy/ue/ue_dl_nr.c` to bypass PDCCH measurement thresholds that produce false negatives with ZMQ (RSRP=-inf, corr=0.000):
  - disabled `isnormal(m->norm_corr)` early return
  - disabled EPRE threshold check
  - both checks set to `if (false && ...)` rather than removed, for clarity
- confirmed `RRC Connected` and `PDU Session Establishment successful. IP: 10.45.1.2`
- measured throughput with iperf3: DL ~26.8 Mbps, UL ~5.5 Mbps
- measured latency with ping (100 packets, 0.1s interval): RTT min=18.7ms avg=35.7ms max=261ms, 0% loss
- GNU Radio tested as broker but not required for single UE; direct ZMQ connection works

### Configuration summary (gnb + srsUE, monolithic)

- band 3, dl_arfcn=368500, bw=10 MHz, SCS=15 kHz, srate=11.52e6
- coreset0_index=6, ss0_index=0, prach_config_index=1
- Open5GS running in Docker on `10.53.1.2`
- gNB bind_addr=10.53.1.1 (host-side ran network gateway)
- srsUE network namespace: ue1, IP: 10.45.1.2

---

## 2026-06-11

### ZMQ power + throughput experiments on CloudLab (node amd004.utah.cloudlab.us, d6515)

- installed Docker, srsRAN_4G, srsRAN Project with ZMQ on fresh CloudLab node
- replicated working ZMQ setup from laptop
- registered IMSI `001010123456780` in Open5GS web UI
- confirmed `RRC Connected` and `PDU Session Establishment` on CloudLab node
- ran `run_zmq_power_throughput.sh`: 3 modes (idle, dl, ul), 5 runs each
- Scaphandre measuring gnb and srsue processes via RAPL

### Results

| mode | power mean (W) | power std (W) | throughput (Mbps) |
|------|---------------|--------------|-------------------|
| idle | 1.974         | 0.010        | 0                 |
| dl   | 2.276         | 0.054        | 27.5              |
| ul   | 2.154         | 0.012        | 6.0               |

- DL overhead vs idle: +0.30W for 27.5 Mbps
- UL overhead vs idle: +0.18W for 6.0 Mbps
- gNB consumes ~1.5W at idle, ~1.6W under load
- srsUE consumes ~0.45W at idle, ~0.68W under DL load
- results stored in `docs/logs/zmq/`

### Next steps

- attempt ZMQ with disaggregated CU/DU setup (srscucp + srscuup + srsdu) on CloudLab
- if successful, run power + throughput matrix across topologies

## 2026-06-14

### ZMQ disaggregated setup (srscucp + srscuup + srsdu) - CloudLab

#### What was done

- confirmed that ZMQ works with the **disaggregated CU/DU split** (srscucp + srscuup + srsdu as separate processes), not just the monolithic gnb
- ran power breakdown experiment for 1CU-1DU topology with 1 UE via ZMQ
- measured per-component power (CU-CP, CU-UP, DU, srsUE) in three modes: idle, DL traffic, UL traffic
- measured throughput (iperf3) and latency (ping) alongside power

#### Configuration issues and workarounds

- **iptables blocking traffic**: after UE reconnection, ping and iperf3 traffic was dropped silently. Fixed with:
  ```bash
  sudo iptables -I FORWARD -j ACCEPT
  sudo iptables -I DOCKER-USER -j ACCEPT
  ```
- **missing default route in UE namespace**: after reconnection the route was gone. Fixed with:
  ```bash
  sudo ip netns exec ue1 ip route add default dev tun_srsue
  ```
- **GNU Radio broker conflict**: leftover gnuradio_broker process was occupying ZMQ ports after multi-UE experiments. Fixed with `sudo pkill -f gnuradio_broker` before restarting srsUE
- **srsUE stuck at "Attaching UE..."**: caused by stale DU state after UE disconnect. Fixed by restarting srsdu before restarting srsUE

#### Results - 1CU-1DU, 1 UE, ZMQ (CloudLab d6515, AMD EPYC 7452)

| mode | cu-cp (W) | cu-up (W) | du (W) | srsue (W) | total (W) | throughput (Mbps) | RTT (ms) |
|------|-----------|-----------|--------|-----------|-----------|-------------------|---------|
| idle | 0.159     | 0.162     | 1.588  | 0.323     | 2.231     | -                 | -       |
| dl   | 0.156     | 0.158     | 1.571  | 0.318     | 2.269     | 27.6              | 27.7    |
| ul   | 0.157     | 0.164     | 1.600  | 0.357     | 2.278     | 6.0               | -       |

Key observations:
- DU dominates power (~70% of total), consistent with ru_dummy experiments
- CU-CP and CU-UP each consume ~0.16W regardless of traffic mode
- DL and UL add minimal power overhead vs idle (+0.04W and +0.05W respectively)
- throughput and latency consistent with earlier gnb monolithic ZMQ results (27.5 Mbps DL, ~28ms RTT)
- ZMQ disaggregated results are comparable to gnb monolithic, confirming the split architecture does not add significant power overhead

#### Next steps

- run same experiment on additional topologies (1CU-2DU, 2CU-2DU) to compare with ru_dummy matrix
- investigate multi-UE support via GNU Radio broker (currently limited to 1 UE with direct ZMQ)
- add ZMQ results to power_analysis.ipynb

## 2026-06-15

### Multi-UE ZMQ setup - CloudLab (amd004.utah.cloudlab.us, d6515)

#### Objective

Extend the ZMQ disaggregated setup (srscucp + srscuup + srsdu) to support multiple simultaneous UEs, replicating the UE count dimension of the ru_dummy matrix.

#### Approach

Used the official srsRAN Project multi-UE GNU Radio broker (`multi_ue_scenario.grc`), obtained from the archived `srsran/srsRAN_Project_docs` repository. The broker handles:
- DL broadcast: DU tx -> UE1, UE2, UE3 (via separate REP sinks)
- UL multiplexing: UE1, UE2, UE3 tx -> DU rx (via separate REQ sources)

ZMQ port assignments:
- DU: tx=2000, rx=2001
- UE1: rx=2100, tx=2101
- UE2: rx=2200, tx=2201
- UE3: rx=2300, tx=2301 (from `ue3_zmq.conf`)

#### Troubleshooting log

**Phase 1 - srsUE closes immediately (`Closing stdin thread`)**
- cause: running srsUE with `</dev/null` or `setsid` removes its stdin; srsUE detects this and exits
- fix: use `tmux new-session -d -s ueN "..."` to provide a virtual terminal

**Phase 2 - DU stuck at `Completed 0 of 11520 samples`**
- cause 1: `multi_ue_scenario.py` attempts to render Qt GUI; on headless CloudLab node this causes deadlock
- fix 1: use `xvfb-run -a` to provide a virtual framebuffer
- cause 2: GNU Radio broker uses synchronous REQ/REP sockets for 3 UEs; starting only 2 UEs left one socket permanently waiting
- fix 2: start all 3 UEs (broker is designed for exactly 3)

**Phase 3 - UEs stuck at `Sending PDU Session Establishment Request`**
- cause 1 (UE1): config had `apn = srsapn`; Open5GS only accepts `apn = internet`
- fix 1: `sed -i 's/apn = srsapn/apn = internet/' ue*_zmq.conf`
- cause 2 (UE2, UE3): official configs had different K keys (`...ef00`, `...ef01`); Open5GS database has `...eeff` for all subscribers
- fix 2: unified K key to `00112233445566778899aabbccddeeff` across all UE configs

**Phase 4 - `total_nof_ra_preambles` causes DU segfault**
- adding the official multi-UE PRACH parameters to `du_zmq.yml` caused the DU to crash immediately after ZMQ connection
- these parameters appear unsupported in this version of srsRAN Project (commit 4bf1543936)
- workaround: kept original PRACH config (`prach_config_index: 1` only); 3 UEs connected successfully without extra PRACH parameters

**Phase 5 - tmux duplicate session errors**
- cause: killing UE processes left tmux sessions alive
- fix: `tmux kill-server` before restarting

#### Correct startup order

```bash
xvfb-run -a python3 ~/dissertation/configs/zmq/multiue_official/multi_ue_scenario.py &
sleep 3
sudo srscucp -c ~/dissertation/configs/zmq_split/cu_cp_zmq.yml &
sleep 2
sudo srscuup -c ~/dissertation/configs/zmq_split/cu_up_zmq.yml &
sleep 2
sudo srsdu -c ~/dissertation/configs/zmq_split/du_zmq.yml &
sleep 10
sudo tmux new-session -d -s ue1 "srsue ~/dissertation/configs/zmq/multiue_official/ue1_zmq.conf"
sudo tmux new-session -d -s ue2 "srsue ~/dissertation/configs/zmq/multiue_official/ue2_zmq.conf"
sudo tmux new-session -d -s ue3 "srsue ~/dissertation/configs/zmq/multiue_official/ue3_zmq.conf"
```

Post-connection routing:
```bash
sudo iptables -I FORWARD -j ACCEPT
sudo iptables -I DOCKER-USER -j ACCEPT
sudo ip netns exec ue1 ip route add default dev tun_srsue
sudo ip netns exec ue2 ip route add default dev tun_srsue
sudo ip netns exec ue3 ip route add default dev tun_srsue
```

#### Results - 1CU-1DU, 3 UE simultaneous, ZMQ

UE IP assignments:
- UE1: 10.45.1.2
- UE2: 10.45.1.12
- UE3: 10.45.1.13

Ping RTT (from host to each UE): ~80-120 ms, 0% packet loss

Simultaneous DL throughput (iperf3, 10s):

| UE | throughput sender (Mbps) | throughput receiver (Mbps) | retransmits |
|----|--------------------------|----------------------------|-------------|
| 1  | 4.34                     | 2.52                       | 1           |
| 2  | 3.79                     | 2.19                       | 0           |
| 3  | 2.38                     | 1.33                       | 0           |
| total | 10.51                 | 6.04                       | 1           |

The total DL throughput (~10.5 Mbps) is roughly one third of the single-UE throughput (~28 Mbps), consistent with fair round-robin scheduling across 3 UEs on the 10 MHz channel.

### Fix - 100% packet loss on ZMQ UE uplink/internet path

**Symptom**: UEs successfully attached (RRC Connected, PDU Session Establishment successful, `tun_srsue` interface created with correct IP), and ping to the UPF gateway (`10.45.1.1`) worked with 0% loss, but ping from any UE namespace to an external address (`8.8.8.8`) showed 100% packet loss.

**Diagnosis steps**:
- confirmed ICMP echo requests left the UE namespace correctly via `tun_srsue` (`tcpdump -i tun_srsue`)
- confirmed the host correctly routes `10.45.0.0/16` to the Open5GS container (`10.53.1.2`) via the bridge (`ip route show`)
- confirmed the Open5GS container itself has working internet access (`docker exec open5gs_5gc ping 8.8.8.8` succeeded)
- confirmed `net.ipv4.ip_forward = 1` inside the container
- confirmed a `MASQUERADE` rule already existed inside the container for `10.45.0.0/24` (visible only via `iptables-legacy`, not `iptables`, due to legacy/nft table split) - but UE IPs were in `10.45.1.0/24`, outside that rule's scope
- added a matching rule inside the container for `10.45.1.0/24`, still no effect
- ran `tcpdump -i any icmp -n` on the **host** while pinging from a UE namespace: the packet was visible leaving the host's physical NIC (`enp1s0f0np0`) with source IP still `10.45.1.18` (the UE's private IP), meaning **no NAT was ever applied** - the packet bypassed the container's NAT path entirely at the host level

**Root cause**: the host's NAT table (`iptables -t nat -L POSTROUTING`) had `MASQUERADE` rules for other internal subnets (`10.53.1.0/24`, `172.19.1.0/24`, `172.17.0.0/16`) but **none for `10.45.0.0/16`** (the UE subnet range used by Open5GS). The host was correctly routing UE traffic to the container's bridge, but never rewriting the source address before it left the physical interface.

**Fix** (applied at the host level, not inside the container):
```bash
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o enp1s0f0np0 -j MASQUERADE
```

**Verification**:
```bash
sudo ip netns exec ue1 ping -c 3 -W 5 8.8.8.8
# 0% packet loss, RTT ~86-127 ms
```
Confirmed working for UE1, UE2, and UE3 after the fix - all reached 0% packet loss to `8.8.8.8`.

**Note**: this rule does not persist across host reboots unless added to a persistent iptables config (e.g. `iptables-persistent` or a startup script). Re-check this rule (`sudo iptables -t nat -L POSTROUTING -n -v | grep 10.45`) after any node reboot or `iptables` flush.

#### Next steps

- extend to multi-DU with ZMQ

## 2026-06-18
### Multi-UE ZMQ setup - debugging session, CloudLab (amd004.utah.cloudlab.us, d6515)
#### Objective
Get the 3-UE setup (documented 2026-06-15) running again after it stopped working, and extend it to 4 simultaneous UEs by adding a fourth branch to the GNU Radio broker.

#### Approach
Wrote a headless 4-UE extension of the official broker (`multi_ue_4ue.py`), removing the Qt GUI (not needed under `xvfb-run`) and adding a fourth REQ source / REP sink pair (ports 2400/2401) following the same pattern as UE1-3. Path loss values moved to CLI args instead of GUI sliders.

The 3-UE setup had stopped working since 2026-06-15 (DU stuck at "Completed 0 of 11520 samples", all UEs stuck at "Attaching UE..."). Spent most of the session re-diagnosing this before the 4-UE extension could even be tested, since the symptom looked identical regardless of UE count.

#### Fix 1 - subscriber DB / APN mismatch (UE1)
UE1's IMSI (`001010123456780`) was registered in the Open5GS subscriber DB with APN `srsapn`/`ims` only, while `ue1_zmq.conf` requests `apn = internet`. The PDU Session Establishment Request was silently never accepted because the requested APN didn't exist in that subscriber's slice.

Fixed by updating the subscriber's `slice` array directly in MongoDB to match the structure of the other (working) subscribers, with `name: 'internet'` and a free IP (`10.45.1.18`):
```bash
docker exec open5gs_5gc mongosh open5gs --quiet --eval '
db.subscribers.updateOne(
  { imsi: "001010123456780" },
  { $set: { slice: [ { sst: 1, default_indicator: true, session: [ {
    qos: { arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 }, index: 9 },
    ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
    name: "internet", type: 3, pcc_rule: [], ue: { ipv4: "10.45.1.18" }
  } ] } ] } }
)'
```
This alone did not resolve the full stall (see Fix 2/3 below) but was a real and necessary correction.

#### Fix 2 - stale `srsue` processes holding ZMQ ports
Several previous test runs had left `srsue` processes alive in the background (not reachable by `pkill -f srsue`, likely orphaned from earlier `tmux` sessions), still bound to the UE ports and `ESTABLISHED` against the broker. New `srsue` launches failed silently with `Address already in use` whenever redirected to a log file, masking the real error.

Identified via:
```bash
sudo lsof -i :2100 -i :2101 -i :2200 -i :2201 -i :2300 -i :2301 -i :2400 -i :2401
```
Fixed by killing the stale PIDs explicitly, then using `sudo tmux kill-server` (not just `kill-session`) before any subsequent restart.

#### Fix 3 - wrong binary paths / launch timing
Re-ran the exact startup sequence documented on 2026-06-15, but with relative binary names (`srscucp`, `srscuup`, `srsdu`) instead of absolute paths - all three exited immediately (`command not found`). Corrected to absolute paths.

Also confirmed empirically that all 3 (then 4) `srsue` instances must be launched in close succession (no long `sleep` between them) - the broker's synchronous REQ/REP sockets require all expected UEs to connect before any data flows; staggering launches by 10-15s left earlier UEs timed out by the time the last one connected.

With all three fixes applied, the 3-UE setup worked end-to-end: all UEs reached `RRC Connected` -> `PDU Session Establishment successful` -> `tun_srsue` interface created with correct subscriber IP.

#### Fix 4 - host-level NAT missing for UE subnet (100% packet loss to internet)
Once attached, all UEs could ping the UPF gateway (`10.45.1.1`, same subnet, no NAT needed) with 0% loss, but pinging any external address (`8.8.8.8`) showed 100% packet loss.

Traced with `tcpdump -i any icmp -n` on the host while pinging from a UE namespace: the ICMP packet was seen leaving the host's physical NIC (`enp1s0f0np0`) with source IP still `10.45.1.18` (the UE's private IP) - meaning no NAT was ever applied, despite a `MASQUERADE` rule already existing *inside* the Open5GS container for `10.45.0.0/24` (visible only via `iptables-legacy`, due to legacy/nft table split). The host was correctly routing UE traffic to the container's bridge, but the host's own NAT table had `MASQUERADE` rules for other internal subnets (`10.53.1.0/24`, `172.19.1.0/24`, `172.17.0.0/16`) but none for `10.45.0.0/16`.

Fixed at the host level (not inside the container):
```bash
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o enp1s0f0np0 -j MASQUERADE
```
Verified 0% packet loss to `8.8.8.8` from UE1, UE2, UE3 after applying.

**Note**: this rule does not persist across host reboots. Re-check (`sudo iptables -t nat -L POSTROUTING -n -v | grep 10.45`) after any node reboot or iptables flush.

#### Fix 5 - 4-UE broker deadlock (ZMQ High Water Mark)
With all of the above fixed, extended to 4 UEs using `multi_ue_4ue.py`. UE1 attached and exchanged regular PUCCH/PDSCH traffic for a few seconds, then received `RRC Release`; UE2/3/4 never completed random access, looping on PRACH transmission. The DU process stayed alive at ~150% CPU but stopped writing to its log entirely, with no progress even after 20+ seconds of additional wait.

Ruled out (in order): flow graph structural errors (block/connection counts matched the working 3-UE original exactly, scaled by one branch), `add_vcc` parameter misuse (already corrected earlier in the session - it's vector length, not port count), ZMQ receive timeout (raised 100ms -> 1000ms, no effect), subscriber DB/APN mismatches (already correct for all 4 IMSIs), stale processes (checked clean).

Root cause: the ZMQ `req_source`/`rep_sink` blocks used the default High Water Mark (`zmq_hwm = -1`), unchanged from the official 3-UE broker. Sufficient buffering for 3 synchronous REQ/REP socket pairs was not enough once a 4th pair was added and UEs began exchanging sustained uplink/downlink traffic, leading to a GNU Radio scheduler deadlock.

Fixed:
```python
self.zmq_hwm = 1000
```
(single change in `multi_ue_4ue.py`'s `__init__`, applies to all REQ/REP sockets)

#### Results - 4 UE simultaneous, ZMQ, after all fixes
All four RNTIs (`0x4601`-`0x4604`) active and stable for 800+ seconds of internal DU runtime, continuous PUCCH/PDSCH activity, no further deadlock.

UE IP assignments:
- UE1: 10.45.1.18
- UE2: 10.45.1.12
- UE3: 10.45.1.13
- UE4: 10.45.1.14

Ping to `8.8.8.8` (external), all 4 UEs:
| UE | RTT min/avg/max (ms) | packet loss |
|----|----------------------|-------------|
| 1  | 130.6 / 276.9 / 567.3 | 0% |
| 2  | 110.2 / 133.9 / 147.2 | 0% |
| 3  | 114.9 / 139.8 / 153.6 | 0% |
| 4  | 102.8 / 129.8 / 144.7 | 0% |

#### Next steps
- run simultaneous iperf3 throughput test across all 4 UEs (same methodology as the 3-UE result from 2026-06-15) to complete the power/throughput correlation
- integrate these results into the analysis notebook
- consider scripting the full startup sequence (broker + core + DU + 4x UE + routing) into a single reusable script, given how much of this session was spent re-discovering steps already documented

#### Addendum - parameter tuning: slow_down_ratio, HWM, and path loss (4 UE)

**Context**: following the DL/UL methodology mismatch found above, two broker parameters were tested empirically to see whether they affected the low uplink throughput observed.

**Test 1 - HWM and slow_down_ratio**

Default broker parameters at the time (`zmq_hwm=1000`, `slow_down_ratio=4`, inherited from the original 3-UE broker) were changed to `zmq_hwm=10000` and `slow_down_ratio=1` (i.e. no artificial channel slowdown).

Result (path loss still at original defaults, 0/10/20/30 dB for UE1-4):

| UE | Sender (Mbps) | Receiver (Kbps) | Retr |
|----|---------------|------------------|------|
| 1  | 1.48          | 568              | 0    |
| 2  | 1.07          | 523              | 0    |
| 3  | 1.38          | 454              | 0    |
| 4  | 1.01          | 272              | 0    |
| **total** | **4.94** | **1817** | **0** |

Compared to the prior result with the old defaults (~0.86-1 Mbps aggregate, 7-21 retransmits across the run) this is a ~5x improvement with zero retransmits. The ~5x factor is consistent with removing `slow_down_ratio=4` (which by design throttles the sample rate by that factor).

**Decision**: `zmq_hwm=10000` and `slow_down_ratio=1` adopted as the new standard defaults in `multi_ue_4ue.py`, both in the broker class constructor and the CLI argument defaults. Any future single-UE (no-broker) baseline measurement should be re-checked for an equivalent parameter before being compared against multi-UE results, since the original single-UE figures (2026-06-14) may not have had an equivalent slowdown applied at all (single UE connects directly via ZMQ, no GNU Radio broker in between).

**Test 2 - path loss uniformity (0 dB for all 4 UEs)**

Hypothesis: the default per-UE path loss progression (0/10/20/30 dB) might be forcing UE3/UE4 into conservative MCS (QPSK), and removing that asymmetry might restore higher throughput.

Setting all four UEs to 0 dB path loss caused a new failure mode: all 4 UEs got stuck in a PRACH retry loop, never completing random access. DU log showed one successful PRACH detection every ~16 seconds, each assigned a new `tc-rnti`, suggesting only one UE at a time was being processed successfully rather than all four failing simultaneously. Root cause not fully diagnosed - possibly related to the uplink combiner (`add_vcc`) behaving differently when all four branches carry identical-amplitude signals (no path loss to differentiate them), though this remains a hypothesis, not confirmed.

**Test 3 - path loss, modest and diversified (0/3/6/9 dB)**

Retried with a smaller, more realistic spread instead of either extreme (0 dB uniform, or 0-30 dB original). All 4 UEs attached successfully this time (no PRACH loop).

Result (same `zmq_hwm=10000`, `slow_down_ratio=1` as Test 1):

| UE | Path loss (dB) | Sender (Mbps) | Retr |
|----|------------------|----------------|------|
| 1  | 0  | 1.48  | 0 |
| 2  | 3  | 1.16  | 0 |
| 3  | 6  | 1.01  | 0 |
| 4  | 9  | 0.858 | 0 |
| **total** | | **4.51** | **0** |

Compared to Test 1 (path loss 0/10/20/30, total 4.94 Mbps), the much smaller path loss spread (0/3/6/9) produced essentially the same aggregate throughput (4.51 Mbps) - within measurement noise of Test 1, not a meaningful improvement.

**Conclusion**: `slow_down_ratio` and `zmq_hwm` are the parameters that actually determine achievable throughput in this ZMQ simulation; per-UE path loss, at least within the ranges tested (0-9 dB and 0-30 dB), has negligible effect on aggregate throughput. Path loss of exactly 0 dB for all UEs simultaneously should be avoided - it triggers a PRACH retry loop rather than a clean attach, for reasons not yet fully understood. A modest, non-zero, diversified path loss (e.g. 0/3/6/9 dB) is recommended going forward: it avoids the all-zero failure mode while not measurably penalising throughput, and still gives each UE a distinguishable signal characteristic if that is useful for future analysis.

#### Addendum - DL test with new parameters (closing the loop on the DL/UL asymmetry)

To confirm the DL/UL asymmetry identified earlier also holds with the new `slow_down_ratio=1`/`zmq_hwm=10000` parameters (not just with the old defaults, as in the 2026-06-14 single-UE reference), ran a DL test: iperf3 server inside each UE namespace, client from the host connecting in to each UE's IP (0/3/6/9 dB path loss, same as Test 3 above).

| UE | Path loss (dB) | Sender (Mbps) | Receiver (Mbps) | Retr |
|----|------------------|----------------|--------------------|------|
| 1  | 0  | 9.71 | 7.71 | 0 |
| 2  | 3  | 9.48 | 7.36 | 0 |
| 3  | 6  | 7.76 | 6.18 | 0 |
| 4  | 9  | 6.38 | 5.16 | 1 |
| **total** | | **33.33** | **26.41** | **1** |

DL aggregate (33.33 Mbps) vs UL aggregate from Test 3 (4.51 Mbps) under identical broker parameters and path loss: a **~7.4x DL/UL ratio**. This is consistent with - if anything more pronounced than - the ~4.6x ratio seen in the single-UE 2026-06-14 reference (DL 27.6 Mbps vs UL 6.0 Mbps), confirming the asymmetry is a real, reproducible characteristic of this ZMQ-based setup rather than an artefact of the old default parameters.

Also notable: 4-UE aggregate DL throughput (33.3 Mbps) exceeds the single-UE DL reference (27.6 Mbps) - plausible, since multiplexing 4 UEs may let the scheduler use the shared 10 MHz channel more efficiently than a single UE alone can.

**Final summary of today's three isolated variables**:
1. **Direction (DL vs UL)**: ~4.6-7.4x difference, intrinsic to the stack - always specify which direction any reported figure refers to
2. **Broker parameters (`slow_down_ratio`, `zmq_hwm`)**: ~5x difference between old (4, 1000) and new (1, 10000) defaults, same direction
3. **Per-UE path loss**: no measurable effect within 0-30 dB (except exactly-0-for-all, which breaks attach)

All three are independent and compose multiplicatively; none of today's earlier "low throughput" readings indicated a regression or leftover bug from the 4-UE broker work - they were uplink measurements with the old broker defaults, simply not comparable to the 2026-06-15 downlink figure without accounting for both factors.

## 2026-06-20
#### Addendum - scalability limit beyond 4 UE (7 UE and 16 UE attempts)

**Context**: after validating 4 UE as fully working (attach, routing, DL/UL throughput - see addenda above), attempted to scale further using a newly generalised broker.

**New tooling created** (kept for future use, even though scaling beyond 4 UE was not achieved this session):
- `multi_ue_nue.py`: programmatically generates an N-UE GNU Radio broker (same topology as `multi_ue_4ue.py` - shared throttle, per-UE path loss, single `add_vcc(1)` combiner - but built in a loop instead of hand-copied blocks). Takes `--n-ue`, `--path-loss` (space-separated dB list), `--zmq-hwm`, `--slow-down-ratio` as CLI args. Defaults: `zmq_hwm=10000`, `slow_down_ratio=1` (matching today's validated standard), path loss defaults to a 2 dB step progression if not specified.
- `generate_16ue_confs.sh`: generates N `srsue` ZMQ conf files from a working template, substituting IMSI (sequential, matching the 16 subscribers already in the Open5GS DB, `...780` to `...795`), ZMQ ports (matching `multi_ue_nue.py`'s scheme: UE*i* = `2000+i*100+1` / `2000+i*100`), and - critically - `netns`, `filename`, and pcap paths (see bug below).

**Bug found and fixed in the generator script**: the first version of `generate_16ue_confs.sh` substituted IMSI and ports correctly but left `netns = ue1` and all log/pcap filenames (`/tmp/ue1.log`, etc.) unchanged in every generated file, copied verbatim from the UE1 template. This meant every "UE2" through "UE16" config was actually trying to attach inside UE1's already-occupied network namespace, producing a misleading `Failed to setup/configure GW interface` error that looked like a namespace or permissions problem but was actually a config generation bug. Fixed by adding `netns`, `mac_filename`, `mac_nr_filename`, `nas_filename`, and `filename` to the substitution list, each parameterised by UE index.

**16 UE attempt**: broker started successfully (8+16=... sockets all bound), but only 7 of 16 UEs ever completed random access; the remaining 9 looped on PRACH transmission indefinitely. Broker CPU usage was extreme: **1065% (over 10 cores)**, with system load average 24+. This is a clear computational bottleneck in the single-process GNU Radio broker, not a configuration issue - confirmed by checking socket counts (correct, 16 LISTEN sockets) and system resources (`97%+ idle` when only 7 UE branches were active, vs the saturated state with 16).

**7 UE attempt** (after fixing the netns/filename bug above): 4 of 7 UEs (UE1-4) completed the full attach sequence (RRC Connected, PDU Session Establishment successful, correct per-UE IP assigned) and remained stable. UE5-7 got stuck in the same PRACH retry loop as the 16-UE case, and did **not** recover even after an additional 4 minutes of waiting with no other changes - confirming this is a stable failure point, not a slow-but-eventually-successful process. Broker CPU at this point was ~300% - higher than the ~160% seen with a healthy 4-UE broker, but far below the 16-UE case's 1065%.

**Conclusion**: **4 simultaneous UEs is the practical, repeatable stability limit** for this single-process GNU Radio broker architecture on this hardware (CloudLab d6515, AMD EPYC 7452). The limiting factor is broker CPU/scheduling load, not subscriber DB, IMSI/APN config, network namespaces, routing, or DU/CU-CP capacity (DU and CU-CP both remained healthy and responsive throughout, even while UE5-7 failed to attach). The PRACH retry pattern (one successful detection roughly every 16 seconds, never overlapping) suggests the broker cannot keep pace with synchronous REQ/REP polling across more than ~4-5 socket pairs under sustained load, regardless of how long it is left running.

**Decision**: descope multi-UE ZMQ throughput/power measurements to 1, 3, and 4 simultaneous UEs, all of which are now verified stable and reproducible. Keep `multi_ue_nue.py` and `generate_16ue_confs.sh` in the repository for any future attempt at a redesigned (e.g. multi-process) broker - the generalised, parameterised tooling is sound and bug-free; the limitation is architectural (single GNU Radio process), not something fixable by configuration changes within the current broker design.