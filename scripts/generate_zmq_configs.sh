#!/bin/bash
# generate_zmq_configs.sh - generates srsUE configs and GNU Radio broker for N UEs
# usage: ./generate_zmq_configs.sh <n_ues>

set -uo pipefail

N=${1:-2}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../configs/zmq"
BASE_IMSI="001010123456780"
BASE_DL_PORT=2100
BASE_UL_PORT=2101
BASE_IP="10.45.1"

mkdir -p "$CONFIG_DIR"

echo "generating configs for $N UE(s)..."

# generate srsUE config for each UE
for i in $(seq 1 "$N"); do
    IMSI=$(printf "%015d" $((10001012345678 + i - 1)))
    # fix: use python to avoid bash arithmetic overflow
    IMSI=$(python3 -c "print(str(1010123456780 + $i - 1).zfill(15))")
    DL_PORT=$((BASE_DL_PORT + (i - 1) * 10))
    UL_PORT=$((BASE_UL_PORT + (i - 1) * 10))
    NETNS="ue$i"
    OUTFILE="$CONFIG_DIR/ue${i}_zmq.conf"

    cat > "$OUTFILE" << UEOF
[rf]
freq_offset = 0
tx_gain = 80
rx_gain = 40
srate = 11.52e6
nof_antennas = 1

device_name = zmq
device_args = tx_port=tcp://127.0.0.1:${UL_PORT},rx_port=tcp://127.0.0.1:${DL_PORT},base_srate=11.52e6

[rat.eutra]
dl_earfcn = 2850
nof_carriers = 0

[rat.nr]
bands = 3
nof_carriers = 1
dl_nr_arfcn = 368500

[usim]
mode = soft
algo = milenage
opc  = 63BFA50EE6523365FF14C1F45F88737D
k    = 00112233445566778899AABBCCDDEEFF
imsi = ${IMSI}
imei = 35349006987331${i}

[rrc]
release = 15
ue_category = 4

[nas]
apn = internet
apn_protocol = ipv4

[gw]
netns = ${NETNS}

[log]
filename = /tmp/ue${i}_zmq.log
all_level = warning
UEOF
    echo "  generated: $OUTFILE (imsi=$IMSI dl=$DL_PORT ul=$UL_PORT netns=$NETNS)"
done

# generate GNU Radio broker
BROKER_FILE="$CONFIG_DIR/gnuradio_broker_${N}ue.py"
cat > "$BROKER_FILE" << PYEOF
#!/usr/bin/env python3
# GNU Radio ZMQ broker for ${N} UE(s)
# DL: DU tx (2000) -> UE1..N rx
# UL: UE1..N tx -> DU rx (2001) via adder

from gnuradio import gr, zeromq, blocks

class zmq_broker(gr.top_block):
    def __init__(self):
        gr.top_block.__init__(self, "ZMQ Broker ${N} UE")

        self.dl_src = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2000', 100, False, -1)
        self.ul_snk = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2001', 100, False, -1)

        self.dl_sinks = []
        self.ul_sources = []

PYEOF

    for i in $(seq 1 "$N"); do
        DL_PORT=$((BASE_DL_PORT + (i - 1) * 10))
        UL_PORT=$((BASE_UL_PORT + (i - 1) * 10))
        cat >> "$BROKER_FILE" << PYEOF
        self.dl_snk${i} = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:${DL_PORT}', 100, False, -1)
        self.ul_src${i} = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:${UL_PORT}', 100, False, -1)
        self.dl_sinks.append(self.dl_snk${i})
        self.ul_sources.append(self.ul_src${i})
PYEOF
    done

    cat >> "$BROKER_FILE" << PYEOF

        self.adder = blocks.add_cc(${N})

        for i, snk in enumerate(self.dl_sinks):
            self.connect(self.dl_src, snk)

        for i, src in enumerate(self.ul_sources):
            self.connect(src, (self.adder, i))

        self.connect(self.adder, self.ul_snk)

def main():
    tb = zmq_broker()
    tb.start()
    print("Broker running for ${N} UE(s)...")
    input("Press Enter to stop\n")
    tb.stop()
    tb.wait()

if __name__ == '__main__':
    main()
PYEOF

    chmod +x "$BROKER_FILE"
    echo "  generated: $BROKER_FILE"

# generate startup script
STARTUP_FILE="$SCRIPT_DIR/../scripts/start_zmq_${N}ue.sh"
cat > "$STARTUP_FILE" << SEOF
#!/bin/bash
# start ZMQ setup with ${N} UE(s)
# run each command in a separate terminal

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
SRSRAN_PROJECT="\$SCRIPT_DIR/../srsRAN_Project/build/apps"
SRSRAN_4G="\$SCRIPT_DIR/../srsRAN_4G/build/srsue/src"
CONFIGS="\$SCRIPT_DIR/../configs"

echo "start in separate terminals:"
echo ""
echo "1. CU-CP:"
echo "   sudo \$SRSRAN_PROJECT/cu_cp/srscucp -c \$CONFIGS/zmq_split/cu_cp_zmq.yml"
echo ""
echo "2. CU-UP:"
echo "   sudo \$SRSRAN_PROJECT/cu_up/srscuup -c \$CONFIGS/zmq_split/cu_up_zmq.yml"
echo ""
echo "3. DU:"
echo "   sudo \$SRSRAN_PROJECT/du/srsdu -c \$CONFIGS/zmq_split/du_zmq.yml"
echo ""
echo "4. GNU Radio broker:"
echo "   python3 \$CONFIGS/zmq/gnuradio_broker_${N}ue.py"
echo ""
SEOF

    for i in $(seq 1 "$N"); do
        echo "echo \"$((i + 4)). UE$i:\"" >> "$STARTUP_FILE"
        echo "echo \"   sudo \$SRSRAN_4G/srsue \$CONFIGS/zmq/ue${i}_zmq.conf\"" >> "$STARTUP_FILE"
        echo "echo \"\"" >> "$STARTUP_FILE"
    done

    cat >> "$STARTUP_FILE" << SEOF

echo "after all UEs connected, add routes:"
SEOF

    for i in $(seq 1 "$N"); do
        echo "echo \"sudo ip netns exec ue$i ip route add default via 10.45.1.1 dev tun_srsue\"" >> "$STARTUP_FILE"
    done

    chmod +x "$STARTUP_FILE"
    echo "  generated: $STARTUP_FILE"

echo "done. run: $STARTUP_FILE to see startup instructions"
