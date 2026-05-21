#!/bin/bash
# scale.sh - Dynamic CU-DU topology scaler for containerised 5G deployments
# Usage: ./scale.sh --cu <n> --du <m> [--warn-threshold <pct>] [--scaledown-threshold <pct>]

set -euo pipefail

# ============================================================
# Default parameters
# ============================================================
TARGET_CU=1
TARGET_DU=1
WARN_THRESHOLD=80
SCALEDOWN_THRESHOLD=30
MONITOR_INTERVAL=0
CQI=15
NOF_UES=96

# ============================================================
# Path configuration
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMPLATE_DIR="$PROJECT_DIR/configs/templates"
RUNTIME_DIR="$PROJECT_DIR/configs/runtime"
STATE_FILE="$PROJECT_DIR/configs/state.json"
LOGS_DIR="$PROJECT_DIR/docs/logs/scaling"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"
AMF_ADDR="10.53.1.2"
DOCKER_IMAGE="srsran/gnb"

# ============================================================
# IP pools (RAN, F1U, metrics networks)
# ============================================================
# RAN pool: 10.53.1.40 onwards (avoids conflicts with static containers)
RAN_BASE="10.53.1"
RAN_START=40

# F1U pool: 172.18.10.30 onwards
F1U_BASE="172.18.10"
F1U_START=30

# Metrics pool: 172.19.1.40 onwards
METRICS_BASE="172.19.1"
METRICS_START=40

# RNTI base (hex): 0x1000 onwards
RNTI_BASE=4096

# ============================================================
# Parse arguments
# ============================================================
usage() {
    echo "Usage: $0 --cu <n> --du <m> [--warn-threshold <pct>] [--scaledown-threshold <pct>] [--cqi <val>] [--ues <val>]"
    echo ""
    echo "  --cu <n>                    Number of CU instances (default: 1)"
    echo "  --du <m>                    Number of DUs per CU (default: 1)"
    echo "  --warn-threshold <pct>      Power warning threshold as % of estimated max (default: 80)"
    echo "  --scaledown-threshold <pct> Power scale-down suggestion threshold % (default: 30)"
    echo "  --cqi <val>                 CQI value for testmode (default: 15)"
    echo "  --ues <val>                 Number of UEs per DU for testmode (default: 96)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --cu) TARGET_CU="$2"; shift 2 ;;
        --du) TARGET_DU="$2"; shift 2 ;;
        --warn-threshold) WARN_THRESHOLD="$2"; shift 2 ;;
        --scaledown-threshold) SCALEDOWN_THRESHOLD="$2"; shift 2 ;;
        --cqi) CQI="$2"; shift 2 ;;
        --monitor) MONITOR_INTERVAL="$2"; shift 2 ;;
        --ues) NOF_UES="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

mkdir -p "$RUNTIME_DIR" "$LOGS_DIR"
log_early() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Ensure monitoring stack is up
DOCKER_DIR="$PROJECT_DIR/srsRAN_Project/docker"
if ! curl -s --max-time 3 "$SCAPHANDRE_URL" > /dev/null 2>&1; then
    log_early "Scaphandre not reachable - starting monitoring stack..."
    cd "$DOCKER_DIR"
    docker compose -f docker-compose.yml -f docker-compose.ui.yml up -d scaphandre prometheus
    log_early "Waiting for Scaphandre to start..."
    sleep 10
    cd - > /dev/null
fi

# Ensure 5GC is up
if [ -z "$(docker ps --format '{{.Names}}' | grep open5gs_5gc)" ]; then
    log_early "5GC not running - starting..."
    cd "$DOCKER_DIR"
    docker compose -f docker-compose.yml up -d 5gc
    log_early "Waiting for 5GC to be healthy..."
    while [ "$(docker inspect --format='{{.State.Health.Status}}' open5gs_5gc 2>/dev/null)" != "healthy" ]; do
        sleep 3
    done
    log_early "5GC is healthy"
    cd - > /dev/null
fi



# ============================================================
# Logging
# ============================================================
LOG_FILE="$LOGS_DIR/scale_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE" >&2; }
warn() { echo "[$(date -u +%H:%M:%S)] [WARNING] $*" | tee -a "$LOG_FILE" 1>&2; }

# ============================================================
# IP allocation
# ============================================================
get_ran_ip() {
    local idx=$1
    local octet=$(( RAN_START + idx ))
    echo "${RAN_BASE}.${octet}"
}

get_f1u_ip() {
    local idx=$1
    local octet=$(( F1U_START + idx ))
    echo "${F1U_BASE}.${octet}"
}

