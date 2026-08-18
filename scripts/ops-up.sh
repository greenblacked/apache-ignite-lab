#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
"$ROOT/scripts/network-up.sh"
# Recreate the ops containers so mounted provisioning/config changes and a
# rebuilt exporter are applied even when an older stack is already running.
# Prometheus and Grafana state remain in their named volumes.
lab_compose "$ROOT/ops/docker-compose.yml" up -d --build --force-recreate

wait_for_healthy_service() {
  local service="$1"
  local container_id=""
  local status=""

  for _ in $(seq 1 60); do
    container_id=$(lab_compose "$ROOT/ops/docker-compose.yml" ps -q "$service")
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

for SERVICE in ignite-exporter prometheus grafana; do
  wait_for_healthy_service "$SERVICE"
done

curl -fsS --max-time 5 http://127.0.0.1:9090/-/ready >/dev/null
curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >/dev/null

echo "Grafana:    http://127.0.0.1:3000/"
echo "Prometheus: http://127.0.0.1:9090/"
echo "Login:      ${GF_SECURITY_ADMIN_USER:-admin} / value from .env (default admin)"
echo "Optional:   https://grafana.ops.orb.local/ (needs browser Local Network + no Secure DNS)"
