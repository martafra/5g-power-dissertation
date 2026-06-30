#!/bin/bash
# Power + throughput breakdown collector for a 2CU-NDU(per group) ZMQ
# multi-CU topology, where N_DU = du_per_group * 2 total DUs split
# evenly between two independent CU-CP/CU-UP groups (group 1 keeps the
# existing single-CU conventions unchanged, group 2 uses the
# zmq_multicu/ configs validated against group 1 at equal load).
# Generalises collect_zmq_multidu_breakdown.sh to track two CU-CP and
# two CU-UP processes instead of one, distinguishing them by config
# filename (cu_cp_zmq.yml vs cu_cp2_zmq.yml) exactly like DU/UE PIDs
# are already distinguished by their own conf filename.
#
# DU global index d (1-indexed) belongs to group 1 if d <= du_per_group,
# group 2 otherwise:
#   - group 1, d=1: zmq_split/du_zmq.yml | group 1, d>1: zmq_multidu/du${d}_zmq.yml
#   - group 2 (any d): zmq_multicu/du${d}_zmq.yml
#   - UE global index = (d-1)*4 + local_ue, local_ue in 1..ue_per_du (unchanged,
#     the UE/broker layer is fully agnostic to which CU group a DU belongs to)
#
# Usage: ./collect_zmq_multicu_breakdown.sh [du_per_group] [ue_per_du] [duration] [warmup] [interval] [run_tag]
# Example: ./collect_zmq_multicu_breakdown.sh 2 4 300 60 5 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs"
DU_PER_GROUP=${1:-1}
UE_PER_DU=${2:-1}
DURATION=${3:-300}
WARMUP=${4:-60}
INTERVAL=${5:-5}
RUN_TAG=${6:-1}
N_DU=$((DU_PER_GROUP * 2))
OUTPUT="$LOGS_DIR/zmq_multicu_breakdown_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN_TAG}_$(date +%Y%m%d_%H%M%S).csv"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"

SLOTS_PER_DU=4   # must match generate_multidu_ue_confs.sh

mkdir -p "$LOGS_DIR"

get_host_pid() {
    pgrep -f "$1" | tail -1
}

du_conf_basename() {
    # basename-only match: safe because within a single run no two
    # DUs ever share a global index, regardless of which group's
    # directory the file actually lives in
    local d=$1
    if [ "$d" -eq 1 ]; then
        echo "du_zmq.yml"
    else
        echo "du${d}_zmq.yml"
    fi
}

CU_CP1=$(get_host_pid "cu_cp_zmq.yml")
CU_UP1=$(get_host_pid "cu_up_zmq.yml")
CU_CP2=$(get_host_pid "cu_cp2_zmq.yml")
CU_UP2=$(get_host_pid "cu_up2_zmq.yml")

declare -A DU_PIDS
declare -A UE_PIDS
UE_INDICES=()

for d in $(seq 1 "$N_DU"); do
    DU_PIDS["du${d}"]=$(get_host_pid "$(du_conf_basename "$d")")
    for local_i in $(seq 1 "$UE_PER_DU"); do
        global_i=$(( (d - 1) * SLOTS_PER_DU + local_i ))
        UE_INDICES+=("$global_i")
        UE_PIDS["ue${global_i}"]=$(get_host_pid "ue${global_i}_zmq.conf")
    done
done

echo "=== srsRAN 2CUx${DU_PER_GROUP}DU(each) ZMQ Power + Throughput Collector ==="
echo -n "PIDs: CU-CP1=$CU_CP1 | CU-UP1=$CU_UP1 | CU-CP2=$CU_CP2 | CU-UP2=$CU_UP2"
for key in $(echo "${!DU_PIDS[@]}" | tr ' ' '\n' | sort -V); do
    echo -n " | ${key^^}=${DU_PIDS[$key]}"
done
for key in $(echo "${!UE_PIDS[@]}" | tr ' ' '\n' | sort -V); do
    echo -n " | ${key^^}=${UE_PIDS[$key]}"
done
echo ""
echo "Config: DU_per_group=$DU_PER_GROUP (N_DU_total=$N_DU) | UE_per_DU=$UE_PER_DU | Duration=${DURATION}s | Warmup=${WARMUP}s | Interval=${INTERVAL}s"
echo "Output: $OUTPUT"
echo "==========================================================="

