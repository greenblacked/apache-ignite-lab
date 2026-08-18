#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/monitoring/docker-compose.yml"
MONITORING_NETWORK="${MONITORING_LAB_NETWORK:-monitoring-lab}"

if [[ ! "$MONITORING_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "Invalid MONITORING_LAB_NETWORK: $MONITORING_NETWORK" >&2
  exit 2
fi

export MONITORING_LAB_NETWORK="$MONITORING_NETWORK"

if ! docker network inspect "$MONITORING_NETWORK" >/dev/null 2>&1; then
  docker network create "$MONITORING_NETWORK" >/dev/null
  echo "Created network: $MONITORING_NETWORK"
fi

docker compose -f "$COMPOSE_FILE" up -d

wait_for_healthy_service() {
  local service="$1"
  local container_id=""
  local status=""

  for _ in $(seq 1 60); do
    container_id=$(docker compose -f "$COMPOSE_FILE" ps -q "$service")
    if [[ -n "$container_id" ]]; then
      status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container_id" 2>/dev/null || true)
      if [[ "$status" == "healthy" ]]; then
        echo "$service is healthy"
        return 0
      fi
      if [[ "$status" == "exited" || "$status" == "dead" ]]; then
        echo "$service stopped before becoming healthy." >&2
        return 1
      fi
    fi
    sleep 2
  done

  echo "Timed out waiting for $service (last status: ${status:-not created})." >&2
  return 1
}

for SERVICE in prometheus grafana otel-collector; do
  wait_for_healthy_service "$SERVICE"
done

curl -fsS --max-time 5 http://127.0.0.1:9091/-/ready >/dev/null
curl -fsS --max-time 5 http://127.0.0.1:3001/api/health >/dev/null

echo "Prometheus: http://127.0.0.1:9091/"
echo "Grafana:    http://127.0.0.1:3001/"
echo "Grafana login: ${MONITORING_GF_ADMIN_USER:-admin} / value from MONITORING_GF_ADMIN_PASSWORD (default playground)"
echo "OTLP/gRPC:  127.0.0.1:4317"
echo "OTLP/HTTP:  http://127.0.0.1:4318/"

