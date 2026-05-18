#!/bin/bash
set -e
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.split.yml -f docker-compose.ui.yml"

wait_healthy() {
    local container=$1
    echo "Waiting for $container to be healthy..."
    while [ "$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null)" != "healthy" ]; do
        sleep 3
    done
    echo "$container is healthy!"
}

echo "=== Starting 3CU-3DU topology ==="
echo "Starting 5GC..."
$COMPOSE up -d 5gc
wait_healthy open5gs_5gc

echo "Starting CU-CPs..."
$COMPOSE up -d cu-cp cu-cp2 cu-cp3
wait_healthy srsran_cu_cp
wait_healthy srsran_cu_cp2
wait_healthy srsran_cu_cp3

echo "Starting CU-UPs..."
$COMPOSE up -d cu-up cu-up2 cu-up3
sleep 10

echo "Starting DUs..."
$COMPOSE up -d du du-b du-c
sleep 10

echo "Starting monitoring stack..."
$COMPOSE up -d telegraf influxdb grafana scaphandre prometheus
sleep 5

echo "=== All containers up! ==="
docker ps --format "{{.Names}} {{.Status}}" | grep -E "srsran|open5gs"
