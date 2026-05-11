# Power Consumption Analysis of Containerised 5G Deployments with Variable Topologies and Load

MSc Dissertation - Trinity College Dublin  
**Author**: Marta Fraioli  
**Supervisor**: Merim Dzaferagic  

## Overview

This project investigates the power consumption of containerised 5G deployments using srsRAN and Open5GS, across variable RAN topologies and traffic loads. The testbed deploys a full 5G stack in Docker containers and measures per-component energy consumption using Scaphandre and Prometheus.

## Research Questions

- How does power consumption scale with the number of Distributed Units (DUs)?
- How do traffic load (number of UEs) and channel quality (CQI) influence energy usage?
- What is the per-component power breakdown between CU-CP, CU-UP, and DU instances?

## Testbed Architecture

- **5G Core**: Open5GS (AMF, SMF, UPF, and associated NFs)
- **RAN**: srsRAN CU-CP, CU-UP, and DU (ru_dummy test mode)
- **Topologies tested**: 1CU-1DU, 1CU-2DU, 1CU-3DU, 1CU-4DU
- **Power measurement**: Scaphandre (eBPF + RAPL) with Prometheus scraping
- **Monitoring**: Grafana dashboards via InfluxDB and Telegraf
- **Containerisation**: Docker Compose

## Repository Structure

```
.
- scripts/          Experiment automation and data collection scripts
- analysis/         Jupyter notebook and generated figures
- docs/             Lab notebook and project documentation
```

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/run_matrix_experiments.sh` | Runs the full experiment matrix across topologies, CQI values, and UE counts |
| `scripts/collect_power_breakdown.sh` | Collects per-component power breakdown for a given topology |

## Experiment Matrix

- **Topologies**: 1CU-1DU, 1CU-2DU, 1CU-3DU, 1CU-4DU
- **CQI values**: 5, 10, 15
- **UE counts**: 1, 4, 16, 64, 96
- **Runs per combination**: 5
- **Total experiments**: 225

## Requirements

- Docker and Docker Compose
- srsRAN Project (with ZMQ support)
- Open5GS
- Scaphandre
- Prometheus and Grafana
- Python 3 with pandas, numpy, matplotlib, seaborn, jupyter

## Hardware Note

Experiments were conducted on a Lenovo Legion laptop. Thermal throttling was observed when running 5 or more DU instances simultaneously (CPU cores exceeding 90°C). Results for 1CU-4DU were validated at thermal steady state (cores below 35°C).

## License

This repository is part of an academic dissertation. Code may be reused with attribution.
