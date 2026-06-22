#!/bin/bash
# Trial power + throughput collector for the 1CU-2DU ZMQ topology
# (DU1+UE1, DU2+UE5). Extends collect_zmq_breakdown.sh's structure to
# track two DUs and two non-contiguous UE indices instead of one DU and
# a contiguous 1..N UE range. Deliberately scoped to today's specific
# topology rather than a generic N-DU list - a stepping stone towards a
# fully generalised multi-DU matrix script.
#
# Usage: ./collect_zmq_multidu_trial.sh [duration_seconds] [warmup_seconds] [sample_interval] [run_tag]
# Example: ./collect_zmq_multidu_trial.sh 120 30 5 trial1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs"
DURATION=${1:-120}
WARMUP=${2:-30}
INTERVAL=${3:-5}
RUN_TAG=${4:-trial1}
OUTPUT="$LOGS_DIR/zmq_multidu_breakdown_run${RUN_TAG}_$(date +%Y%m%d_%H%M%S).csv"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"

UE_INDICES=(1 5)

mkdir -p "$LOGS_DIR"

# pgrep -f matches the whole sudo wrapper chain, since the full command
# line contains the binary/conf name at every level. The real process
# (the one with actual CPU/power, not 0W like the sudo wrappers) is
# consistently the last PID in the chain, not the first.
get_host_pid() {
    pgrep -f "$1" | tail -1
}

CU_CP=$(get_host_pid "srscucp")
CU_UP=$(get_host_pid "srscuup")
# "du_zmq.yml" and "du2_zmq.yml" are distinct substrings (the former is
# not contained in the latter), so these two patterns cannot cross-match
DU1=$(get_host_pid "du_zmq.yml")
DU2=$(get_host_pid "du2_zmq.yml")

declare -A UE_PIDS
for i in "${UE_INDICES[@]}"; do
    UE_PIDS["ue${i}"]=$(get_host_pid "ue${i}_zmq.conf")
done

echo "=== srsRAN 1CU-2DU ZMQ Power + Throughput Trial Collector ==="
echo -n "PIDs: CU-CP=$CU_CP | CU-UP=$CU_UP | DU1=$DU1 | DU2=$DU2"
for key in "${!UE_PIDS[@]}"; do
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

        for ENTRY in "cu_cp:$CU_CP" "cu_up:$CU_UP" "du1:$DU1" "du2:$DU2"; do
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
    # container (the host has no real path to UE namespace IPs)
    local PIDS=()
    for i in "${UE_INDICES[@]}"; do
        sudo ip netns exec "ue${i}" iperf3 -s -p "53${i}1" -1 < /dev/null > /dev/null 2>&1 &
    done
    sleep 1
    for i in "${UE_INDICES[@]}"; do
        UE_IP=$(sudo ip netns exec "ue${i}" ip -4 addr show tun_srsue 2>/dev/null | grep -oP 'inet \K[\d.]+')
        if [ -z "$UE_IP" ]; then
            echo "  warning: no IP found for ue${i}, skipping DL client"
            continue
        fi
        docker exec open5gs_5gc iperf3 -c "$UE_IP" -p "53${i}1" -t "$DURATION" \
            > "$LOGS_DIR/iperf_dl_ue${i}_multidu_run${RUN_TAG}.log" 2>&1 &
        PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
}

run_iperf_ul() {
    # server in the Open5GS container, client inside each UE namespace
    for i in "${UE_INDICES[@]}"; do
        docker exec -d open5gs_5gc iperf3 -s -p "52${i}1"
    done
    sleep 1
    local PIDS=()
    for i in "${UE_INDICES[@]}"; do
        sudo ip netns exec "ue${i}" iperf3 -c 10.53.1.2 -p "52${i}1" -t "$DURATION" < /dev/null > "$LOGS_DIR/iperf_ul_ue${i}_multidu_run${RUN_TAG}.log" 2>&1 &
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
for i in "${UE_INDICES[@]}"; do
    echo "ue${i}:"
    echo -n "  DL: "
    grep -A 3 "sender" "$LOGS_DIR/iperf_dl_ue${i}_multidu_run${RUN_TAG}.log" 2>/dev/null | head -1 || echo "no data"
    echo -n "  UL: "
    grep -A 3 "sender" "$LOGS_DIR/iperf_ul_ue${i}_multidu_run${RUN_TAG}.log" 2>/dev/null | head -1 || echo "no data"
done
