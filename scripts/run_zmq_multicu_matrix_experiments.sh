#!/bin/bash
# Full ZMQ experiment matrix for 2CU topologies: two independent
# CU-CP/CU-UP groups, du_per_group DUs each (so N_DU_total =
# du_per_group * 2), at varying UE/DU load. Companion to
# run_zmq_multidu_matrix_experiments.sh (1CU-NDU only), reusing every
# convention validated there plus the multi-CU addressing scheme
# validated manually across scenarios A-D:
#   - Group 1 (DU global index d <= du_per_group): existing 1CU
#     configs, completely unchanged - du_zmq.yml for d=1,
#     zmq_multidu/du${d}_zmq.yml otherwise.
#   - Group 2 (DU global index d > du_per_group): zmq_multicu/
#     configs (cu_cp2_zmq.yml, cu_up2_zmq.yml, du${d}_zmq.yml),
#     gnb_id 412, F1AP/E1AP on the 127.0.11.x/127.0.21.x subnets,
#     N2/N3 on the secondary host IP 10.53.1.3.
#   - UE global index = (d-1)*4 + local_ue, local_ue in 1..ue_per_du,
#     unchanged - the UE/broker layer never knows which CU group its
#     DU belongs to.
#
# Three lessons learned the hard way during manual multi-CU
# validation, all baked into this script so they are never
# rediscovered by hand again:
#   1. ALWAYS use zmq_broker.py, NEVER multi_ue_nue.py, for every DU
#      including DU1 - multi_ue_nue.py reliably wedges when a second
#      independent CU-CP/CU-UP/DU stack is running concurrently.
#   2. A broker, its DU, and its UEs must be restarted together as a
#      single unit - restarting one tier while leaving an adjacent
#      tier alive desyncs the ZMQ socket pairing.
#   3. UE network namespaces must be created explicitly inside
#      start_branch_multicu() before launching srsue - srsue does not
#      create its own namespace, and relying on leftover namespaces
#      from earlier sessions (as the single-CU matrix unknowingly did
#      for weeks) silently breaks the very first run after any clean
#      reboot.
#
# IMPORTANT: launch this script itself inside a tmux session, or
# everything it backgrounds with & dies the moment the calling SSH
# session disconnects:
#   tmux new-session -d -s multicu_matrix \
#       "~/dissertation/scripts/run_zmq_multicu_matrix_experiments.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="$SCRIPT_DIR/../docs/logs/zmq_multicu_matrix"
BREAKDOWN_SCRIPT="$SCRIPT_DIR/collect_zmq_multicu_breakdown.sh"
DURATION=300
WARMUP=60
SAMPLE_INTERVAL=5
RUNS=5
BRANCH_MAX_RETRIES=3
BRANCH_ATTACH_TIMEOUT=60

DU_PER_GROUP_VALUES=(1 2)
UE_PER_DU_VALUES=(1 4)

mkdir -p "$LOGDIR"

