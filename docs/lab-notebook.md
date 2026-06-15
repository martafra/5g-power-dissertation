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

#### Next steps

- extend to multi-DU with ZMQ