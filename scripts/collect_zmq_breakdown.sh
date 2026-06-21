#!/bin/bash
# Collect power consumption per srsRAN component for a ZMQ-based deployment,
# alongside DL/UL throughput (iperf3) and latency (ping). Mirrors the
# structure of collect_power_breakdown.sh (ru_dummy version), extended with
# idle/DL/UL phases since ZMQ uses real srsUE traffic instead of synthetic
# testmode load.
#
# Usage: ./collect_zmq_breakdown.sh [n_ue] [duration_seconds] [warmup_seconds] [sample_interval] [run_tag]
# Example: ./collect_zmq_breakdown.sh 4 300 60 5 2
# run_tag is included in output filenames so repeated runs of the same
# configuration don't overwrite each other's iperf3 logs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs"
N_UE=${1:-1}
DURATION=${2:-300}
WARMUP=${3:-60}
INTERVAL=${4:-5}
RUN_TAG=${5:-1}
OUTPUT="$LOGS_DIR/zmq_breakdown_${N_UE}ue_run${RUN_TAG}_$(date +%Y%m%d_%H%M%S).csv"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"

mkdir -p "$LOGS_DIR"

get_pid() {
    docker inspect "$1" --format '{{.State.Pid}}' 2>/dev/null || echo ""
}

# CU-CP/CU-UP/DU run as host processes via sudo for the ZMQ setup, not
# containers, so PIDs come from ps instead of docker inspect
get_host_pid() {
    # pgrep -f matches the whole sudo wrapper chain (sudo -> sudo -> real
    # binary), since the full command line contains the binary name at
    # every level. The actual process (the one with real CPU/power, not
    # always 0W like the sudo wrappers) is consistently the last PID in
    # the chain, not the first.
    pgrep -f "$1" | tail -1
}

CU_CP=$(get_host_pid "srscucp")
CU_UP=$(get_host_pid "srscuup")
DU=$(get_host_pid "srsdu")

declare -A UE_PIDS
for i in $(seq 1 "$N_UE"); do
    UE_PIDS["ue${i}"]=$(pgrep -f "ue${i}_zmq.conf" | tail -1)
done

echo "=== srsRAN ZMQ Power + Throughput Breakdown Collector ==="
echo "N_UE: $N_UE"
echo -n "PIDs: CU-CP=$CU_CP | CU-UP=$CU_UP | DU=$DU"
for key in $(echo "${!UE_PIDS[@]}" | tr ' ' '\n' | sort); do
    echo -n " | ${key^^}=${UE_PIDS[$key]}"
done
echo ""
echo "Config: Duration=${DURATION}s | Warmup=${WARMUP}s | Interval=${INTERVAL}s"
echo "Output: $OUTPUT"
echo "==========================================================="

echo "timestamp,phase,component,pid,microwatts,watts" > "$OUTPUT"

