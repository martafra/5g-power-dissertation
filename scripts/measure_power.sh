#!/bin/bash
# Usage: ./measure_power.sh <topology> <nof_ues>
# topology: 1du or 2du
# nof_ues: number of UEs per DU

TOPOLOGY=$1
NOF_UES=$2
DURATION=60  # seconds to average over
PROM="http://localhost:9090"
LOGDIR=~/Desktop/dissertation/docs/logs

echo "=== Measuring ${TOPOLOGY} with ${NOF_UES} UE/DU ==="
echo "Waiting ${DURATION}s for stability..."
sleep $DURATION

# Query average over last 60s
QUERY="avg_over_time(scaph_process_power_consumption_microwatts{exe=~\".*(srsdu|runc).*\",cmdline=~\".*(srsdu|runcinit).*\"}[${DURATION}s])"
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$QUERY'))")

curl -s "${PROM}/api/v1/query?query=${ENCODED}" | \
  python3 -m json.tool > "${LOGDIR}/power_${TOPOLOGY}_${NOF_UES}ue.json"

echo "Results:"
cat "${LOGDIR}/power_${TOPOLOGY}_${NOF_UES}ue.json" | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
vals=[float(r['value'][1]) for r in d['data']['result']]
vals_sorted=sorted(vals, reverse=True)
print([f'{v/1e6:.3f}W' for v in vals_sorted])
"
