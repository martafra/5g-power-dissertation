#!/bin/bash
# Collect power consumption per srsRAN component.
# DU containers are discovered dynamically from docker ps, so any topology
# (any CU group) is captured correctly without a hand-maintained list.
# Usage: ./collect_power_breakdown.sh [topology] [samples] [interval_seconds]
# Example: ./collect_power_breakdown.sh 3cu6du 30 10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs"
TOPOLOGY=${1:-1cu1du}
SAMPLES=${2:-30}
INTERVAL=${3:-10}
OUTPUT="$LOGS_DIR/breakdown_${TOPOLOGY}_$(date +%Y%m%d_%H%M%S).csv"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"

mkdir -p "$LOGS_DIR"

get_pid() {
  docker inspect $1 --format '{{.State.Pid}}' 2>/dev/null || echo ""
}

# CU PIDs (up to 4 groups)
declare -A CU_PIDS
for name in srsran_cu_cp srsran_cu_up srsran_cu_cp2 srsran_cu_up2 \
            srsran_cu_cp3 srsran_cu_up3 srsran_cu_cp4 srsran_cu_up4; do
  PID=$(get_pid $name)
  if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    label=${name#srsran_}
    CU_PIDS[$label]=$PID
  fi
done

# DU PIDs discovered dynamically: every running container named srsran_du*
declare -A DU_PIDS
for name in $(docker ps --format '{{.Names}}' | grep -E '^srsran_du' | sort); do
  PID=$(get_pid $name)
  if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    label=${name#srsran_}
    DU_PIDS[$label]=$PID
  fi
done

echo "=== srsRAN Power Breakdown Collector ==="
echo "Topology: $TOPOLOGY"
echo "CU count: ${#CU_PIDS[@]}  |  DU count: ${#DU_PIDS[@]}"
echo -n "DUs:"
for key in $(echo "${!DU_PIDS[@]}" | tr ' ' '\n' | sort); do
  echo -n " $key=${DU_PIDS[$key]}"
done
echo ""
echo "Config: Samples=$SAMPLES | Interval=${INTERVAL}s | Output=$OUTPUT"
echo "Starting collection..."

echo "timestamp,component,pid,microwatts,watts" > "$OUTPUT"

for i in $(seq 1 $SAMPLES); do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%S")
  METRICS=$(curl -s $SCAPHANDRE_URL | grep "scaph_process_power")

  for key in $(echo "${!CU_PIDS[@]}" | tr ' ' '\n' | sort); do
    PID=${CU_PIDS[$key]}
    VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
    if [ -n "$VAL" ]; then
      WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
      echo "$TS,$key,$PID,$VAL,$WATTS" >> "$OUTPUT"
    fi
  done

  for key in $(echo "${!DU_PIDS[@]}" | tr ' ' '\n' | sort); do
    PID=${DU_PIDS[$key]}
    VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
    if [ -n "$VAL" ]; then
      WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
      echo "$TS,$key,$PID,$VAL,$WATTS" >> "$OUTPUT"
    fi
  done

  echo "Sample $i/$SAMPLES at $TS"
  sleep $INTERVAL
done

echo "=== Collection complete! ==="
echo "Rows saved: $(wc -l < "$OUTPUT")"
echo "Output: $OUTPUT"
echo ""
echo "=== SUMMARY ==="
python3 - << PYEOF
import csv, numpy as np
from collections import defaultdict
data = defaultdict(list)
with open('$OUTPUT') as f:
    for row in csv.DictReader(f):
        data[row['component']].append(float(row['watts']))
for comp, vals in sorted(data.items()):
    if vals:
        print(f"{comp}: mean={np.mean(vals):.3f}W std={np.std(vals):.3f}W n={len(vals)}")
PYEOF