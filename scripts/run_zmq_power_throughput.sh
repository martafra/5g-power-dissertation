#!/bin/bash
# run_zmq_power_throughput.sh - measures power and throughput for ZMQ gnb+srsUE setup
# runs idle, dl, and ul experiments with 5 runs each
# results saved as JSON in docs/logs/zmq/

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="$SCRIPT_DIR/../docs/logs/zmq"
SCAPHANDRE_URL="http://localhost:8080/metrics"
WARMUP=20
DURATION=30
SAMPLE_INTERVAL=5
RUNS=5
IPERF_DURATION=20
UE_IP="10.45.1.2"
UE_NETNS="ue1"

mkdir -p "$LOGDIR"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

get_power() {
    curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power_consumption_microwatts" | \
    python3 -c "
import sys
total = 0
for line in sys.stdin:
    if line.startswith('#'):
        continue
    try:
        if any(x in line for x in ['gnb', 'srsue']):
            val = float(line.split('}')[-1].strip()) / 1e6
            if val > 0.1:
                total += val
    except:
        pass
print(f'{total:.3f}')
" 2>/dev/null || echo "0"
}

get_power_breakdown() {
    curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power_consumption_microwatts" | \
    python3 -c "
import sys
gnb = 0
srsue = 0
for line in sys.stdin:
    if line.startswith('#'):
        continue
    try:
        val = float(line.split('}')[-1].strip()) / 1e6
        if val < 0.1:
            continue
        if 'gnb' in line:
            gnb += val
        elif 'srsue' in line:
            srsue += val
    except:
        pass
print(f'{gnb:.3f} {srsue:.3f}')
" 2>/dev/null || echo "0 0"
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

measure() {
    local MODE=$1
    local RUN=$2
    local OUTFILE="${LOGDIR}/zmq_${MODE}_run${RUN}.json"

    if [ -f "$OUTFILE" ]; then
        log "already exists, skipping: $(basename "$OUTFILE")"
        return
    fi

    log "warming up ${WARMUP}s..."
    sleep "$WARMUP"

    local POWER_SAMPLES=()
    local GNB_SAMPLES=()
    local UE_SAMPLES=()
    local THROUGHPUT_MBPS=0
    local RETRANSMITS=0
    local N_SAMPLES=$((DURATION / SAMPLE_INTERVAL))

    if [ "$MODE" = "dl" ]; then
        log "starting iperf3 dl..."
        read -r THROUGHPUT_MBPS RETRANSMITS <<< "$(run_iperf_dl)"
        log "dl throughput: ${THROUGHPUT_MBPS} Mbits/sec retrans: ${RETRANSMITS}"
    elif [ "$MODE" = "ul" ]; then
        log "starting iperf3 ul..."
        read -r THROUGHPUT_MBPS RETRANSMITS <<< "$(run_iperf_ul)"
        log "ul throughput: ${THROUGHPUT_MBPS} Mbits/sec retrans: ${RETRANSMITS}"
    fi

    log "sampling power every ${SAMPLE_INTERVAL}s for ${DURATION}s..."
    for i in $(seq 1 "$N_SAMPLES"); do
        TOTAL=$(get_power)
        read -r GNB UE_PWR <<< "$(get_power_breakdown)"
        POWER_SAMPLES+=("$TOTAL")
        GNB_SAMPLES+=("$GNB")
        UE_SAMPLES+=("$UE_PWR")
        log "  sample $i/$N_SAMPLES: total=${TOTAL}W gnb=${GNB}W srsue=${UE_PWR}W"
        [ "$i" -lt "$N_SAMPLES" ] && sleep "$SAMPLE_INTERVAL"
    done

    python3 - << PYEOF > "$OUTFILE"
import json, numpy as np
power = [$(IFS=,; echo "${POWER_SAMPLES[*]}")]
gnb = [$(IFS=,; echo "${GNB_SAMPLES[*]}")]
srsue = [$(IFS=,; echo "${UE_SAMPLES[*]}")]
valid = [s for s in power if s > 0.1]
valid_gnb = [s for s in gnb if s > 0.1]
valid_srsue = [s for s in srsue if s > 0.1]
result = {
    "mode": "$MODE",
    "run": $RUN,
    "throughput_mbps": float("$THROUGHPUT_MBPS"),
    "retransmits": int("$RETRANSMITS"),
    "power_samples": power,
    "gnb_samples": gnb,
    "srsue_samples": srsue,
    "total_power_mean_W": round(np.mean(valid), 3) if valid else 0,
    "total_power_std_W": round(np.std(valid), 3) if valid else 0,
    "gnb_power_mean_W": round(np.mean(valid_gnb), 3) if valid_gnb else 0,
    "srsue_power_mean_W": round(np.mean(valid_srsue), 3) if valid_srsue else 0,
    "n": len(valid)
}
print(json.dumps(result, indent=2))
PYEOF

    log "saved: $(basename "$OUTFILE")"
    python3 -c "
import json
d = json.load(open('$OUTFILE'))
print(f'  total={d[\"total_power_mean_W\"]:.3f}W gnb={d[\"gnb_power_mean_W\"]:.3f}W srsue={d[\"srsue_power_mean_W\"]:.3f}W throughput={d[\"throughput_mbps\"]:.1f}Mbps')
"
}

MODES=("idle" "dl" "ul")
TOTAL=$(( ${#MODES[@]} * RUNS ))
COUNT=0

echo "=== ZMQ Power + Throughput Experiment ==="
echo "Modes: ${MODES[*]}"
echo "Runs per mode: $RUNS"
echo "Total experiments: $TOTAL"
echo "Output dir: $LOGDIR"
echo "=========================================="

for MODE in "${MODES[@]}"; do
    for RUN in $(seq 1 "$RUNS"); do
        COUNT=$((COUNT + 1))
        echo ""
        log "[$COUNT/$TOTAL] mode=$MODE run=$RUN"

        if [ "$MODE" = "idle" ]; then
            log "idle mode - no traffic"
        else
            log "starting iperf3 server in ue netns..."
            sudo ip netns exec "$UE_NETNS" iperf3 -s -D --one-off 2>/dev/null || \
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
files = glob.glob("${LOGDIR}/zmq_${MODE}_run*.json")
if not files:
    print("no data")
else:
    power = [json.load(open(f))['total_power_mean_W'] for f in sorted(files)]
    tput = [json.load(open(f))['throughput_mbps'] for f in sorted(files)]
    print(f"power={np.mean(power):.3f}W±{np.std(power):.3f} throughput={np.mean(tput):.1f}Mbps runs={len(power)}")
PYEOF
done