get_metrics_ip() {
    local idx=$1
    local octet=$(( METRICS_START + idx ))
    echo "${METRICS_BASE}.${octet}"
}

get_rnti() {
    local cu_id=$1
    local du_id=$2
    printf "0x%X" $(( RNTI_BASE + (cu_id - 1) * 100 + du_id ))
}

get_pci() {
    local cu_id=$1
    local du_id=$2
    echo $(( (cu_id - 1) * 20 + du_id + 100 ))
}

# ============================================================
# Config generation
# ============================================================
generate_cu_cp_config() {
    local cu_id=$1
    local cu_cp_addr=$2
    local out="$RUNTIME_DIR/cu_cp_${cu_id}.yml"
    sed \
        -e "s|{{AMF_ADDR}}|${AMF_ADDR}|g" \
        -e "s|{{CU_CP_ADDR}}|${cu_cp_addr}|g" \
        -e "s|{{CU_ID}}|${cu_id}|g" \
        "$TEMPLATE_DIR/cu_cp.yml.template" > "$out"
    echo "$out"
}

generate_cu_up_config() {
    local cu_id=$1
    local cu_cp_addr=$2
    local cu_up_addr=$3
    local cu_up_f1u_addr=$4
    local out="$RUNTIME_DIR/cu_up_${cu_id}.yml"
    sed \
        -e "s|{{CU_CP_ADDR}}|${cu_cp_addr}|g" \
        -e "s|{{CU_UP_ADDR}}|${cu_up_addr}|g" \
        -e "s|{{CU_UP_F1U_ADDR}}|${cu_up_f1u_addr}|g" \
        -e "s|{{CU_ID}}|${cu_id}|g" \
        "$TEMPLATE_DIR/cu_up.yml.template" > "$out"
    echo "$out"
}

generate_du_config() {
    local cu_id=$1
    local du_id=$2
    local cu_cp_addr=$3
    local du_addr=$4
    local du_f1u_addr=$5
    local pci=$6
    local out="$RUNTIME_DIR/du_${cu_id}_${du_id}.yml"
    sed \
        -e "s|{{CU_CP_ADDR}}|${cu_cp_addr}|g" \
        -e "s|{{DU_ADDR}}|${du_addr}|g" \
        -e "s|{{DU_F1U_ADDR}}|${du_f1u_addr}|g" \
        -e "s|{{PCI}}|${pci}|g" \
        -e "s|{{CU_ID}}|${cu_id}|g" \
        -e "s|{{DU_ID}}|${du_id}|g" \
        "$TEMPLATE_DIR/du.yml.template" > "$out"
    echo "$out"
}

generate_testmode_config() {
    local cu_id=$1
    local du_id=$2
    local rnti=$3
    local out="$RUNTIME_DIR/testmode_${cu_id}_${du_id}.yml"
    sed \
        -e "s|{{RNTI}}|${rnti}|g" \
        -e "s|{{CQI}}|${CQI}|g" \
        -e "s|{{NOF_UES}}|${NOF_UES}|g" \
        "$TEMPLATE_DIR/testmode.yml.template" > "$out"
    echo "$out"
}

# ============================================================
# Container management
# ============================================================
wait_healthy() {
    local name=$1
    local max_wait=${2:-60}
    local elapsed=0
    log "Waiting for $name to be healthy..."
    while [ "$(docker inspect --format='{{.State.Health.Status}}' $name 2>/dev/null)" != "healthy" ]; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [ $elapsed -ge $max_wait ]; then
            warn "$name did not become healthy within ${max_wait}s"
            return 1
        fi
    done
    log "$name is healthy"
}

