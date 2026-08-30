#!/usr/bin/env bash
set -euo pipefail
# Prove the alerting works: stop one Ignite node, wait for IgniteNodeDown to
# fire in Prometheus, start it again, and wait for the alert to clear and the
# node to rejoin.
#
# This automates step 6 of the practice checklist in README.md. Unlike the
# smoke test it deliberately breaks the lab, so it restores the node through a
# trap: interrupting it with Ctrl-C still brings the node back.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"

# Exit codes, so a caller can tell these apart:
#   0 drill passed        2 usage or validation error
#   1 drill failed        3 lab is not in a state to drill against
readonly EXIT_FAILED=1
readonly EXIT_USAGE=2
readonly EXIT_NOT_READY=3

NODE="ignite3-node2"
DRY_RUN=0
JSON_LOGS=0
LOG_LEVEL="${LOG_LEVEL:-info}"
# IgniteNodeDown has "for: 2m", and Prometheus needs a scrape plus an
# evaluation on top of that, so the fire window is ~2m30s in practice.
FIRE_TIMEOUT=300
RECOVER_TIMEOUT=300
POLL_INTERVAL=5
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

# Set once the node is stopped, so the trap knows whether to restore it.
NODE_STOPPED=0
COMPOSE_FILE=""

usage() {
  cat <<'EOF'
Usage: failure-drill.sh [--node NAME] [--dry-run] [--json] [--timeout SECONDS]

Stops one Ignite node, waits for IgniteNodeDown to fire in Prometheus, then
restarts it and waits for the alert to clear and the node to rejoin.

Options:
  --node NAME        Node to stop. One of ignite2-node1..3, ignite3-node1..3.
                     Default: ignite3-node2.
  --dry-run          Print the plan and exit without touching the lab.
  --json             Emit logs as JSON objects instead of plain text.
  --timeout SECONDS  Per-phase timeout, 60-3600. Default: 300.
  -h, --help         Show this help.

Environment:
  PROMETHEUS_URL     Default http://127.0.0.1:9090
  LOG_LEVEL          debug, info, warn or error. Default: info.

Requires the target stack and ./scripts/ops-up.sh to be running.
EOF
}

level_num() {
  case "$1" in
    debug) printf '10' ;;
    info) printf '20' ;;
    warn) printf '30' ;;
    error) printf '40' ;;
    *) printf '20' ;;
  esac
}

# Logs go to stderr so stdout carries only the drill's own result.
log() {
  local level="$1"
  shift
  local message="$*"

  if [[ "$(level_num "$level")" -lt "$(level_num "$LOG_LEVEL")" ]]; then
    return 0
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ "$JSON_LOGS" -eq 1 ]]; then
    python3 -c '
import json, sys
print(json.dumps({"ts": sys.argv[1], "level": sys.argv[2],
                  "node": sys.argv[3], "msg": sys.argv[4]}))
' "$timestamp" "$level" "$NODE" "$message" >&2
  else
    printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >&2
  fi
}

# Restores the node on any exit path, including Ctrl-C, so an interrupted
# drill never leaves the lab a node short.
cleanup() {
  local rc=$?
  trap - EXIT INT TERM

  if [[ "$NODE_STOPPED" -eq 1 ]]; then
    log warn "Restoring $NODE before exit."
    if lab_compose "$COMPOSE_FILE" start "$NODE" >/dev/null 2>&1; then
      NODE_STOPPED=0
      log info "$NODE restarted."
    else
      log error "Could not restart $NODE. Run this by hand:"
      log error "  docker compose -f $COMPOSE_FILE start $NODE"
    fi
  fi

  exit "$rc"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      [[ $# -ge 2 ]] || { echo "--node needs a value" >&2; exit "$EXIT_USAGE"; }
      NODE="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "--timeout needs a value" >&2; exit "$EXIT_USAGE"; }
      FIRE_TIMEOUT="$2"
      RECOVER_TIMEOUT="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_LOGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
done

# ---- Validate every input before touching the lab ----------------------------

if [[ ! "$NODE" =~ ^ignite[23]-node[1-3]$ ]]; then
  echo "Invalid --node '$NODE'." >&2
  echo "Expected ignite2-node1..3 or ignite3-node1..3." >&2
  exit "$EXIT_USAGE"
fi

if [[ ! "$FIRE_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$FIRE_TIMEOUT" -lt 60 ]] || [[ "$FIRE_TIMEOUT" -gt 3600 ]]; then
  echo "Invalid --timeout '$FIRE_TIMEOUT'. Expected an integer from 60 to 3600." >&2
  echo "IgniteNodeDown has a 2m 'for' window, so anything under 60s cannot pass." >&2
  exit "$EXIT_USAGE"
fi

case "$LOG_LEVEL" in
  debug|info|warn|error) ;;
  *)
    echo "Invalid LOG_LEVEL '$LOG_LEVEL'. Expected debug, info, warn or error." >&2
    exit "$EXIT_USAGE"
    ;;
esac

STACK="${NODE%%-*}"
COMPOSE_FILE="$ROOT/$STACK/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
  exit "$EXIT_USAGE"
fi

lab_load_env "$ROOT"

for required in curl docker python3; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "Required command not found: $required" >&2
    exit "$EXIT_NOT_READY"
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "The Docker Compose plugin is unavailable." >&2
  exit "$EXIT_NOT_READY"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
Dry run. Nothing will be changed.

  1. Check $NODE is running and IgniteNodeDown is not already firing for it.
  2. docker compose -f $COMPOSE_FILE stop $NODE
  3. Poll $PROMETHEUS_URL/api/v1/alerts for up to ${FIRE_TIMEOUT}s until
     IgniteNodeDown is firing for $NODE.
  4. docker compose -f $COMPOSE_FILE start $NODE
  5. Poll for up to ${RECOVER_TIMEOUT}s until the alert clears and
     ignite_node_up{node="$NODE"} is 1 again.

The node is restarted by a trap even if this is interrupted.
EOF
  exit 0
fi

# ---- Preflight ---------------------------------------------------------------

log info "Checking the lab is ready to drill against."

if ! curl -fsS --connect-timeout 2 --max-time 10 "$PROMETHEUS_URL/-/ready" >/dev/null 2>&1; then
  log error "Prometheus is not ready at $PROMETHEUS_URL. Start it with ./scripts/ops-up.sh"
  exit "$EXIT_NOT_READY"
fi

CONTAINER_ID=$(lab_compose "$COMPOSE_FILE" ps -q "$NODE" 2>/dev/null || true)
if [[ -z "$CONTAINER_ID" ]]; then
  log error "No container for $NODE. Start the stack with ./scripts/${STACK}-up.sh"
  exit "$EXIT_NOT_READY"
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null)" != "true" ]]; then
  log error "$NODE is not running, so stopping it would prove nothing."
  exit "$EXIT_NOT_READY"
