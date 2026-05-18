#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../docs/logs"
TOPOLOGY=${1:-3cu3du}
SAMPLES=${2:-60}
INTERVAL=${3:-5}
OUTPUT="$LOGS_DIR/breakdown_${TOPOLOGY}_$(date +%Y%m%d_%H%M%S).csv"
SCAPHANDRE_URL="http://10.53.1.11:8080/metrics"

mkdir -p "$LOGS_DIR"

get_pid() {
    docker inspect $1 --format '{{.State.Pid}}' 2>/dev/null || echo ""
}

CU_CP=$(get_pid srsran_cu_cp)
CU_UP=$(get_pid srsran_cu_up)
CU_CP2=$(get_pid srsran_cu_cp2)
CU_UP2=$(get_pid srsran_cu_up2)
CU_CP3=$(get_pid srsran_cu_cp3)
CU_UP3=$(get_pid srsran_cu_up3)
DU1=$(get_pid srsran_du)
DU_B=$(get_pid srsran_du_b)
DU_C=$(get_pid srsran_du_c)

echo "=== srsRAN Power Breakdown Collector ==="
echo "Topology: $TOPOLOGY"
echo "PIDs: CU-CP=$CU_CP | CU-UP=$CU_UP | CU-CP2=$CU_CP2 | CU-UP2=$CU_UP2 | CU-CP3=$CU_CP3 | CU-UP3=$CU_UP3 | DU1=$DU1 | DU_B=$DU_B | DU_C=$DU_C"
echo "Config: Samples=$SAMPLES | Interval=${INTERVAL}s | Output=$OUTPUT"
echo "Starting collection..."

echo "timestamp,component,pid,microwatts,watts" > "$OUTPUT"

for i in $(seq 1 $SAMPLES); do
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S")
    METRICS=$(curl -s $SCAPHANDRE_URL | grep "scaph_process_power")

    for ENTRY in "cu_cp:$CU_CP" "cu_up:$CU_UP" "cu_cp2:$CU_CP2" "cu_up2:$CU_UP2" "cu_cp3:$CU_CP3" "cu_up3:$CU_UP3" "du1:$DU1" "du_b:$DU_B" "du_c:$DU_C"; do
        COMP=$(echo $ENTRY | cut -d: -f1)
        PID=$(echo $ENTRY | cut -d: -f2)
        if [ -z "$PID" ]; then continue; fi
        VAL=$(echo "$METRICS" | grep "pid=\"$PID\"" | grep -oP '} \K[\d.]+' | head -1)
        if [ -n "$VAL" ]; then
            WATTS=$(python3 -c "print(f'{$VAL/1e6:.6f}')")
            echo "$TS,$COMP,$PID,$VAL,$WATTS" >> "$OUTPUT"
        fi
    done

    echo "Sample $i/$SAMPLES at $TS"
    sleep $INTERVAL
done

echo "=== Collection complete! ==="
echo "Rows saved: $(wc -l < "$OUTPUT")"
echo "Output: $OUTPUT"
echo ""
echo "=== SUMMARY ==="
python3 - << PYEOF
import csv, numpy as np
from collections import defaultdict
data = defaultdict(list)
with open('$OUTPUT') as f:
    reader = csv.DictReader(f)
    for row in reader:
        data[row['component']].append(float(row['watts']))
for comp, vals in sorted(data.items()):
    if vals:
        print(f"{comp}: mean={np.mean(vals):.3f}W std={np.std(vals):.3f}W n={len(vals)}")
PYEOF
