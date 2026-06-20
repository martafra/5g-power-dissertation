#!/bin/bash
# generates 16 srsue ZMQ conf files matching multi_ue_nue.py's port scheme
# and the 16 subscribers already present in the Open5GS DB (...780-...795)

set -e

TEMPLATE="$1"
OUTPUT_DIR="$2"

if [ -z "$TEMPLATE" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "usage: $0 <template_conf> <output_dir>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# base imsi suffix for subscriber 1 is 780, incrementing by 1 per UE
BASE_IMSI_SUFFIX=780

for i in $(seq 1 16); do
  imsi_suffix=$((BASE_IMSI_SUFFIX + i - 1))
  imsi="001010123456${imsi_suffix}"
  tx_port=$((2000 + i * 100 + 1))
  rx_port=$((2000 + i * 100))
  path_loss=$(( (i - 1) * 2 ))

  out_file="$OUTPUT_DIR/ue${i}_zmq.conf"

  sed \
    -e "s/imsi = [0-9]*/imsi = ${imsi}/" \
    -e "s|device_args = tx_port=tcp://127.0.0.1:[0-9]*,rx_port=tcp://127.0.0.1:[0-9]*,base_srate=11.52e6|device_args = tx_port=tcp://127.0.0.1:${tx_port},rx_port=tcp://127.0.0.1:${rx_port},base_srate=11.52e6|" \
    -e "s/netns = ue[0-9]*/netns = ue${i}/" \
    -e "s|mac_filename = /tmp/ue[0-9]*_mac\.pcap|mac_filename = /tmp/ue${i}_mac.pcap|" \
    -e "s|mac_nr_filename = /tmp/ue[0-9]*_mac_nr\.pcap|mac_nr_filename = /tmp/ue${i}_mac_nr.pcap|" \
    -e "s|nas_filename = /tmp/ue[0-9]*_nas\.pcap|nas_filename = /tmp/ue${i}_nas.pcap|" \
    -e "s|filename = /tmp/ue[0-9]*\.log|filename = /tmp/ue${i}.log|" \
    "$TEMPLATE" > "$out_file"

  echo "generated $out_file: imsi=$imsi tx=$tx_port rx=$rx_port (suggested path loss: ${path_loss}dB)"
done

echo ""
echo "done. 16 conf files written to $OUTPUT_DIR"
echo "note: path loss is applied by the broker (multi_ue_nue.py --path-loss), not in the conf files"
