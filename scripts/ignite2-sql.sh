#!/usr/bin/env bash
set -euo pipefail
# Run a read-only SQL smoke check through Ignite's JDBC thin client.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
lab_require_builtin_user

USER_NAME="${IGNITE_LAB_USER:-ignite}"
PASS="${IGNITE2_PASSWORD:-ignite}"

# The quoted command is expanded by the container's bash, not this shell.
# shellcheck disable=SC2016
if ! OUTPUT=$(lab_compose "$ROOT/ignite2/docker-compose.yml" exec -T ignite2-node1 \
  bash -lc '
    BIN=$(ls -d /opt/ignite/apache-ignite*/bin 2>/dev/null | head -1)
    "$BIN/sqlline.sh" \
      -u jdbc:ignite:thin://127.0.0.1:10800 \
      -n "$1" -p "$2" \
      --readOnly=true \
      --silent=true \
      --showWarnings=false \
      --outputformat=csv \
      -e "SELECT 1 AS HEALTH_CHECK;"
  ' _ "$USER_NAME" "$PASS" 2>&1); then
  echo "$OUTPUT" >&2
  echo "Ignite 2 SQL check could not run." >&2
  exit 1
fi

# Sqlline 1.9 can return zero even when connection or SQL execution fails.
# Require the known result row so failures cannot be reported as success.
if ! grep -Fqx "'1'" <<<"$OUTPUT"; then
  echo "$OUTPUT" >&2
  echo "Ignite 2 SQL check failed: expected result row was not returned." >&2
  exit 1
fi

echo "Ignite 2 SQL check passed: HEALTH_CHECK=1"
