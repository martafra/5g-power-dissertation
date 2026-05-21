#!/bin/bash
# autoscale.sh - Automatic CU-DU topology scaler based on per-DU power consumption
# Usage: ./autoscale.sh [options]

set -uo pipefail

# ============================================================
# Default parameters
# ============================================================
MIN_CU=1
MAX_CU=4
DU_PER_CU=1
INTERVAL=30
CONSECUTIVE=3
COOLDOWN=120
HIGH_THRESHOLD=3.5
LOW_THRESHOLD=1.5
CQI=15
NOF_UES=96

# ============================================================
# Path configuration
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs/autoscaling"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"
STATE_FILE="$SCRIPT_DIR/../configs/autoscale_state.json"

mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/autoscale_$(date +%Y%m%d_%H%M%S).log"

# ============================================================
# Parse arguments
# ============================================================
usage() {
    echo "Usage: $0 [options]"
    echo "  --min-cu <n>         Minimum CU instances (default: 1)"
    echo "  --max-cu <n>         Maximum CU instances (default: 4)"
    echo "  --du <m>             DUs per CU (default: 1)"
    echo "  --interval <s>       Sampling interval in seconds (default: 30)"
    echo "  --consecutive <n>    Consecutive samples before scaling (default: 3)"
    echo "  --cooldown <s>       Cooldown period after scaling event (default: 120)"
    echo "  --high-threshold <w> Per-DU power threshold for scale-up in W (default: 3.5)"
    echo "  --low-threshold <w>  Per-DU power threshold for scale-down in W (default: 1.5)"
    echo "  --cqi <val>          CQI for testmode (default: 15)"
    echo "  --ues <val>          UEs per DU for testmode (default: 96)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --min-cu) MIN_CU="$2"; shift 2 ;;
        --max-cu) MAX_CU="$2"; shift 2 ;;
        --du) DU_PER_CU="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --consecutive) CONSECUTIVE="$2"; shift 2 ;;
        --cooldown) COOLDOWN="$2"; shift 2 ;;
        --high-threshold) HIGH_THRESHOLD="$2"; shift 2 ;;
        --low-threshold) LOW_THRESHOLD="$2"; shift 2 ;;
        --cqi) CQI="$2"; shift 2 ;;
        --ues) NOF_UES="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# ============================================================
# Logging
# ============================================================
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date -u +%H:%M:%S)] [WARNING] $*" | tee -a "$LOG_FILE"; }
event() { echo "[$(date -u +%H:%M:%S)] [SCALING EVENT] $*" | tee -a "$LOG_FILE"; }

# ============================================================
# State
# ============================================================
get_current_cu() {
    docker ps --format "{{.Names}}" | { grep "^srsran_cu_cp_" || true; } | wc -l
}

measure_power_per_du() {
    local total_power
    total_power=$(curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power_consumption_microwatts" | \
    python3 -c "
import sys
total = 0
for line in sys.stdin:
    if line.startswith('#'):
        continue
    try:
        if any(x in line for x in ['srscucp', 'srscuup', 'srsdu']):
            val = float(line.split('}')[-1].strip()) / 1e6
            if val > 0.05:
                total += val
    except:
        pass
print(f'{total:.3f}')
" 2>/dev/null || echo "0")

    local current_cu
    current_cu=$(get_current_cu)
    local total_du=$(( current_cu * DU_PER_CU ))

    if [ "$total_du" -eq 0 ]; then
        echo "0"
        return
    fi

    python3 -c "print(f'{float(\"$total_power\") / $total_du:.3f}')" 2>/dev/null || echo "0"
}

# ============================================================
# Main loop
# ============================================================
log "=================================================="
log "Autoscaler started"
log "Min CU: $MIN_CU | Max CU: $MAX_CU | DU/CU: $DU_PER_CU"
log "Interval: ${INTERVAL}s | Consecutive: $CONSECUTIVE | Cooldown: ${COOLDOWN}s"
log "High threshold: ${HIGH_THRESHOLD}W/DU | Low threshold: ${LOW_THRESHOLD}W/DU"
log "=================================================="

consecutive_high=0
consecutive_low=0
last_scaling=$(date +%s)

while true; do
    sleep "$INTERVAL"

    CURRENT_CU=$(get_current_cu)
    POWER_PER_DU=$(measure_power_per_du)
    NOW=$(date +%s)
    SINCE_LAST=$(( NOW - last_scaling ))

    log "CU: $CURRENT_CU | Power/DU: ${POWER_PER_DU}W | Cooldown remaining: $(( COOLDOWN - SINCE_LAST > 0 ? COOLDOWN - SINCE_LAST : 0 ))s"

    # Check if in cooldown
    if [ "$SINCE_LAST" -lt "$COOLDOWN" ]; then
        log "In cooldown period, skipping scaling decision"
        consecutive_high=0
        consecutive_low=0
        continue
    fi

    # Check high threshold
    if python3 -c "exit(0 if float('$POWER_PER_DU') > $HIGH_THRESHOLD else 1)" 2>/dev/null; then
        consecutive_high=$(( consecutive_high + 1 ))
        consecutive_low=0
        log "Above high threshold ($consecutive_high/$CONSECUTIVE consecutive)"

        if [ "$consecutive_high" -ge "$CONSECUTIVE" ] && [ "$CURRENT_CU" -lt "$MAX_CU" ]; then
            event "Scaling UP: ${CURRENT_CU}CU → $((CURRENT_CU + 1))CU (Power/DU: ${POWER_PER_DU}W > ${HIGH_THRESHOLD}W)"
            "$SCRIPT_DIR/scale.sh" --cu $((CURRENT_CU + 1)) --du $DU_PER_CU --cqi $CQI --ues $NOF_UES
            last_scaling=$(date +%s)
            consecutive_high=0
            consecutive_low=0
        elif [ "$CURRENT_CU" -ge "$MAX_CU" ]; then
            warn "Already at maximum CU count ($MAX_CU)"
        fi

    # Check low threshold
    elif python3 -c "exit(0 if float('$POWER_PER_DU') < $LOW_THRESHOLD else 1)" 2>/dev/null; then
        consecutive_low=$(( consecutive_low + 1 ))
        consecutive_high=0
        log "Below low threshold ($consecutive_low/$CONSECUTIVE consecutive)"

        if [ "$consecutive_low" -ge "$CONSECUTIVE" ] && [ "$CURRENT_CU" -gt "$MIN_CU" ]; then
            event "Scaling DOWN: ${CURRENT_CU}CU → $((CURRENT_CU - 1))CU (Power/DU: ${POWER_PER_DU}W < ${LOW_THRESHOLD}W)"
            "$SCRIPT_DIR/scale.sh" --cu $((CURRENT_CU - 1)) --du $DU_PER_CU --cqi $CQI --ues $NOF_UES
            last_scaling=$(date +%s)
            consecutive_high=0
            consecutive_low=0
        elif [ "$CURRENT_CU" -le "$MIN_CU" ]; then
            warn "Already at minimum CU count ($MIN_CU)"
        fi

    else
        consecutive_high=0
        consecutive_low=0
    fi

done