sample_power() {
    local PHASE=$1
    local N_SAMPLES=$((DURATION / INTERVAL))

    for i in $(seq 1 "$N_SAMPLES"); do
        TS=$(date -u +"%Y-%m-%dT%H:%M:%S")
        METRICS=$(curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power")

        for ENTRY in "cu_cp:$CU_CP" "cu_up:$CU_UP" "du:$DU"; do
            COMP=$(echo "$ENTRY" | cut -d: -f1)
            PID=$(echo "$ENTRY" | cut -d: -f2)
            if [ -z "$PID" ]; then continue; fi
            VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
            if [ -n "$VAL" ]; then
                WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
                echo "$TS,$PHASE,$COMP,$PID,$VAL,$WATTS" >> "$OUTPUT"
            fi
        done

        for key in $(echo "${!UE_PIDS[@]}" | tr ' ' '\n' | sort); do
            PID=${UE_PIDS[$key]}
            if [ -z "$PID" ]; then continue; fi
            VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
            if [ -n "$VAL" ]; then
                WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
                echo "$TS,$PHASE,$key,$PID,$VAL,$WATTS" >> "$OUTPUT"
            fi
        done

        echo "  [$PHASE] sample $i/$N_SAMPLES at $TS"
        sleep "$INTERVAL"
    done
}

run_iperf_dl() {
    # server inside each UE namespace, client from inside the Open5GS
    # container connecting in. The host itself cannot reach UE namespace
    # IPs directly (no working path even though a route exists), but the
    # container can, via the real UPF/DU/broker data path.
    local PIDS=()
    for i in $(seq 1 "$N_UE"); do
        sudo ip netns exec "ue${i}" iperf3 -s -p "53${i}1" -1 < /dev/null > /dev/null 2>&1 &
    done
    sleep 1
    for i in $(seq 1 "$N_UE"); do
        UE_IP=$(sudo ip netns exec "ue${i}" ip -4 addr show tun_srsue 2>/dev/null | grep -oP 'inet \K[\d.]+')
        if [ -z "$UE_IP" ]; then
            echo "  warning: no IP found for ue${i}, skipping DL client"
            continue
        fi
        docker exec open5gs_5gc iperf3 -c "$UE_IP" -p "53${i}1" -t "$DURATION" \
            > "$LOGS_DIR/iperf_dl_ue${i}_${N_UE}ue_run${RUN_TAG}.log" 2>&1 &
        PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
}

run_iperf_ul() {
    # server in the Open5GS container, client inside each UE namespace
    for i in $(seq 1 "$N_UE"); do
        docker exec -d open5gs_5gc iperf3 -s -p "52${i}1"
    done
    sleep 1
    local PIDS=()
    for i in $(seq 1 "$N_UE"); do
        sudo ip netns exec "ue${i}" iperf3 -c 10.53.1.2 -p "52${i}1" -t "$DURATION" < /dev/null > "$LOGS_DIR/iperf_ul_ue${i}_${N_UE}ue_run${RUN_TAG}.log" 2>&1 &
        PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
}

echo ""
echo "--- phase: idle ---"
echo "Warming up ${WARMUP}s..."
sleep "$WARMUP"
sample_power "idle"

echo ""
echo "--- phase: dl ---"
echo "Starting DL traffic and sampling in parallel..."
run_iperf_dl &
IPERF_DL_PID=$!
sample_power "dl"
wait "$IPERF_DL_PID"

echo ""
echo "--- phase: ul ---"
echo "Starting UL traffic and sampling in parallel..."
run_iperf_ul &
IPERF_UL_PID=$!
sample_power "ul"
wait "$IPERF_UL_PID"

echo ""
echo "=== Collection complete! ==="
echo "Rows saved: $(wc -l < "$OUTPUT")"
echo "Output: $OUTPUT"
echo ""
echo "=== POWER SUMMARY (by phase and component) ==="
python3 - << PYEOF
import csv, numpy as np
from collections import defaultdict
data = defaultdict(list)
with open('$OUTPUT') as f:
    reader = csv.DictReader(f)
    for row in reader:
        data[(row['phase'], row['component'])].append(float(row['watts']))
for (phase, comp), vals in sorted(data.items()):
    if vals:
        print(f"{phase:6s} {comp:8s}: mean={np.mean(vals):.3f}W std={np.std(vals):.3f}W n={len(vals)}")
PYEOF

echo ""
echo "=== THROUGHPUT SUMMARY ==="
for i in $(seq 1 "$N_UE"); do
    echo "ue${i}:"
    echo -n "  DL: "
    grep -A 3 "sender" "$LOGS_DIR/iperf_dl_ue${i}_${N_UE}ue_run${RUN_TAG}.log" 2>/dev/null | head -1 || echo "no data"
    echo -n "  UL: "
    grep -A 3 "sender" "$LOGS_DIR/iperf_ul_ue${i}_${N_UE}ue_run${RUN_TAG}.log" 2>/dev/null | head -1 || echo "no data"
done
