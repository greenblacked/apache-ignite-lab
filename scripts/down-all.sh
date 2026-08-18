#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"

WIPE=0
case "${1:-}" in
  "") ;;
  --wipe) WIPE=1 ;;
  *)
    echo "Usage: $0 [--wipe]" >&2
    exit 2
    ;;
esac

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [--wipe]" >&2
  exit 2
fi

FLAGS=(down)
[[ "$WIPE" -eq 1 ]] && FLAGS+=(-v)

FAILED_STACKS=()
for STACK in ops ignite2 ignite3; do
  echo "Stopping $STACK..."
  if ! lab_compose "$ROOT/$STACK/docker-compose.yml" "${FLAGS[@]}"; then
    FAILED_STACKS+=("$STACK")
  fi
done

if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
  echo "Failed to stop: ${FAILED_STACKS[*]}" >&2
  exit 1
fi

if [[ "$WIPE" -eq 1 ]]; then
  echo "Stacks stopped and volumes wiped"
else
  echo "Stacks stopped (volumes kept)"
fi
