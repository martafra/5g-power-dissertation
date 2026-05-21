#!/bin/bash
# load_generator.sh - Varies testmode UE count to simulate dynamic load
# Usage: ./load_generator.sh --sequence "1,16,96,16,1" --duration 120 --cqi 15

set -uo pipefail

# ============================================================
# Default parameters
# ============================================================
SEQUENCE="1,4,16,64,96,64,16,4,1"
DURATION=120
CQI=15

# ============================================================
# Path configuration
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../configs/runtime"
LOGS_DIR="$SCRIPT_DIR/../docs/logs/load"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"

mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/load_$(date +%Y%m%d_%H%M%S).log"

# ============================================================
# Parse arguments
# ============================================================
usage() {
    echo "Usage: $0 [options]"
    echo "  --sequence <n,n,...>  Comma-separated UE counts (default: 1,4,16,64,96,64,16,4,1)"
    echo "  --duration <s>        Duration per step in seconds (default: 120)"
    echo "  --cqi <val>           CQI value (default: 15)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --sequence) SEQUENCE="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --cqi) CQI="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# ============================================================
# Logging
# ============================================================
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# ============================================================
# Power measurement
# ============================================================
measure_power() {
    curl -s "$SCAPHANDRE_URL" | grep "scaph_process_power_consumption_microwatts" | \
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
" 2>/dev/null || echo "0"
}

# ============================================================
# Update testmode for all active DUs
# ============================================================
update_load() {
    local nof_ues=$1
    local updated=0

    # Find all active DU testmode configs
    for f in "$RUNTIME_DIR"/testmode_*.yml; do
        [ -f "$f" ] || continue
        # Update nof_ues
        sed -i "s/nof_ues: [0-9]*/nof_ues: $nof_ues/" "$f"
        updated=$((updated + 1))
    done

    if [ "$updated" -eq 0 ]; then
        log "No active DU configs found in $RUNTIME_DIR"
        return 1
    fi

    # Restart all active DUs to pick up new config
    local restarted=0
    while IFS= read -r container; do
        log "Restarting $container..."
        docker restart "$container" > /dev/null 2>&1
        restarted=$((restarted + 1))
    done < <(docker ps --format "{{.Names}}" | grep "^srsran_du_")

    log "Updated $updated testmode configs, restarted $restarted DUs"
    sleep 10
}

# ============================================================
# Main
# ============================================================
IFS=',' read -ra STEPS <<< "$SEQUENCE"
TOTAL_STEPS=${#STEPS[@]}
TOTAL_DURATION=$(( TOTAL_STEPS * DURATION ))

log "=================================================="
log "Load generator started"
log "Sequence: $SEQUENCE"
log "Duration per step: ${DURATION}s"
log "Total duration: ${TOTAL_DURATION}s (~$(( TOTAL_DURATION / 60 ))min)"
log "CQI: $CQI"
log "=================================================="

STEP=0
for NUE in "${STEPS[@]}"; do
    STEP=$((STEP + 1))
    log "Step $STEP/$TOTAL_STEPS: Setting load to $NUE UEs"

    update_load "$NUE"

    POWER=$(measure_power)
    log "Step $STEP: $NUE UEs | Power: ${POWER}W"

    # Sample power periodically during this step
    ELAPSED=10
    while [ "$ELAPSED" -lt "$DURATION" ]; do
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        POWER=$(measure_power)
        log "  t=${ELAPSED}s | UEs=$NUE | Power: ${POWER}W"
    done

    # Wait remaining time
    REMAINING=$(( DURATION - ELAPSED ))
    if [ "$REMAINING" -gt 0 ]; then
        sleep "$REMAINING"
    fi
done

log "=================================================="
log "Load generation complete"
log "Log saved to: $LOG_FILE"
