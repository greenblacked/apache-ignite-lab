#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
lab_require_builtin_user

IMAGE="${IGNITE3_IMAGE:-apacheignite/ignite:3.1.0}"
USER_NAME="${IGNITE_LAB_USER:-ignite}"
PASS="${IGNITE_LAB_PASSWORD:-ignite-lab-pass}"
CONTAINER_URL="http://ignite3-node1:10300"
HOST_CLUSTER_URL="http://127.0.0.1:10300/management/v1/cluster/state"

if [[ -z "$PASS" ]]; then
  echo "IGNITE_LAB_PASSWORD must not be empty." >&2
  exit 2
fi

http_code() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 2 --max-time 5 "$@" 2>/dev/null || true)
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

run_cli() {
  docker run --rm --network "$LAB_NETWORK" \
    -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 \
    "$IMAGE" cli "$@"
}

ANONYMOUS_CODE=$(http_code "$HOST_CLUSTER_URL")

if [[ "$ANONYMOUS_CODE" == "401" || "$ANONYMOUS_CODE" == "403" ]]; then
  AUTHENTICATED_CODE=$(http_code -u "$USER_NAME:$PASS" "$HOST_CLUSTER_URL")
  if [[ "$AUTHENTICATED_CODE" == "200" ]]; then
    echo "Ignite 3 is already initialized and authentication is configured."
    exit 0
  fi

  echo "Ignite 3 authentication is already enabled, but the configured credentials were rejected." >&2
  echo "Refusing to change cluster configuration; use the current ignite password in .env." >&2
  exit 1
fi

# "cluster init" returns before the cluster accepts configuration writes, so
# a config update issued immediately after it fails with "Cannot update
# cluster config". Wait for the cluster state endpoint to answer first.
wait_for_cluster_state() {
  for _ in $(seq 1 60); do
    if [[ "$(http_code "$HOST_CLUSTER_URL")" == "200" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Cluster did not report a readable state after initialization." >&2
  return 1
}

if [[ "$ANONYMOUS_CODE" == "404" || "$ANONYMOUS_CODE" == "409" ]]; then
  echo "Initializing Ignite 3 cluster..."
  run_cli cluster init \
    --url "$CONTAINER_URL" \
    --name=ignite3-lab \
    --metastorage-group=ignite3-node1,ignite3-node2,ignite3-node3
  wait_for_cluster_state
elif [[ "$ANONYMOUS_CODE" == "200" ]]; then
  echo "Ignite 3 is initialized without authentication; completing security setup..."
else
  echo "Cannot determine Ignite 3 cluster state (HTTP $ANONYMOUS_CODE)." >&2
  echo "Start the nodes with ./scripts/ignite3-up.sh, then retry." >&2
  exit 1
fi

PASSWORD_VALUE=${PASS//\\/\\\\}
PASSWORD_VALUE=${PASSWORD_VALUE//\"/\\\"}

run_cli cluster config update --url "$CONTAINER_URL" \
  "ignite.security.authentication.providers.default.users.ignite.password=\"${PASSWORD_VALUE}\""

run_cli cluster config update --url "$CONTAINER_URL" \
  "ignite.security.enabled=true"

for _ in $(seq 1 15); do
  if [[ "$(http_code -u "$USER_NAME:$PASS" "$HOST_CLUSTER_URL")" == "200" ]]; then
    echo "Initialized ignite3-lab with authentication."
    echo "REST check: curl -u ${USER_NAME}:**** http://127.0.0.1:10300/management/v1/cluster/state"
    echo "Interactive CLI: ./scripts/ignite3-cli.sh"
    exit 0
  fi
  sleep 1
done

echo "Security configuration was submitted, but authenticated verification failed." >&2
exit 1
