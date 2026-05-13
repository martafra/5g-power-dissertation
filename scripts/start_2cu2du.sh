#!/bin/bash
set -e

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.split.yml -f docker-compose.ui.yml"
TEMP_LIMIT=60

wait_temp() {
    echo "Waiting for CPU to cool below ${TEMP_LIMIT}°C..."
    while true; do
        MAX=$(sensors | grep "Core" | awk '{print $3}' | tr -d '+°C' | sort -n | tail -1)
        echo "  Current max: ${MAX}°C"
        if (( $(echo "$MAX < $TEMP_LIMIT" | bc -l) )); then
            echo "Temperature OK, proceeding..."
            break
        fi
        sleep 30
    done
}

wait_healthy() {
    local container=$1
    echo "Waiting for $container to be healthy..."
    while [ "$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null)" != "healthy" ]; do
        sleep 3
    done
    echo "$container is healthy!"
}

echo "=== Starting 2CU-2DU topology ==="

wait_temp

echo "Starting 5GC..."
$COMPOSE up -d 5gc
wait_healthy open5gs_5gc

echo "Starting CU-CP and CU-CP2..."
$COMPOSE up -d cu-cp cu-cp2
wait_healthy srsran_cu_cp
wait_healthy srsran_cu_cp2

echo "Starting CU-UP and CU-UP2..."
$COMPOSE up -d cu-up cu-up2
sleep 10

echo "Starting DUs..."
$COMPOSE up -d du du-b
sleep 10

echo "Starting monitoring stack..."
$COMPOSE up -d telegraf influxdb grafana scaphandre prometheus
sleep 5

echo "=== All containers up! ==="
docker ps --format "{{.Names}} {{.Status}}" | grep -E "srsran|open5gs"
sensors | grep "Core"