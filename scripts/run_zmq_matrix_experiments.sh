#!/bin/bash
# Full ZMQ experiment matrix: UE count x runs, for 1CU-1DU only (the only
# topology validated for ZMQ multi-UE so far - see lab notebook 2026-06-20
# for the 4-UE stability limit). Mirrors the structure of
# run_matrix_experiments.sh (ru_dummy version), with idle/DL/UL power and
# throughput collected via collect_zmq_breakdown.sh for each run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="$SCRIPT_DIR/../docs/logs/zmq_matrix"
BREAKDOWN_SCRIPT="$SCRIPT_DIR/collect_zmq_breakdown.sh"
DURATION=300
WARMUP=60
SAMPLE_INTERVAL=5
RUNS=5

UE_VALUES=(1 4)

mkdir -p "$LOGDIR"

preflight_check() {
    local failed=0

    echo "=== Pre-flight check ==="

    # 1. host-level MASQUERADE rule (does not survive a node reboot)
    if sudo iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "10.45.0.0/16"; then
        echo "  [OK] MASQUERADE rule for 10.45.0.0/16 present"
    else
        echo "  [FAIL] MASQUERADE rule for 10.45.0.0/16 missing on the host."
        echo "         Without it, UL/DL traffic to/from UEs will silently fail"
        echo "         (100% packet loss, see lab notebook 2026-06-17/18)."
        echo "         Fix: sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o enp1s0f0np0 -j MASQUERADE"
        failed=1
    fi

    # 2. core containers must already be up and healthy
    for c in open5gs_5gc prometheus scaphandre; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${c} .*Up"; then
            echo "  [OK] container $c is up"
        else
            echo "  [FAIL] container $c is not running."
            echo "         Fix: check 'docker ps -a' and restart the core stack manually."
            failed=1
        fi
    done

    # 3. subscriber DB must have at least UE1's APN fixed (internet, not srsapn)
    local apn_check
    apn_check=$(docker exec open5gs_5gc mongosh open5gs --quiet --eval \
        'db.subscribers.findOne({imsi: "001010123456780"}, {"slice.session.name":1})' 2>/dev/null)
    if echo "$apn_check" | grep -q "internet"; then
        echo "  [OK] subscriber 001010123456780 has APN 'internet'"
    else
        echo "  [FAIL] subscriber 001010123456780 does not have APN 'internet' set."
        echo "         See lab notebook 2026-06-18, Fix 1, for the mongosh command to correct this."
        failed=1
    fi

    # 4. no stale srsue/srscucp/srscuup/srsdu/broker processes or held ports
    local stale
    stale=$(pgrep -f "srsue|srscucp|srscuup|srsdu|multi_ue" 2>/dev/null)
    if [ -n "$stale" ]; then
        echo "  [FAIL] stale srsRAN/broker processes already running (PIDs: $(echo "$stale" | tr '\n' ' '))."
        echo "         These will conflict with the ports this script needs to bind."
        echo "         Fix: sudo pkill -9 -f srsue; sudo pkill -9 -f srscucp; sudo pkill -9 -f srscuup;"
        echo "              sudo pkill -9 -f srsdu; sudo pkill -9 -f multi_ue; sudo tmux kill-server"
        failed=1
    else
        echo "  [OK] no stale srsRAN/broker processes"
    fi

    local held_ports
    held_ports=$(sudo lsof -i :2000 -i :2001 -i :2100 -i :2101 -i :2200 -i :2201 -i :2300 -i :2301 -i :2400 -i :2401 2>/dev/null)
    if [ -n "$held_ports" ]; then
        echo "  [FAIL] one or more ZMQ ports already held:"
        echo "$held_ports" | tail -n +2 | sed 's/^/         /'
        failed=1
    else
        echo "  [OK] all ZMQ ports (2000-2401) free"
    fi

    # 5. required binaries exist
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

    # 6. iperf3 available, both on host and inside the Open5GS container
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

    echo "========================="
    if [ "$failed" -ne 0 ]; then
        echo "Pre-flight check FAILED. Refusing to start an unattended multi-hour run"
        echo "on an environment that is not ready - fix the items above and re-run."
        exit 1
    fi
    echo "Pre-flight check passed. Proceeding with the experiment matrix."
    echo ""
}