start_cu() {
    local cu_id=$1
    local ip_idx=$(( (cu_id - 1) * 3 ))

    local cu_cp_addr=$(get_ran_ip $ip_idx)
    local cu_up_addr=$(get_ran_ip $(( ip_idx + 1 )))
    local cu_up_f1u_addr=$(get_f1u_ip $(( ip_idx )))
    local metrics_addr=$(get_metrics_ip $(( ip_idx )))

    log "Starting CU ${cu_id}: CU-CP=${cu_cp_addr} CU-UP=${cu_up_addr}"

    local cu_cp_cfg=$(generate_cu_cp_config $cu_id $cu_cp_addr)
    local cu_up_cfg=$(generate_cu_up_config $cu_id $cu_cp_addr $cu_up_addr $cu_up_f1u_addr)

    # Start CU-CP
    docker run -d \
        --name "srsran_cu_cp_${cu_id}" \
        --network ran \
        --ip "$cu_cp_addr" \
        -v "gnb-storage:/tmp" \
        -v "${cu_cp_cfg}:/cu_cp.yml:ro" \
        --health-cmd 'for p in 38462 38472; do ss -l -H -A sctp "sport = :$p" | grep -q . || exit 1; done; exit 0' \
        --health-interval 3s \
        --health-retries 60 \
        "$DOCKER_IMAGE" srscucp -c /cu_cp.yml 1>&2

    wait_healthy "srsran_cu_cp_${cu_id}"

    # Start CU-UP
    docker run -d \
        --name "srsran_cu_up_${cu_id}" \
        --network ran \
        --ip "$cu_up_addr" \
        -v "gnb-storage:/tmp" \
        -v "${cu_up_cfg}:/cu_up.yml:ro" \
        "$DOCKER_IMAGE" srscuup -c /cu_up.yml 1>&2

    docker network connect --ip "$cu_up_f1u_addr" f1u "srsran_cu_up_${cu_id}"
    docker network connect --ip "$metrics_addr" metrics "srsran_cu_up_${cu_id}"

    sleep 10
    log "CU ${cu_id} started"
    echo "$cu_cp_addr"
}

start_du() {
    local cu_id=$1
    local du_id=$2
    local cu_cp_addr=$3
    local ip_idx=$(( (cu_id - 1) * 20 + du_id - 1 ))

    local du_addr=$(get_ran_ip $(( 60 + ip_idx )))
    local du_f1u_addr=$(get_f1u_ip $(( 20 + ip_idx )))
    local du_metrics_addr=$(get_metrics_ip $(( 20 + ip_idx )))
    local pci=$(get_pci $cu_id $du_id)
    local rnti=$(get_rnti $cu_id $du_id)

    log "Starting DU ${cu_id}-${du_id}: addr=${du_addr} pci=${pci} rnti=${rnti}"

    local du_cfg=$(generate_du_config $cu_id $du_id $cu_cp_addr $du_addr $du_f1u_addr $pci)
    local tm_cfg=$(generate_testmode_config $cu_id $du_id $rnti)

    docker run -d \
        --name "srsran_du_${cu_id}_${du_id}" \
        --network ran \
        --ip "$du_addr" \
        --privileged \
        --cap-add SYS_NICE \
        --cap-add CAP_SYS_PTRACE \
        -v "gnb-storage:/tmp" \
        -v "${du_cfg}:/du.yml:ro" \
        -v "${tm_cfg}:/testmode.yml:ro" \
        "$DOCKER_IMAGE" srsdu -c /du.yml -c /testmode.yml 1>&2

    docker network connect --ip "$du_f1u_addr" f1u "srsran_du_${cu_id}_${du_id}"
    docker network connect --ip "$du_metrics_addr" metrics "srsran_du_${cu_id}_${du_id}"

    log "DU ${cu_id}-${du_id} started"
}

stop_cu() {
    local cu_id=$1
    log "Stopping CU ${cu_id}..."
    docker stop "srsran_cu_cp_${cu_id}" "srsran_cu_up_${cu_id}" 2>/dev/null || true
    docker rm "srsran_cu_cp_${cu_id}" "srsran_cu_up_${cu_id}" 2>/dev/null || true
    log "CU ${cu_id} stopped"
}

stop_du() {
    local cu_id=$1
    local du_id=$2
    log "Stopping DU ${cu_id}-${du_id}..."
    docker stop "srsran_du_${cu_id}_${du_id}" 2>/dev/null || true
    docker rm "srsran_du_${cu_id}_${du_id}" 2>/dev/null || true
    log "DU ${cu_id}-${du_id} stopped"
}

# ============================================================
# Current state detection
# ============================================================
get_current_cu_count() {
    docker ps --format "{{.Names}}" | { grep "^srsran_cu_cp_" || true; } | wc -l
}

get_current_du_count_for_cu() {
    local cu_id=$1
    docker ps --format "{{.Names}}" | { grep "^srsran_du_${cu_id}_" || true; } | wc -l
}

# ============================================================
# Power measurement
# ============================================================
measure_total_power() {
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
" 2>/dev/null | tr -d "\n" || echo "0"
}

