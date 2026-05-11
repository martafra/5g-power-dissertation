#!/bin/bash
DOCKER_DIR=~/Desktop/dissertation/srsRAN_Project/docker
CONFIGS=~/Desktop/dissertation/srsRAN_Project/configs
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.split.yml -f docker-compose.ui.yml"
LOGDIR=~/Desktop/dissertation/docs/logs
PROM="http://localhost:9090"
DURATION=300
WARMUP=60
SAMPLE_INTERVAL=10
RUNS=5

cd $DOCKER_DIR

truncate_du_logs() {
  sudo truncate -s 0 /mnt/hdd/docker/rootfs/overlayfs/*/tmp/du*.log 2>/dev/null || true
}

get_du_power() {
  # Campiona potenza istantanea e restituisce solo valori DU (>1W)
  curl -s "${PROM}/api/v1/query?query=scaph_process_power_consumption_microwatts%7Bexe%3D~%22.*(srsdu%7Crunc).*%22%2Ccmdline%3D~%22.*(srsdu%7Cruncinit).*%22%7D" | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
vals=[float(r['value'][1])/1e6 for r in d['data']['result'] if float(r['value'][1])/1e6 > 1.0]
print(sum(vals))
" 2>/dev/null || echo "0"
}

measure() {
  local TOPOLOGY=$1
  local NUE=$2
  local RUN=$3
  local OUTFILE="${LOGDIR}/power_${TOPOLOGY}_${NUE}ue_run${RUN}.json"

  truncate_du_logs

  echo "  Warming up ${WARMUP}s..."
  sleep $WARMUP

  echo "  Sampling every ${SAMPLE_INTERVAL}s for ${DURATION}s..."
  local SAMPLES=()
  local N_SAMPLES=$((DURATION / SAMPLE_INTERVAL))
  
  for i in $(seq 1 $N_SAMPLES); do
    SAMPLE=$(get_du_power)
    SAMPLES+=($SAMPLE)
    echo "    Sample $i/$N_SAMPLES: ${SAMPLE}W"
    if [ $i -lt $N_SAMPLES ]; then
      sleep $SAMPLE_INTERVAL
    fi
  done

  # Salva risultati e calcola media/std
  python3 - << PYEOF > "$OUTFILE"
import json, numpy as np
samples = [$(IFS=,; echo "${SAMPLES[*]}")]
# Filtra campioni a 0 (DU non ancora visibile)
valid = [s for s in samples if s > 1.0]
result = {
    "topology": "$TOPOLOGY",
    "nof_ues": $NUE,
    "run": $RUN,
    "samples": samples,
    "valid_samples": valid,
    "mean_W": np.mean(valid) if valid else 0,
    "std_W": np.std(valid) if valid else 0,
    "n": len(valid)
}
print(json.dumps(result, indent=2))
PYEOF

  echo "  Results:"
  cat "$OUTFILE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'  mean={d[\"mean_W\"]:.3f}W std={d[\"std_W\"]:.3f}W n={d[\"n\"]}')
"
}

set_du2_rnti() {
  local NUE=$1
  local RNTI=$(python3 -c "print(hex(0x44 + $NUE))")
  sed -i "s/rnti: .*/rnti: ${RNTI}/" $CONFIGS/testmode2.yml
}

for RUN in $(seq 1 $RUNS); do
  echo ""
  echo "######################################"
  echo "RUN $RUN / $RUNS"
  echo "######################################"

  for NUE in 1 2 4 8 16 64 96; do
    echo ""
    echo "=== 1CU-1DU: ${NUE} UE (run ${RUN}) ==="
    sed -i "s/nof_ues: .*/nof_ues: ${NUE}/" $CONFIGS/testmode.yml
    docker stop srsran_du2 2>/dev/null
    $COMPOSE up -d --force-recreate du 2>/dev/null
    measure "1cu1du" $NUE $RUN
  done

  for NUE in 1 2 4 8 16 64 96; do
    echo ""
    echo "=== 1CU-2DU: ${NUE} UE/DU (run ${RUN}) ==="
    sed -i "s/nof_ues: .*/nof_ues: ${NUE}/" $CONFIGS/testmode.yml
    sed -i "s/nof_ues: .*/nof_ues: ${NUE}/" $CONFIGS/testmode2.yml
    set_du2_rnti $NUE
    $COMPOSE up -d --force-recreate du du2 2>/dev/null
    measure "1cu2du" $NUE $RUN
  done
done

echo ""
echo "=== All experiments done! ==="

echo ""
echo "=== SUMMARY ==="
for TOPOLOGY in 1cu1du 1cu2du; do
  for NUE in 1 2 4 8 16 64 96; do
    echo -n "${TOPOLOGY} ${NUE}UE: "
    python3 - << PYEOF
import json, glob, numpy as np
files = glob.glob("${LOGDIR}/power_${TOPOLOGY}_${NUE}ue_run*.json")
means = []
for f in sorted(files):
    d = json.load(open(f))
    if d['mean_W'] > 0:
        means.append(d['mean_W'])
if means:
    print(f"mean={np.mean(means):.3f}W std={np.std(means):.3f}W runs={len(means)}")
else:
    print("no data")
PYEOF
  done
done
