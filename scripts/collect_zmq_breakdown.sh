#!/bin/bash
# collect_zmq_breakdown.sh - per-component power breakdown for ZMQ 1CU-1DU setup
# measures CU-CP, CU-UP, DU, srsUE separately with idle/dl/ul traffic modes
# usage: ./collect_zmq_breakdown.sh [topology] [samples] [interval] [runs]
# example: ./collect_zmq_breakdown.sh 1cu1du 60 5 5

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs/zmq"
TOPOLOGY=${1:-1cu1du}
SAMPLES=${2:-60}
INTERVAL=${3:-5}
RUNS=${4:-5}
WARMUP=20
IPERF_DURATION=20
UE_IP="10.45.1.2"
UE_NETNS="ue1"
SCAPHANDRE_URL="http://localhost:8080/metrics"

mkdir -p "$LOGS_DIR"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

get_pid_native() {
    pgrep -f "$1" | tail -1 || echo ""
}

get_component_power() {
    local pid=$1
    if [ -z "$pid" ]; then echo "0"; return; fi
    local result
    result=$(curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power_consumption_microwatts" | \
    grep "pid=\"$pid\"" | \
    python3 -c "
import sys
found = False
for line in sys.stdin:
    try:
        val = float(line.split('}')[-1].strip()) / 1e6
        print(f'{val:.6f}')
        found = True
        break
    except:
        pass
if not found:
    print('0')
" 2>/dev/null | head -1)
    echo "${result:-0}"
}

run_iperf_dl() {
    iperf3 -c "$UE_IP" -t "$IPERF_DURATION" -J 2>/dev/null | \
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    bps = d['end']['sum_sent']['bits_per_second']
    retrans = d['end']['sum_sent']['retransmits']
    print(f'{bps/1e6:.3f} {retrans}')
except:
    print('0 0')
"
}

run_iperf_ul() {
    iperf3 -c "$UE_IP" -t "$IPERF_DURATION" -R -J 2>/dev/null | \
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    bps = d['end']['sum_received']['bits_per_second']
    retrans = d['end']['sum_sent']['retransmits']
    print(f'{bps/1e6:.3f} {retrans}')
except:
    print('0 0')
"
}

run_ping_latency() {
    ping -c 20 -i 0.2 "$UE_IP" 2>/dev/null | \
    python3 -c "
import sys, re
rtts = []
for line in sys.stdin:
    m = re.search(r'time=([\d.]+)', line)
    if m:
        rtts.append(float(m.group(1)))
if rtts:
    import numpy as np
    print(f'{np.mean(rtts):.2f} {np.min(rtts):.2f} {np.max(rtts):.2f} {np.std(rtts):.2f} {len(rtts)}')
else:
    print('0 0 0 0 0')
"
}

measure() {
    local MODE=$1
    local RUN=$2
    local OUTFILE="${LOGS_DIR}/zmq_breakdown_${TOPOLOGY}_${MODE}_run${RUN}.json"

    if [ -f "$OUTFILE" ]; then
        log "already exists, skipping: $(basename "$OUTFILE")"
        return
    fi

    # get PIDs
    local PID_CUCP PID_CUUP PID_DU PID_UE
    PID_CUCP=$(get_pid_native srscucp)
    PID_CUUP=$(get_pid_native srscuup)
    PID_DU=$(get_pid_native srsdu)
    PID_UE=$(get_pid_native srsue)

    log "PIDs: cu-cp=$PID_CUCP cu-up=$PID_CUUP du=$PID_DU srsue=$PID_UE"

    log "warming up ${WARMUP}s..."
    sleep "$WARMUP"

    local THROUGHPUT_MBPS=0
    local RETRANSMITS=0
    local RTT_MEAN=0 RTT_MIN=0 RTT_MAX=0 RTT_STD=0 RTT_N=0

    if [ "$MODE" = "dl" ]; then
        log "starting iperf3 dl..."
        read -r THROUGHPUT_MBPS RETRANSMITS <<< "$(run_iperf_dl)"
        log "dl throughput: ${THROUGHPUT_MBPS} Mbps retrans: ${RETRANSMITS}"
        log "measuring latency..."
        read -r RTT_MEAN RTT_MIN RTT_MAX RTT_STD RTT_N <<< "$(run_ping_latency)"
    elif [ "$MODE" = "ul" ]; then
        log "starting iperf3 ul..."
        read -r THROUGHPUT_MBPS RETRANSMITS <<< "$(run_iperf_ul)"
        log "ul throughput: ${THROUGHPUT_MBPS} Mbps retrans: ${RETRANSMITS}"
    fi

    log "sampling power every ${INTERVAL}s for $((SAMPLES * INTERVAL))s..."

    local CUCP_SAMPLES=() CUUP_SAMPLES=() DU_SAMPLES=() UE_SAMPLES=() TOTAL_SAMPLES=()

    for i in $(seq 1 "$SAMPLES"); do
        local cucp cuup du ue total
        cucp=$(get_component_power "$PID_CUCP")
        cuup=$(get_component_power "$PID_CUUP")
        du=$(get_component_power "$PID_DU")
        ue=$(get_component_power "$PID_UE")
        total=$(python3 -c "vals=['$cucp','$cuup','$du','$ue']; print(f'{sum(float(v) if v.strip() else 0 for v in vals):.6f}')" 2>/dev/null || echo "0")
        CUCP_SAMPLES+=("$cucp")
        CUUP_SAMPLES+=("$cuup")
        DU_SAMPLES+=("$du")
        UE_SAMPLES+=("$ue")
        TOTAL_SAMPLES+=("$total")
        log "  sample $i/$SAMPLES: total=${total}W cu-cp=${cucp}W cu-up=${cuup}W du=${du}W srsue=${ue}W"
        [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
    done

    python3 - << PYEOF > "$OUTFILE"
import json, numpy as np

def stats(samples):
    valid = [s for s in samples if s > 0.05]
    if not valid:
        return {"mean_W": 0, "std_W": 0, "n": 0, "samples": samples}
    return {"mean_W": round(np.mean(valid), 6), "std_W": round(np.std(valid), 6), "n": len(valid), "samples": samples}

cucp = [$(IFS=,; echo "${CUCP_SAMPLES[*]}")]
cuup = [$(IFS=,; echo "${CUUP_SAMPLES[*]}")]
du   = [$(IFS=,; echo "${DU_SAMPLES[*]}")]
ue   = [$(IFS=,; echo "${UE_SAMPLES[*]}")]
total = [$(IFS=,; echo "${TOTAL_SAMPLES[*]}")]

result = {
    "topology": "$TOPOLOGY",
    "mode": "$MODE",
    "run": $RUN,
    "nof_ues": 1,
    "throughput_mbps": float("$THROUGHPUT_MBPS"),
    "retransmits": int("$RETRANSMITS"),
    "rtt_mean_ms": float("$RTT_MEAN"),
    "rtt_min_ms": float("$RTT_MIN"),
    "rtt_max_ms": float("$RTT_MAX"),
    "rtt_std_ms": float("$RTT_STD"),
    "components": {
        "cu_cp": stats(cucp),
        "cu_up": stats(cuup),
        "du":    stats(du),
        "srsue": stats(ue),
        "total": stats(total)
    }
}
print(json.dumps(result, indent=2))
PYEOF

    log "saved: $(basename "$OUTFILE")"
    python3 -c "
import json
d = json.load(open('$OUTFILE'))
c = d['components']
print(f'  total={c[\"total\"][\"mean_W\"]:.3f}W cu-cp={c[\"cu_cp\"][\"mean_W\"]:.3f}W cu-up={c[\"cu_up\"][\"mean_W\"]:.3f}W du={c[\"du\"][\"mean_W\"]:.3f}W srsue={c[\"srsue\"][\"mean_W\"]:.3f}W throughput={d[\"throughput_mbps\"]:.1f}Mbps rtt={d[\"rtt_mean_ms\"]:.1f}ms')
"
}

MODES=("idle" "dl" "ul")
TOTAL=$(( ${#MODES[@]} * RUNS ))
COUNT=0

echo "=== ZMQ Power Breakdown Experiment ==="
echo "Topology: $TOPOLOGY"
echo "Modes: ${MODES[*]}"
echo "Runs: $RUNS | Samples: $SAMPLES | Interval: ${INTERVAL}s"
echo "Output: $LOGS_DIR"
echo "======================================"

for MODE in "${MODES[@]}"; do
    for RUN in $(seq 1 "$RUNS"); do
        COUNT=$((COUNT + 1))
        echo ""
        log "[$COUNT/$TOTAL] topology=$TOPOLOGY mode=$MODE run=$RUN"

        if [ "$MODE" != "idle" ]; then
            sudo pkill iperf3 2>/dev/null || true
            sleep 1
            sudo ip netns exec "$UE_NETNS" iperf3 -s -D 2>/dev/null || true
            sleep 2
        fi

        measure "$MODE" "$RUN"
    done
done

echo ""
echo "=== All experiments complete! ==="
echo ""
echo "=== SUMMARY ==="
for MODE in "${MODES[@]}"; do
    echo -n "mode=$MODE: "
    python3 - << PYEOF
import json, glob, numpy as np
files = glob.glob("${LOGS_DIR}/zmq_breakdown_${TOPOLOGY}_${MODE}_run*.json")
if not files:
    print("no data")
else:
    totals = [json.load(open(f))['components']['total']['mean_W'] for f in sorted(files)]
    tputs = [json.load(open(f))['throughput_mbps'] for f in sorted(files)]
    rtts = [json.load(open(f))['rtt_mean_ms'] for f in sorted(files) if json.load(open(f))['rtt_mean_ms'] > 0]
    print(f"power={np.mean(totals):.3f}W±{np.std(totals):.3f} throughput={np.mean(tputs):.1f}Mbps rtt={np.mean(rtts):.1f}ms runs={len(totals)}")
PYEOF
done