fi

alerts_json() {
  curl -fsS --connect-timeout 2 --max-time 10 "$PROMETHEUS_URL/api/v1/alerts" 2>/dev/null || true
}

readonly FIRING_PROGRAM='
import json, sys
d = json.load(sys.stdin)
node = sys.argv[1]
assert d.get("status") == "success"
assert any(
    a["labels"].get("alertname") == "IgniteNodeDown"
    and a["labels"].get("node") == node
    and a.get("state") == "firing"
    for a in d["data"]["alerts"]
)
'

readonly CLEARED_PROGRAM='
import json, sys
d = json.load(sys.stdin)
node = sys.argv[1]
assert d.get("status") == "success"
assert not any(
    a["labels"].get("alertname") == "IgniteNodeDown"
    and a["labels"].get("node") == node
    for a in d["data"]["alerts"]
)
'

readonly NODE_UP_PROGRAM='
import json, sys
d = json.load(sys.stdin)
r = d.get("data", {}).get("result", [])
assert d.get("status") == "success"
assert r and all(float(x["value"][1]) == 1 for x in r)
'

if payload=$(alerts_json) && [[ -n "$payload" ]] &&
   printf '%s' "$payload" | python3 -c "$FIRING_PROGRAM" "$NODE" >/dev/null 2>&1; then
  log error "IgniteNodeDown is already firing for $NODE. Fix the lab before drilling."
  exit "$EXIT_NOT_READY"
fi

log info "Preflight passed. $NODE is running and quiet."

# ---- Poll helpers ------------------------------------------------------------

wait_for_alert() {
  local label="$1"
  local timeout="$2"
  local program="$3"
  local deadline=$((SECONDS + timeout))
  local body=""

  while [[ "$SECONDS" -lt "$deadline" ]]; do
    body=$(alerts_json)
    if [[ -n "$body" ]] && printf '%s' "$body" | python3 -c "$program" "$NODE" >/dev/null 2>&1; then
      log info "$label"
      return 0
    fi
    log debug "Still waiting: $label ($((deadline - SECONDS))s left)"
    sleep "$POLL_INTERVAL"
  done

  log error "Timed out after ${timeout}s waiting for: $label"
  return 1
}

wait_for_query() {
  local label="$1"
  local timeout="$2"
  local query="$3"
  local deadline=$((SECONDS + timeout))
  local body=""

  while [[ "$SECONDS" -lt "$deadline" ]]; do
    body=$(curl -fsS --connect-timeout 2 --max-time 10 -G \
      "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$query" 2>/dev/null || true)
    if [[ -n "$body" ]] && printf '%s' "$body" | python3 -c "$NODE_UP_PROGRAM" >/dev/null 2>&1; then
      log info "$label"
      return 0
    fi
    log debug "Still waiting: $label ($((deadline - SECONDS))s left)"
    sleep "$POLL_INTERVAL"
  done

  log error "Timed out after ${timeout}s waiting for: $label"
  return 1
}

# ---- Drill -------------------------------------------------------------------

trap cleanup EXIT INT TERM

log info "Stopping $NODE."
lab_compose "$COMPOSE_FILE" stop "$NODE" >/dev/null
NODE_STOPPED=1

log info "Waiting for IgniteNodeDown to fire. Its 'for' window is 2m, so this takes a while."
if ! wait_for_alert "IgniteNodeDown is firing for $NODE" "$FIRE_TIMEOUT" "$FIRING_PROGRAM"; then
  log error "The node was stopped but the alert never fired. The rule or the exporter is not working."
  exit "$EXIT_FAILED"
fi

log info "Starting $NODE again."
lab_compose "$COMPOSE_FILE" start "$NODE" >/dev/null
NODE_STOPPED=0

if ! wait_for_query "$NODE is reachable again" "$RECOVER_TIMEOUT" "ignite_node_up{node=\"$NODE\"}"; then
  log error "$NODE did not rejoin. Check: docker compose -f $COMPOSE_FILE logs $NODE"
  exit "$EXIT_FAILED"
fi

if ! wait_for_alert "IgniteNodeDown cleared for $NODE" "$RECOVER_TIMEOUT" "$CLEARED_PROGRAM"; then
  log error "$NODE is back but the alert is still firing. The rule may not resolve correctly."
  exit "$EXIT_FAILED"
fi

# stdout carries the result and nothing else, so this stays pipeable.
echo "Failure drill passed: $NODE went down, IgniteNodeDown fired, the node recovered and the alert cleared."