preflight_check() {
    local failed=0
    echo "=== Pre-flight check ==="

    if sudo iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "10.45.0.0/16"; then
        echo "  [OK] MASQUERADE rule for 10.45.0.0/16 present"
    else
        echo "  [FAIL] MASQUERADE rule for 10.45.0.0/16 missing on the host."
        echo "         Fix: sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o enp1s0f0np0 -j MASQUERADE"
        failed=1
    fi

    if ip addr show | grep -q "10.53.1.3"; then
        echo "  [OK] secondary host IP 10.53.1.3 present (needed for CU group 2 N2/N3)"
    else
        echo "  [FAIL] secondary host IP 10.53.1.3 missing - CU group 2's CU-CP/CU-UP cannot"
        echo "         bind N2/N3 without it (non-persistent across reboots)."
        echo "         Fix: ip addr show | grep 10.53.1   # find the bridge name first"
        echo "              sudo ip addr add 10.53.1.3/24 dev <bridge_name>"
        failed=1
    fi

    for c in open5gs_5gc prometheus scaphandre; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${c} .*Up"; then
            echo "  [OK] container $c is up"
        else
            echo "  [FAIL] container $c is not running."
            failed=1
        fi
    done

    local apn_check
    apn_check=$(docker exec open5gs_5gc mongosh open5gs --quiet --eval \
        'db.subscribers.findOne({imsi: "001010123456795"}, {"slice.session.name":1})' 2>/dev/null)
    if echo "$apn_check" | grep -q "internet"; then
        echo "  [OK] subscriber 001010123456795 (UE16 slot) has APN 'internet'"
    else
        echo "  [FAIL] subscriber 001010123456795 missing/wrong APN - needed for the 2CUx2DU x 4UE/DU case."
        failed=1
    fi

    local stale
    stale=$(pgrep -f "srsue|srscucp|srscuup|srsdu|multi_ue|zmq_broker" 2>/dev/null)
    if [ -n "$stale" ]; then
        echo "  [FAIL] stale srsRAN/broker processes already running (PIDs: $(echo "$stale" | tr '\n' ' '))."
        echo "         Fix: sudo pkill -9 -f srsue; sudo pkill -9 -f srscucp; sudo pkill -9 -f srscuup;"
        echo "              sudo pkill -9 -f srsdu; sudo pkill -9 -f zmq_broker"
        failed=1
    else
        echo "  [OK] no stale srsRAN/broker processes"
    fi

    for bin in \
        ~/dissertation/srsRAN_Project/build/apps/cu_cp/srscucp \
        ~/dissertation/srsRAN_Project/build/apps/cu_up/srscuup \
        ~/dissertation/srsRAN_Project/build/apps/du/srsdu \
        ~/dissertation/srsRAN_4G/build/srsue/src/srsue; do
        if [ -x "$bin" ]; then
            echo "  [OK] $bin exists and is executable"
        else
            echo "  [FAIL] $bin not found or not executable"
            failed=1
        fi
    done

    if command -v iperf3 > /dev/null; then
        echo "  [OK] iperf3 available on host"
    else
        echo "  [FAIL] iperf3 not found on host"
        failed=1
    fi
    if docker exec open5gs_5gc which iperf3 > /dev/null 2>&1; then
        echo "  [OK] iperf3 available inside open5gs_5gc"
    else
        echo "  [FAIL] iperf3 not found inside open5gs_5gc container"
        failed=1
    fi

    for f in cu_cp2_zmq.yml cu_up2_zmq.yml du2_zmq.yml du3_zmq.yml du4_zmq.yml; do
        if [ -f "$SCRIPT_DIR/../configs/zmq_multicu/$f" ]; then
            echo "  [OK] zmq_multicu/$f exists"
        else
            echo "  [FAIL] zmq_multicu/$f missing"
            failed=1
        fi
    done
    if [ -f "$SCRIPT_DIR/../configs/zmq_multidu/du2_zmq.yml" ]; then
        echo "  [OK] zmq_multidu/du2_zmq.yml exists (group 1's DU2 for the 2CUx2DU scenarios)"
    else
        echo "  [FAIL] zmq_multidu/du2_zmq.yml missing"
        failed=1
    fi
    for i in 2 3 4 6 7 8 10 11 12 14 15 16; do
        if [ -f "$SCRIPT_DIR/../configs/zmq_multidu/ue${i}_zmq.conf" ] || \
           [ -f "$SCRIPT_DIR/../configs/zmq/multiue_official/ue${i}_zmq.conf" ]; then
            :
        else
            echo "  [FAIL] ue${i}_zmq.conf missing - run generate_multidu_ue_confs.sh first"
            failed=1
        fi
    done

    echo "========================="
    if [ "$failed" -ne 0 ]; then
        echo "Pre-flight check FAILED. Refusing to start an unattended multi-hour run"
        echo "on an environment that is not ready - fix the items above and re-run."
        exit 1
    fi
    echo "Pre-flight check passed. Proceeding with the experiment matrix."
    echo ""
}

du_conf_path() {
    local d=$1
    if [ "$d" -eq 1 ]; then
        echo "$SCRIPT_DIR/../configs/zmq_split/du_zmq.yml"
    else
        echo "$SCRIPT_DIR/../configs/zmq_multidu/du${d}_zmq.yml"
    fi
}

