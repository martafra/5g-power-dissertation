#!/bin/bash
# Generates srsue ZMQ conf files for a 1CU-NDU topology, up to 4 UEs
# per DU, extending generate_16ue_confs.sh's templating approach (same
# sed substitutions) across multiple DUs instead of a single one.
#
# Global UE numbering reserves 4 slots per DU regardless of how many
# are actually used in a given experiment run, so IMSI/netns stay
# stable across different UE-per-DU test levels (matches the existing
# DU1=UE1-4, DU2=UE5-8 pattern from today's session):
#   DU1 -> UE1-4   (IMSI suffix 780-783)
#   DU2 -> UE5-8   (IMSI suffix 784-787)
#   DU3 -> UE9-12  (IMSI suffix 788-791)
#   DU4 -> UE13-16 (IMSI suffix 792-795)
#
# Ports are LOCAL to each DU's own broker (local UE index 1..4 within
# that DU), not global - e.g. DU3's first UE (global index 9) still
# uses local index 1 for its port formula against DU3's own base port,
# exactly like UE5 (global index 5, local index 1 within DU2) today.
#   tx_port = du_base_port + local_i*100 + 1
#   rx_port = du_base_port + local_i*100
# where du_base_port follows generate_multidu_confs.sh's scheme:
#   DU1=2000 (broker default) DU2=10000 DU3=20000 DU4=30000
#
# Usage: ./generate_multidu_ue_confs.sh <template_conf> <output_dir> [n_du] [ue_per_du] [start_du]
# Example: ./generate_multidu_ue_confs.sh ue5_zmq.conf ../configs/zmq_multidu 4 4 2

set -e

TEMPLATE="$1"
OUTPUT_DIR="$2"
N_DU=${3:-4}
UE_PER_DU=${4:-4}
START_DU=${5:-1}

if [ -z "$TEMPLATE" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "usage: $0 <template_conf> <output_dir> [n_du] [ue_per_du] [start_du]"
  echo "  start_du defaults to 1; pass 2 to skip DU1 (e.g. when DU1's"
  echo "  UE1-4 confs already exist elsewhere, as in multiue_official/)"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

BASE_IMSI_SUFFIX=780
SLOTS_PER_DU=4   # reserved IMSI/netns slots per DU, independent of ue_per_du

for d in $(seq "$START_DU" "$N_DU"); do
    if [ "$d" -eq 1 ]; then
        du_base_port=2000
    else
        du_base_port=$(( (d - 1) * 10000 ))
    fi

    for local_i in $(seq 1 "$UE_PER_DU"); do
        global_i=$(( (d - 1) * SLOTS_PER_DU + local_i ))
        imsi_suffix=$((BASE_IMSI_SUFFIX + global_i - 1))
        imsi="001010123456${imsi_suffix}"
        tx_port=$((du_base_port + local_i * 100 + 1))
        rx_port=$((du_base_port + local_i * 100))

        out_file="$OUTPUT_DIR/ue${global_i}_zmq.conf"

        sed \
            -e "s/imsi = [0-9]*/imsi = ${imsi}/" \
            -e "s|device_args = tx_port=tcp://127.0.0.1:[0-9]*,rx_port=tcp://127.0.0.1:[0-9]*,base_srate=11.52e6|device_args = tx_port=tcp://127.0.0.1:${tx_port},rx_port=tcp://127.0.0.1:${rx_port},base_srate=11.52e6|" \
            -e "s/netns = ue[0-9]*/netns = ue${global_i}/" \
            -e "s|mac_filename = /tmp/ue[0-9]*_mac\.pcap|mac_filename = /tmp/ue${global_i}_mac.pcap|" \
            -e "s|mac_nr_filename = /tmp/ue[0-9]*_mac_nr\.pcap|mac_nr_filename = /tmp/ue${global_i}_mac_nr.pcap|" \
            -e "s|nas_filename = /tmp/ue[0-9]*_nas\.pcap|nas_filename = /tmp/ue${global_i}_nas.pcap|" \
            -e "s|filename = /tmp/ue[0-9]*\.log|filename = /tmp/ue${global_i}.log|" \
            "$TEMPLATE" > "$out_file"

        echo "generated $out_file: du=${d} local_ue=${local_i} global_ue=${global_i} imsi=$imsi tx=$tx_port rx=$rx_port"
    done
done

echo ""
echo "done. UE confs written to $OUTPUT_DIR"
echo "DU -> global UE index mapping used:"
for d in $(seq "$START_DU" "$N_DU"); do
    first=$(( (d - 1) * SLOTS_PER_DU + 1 ))
    last=$(( (d - 1) * SLOTS_PER_DU + SLOTS_PER_DU ))
    echo "  DU${d}: UE${first}-UE${last}"
done
echo ""
echo "note: path loss is applied by the broker (--path-loss), not in the conf files"
