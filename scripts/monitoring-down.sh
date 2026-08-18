#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/monitoring/docker-compose.yml"

case "${1:-}" in
  "") FLAGS=(down) ;;
  --wipe) FLAGS=(down -v) ;;
  *)
    echo "Usage: $0 [--wipe]" >&2
    exit 2
    ;;
esac

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [--wipe]" >&2
  exit 2
fi

docker compose -f "$COMPOSE_FILE" "${FLAGS[@]}"

if [[ "${1:-}" == "--wipe" ]]; then
  echo "Monitoring playground stopped and volumes wiped"
else
  echo "Monitoring playground stopped (volumes kept)"
fi