ue_conf_path() {
    local global_i=$1
    local d=$2
    if [ "$d" -eq 1 ]; then
        echo "$SCRIPT_DIR/../configs/zmq/multiue_official/ue${global_i}_zmq.conf"
    else
        echo "$SCRIPT_DIR/../configs/zmq_multidu/ue${global_i}_zmq.conf"
    fi
}

du_broker_base_port() {
    local d=$1
    if [ "$d" -eq 1 ]; then
        echo "2000"
    else
        echo "$(( (d - 1) * 10000 ))"
    fi
}

group_for_du() {
    local d=$1
    local du_per_group=$2
    if [ "$d" -le "$du_per_group" ]; then
        echo 1
    else
        echo 2
    fi
}

du_conf_path_multicu() {
    local d=$1
    local g=$2
    if [ "$g" -eq 1 ]; then
        du_conf_path "$d"
    else
        echo "$SCRIPT_DIR/../configs/zmq_multicu/du${d}_zmq.yml"
    fi
}

kill_branch_multicu() {
    local d=$1
    local ue_per_du=$2
    local g=$3
    local du_conf
    du_conf=$(du_conf_path_multicu "$d" "$g")

    for local_i in $(seq 1 "$ue_per_du"); do
        local global_i=$(( (d - 1) * 4 + local_i ))
        sudo tmux kill-session -t "ue${global_i}" 2>/dev/null
    done
    sudo pkill -9 -f "$(basename "$du_conf")"
    # every DU uses zmq_broker.py in multi-CU context; harmless to
    # kill every instance here since the outer loop processes DUs
    # strictly in order and no later DU's broker has started yet
    sudo pkill -9 -f "zmq_broker.py"
}

start_branch_multicu() {
    local d=$1
    local ue_per_du=$2
    local g=$3
    local du_conf base_port
    du_conf=$(du_conf_path_multicu "$d" "$g")
    base_port=$(du_broker_base_port "$d")

    # ALWAYS zmq_broker.py - never multi_ue_nue.py - see header comment,
    # lesson 1
    xvfb-run -a stdbuf -oL -eL python3 "$SCRIPT_DIR/../configs/zmq_multidu/zmq_broker.py" \
        --n-ue "$ue_per_du" --du-base-port "$base_port" \
        > "/tmp/broker${d}_matrix.log" 2>&1 &
    sleep 2
    sudo stdbuf -oL -eL ~/dissertation/srsRAN_Project/build/apps/du/srsdu \
        -c "$du_conf" > "/tmp/du${d}_matrix.log" 2>&1 &
    sleep 5

    for local_i in $(seq 1 "$ue_per_du"); do
        local global_i=$(( (d - 1) * 4 + local_i ))
        local ue_conf
        ue_conf=$(ue_conf_path "$global_i" "$d")
        # srsue does not create its own netns - see header comment,
        # lesson 3
        sudo ip netns add "ue${global_i}" 2>/dev/null
        sudo tmux new-session -d -s "ue${global_i}" \
            "sudo ~/dissertation/srsRAN_4G/build/srsue/src/srsue $ue_conf"
    done
}

