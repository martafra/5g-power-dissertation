#!/bin/bash
# Generate duN_zmq.yml configs for a 1CU-NDU ZMQ topology, for N=2..N_DU.
# DU1 is the existing du_zmq.yml in configs/zmq_split/ and is left
# untouched - it implicitly uses gnb_du_id=0, sector_id=0, pci=1,
# bind_addr=127.0.10.2, RF ports 2000/2001 (the broker's default base
# port, no --du-base-port flag needed for it).
#
# For DU index d (2..N_DU):
#   gnb_du_id          = d-1   (must be unique per DU, was the actual
#                                cause of today's F1SetupFailure when
#                                left unset on two DUs at once)
#   sector_id          = d-1   (must also be unique - feeds into the
#                                NR Cell Identity together with gnb_id,
#                                so a duplicate here causes the same
#                                F1SetupFailure even with distinct pci)
#   pci                = d
#   f1ap/f1u bind_addr = 127.0.10.(d+1)
#   RF base port       = (d-1)*10000   (tx=base, rx=base+1)
#
# Re-running this is idempotent: regenerating du2_zmq.yml with n_du>=2
# reproduces exactly the file validated in the 1CU-2DU session.
#
# Usage: ./generate_multidu_confs.sh <output_dir> [n_du]
# Example: ./generate_multidu_confs.sh ../configs/zmq_multidu 4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$1"
N_DU=${2:-4}

if [ -z "$OUTPUT_DIR" ]; then
  echo "usage: $0 <output_dir> [n_du]"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

for d in $(seq 2 "$N_DU"); do
    GNB_DU_ID=$((d - 1))
    SECTOR_ID=$((d - 1))
    PCI=$d
    BIND_ADDR="127.0.10.$((d + 1))"
    BASE_PORT=$(( (d - 1) * 10000 ))
    TX_PORT=$BASE_PORT
    RX_PORT=$((BASE_PORT + 1))
    OUTFILE="$OUTPUT_DIR/du${d}_zmq.yml"

    cat > "$OUTFILE" << EOF
gnb_du_id: ${GNB_DU_ID}

f1ap:
  cu_cp_addr: 127.0.10.1
  bind_addr: ${BIND_ADDR}
f1u:
  socket:
    -
      bind_addr: ${BIND_ADDR}

ru_sdr:
  device_driver: zmq
  device_args: tx_port=tcp://127.0.0.1:${TX_PORT},rx_port=tcp://127.0.0.1:${RX_PORT},base_srate=11.52e6
  srate: 11.52
  tx_gain: 75
  rx_gain: 75

cell_cfg:
  dl_arfcn: 368500
  band: 3
  channel_bandwidth_MHz: 10
  common_scs: 15
  plmn: "00101"
  tac: 7
  pci: ${PCI}
  sector_id: ${SECTOR_ID}
  pdcch:
    common:
      ss0_index: 0
      coreset0_index: 6
    dedicated:
      ss2_type: common
      dci_format_0_1_and_1_1: false
  prach:
    prach_config_index: 1
  pdsch:
    mcs_table: qam64
  pusch:
    mcs_table: qam64

log:
  filename: /tmp/du${d}_zmq.log
  all_level: info
EOF

    echo "wrote $OUTFILE (gnb_du_id=$GNB_DU_ID sector_id=$SECTOR_ID pci=$PCI bind_addr=$BIND_ADDR ports=$TX_PORT/$RX_PORT)"
done

echo ""
echo "Done. DU1 (du_zmq.yml in zmq_split/) is unchanged - implicitly"
echo "gnb_du_id=0, sector_id=0, pci=1, bind_addr=127.0.10.2, ports=2000/2001."
echo ""
echo "Broker base ports to use with zmq_broker.py --du-base-port:"
echo "  DU1: 2000 (default, multi_ue_nue.py, no flag needed)"
for d in $(seq 2 "$N_DU"); do
    BASE_PORT=$(( (d - 1) * 10000 ))
    echo "  DU${d}: ${BASE_PORT}"
done
