# Power Consumption Analysis of Containerised 5G Deployments with Variable Topologies and Load

MSc Computer Science - Future Networked Systems  
Trinity College Dublin  
**Author**: Marta Fraioli
**Supervisor**: Professor Merim Dzaferagic

---

## Overview

This project investigates how CU-DU topology configurations and traffic load influence per-component power consumption in a disaggregated, containerised 5G RAN. Two complementary experimental campaigns are presented:

- **ru\_dummy campaign**: 1125 runs across 15 topologies (1CU-1DU through 1CU-8DU and 7 multi-CU configurations), varying CQI and UE count, using srsRAN testmode for controlled, reproducible load generation.
- **ZMQ campaign**: 60 validated runs across 8 topologies using real srsUE processes with ZMQ RF emulation, measuring both power and throughput via iperf3.

Power consumption is measured at the process level via Scaphandre and Intel RAPL, with each srsRAN component (CU-CP, CU-UP, DU) running as a separate Docker container.

---

## Research Questions

1. How does the number of DU instances affect total power consumption, and does centralising control plane processing in a single CU yield lower energy consumption than distributing it across multiple CU instances serving the same number of DUs?
2. How does traffic load (UE count and CQI) influence power consumption within each topology?
3. Can a threshold-based dynamic scaling policy reduce energy waste by matching the number of active DUs to current traffic demand?

---

## Testbed

- **Hardware**: CloudLab bare-metal node, AMD EPYC 7452, 32 cores, 125 GB RAM, Ubuntu 22.04
- **5G Core**: Open5GS (AMF, SMF, UPF and associated NFs), single container constant across all experiments
- **RAN**: srsRAN Project - CU-CP, CU-UP, and one DU container per DU instance
- **ZMQ UEs**: srsRAN 4G (srsUE) processes with ZMQ RF emulation, 10 MHz bandwidth
- **Power measurement**: Scaphandre + RAPL via Linux powercap, Prometheus scraping at 5s intervals
- **Monitoring stack**: Prometheus, InfluxDB, Telegraf, Grafana
- **Orchestration**: Flask API + React/Vite UI, served via SSH tunnel on port 5000

---

## Repository Structure

```
.
├── analysis/                   Jupyter notebook and generated figures
│   └── power_analysis.ipynb    Main analysis notebook (ru_dummy + ZMQ sections)
├── api/
│   └── app.py                  Flask API backend for the orchestration platform
├── configs/
│   ├── templates/              Config templates for runtime generation (scale.sh)
│   ├── zmq/                    Base ZMQ configs (CU-CP, CU-UP, DU) and UE confs (ue1-4)
│   ├── zmq_multidu/            Additional DU configs and UE confs for multi-DU ZMQ experiments
│   ├── zmq_multicu/            Additional CU and DU configs for multi-CU ZMQ experiments
│   ├── zmq_split/              ZMQ split configs (CU-CP, CU-UP, DU)
│   └── runtime/                Runtime-generated configs (populated by scale.sh)
├── deploy/
│   ├── configs/                Static deployment configs for ru_dummy experiments
│   ├── srsRAN_Project/         Modified srsRAN Project files (Dockerfile, docker-compose, configs)
│   └── srsRAN_4G/
│       └── patches/            PDCCH threshold patch for ZMQ UE compatibility
├── docs/
│   └── lab-notebook.md         Dated lab notebook: setup steps, troubleshooting, experiment log, known issues
├── scripts/                    Experiment automation and data collection
└── ui/                         React/Vite frontend for the orchestration platform
```

---

## Scripts

