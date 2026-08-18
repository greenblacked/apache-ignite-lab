#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
lab_require_builtin_user
"$ROOT/scripts/network-up.sh"
lab_compose "$ROOT/ignite2/docker-compose.yml" up -d
echo "Waiting for Ignite 2 node1 REST..."
for _ in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:8080/ignite?cmd=version" >/dev/null; then
    echo "Ignite 2 REST is up — activating cluster (persistence)..."
    # The quoted command is expanded by the container's bash, not this shell.
    # shellcheck disable=SC2016
    lab_compose "$ROOT/ignite2/docker-compose.yml" exec -T ignite2-node1 \
      bash -lc 'BIN=$(ls -d /opt/ignite/apache-ignite*/bin 2>/dev/null | head -1); "$BIN/control.sh" --user "$1" --password "$2" --set-state ACTIVE --yes' \
      _ "${IGNITE_LAB_USER:-ignite}" "${IGNITE2_PASSWORD:-ignite}"
    echo "Ignite 2 is up (built-in user: ignite)"
    exit 0
  fi
  sleep 2
done
echo "Timed out waiting for Ignite 2" >&2
exit 1
