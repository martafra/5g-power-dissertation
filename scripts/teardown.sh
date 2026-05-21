#!/bin/bash
# Stops all srsRAN containers and optionally the monitoring stack and 5GC

STOP_ALL=${1:-false}

echo "=== Stopping all srsRAN containers ==="
docker ps --format "{{.Names}}" | grep "^srsran_" | xargs -r docker stop
docker ps -a --format "{{.Names}}" | grep "^srsran_" | xargs -r docker rm
echo "srsRAN containers stopped"

if [ "$STOP_ALL" = "--all" ]; then
    echo "=== Stopping monitoring stack and 5GC ==="
    docker stop scaphandre prometheus open5gs_5gc influxdb telegraf grafana 2>/dev/null || true
    docker rm scaphandre prometheus open5gs_5gc influxdb telegraf grafana 2>/dev/null || true
    echo "All containers stopped"
fi

echo "=== Current state ==="
docker ps --format "{{.Names}} {{.Status}}"