branch_attached() {
    local d=$1
    local ue_per_du=$2
    for local_i in $(seq 1 "$ue_per_du"); do
        local global_i=$(( (d - 1) * 4 + local_i ))
        if ! sudo ip netns exec "ue${global_i}" ip link show tun_srsue > /dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

restart_stack_multicu() {
    local DU_PER_GROUP=$1
    local UE_PER_DU=$2
    local N_DU_TOTAL=$((DU_PER_GROUP * 2))

    # NOTE: does not tmux kill-server (would kill the session this
    # script itself is running in if launched per the header comment)
    for i in $(seq 1 16); do
        sudo tmux kill-session -t "ue${i}" 2>/dev/null
    done
    sudo pkill -9 -f srsue
    sudo pkill -9 -f srscucp
    sudo pkill -9 -f srscuup
    sudo pkill -9 -f srsdu
    sudo pkill -9 -f zmq_broker
    for i in $(seq 1 16); do sudo ip netns delete "ue${i}" 2>/dev/null; done
    sleep 3

    # group 1: existing single-CU configs, completely unchanged
    sudo stdbuf -oL -eL ~/dissertation/srsRAN_Project/build/apps/cu_cp/srscucp \
        -c "$SCRIPT_DIR/../configs/zmq_split/cu_cp_zmq.yml" > /tmp/cucp1_matrix.log 2>&1 &
    sleep 2
    sudo stdbuf -oL -eL ~/dissertation/srsRAN_Project/build/apps/cu_up/srscuup \
        -c "$SCRIPT_DIR/../configs/zmq_split/cu_up_zmq.yml" > /tmp/cuup1_matrix.log 2>&1 &
    sleep 2

    # group 2: gnb_id 412, secondary host IP 10.53.1.3 for N2/N3
    sudo stdbuf -oL -eL ~/dissertation/srsRAN_Project/build/apps/cu_cp/srscucp \
        -c "$SCRIPT_DIR/../configs/zmq_multicu/cu_cp2_zmq.yml" > /tmp/cucp2_matrix.log 2>&1 &
    sleep 2
    sudo stdbuf -oL -eL ~/dissertation/srsRAN_Project/build/apps/cu_up/srscuup \
        -c "$SCRIPT_DIR/../configs/zmq_multicu/cu_up2_zmq.yml" > /tmp/cuup2_matrix.log 2>&1 &
    sleep 2

    for d in $(seq 1 "$N_DU_TOTAL"); do
        local g
        g=$(group_for_du "$d" "$DU_PER_GROUP")
        local ok=0
        for attempt in $(seq 1 "$BRANCH_MAX_RETRIES"); do
            start_branch_multicu "$d" "$UE_PER_DU" "$g"

            local waited=0
            while [ "$waited" -lt "$BRANCH_ATTACH_TIMEOUT" ]; do
                if branch_attached "$d" "$UE_PER_DU"; then
                    ok=1
                    break
                fi
                sleep 2
                waited=$((waited + 2))
            done

            if [ "$ok" -eq 1 ]; then
                break
            fi

            echo "  DU${d} (group ${g}) attempt ${attempt}/${BRANCH_MAX_RETRIES} failed to attach, retrying..."
            kill_branch_multicu "$d" "$UE_PER_DU" "$g"
            sleep 2
        done

        if [ "$ok" -ne 1 ]; then
            echo "  WARNING: DU${d} (group ${g}) never attached after ${BRANCH_MAX_RETRIES} attempts"
        fi
    done

    sudo iptables -I FORWARD -j ACCEPT 2>/dev/null
    sudo iptables -I DOCKER-USER -j ACCEPT 2>/dev/null

    # default route is known to disappear unpredictably - re-check/add
    # for every UE regardless of whether branch_attached already saw
    # tun_srsue exist (the route itself is the fragile part, not just
    # the interface)
    for d in $(seq 1 "$N_DU_TOTAL"); do
        for local_i in $(seq 1 "$UE_PER_DU"); do
            local global_i=$(( (d - 1) * 4 + local_i ))
            sudo ip netns add "ue${global_i}" 2>/dev/null
            local waited=0
            while [ "$waited" -lt 300 ]; do
                if sudo ip netns exec "ue${global_i}" ip link show tun_srsue > /dev/null 2>&1; then
                    sudo ip netns exec "ue${global_i}" ip route add default dev tun_srsue 2>/dev/null
                    break
                fi
                sleep 2
                waited=$((waited + 2))
            done
            if [ "$waited" -ge 300 ]; then
                echo "  WARNING: ue${global_i} never got a tun_srsue interface - giving up on this UE for this run"
            fi
        done
    done
}

verify_attach() {
    local N_DU=$1
    local UE_PER_DU=$2
    local attached=0
    local total=$((N_DU * UE_PER_DU))
    for d in $(seq 1 "$N_DU"); do
        for local_i in $(seq 1 "$UE_PER_DU"); do
            local global_i=$(( (d - 1) * 4 + local_i ))
            if sudo ip netns exec "ue${global_i}" ip a 2>/dev/null | grep -q "inet 10.45"; then
                attached=$((attached + 1))
            fi
        done
    done
    echo "$attached/$total"
}

run_one_multicu() {
    local DU_PER_GROUP=$1
    local UE_PER_DU=$2
    local RUN=$3
    local N_DU_TOTAL=$((DU_PER_GROUP * 2))
    local OUTFILE="${LOGDIR}/zmq_power_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN}.csv"
    local MAX_STACK_RETRIES=2

    if [ -f "$OUTFILE" ]; then
        echo "  Already exists, skipping: $(basename "$OUTFILE")"
        return
    fi

    local total=$((N_DU_TOTAL * UE_PER_DU))
    local attached_count=0

    for stack_attempt in $(seq 1 "$MAX_STACK_RETRIES"); do
        restart_stack_multicu "$DU_PER_GROUP" "$UE_PER_DU"

        local attach_status
        attach_status=$(verify_attach "$N_DU_TOTAL" "$UE_PER_DU")
        echo "  Attached: $attach_status UEs (stack attempt $stack_attempt/$MAX_STACK_RETRIES)"
        attached_count=$(echo "$attach_status" | cut -d/ -f1)

        if [ "$attached_count" -eq "$total" ]; then
            break
        fi
        echo "  Not all UEs attached, retrying full stack restart..."
    done

    if [ "$attached_count" -ne "$total" ]; then
        echo "  ERROR: only $attached_count/$total UEs attached after $MAX_STACK_RETRIES full stack attempts."
        echo "         Skipping data collection for this run - re-run the matrix script later to retry it"
        echo "         (this combination's CSV does not exist yet, so it won't be skipped next time)."
        return
    fi

    "$BREAKDOWN_SCRIPT" "$DU_PER_GROUP" "$UE_PER_DU" "$DURATION" "$WARMUP" "$SAMPLE_INTERVAL" "$RUN"

    # collect_zmq_multicu_breakdown.sh writes its own timestamped file -
    # move the most recent one into this run's expected path for
    # matrix-style organisation
    local LATEST
    LATEST=$(ls -t "$SCRIPT_DIR/../docs/logs/zmq_multicu_breakdown_2cu${DU_PER_GROUP}du_${UE_PER_DU}ue_run${RUN}_"*.csv 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        mv "$LATEST" "$OUTFILE"
        echo "  Saved: $(basename "$OUTFILE")"
    else
        echo "  WARNING: no breakdown output found for this run"
    fi
}

TOTAL=$(( ${#DU_PER_GROUP_VALUES[@]} * ${#UE_PER_DU_VALUES[@]} * RUNS ))
COUNT=0

echo "=== srsRAN Multi-CU ZMQ Power + Throughput Matrix Experiment ==="
echo "DU-per-group values: ${DU_PER_GROUP_VALUES[*]}"
echo "UE-per-DU values: ${UE_PER_DU_VALUES[*]}"
echo "Runs per configuration: $RUNS"
echo "Total experiments: $TOTAL"
echo "Estimated time: $(( TOTAL * (WARMUP + 3 * DURATION) / 3600 ))h $(( (TOTAL * (WARMUP + 3 * DURATION) % 3600) / 60 ))m"
echo "(each run = warmup + idle + DL + UL phases, each $DURATION s)"
echo "Output dir: $LOGDIR"
echo "=================================================================="
echo ""

preflight_check

for DU_PER_GROUP in "${DU_PER_GROUP_VALUES[@]}"; do
    for UE_PER_DU in "${UE_PER_DU_VALUES[@]}"; do
        for RUN in $(seq 1 "$RUNS"); do
            COUNT=$((COUNT + 1))
            echo ""
            echo "[$COUNT/$TOTAL] 2CUx${DU_PER_GROUP}DU | UE/DU=$UE_PER_DU | Run=$RUN"
            run_one_multicu "$DU_PER_GROUP" "$UE_PER_DU" "$RUN"
        done
    done
done

echo ""
echo "=== All experiments complete! ==="