| Script | Description |
|--------|-------------|
| `run_matrix_2cu2du.sh` | Representative per-topology ru_dummy matrix runner (2CU-2DU). Sweeps CQI {5,10,15} x per-DU UE {1,4,16,64,96} x 5 runs |
| `collect_power_breakdown.sh` | Per-component power breakdown collector for ru\_dummy topologies |
| `run_zmq_multidu_matrix_experiments.sh` | Full ZMQ experiment matrix for 1CU-NDU topologies |
| `run_zmq_multicu_matrix_experiments.sh` | Full ZMQ experiment matrix for 2CU topologies |
| `collect_zmq_multidu_breakdown.sh` | Power and throughput collector for 1CU-NDU ZMQ topologies |
| `collect_zmq_multicu_breakdown.sh` | Power and throughput collector for 2CU-NDU ZMQ topologies |
| `scale.sh` | Dynamic CU-DU topology scaler: provisions containers on demand from templates |
| `autoscale.sh` | Threshold-based autoscaler: monitors per-DU power and triggers scale events |
| `load_generator.sh` | Varies testmode UE count to simulate dynamic load for autoscaler demonstration |
| `teardown.sh` | Stops all srsRAN containers and optionally the monitoring stack and 5GC |
| `add_subscribers.sh` | Adds UE subscribers to Open5GS MongoDB |

---

## Experiment Matrices

### ru\_dummy campaign (600 runs)

| Parameter | Values |
|-----------|--------|
| Topologies (1CU) | 1CU-1DU through 1CU-8DU (600 runs) |
| Topologies (multi-CU) | 2CU-2DU, 2CU-4DU, 2CU-6DU, 2CU-8DU, 3CU-3DU, 3CU-6DU, 4CU-4DU (525 runs) |
| CQI values | 5, 10, 15 |
| UE counts | 1, 4, 16, 64, 96 |
| Runs per combination | 5 |
| **Total** | **1125 runs** |

### ZMQ campaign (60 runs)

| Parameter | Values |
|-----------|--------|
| Multi-DU topologies | 1CU-1DU, 1CU-2DU, 1CU-3DU, 1CU-4DU |
| Multi-CU topologies | 2CU-1DU/group, 2CU-2DU/group |
| UE/DU | 1, 4 |
| Runs per combination | 5 |

---

## Key Findings

- DU instances dominate infrastructure power consumption across all topologies (83-94% of total).
- CQI has negligible impact on power consumption in testmode; UE count is the primary load driver.
- Power scales approximately linearly with DU count up to 5 DUs (~3.2W per additional DU in testmode).
- Centralised CU architectures consistently draw less power than distributed configurations at equal DU count, with the overhead of CU distribution ranging from 5-25% depending on topology and load.
- Fixed power accounts for 70-80% of per-unit DU consumption, suggesting that powering down idle DUs is the most impactful energy saving strategy.
- ZMQ throughput scales approximately linearly with DU count (~27 Mbps per DU at 1 UE/DU); energy efficiency degrades with scale (0.10 W/Mbps at 1CU-1DU, up to 0.30 W/Mbps at 1CU-4DU with 4 UE/DU).

---

## Requirements

- Docker and Docker Compose
- srsRAN Project (built with ZMQ support)
- srsRAN 4G (srsUE, with PDCCH measurement threshold patch for ZMQ)
- Open5GS
- Scaphandre
- Prometheus, InfluxDB, Telegraf, Grafana
- Python 3 with pandas, numpy, matplotlib, seaborn, jupyter
- Node.js and npm (for the React UI)

---

## Notes

- All experiments were conducted on a CloudLab bare-metal node. RAPL requires `chmod -R a+r /sys/class/powercap/intel-rapl` on each boot.
- The ZMQ campaign is limited to 10 MHz bandwidth and a practical maximum of 4 UE/DU due to single-process GNU Radio broker CPU saturation.
- Git operations run on the local laptop only; the CloudLab node has no git access.
- MongoDB subscriber documents may revert after node reboot and must be re-applied via mongosh.

---

## Lab Notebook

`docs/lab-notebook.md` documents the full experimental journey in chronological order, including:
- CloudLab node setup and Docker configuration
- srsRAN and Open5GS deployment steps
- ZMQ broker setup and known issues (PDCCH patch, namespace management, broker PID selection)
- Per-experiment troubleshooting log
- Known issues and workarounds (MongoDB DNN revert, RAPL permissions, Xvfb cleanup)

---

## License

This repository is part of an MSc dissertation at Trinity College Dublin. Code may be reused with attribution.