restart_stack() {
    local NUE=$1

    # NOTE: do not use 'tmux kill-server' here - if this script itself is
    # running inside a tmux session (e.g. for unattended overnight runs),
    # kill-server would terminate that session too, killing this script.
    # Kill only the UE sessions we know about instead.
    for i in $(seq 1 16); do
        sudo tmux kill-session -t "ue${i}" 2>/dev/null
    done
    sudo pkill -9 -f srsue
    sudo pkill -9 -f srscucp
    sudo pkill -9 -f srscuup
    sudo pkill -9 -f srsdu
    sudo pkill -9 -f multi_ue
    sleep 3

    # NOTE: there is no working direct-connect (no-broker) UE conf in this
    # environment - the only available single-UE conf (ue_zmq.conf) uses
    # the same broker-facing ports (2101/2100) as the multi-UE confs, not
    # the DU's native ports (2000/2001). So even NUE=1 needs the broker,
    # using the generalised multi_ue_nue.py with --n-ue 1.
    xvfb-run -a python3 "$SCRIPT_DIR/../configs/zmq/multiue_official/multi_ue_nue.py" --n-ue "$NUE" &
    sleep 5

    sudo ~/dissertation/srsRAN_Project/build/apps/cu_cp/srscucp \
        -c "$SCRIPT_DIR/../configs/zmq_split/cu_cp_zmq.yml" \
        > /tmp/cucp_matrix.log 2>&1 &
    sleep 2
    sudo ~/dissertation/srsRAN_Project/build/apps/cu_up/srscuup \
        -c "$SCRIPT_DIR/../configs/zmq_split/cu_up_zmq.yml" \
        > /tmp/cuup_matrix.log 2>&1 &
    sleep 2

    sudo ~/dissertation/srsRAN_Project/build/apps/du/srsdu \
        -c "$SCRIPT_DIR/../configs/zmq_split/du_zmq.yml" \
        > /tmp/du_matrix.log 2>&1 &
    sleep 10

    for i in $(seq 1 "$NUE"); do
        local CONF="$SCRIPT_DIR/../configs/zmq/multiue_official/ue${i}_zmq.conf"
        sudo tmux new-session -d -s "ue${i}" \
            "sudo ~/dissertation/srsRAN_4G/build/srsue/src/srsue $CONF"
    done

    echo "  Waiting for attach (this can take a while - see lab notebook for known timing)..."
    sleep 30

    sudo iptables -I FORWARD -j ACCEPT 2>/dev/null
    sudo iptables -I DOCKER-USER -j ACCEPT 2>/dev/null
    for i in $(seq 1 "$NUE"); do
        sudo ip netns add "ue${i}" 2>/dev/null
    done

    # the route add only works once tun_srsue actually exists inside the
    # namespace (i.e. once PDU Session Establishment has completed) - a
    # single attempt right after a fixed sleep can silently fail if attach
    # is still in progress, leaving the UE with no default route for the
    # rest of the run even after it does attach. Retry with a generous
    # wait (up to 5 minutes per UE) since 4-UE attach timing has been
    # observed to vary significantly (PRACH processed one UE at a time,
    # roughly every 16s - see lab notebook 2026-06-20).
    for i in $(seq 1 "$NUE"); do
        local waited=0
        local max_wait=300
        while [ "$waited" -lt "$max_wait" ]; do
            if sudo ip netns exec "ue${i}" ip link show tun_srsue > /dev/null 2>&1; then
                sudo ip netns exec "ue${i}" ip route add default dev tun_srsue 2>/dev/null
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done
        if [ "$waited" -ge "$max_wait" ]; then
            echo "  WARNING: ue${i} never got a tun_srsue interface after ${max_wait}s - giving up on this UE for this run"
        fi
    done
}

verify_attach() {
    local NUE=$1
    local attached=0
    for i in $(seq 1 "$NUE"); do
        if sudo ip netns exec "ue${i}" ip a 2>/dev/null | grep -q "inet 10.45"; then
            attached=$((attached + 1))
        fi
    done
    echo "$attached"
}

run_one() {
    local NUE=$1
    local RUN=$2
    local OUTFILE="${LOGDIR}/zmq_power_${NUE}ue_run${RUN}.csv"

    if [ -f "$OUTFILE" ]; then
        echo "  Already exists, skipping: $(basename "$OUTFILE")"
        return
    fi

    restart_stack "$NUE"

    local n_attached
    n_attached=$(verify_attach "$NUE")
    echo "  Attached: $n_attached / $NUE UEs"
    if [ "$n_attached" -lt "$NUE" ]; then
        echo "  WARNING: not all UEs attached, results may be incomplete or this run should be discarded"
    fi

    "$BREAKDOWN_SCRIPT" "$NUE" "$DURATION" "$WARMUP" "$SAMPLE_INTERVAL" "$RUN"

    # collect_zmq_breakdown.sh writes its own timestamped file under
    # docs/logs/ - move the most recent one into this run's expected path
    # for matrix-style organisation
    local LATEST
    LATEST=$(ls -t "$SCRIPT_DIR/../docs/logs/zmq_breakdown_${NUE}ue_"*.csv 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        mv "$LATEST" "$OUTFILE"
        echo "  Saved: $(basename "$OUTFILE")"
    else
        echo "  WARNING: no breakdown output found for this run"
    fi
}

TOTAL=$(( ${#UE_VALUES[@]} * RUNS ))
COUNT=0

echo "=== srsRAN ZMQ Power + Throughput Matrix Experiment ==="
echo "Topology: 1CU-1DU (only validated ZMQ multi-UE topology so far)"
echo "UE values: ${UE_VALUES[*]}"
echo "Runs per configuration: $RUNS"
echo "Total experiments: $TOTAL"
echo "Estimated time: $(( TOTAL * (WARMUP + 3 * DURATION) / 3600 ))h $(( (TOTAL * (WARMUP + 3 * DURATION) % 3600) / 60 ))m"
echo "(each run = warmup + idle + DL + UL phases, each $DURATION s)"
echo "Output dir: $LOGDIR"
echo "========================================================="
echo ""

preflight_check

for NUE in "${UE_VALUES[@]}"; do
    for RUN in $(seq 1 "$RUNS"); do
        COUNT=$((COUNT + 1))
        echo ""
        echo "[$COUNT/$TOTAL] 1CU-1DU | UEs=$NUE | Run=$RUN"
        run_one "$NUE" "$RUN"
    done
done

echo ""
echo "=== All experiments complete! ==="
echo ""
echo "=== SUMMARY ==="
for NUE in "${UE_VALUES[@]}"; do
    echo "${NUE} UE:"
    python3 - << PYEOF
import csv, glob, numpy as np
from collections import defaultdict
files = glob.glob("${LOGDIR}/zmq_power_${NUE}ue_run*.csv")
data = defaultdict(list)
for f in files:
    with open(f) as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            data[(row['phase'], row['component'])].append(float(row['watts']))
for (phase, comp), vals in sorted(data.items()):
    if vals:
        print(f"  {phase:6s} {comp:8s}: mean={np.mean(vals):.3f}W std={np.std(vals):.3f}W n={len(vals)}")
PYEOF
done