echo "timestamp,phase,component,pid,microwatts,watts" > "$OUTPUT"

sample_power() {
    local PHASE=$1
    local N_SAMPLES=$((DURATION / INTERVAL))

    for i in $(seq 1 "$N_SAMPLES"); do
        TS=$(date -u +"%Y-%m-%dT%H:%M:%S")
        METRICS=$(curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power")

        for ENTRY in "cu_cp1:$CU_CP1" "cu_up1:$CU_UP1" "cu_cp2:$CU_CP2" "cu_up2:$CU_UP2"; do
            COMP=$(echo "$ENTRY" | cut -d: -f1)
            PID=$(echo "$ENTRY" | cut -d: -f2)
            if [ -z "$PID" ]; then continue; fi
            VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
            if [ -n "$VAL" ]; then
                WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
                echo "$TS,$PHASE,$COMP,$PID,$VAL,$WATTS" >> "$OUTPUT"
            fi
        done

        for key in $(echo "${!DU_PIDS[@]}" | tr ' ' '\n' | sort -V); do
            PID=${DU_PIDS[$key]}
            if [ -z "$PID" ]; then continue; fi
            VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
            if [ -n "$VAL" ]; then
                WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
                echo "$TS,$PHASE,$key,$PID,$VAL,$WATTS" >> "$OUTPUT"
            fi
        done

        for key in $(echo "${!UE_PIDS[@]}" | tr ' ' '\n' | sort -V); do
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

ensure_default_routes() {
    # The default route on tun_srsue has been observed to disappear
    # unpredictably (not just after an explicit UE restart), causing
    # "Bad file descriptor" / "Network is unreachable" failures in
    # iperf3. Defensively re-check/re-add before any phase that needs
    # real connectivity, rather than trusting a one-time setup.
    for i in "${UE_INDICES[@]}"; do
        if ! sudo ip netns exec "ue${i}" ip route | grep -q "^default"; then
            echo "  ue${i}: default route missing, re-adding"
            sudo ip netns exec "ue${i}" ip route add default dev tun_srsue 2>/dev/null
        fi
    done
}

run_iperf_dl() {
    ensure_default_routes
    # server inside each UE namespace, client from inside the Open5GS
    # container (the host has no real path to UE namespace IPs) - this
    # layer is fully agnostic to which CU group a UE's DU belongs to
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
            > "$LOGS_DIR/iperf_dl_ue${i}_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN_TAG}.log" 2>&1 &
        PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
}

run_iperf_ul() {
    ensure_default_routes
    # server in the Open5GS container, client inside each UE namespace
    for i in "${UE_INDICES[@]}"; do
        docker exec -d open5gs_5gc iperf3 -s -p "52${i}1"
    done
    sleep 1
    local PIDS=()
    for i in "${UE_INDICES[@]}"; do
        sudo ip netns exec "ue${i}" iperf3 -c 10.53.1.2 -p "52${i}1" -t "$DURATION" < /dev/null > "$LOGS_DIR/iperf_ul_ue${i}_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN_TAG}.log" 2>&1 &
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
# NOTE: captures grep output into a variable first, then tests the
# variable directly - "grep ... | head -1 || echo no data" (the
# previous approach) never actually falls through to "no data",
# because head -1 exits 0 even when grep matched nothing.
for i in "${UE_INDICES[@]}"; do
    echo "ue${i}:"
    DL_LOG="$LOGS_DIR/iperf_dl_ue${i}_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN_TAG}.log"
    UL_LOG="$LOGS_DIR/iperf_ul_ue${i}_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN_TAG}.log"
    DL_LINE=$(grep "sender" "$DL_LOG" 2>/dev/null | head -1)
    UL_LINE=$(grep "sender" "$UL_LOG" 2>/dev/null | head -1)
    if [ -n "$DL_LINE" ]; then
        echo "  DL: $DL_LINE"
    else
        echo "  DL: no data (check $DL_LOG)"
    fi
    if [ -n "$UL_LINE" ]; then
        echo "  UL: $UL_LINE"
    else
        echo "  UL: no data (check $UL_LOG)"
    fi
done