check_power_thresholds() {
    local current_power=$1
    local n_cu=$2
    local n_du=$3

    # Estimate max power based on breakdown data (approx 4W per DU at full load)
    local estimated_max=$(python3 -c "print(f'{($n_cu * 2 * 0.2) + ($n_cu * $n_du * 4.0):.1f}')")
    local pct=$(python3 -c "print(int($current_power / $estimated_max * 100))" 2>/dev/null || echo 0)

    log "Power: ${current_power}W | Estimated max: ${estimated_max}W | Load: ${pct}%"

    if [ "$pct" -ge "$WARN_THRESHOLD" ]; then
        warn "Power consumption at ${pct}% of estimated capacity for ${n_cu}CU-${n_du}DU topology."
        warn "Consider scaling up: $0 --cu $((n_cu + 1)) --du $n_du"
    elif [ "$pct" -le "$SCALEDOWN_THRESHOLD" ] && [ "$n_cu" -gt 1 -o "$n_du" -gt 1 ]; then
        warn "Power consumption at ${pct}% - topology may be oversized."
        warn "Consider scaling down: $0 --cu $((n_cu > 1 ? n_cu - 1 : 1)) --du $n_du"
    fi
}

# ============================================================
# Main scaling logic
# ============================================================
log "=================================================="
log "Scale request: ${TARGET_CU} CU x ${TARGET_DU} DU/CU"
log "Warn threshold: ${WARN_THRESHOLD}% | Scale-down threshold: ${SCALEDOWN_THRESHOLD}%"
log "=================================================="

CURRENT_CU=$(get_current_cu_count)
log "Current state: ${CURRENT_CU} CU"

# Measure power before transition
POWER_BEFORE=$(measure_total_power)
log "Power before transition: ${POWER_BEFORE}W"

# ---- Scale CUs ----
if [ "$TARGET_CU" -gt "$CURRENT_CU" ]; then
    log "Scaling UP: adding $((TARGET_CU - CURRENT_CU)) CU(s)"
    for cu_id in $(seq $((CURRENT_CU + 1)) $TARGET_CU); do
        CU_CP_ADDR=$(start_cu $cu_id)
        for du_id in $(seq 1 $TARGET_DU); do
            start_du $cu_id $du_id $CU_CP_ADDR
        done
    done
elif [ "$TARGET_CU" -lt "$CURRENT_CU" ]; then
    log "Scaling DOWN: removing $((CURRENT_CU - TARGET_CU)) CU(s)"
    for cu_id in $(seq $((TARGET_CU + 1)) $CURRENT_CU); do
        CURRENT_DU=$(get_current_du_count_for_cu $cu_id)
        for du_id in $(seq 1 $CURRENT_DU); do
            stop_du $cu_id $du_id
        done
        stop_cu $cu_id
    done
fi

# ---- Scale DUs per CU ----
for cu_id in $(seq 1 $TARGET_CU); do
    CURRENT_DU=$(get_current_du_count_for_cu $cu_id)
    CU_CP_ADDR=$(get_ran_ip $(( (cu_id - 1) * 3 )))

    if [ "$TARGET_DU" -gt "$CURRENT_DU" ]; then
        log "CU ${cu_id}: adding $((TARGET_DU - CURRENT_DU)) DU(s)"
        for du_id in $(seq $((CURRENT_DU + 1)) $TARGET_DU); do
            start_du $cu_id $du_id $CU_CP_ADDR
        done
    elif [ "$TARGET_DU" -lt "$CURRENT_DU" ]; then
        log "CU ${cu_id}: removing $((CURRENT_DU - TARGET_DU)) DU(s)"
        for du_id in $(seq $((TARGET_DU + 1)) $CURRENT_DU); do
            stop_du $cu_id $du_id
        done
    fi
done

# Wait for stabilisation
log "Waiting 60s for stabilisation..."
sleep 60

# Measure power after transition
POWER_AFTER=$(measure_total_power)
DELTA=$(python3 -c "a=float('$POWER_AFTER'.strip()); b=float('$POWER_BEFORE'.strip()); print(f'{a-b:+.3f}')")

log "=================================================="
log "Transition complete"
log "Power before: ${POWER_BEFORE}W"
log "Power after:  ${POWER_AFTER}W"
log "Delta:        ${DELTA}W"
log "Topology:     ${TARGET_CU}CU x ${TARGET_DU}DU"
log "=================================================="

# Check thresholds
check_power_thresholds $POWER_AFTER $TARGET_CU $TARGET_DU

log "Log saved to: $LOG_FILE"
# ============================================================
# Monitoring loop (if --monitor specified)
# ============================================================
if [ "$MONITOR_INTERVAL" -gt 0 ]; then
    log "Starting monitoring loop (interval: ${MONITOR_INTERVAL}s) - press Ctrl+C to stop"
    while true; do
        sleep "$MONITOR_INTERVAL"
        CURRENT_POWER=$(measure_total_power)
        check_power_thresholds $CURRENT_POWER $TARGET_CU $TARGET_DU
    done
fi

