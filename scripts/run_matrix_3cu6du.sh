#!/bin/bash
# Matrix experiments for 3CU-6DU topology (balanced 2+2+2)
# CUs: main (du,du2) + b (du-b,du-b2) + c (du-c,du-c2)
# Results saved as JSON in docs/logs/matrix/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../srsRAN_Project/docker"
CONFIGS="$SCRIPT_DIR/../srsRAN_Project/configs"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.split.yml -f docker-compose.ui.yml"
LOGDIR="$SCRIPT_DIR/../docs/logs/matrix"
PROM="http://localhost:9090"
DURATION=300
WARMUP=60
SAMPLE_INTERVAL=10
RUNS=5

CQI_VALUES=(5 10 15)
UE_VALUES=(1 4 16 64 96)

mkdir -p "$LOGDIR"
cd "$DOCKER_DIR"

truncate_du_logs() {
  sudo truncate -s 0 /mnt/hdd/docker/rootfs/overlayfs/*/tmp/du*.log 2>/dev/null || true
}

get_du_power() {
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
  local CQI=$3
  local RUN=$4
  local OUTFILE="${LOGDIR}/power_${TOPOLOGY}_cqi${CQI}_${NUE}ue_run${RUN}.json"

  if [ -f "$OUTFILE" ]; then
    echo "  Already exists, skipping: $(basename $OUTFILE)"
    return
  fi

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

  python3 - << PYEOF > "$OUTFILE"
import json, numpy as np
samples = [$(IFS=,; echo "${SAMPLES[*]}")]
valid = [s for s in samples if s > 1.0]
result = {
    "topology": "$TOPOLOGY",
    "nof_ues": $NUE,
    "cqi": $CQI,
    "run": $RUN,
    "samples": samples,
    "valid_samples": valid,
    "mean_W": np.mean(valid) if valid else 0,
    "std_W": np.std(valid) if valid else 0,
    "n": len(valid)
}
print(json.dumps(result, indent=2))
PYEOF

  echo "  Saved: $(basename $OUTFILE)"
  python3 -c "
import json
d=json.load(open('$OUTFILE'))
print(f'  mean={d[\"mean_W\"]:.3f}W std={d[\"std_W\"]:.3f}W n={d[\"n\"]}')
"
}

# Writes all six testmode files, one per DU, with distinct RNTI bases
# spaced by at least 0x60 (96) so UE ranges never overlap at nof_ues=96.
set_testmode() {
  local NUE=$1
  local CQI=$2
  local BASES=(0x44 0xa4 0x166 0x288 0x400 0x460)
  local FILES=(testmode testmode2 testmode_b testmode_b2 testmode_c testmode_c2)
  for idx in "${!FILES[@]}"; do
    cat > "$CONFIGS/${FILES[$idx]}.yml" << TMEOF
test_mode:
  test_ue:
    rnti: ${BASES[$idx]}
    ri: 1
    cqi: $CQI
    nof_ues: $NUE
    pusch_active: true
    pdsch_active: true
TMEOF
  done
}

TOTAL=$(( ${#CQI_VALUES[@]} * ${#UE_VALUES[@]} * RUNS ))
COUNT=0

echo "=== srsRAN Power Matrix Experiment: 3CU-6DU (2+2+2) ==="
echo "UE values:  ${UE_VALUES[*]}"
echo "CQI values: ${CQI_VALUES[*]}"
echo "Runs: $RUNS"
echo "Total experiments: $TOTAL"
echo "Estimated time: $(( TOTAL * (WARMUP + DURATION) / 3600 ))h $(( (TOTAL * (WARMUP + DURATION) % 3600) / 60 ))m"
echo "Output dir: $LOGDIR"
echo "=================================================="

for CQI in "${CQI_VALUES[@]}"; do
  for NUE in "${UE_VALUES[@]}"; do
    for RUN in $(seq 1 $RUNS); do

      COUNT=$((COUNT + 1))
      echo ""
      echo "[$COUNT/$TOTAL] 3CU-6DU | CQI=$CQI | UEs=$NUE | Run=$RUN"
      set_testmode $NUE $CQI
      docker stop srsran_du srsran_du2 srsran_du_b srsran_du_b2 srsran_du_c srsran_du_c2 2>/dev/null
      docker rm   srsran_du srsran_du2 srsran_du_b srsran_du_b2 srsran_du_c srsran_du_c2 2>/dev/null
      $COMPOSE up -d du du2 du-b du-b2 du-c du-c2 2>/dev/null
      sleep 10
      measure "3cu6du" $NUE $CQI $RUN

    done
  done
done

echo ""
echo "=== All experiments complete! ==="
echo ""
echo "=== SUMMARY ==="
for CQI in "${CQI_VALUES[@]}"; do
  for NUE in "${UE_VALUES[@]}"; do
    echo -n "3cu6du CQI=${CQI} ${NUE}UE: "
    python3 - << PYEOF
import json, glob, numpy as np
files = glob.glob("${LOGDIR}/power_3cu6du_cqi${CQI}_${NUE}ue_run*.json")
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