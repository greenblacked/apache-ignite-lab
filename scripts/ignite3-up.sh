#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
lab_require_builtin_user
"$ROOT/scripts/network-up.sh"
lab_compose "$ROOT/ignite3/docker-compose.yml" up -d

USER_NAME="${IGNITE_LAB_USER:-ignite}"
PASS="${IGNITE_LAB_PASSWORD:-ignite-lab-pass}"
STATE_URL="http://127.0.0.1:10300/management/v1/node/state"

http_code() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 2 --max-time 5 "$@" 2>/dev/null || true)
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

echo "Waiting for Ignite 3 REST on :10300..."
for _ in $(seq 1 90); do
  ANONYMOUS_CODE=$(http_code "$STATE_URL")
  if [[ "$ANONYMOUS_CODE" == "200" ]]; then
    echo "Ignite 3 nodes are reachable without authentication."
    echo "Run ./scripts/ignite3-init.sh if the cluster is not initialized."
    exit 0
  fi

  if [[ "$ANONYMOUS_CODE" == "401" || "$ANONYMOUS_CODE" == "403" ]]; then
    AUTHENTICATED_CODE=$(http_code -u "$USER_NAME:$PASS" "$STATE_URL")
    if [[ "$AUTHENTICATED_CODE" == "200" ]]; then
      echo "Ignite 3 nodes are reachable with authentication."
      exit 0
    fi

    if [[ "$AUTHENTICATED_CODE" == "401" || "$AUTHENTICATED_CODE" == "403" ]]; then
      echo "Ignite 3 is reachable, but configured credentials were rejected." >&2
      echo "Check IGNITE_LAB_USER and IGNITE_LAB_PASSWORD in .env." >&2
      exit 1
    fi
  fi

  sleep 2
done
echo "Timed out waiting for Ignite 3" >&2
exit 1
