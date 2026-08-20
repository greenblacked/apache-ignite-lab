#!/usr/bin/env bash
set -euo pipefail

# Read-only acceptance checks for the running Ignite lab and observability stack.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
lab_require_builtin_user

for REQUIRED_COMMAND in curl docker grep python3 seq; do
  if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
    echo "Required command not found: $REQUIRED_COMMAND" >&2
    exit 2
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "Required Docker Compose plugin is unavailable." >&2
  exit 2
fi

IGNITE_USER="${IGNITE_LAB_USER:-ignite}"
IGNITE2_PASS="${IGNITE2_PASSWORD:-ignite}"
IGNITE3_PASS="${IGNITE_LAB_PASSWORD:-ignite-lab-pass}"
GRAFANA_USER="${GF_SECURITY_ADMIN_USER:-admin}"
GRAFANA_PASS="${GF_SECURITY_ADMIN_PASSWORD:-admin}"
CHECKS_PASSED=0

pass() {
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
  echo "ok - $1"
}

fail() {
  echo "not ok - $1" >&2
  exit 1
}

fetch_json() {
  local label="$1"
  shift
  local payload=""

  if ! payload=$(curl -fsS --connect-timeout 2 --max-time 10 \
    -H 'Accept: application/json' "$@"); then
    echo "Request failed: $label" >&2
    return 1
  fi
  printf '%s' "$payload"
}

json_matches() {
  local payload="$1"
  local program="$2"
  shift 2
  printf '%s' "$payload" | python3 -c "$program" "$@" >/dev/null 2>&1
}

check_json() {
  local label="$1"
  local payload="$2"
  local program="$3"
  shift 3

  if ! printf '%s' "$payload" | python3 -c "$program" "$@"; then
    fail "$label returned unexpected JSON"
  fi
  pass "$label"
}

check_http() {
  local label="$1"
  local endpoint_url="$2"

  if ! curl -fsS --connect-timeout 2 --max-time 10 "$endpoint_url" >/dev/null; then
    fail "$label is unavailable"
  fi
  pass "$label"
}

check_http_rejected() {
  local label="$1"
  local endpoint_url="$2"
  local status_code=""

  status_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 2 --max-time 10 "$endpoint_url" 2>/dev/null || true)
  if [[ "$status_code" != "401" && "$status_code" != "403" ]]; then
    fail "$label expected HTTP 401/403, got ${status_code:-no response}"
  fi
  pass "$label"
}

wait_for_prometheus_query() {
  local label="$1"
  local query="$2"
  local program="$3"
  local payload=""

  for _ in $(seq 1 15); do
    payload=$(curl -fsS --connect-timeout 2 --max-time 10 -G \
      http://127.0.0.1:9090/api/v1/query \
      --data-urlencode "query=$query" 2>/dev/null || true)
    if [[ -n "$payload" ]] && json_matches "$payload" "$program"; then
      pass "$label"
      return 0
    fi
    sleep 2
  done

  if [[ -n "$payload" ]]; then
    printf '%s' "$payload" | python3 -c "$program" || true
  fi
  fail "$label did not become ready"
}

wait_for_prometheus_rules() {
  local label="$1"
  local program="$2"
  local payload=""

  for _ in $(seq 1 15); do
    payload=$(curl -fsS --connect-timeout 2 --max-time 10 \
      http://127.0.0.1:9090/api/v1/rules 2>/dev/null || true)
    if [[ -n "$payload" ]] && json_matches "$payload" "$program"; then
      pass "$label"
      return 0
    fi
    sleep 2
  done

  if [[ -n "$payload" ]]; then
    printf '%s' "$payload" | python3 -c "$program" || true
  fi
  fail "$label did not become ready"
}

echo "Running read-only Ignite lab smoke checks..."

IGNITE2_PORTS=(8080 8081 8082)
for REST_PORT in "${IGNITE2_PORTS[@]}"; do
  VERSION_PAYLOAD=$(fetch_json "Ignite 2 REST :$REST_PORT" -G \
    "http://127.0.0.1:$REST_PORT/ignite" \
    --data-urlencode cmd=version \
    --data-urlencode "ignite.login=$IGNITE_USER" \
    --data-urlencode "ignite.password=$IGNITE2_PASS")
  check_json "Ignite 2 REST :$REST_PORT" "$VERSION_PAYLOAD" \
    'import json,sys; d=json.load(sys.stdin); assert d.get("successStatus")==0; assert isinstance(d.get("response"),str) and d["response"]'
done

IGNITE2_TOPOLOGY=$(fetch_json "Ignite 2 topology" -G \
  http://127.0.0.1:8080/ignite \
  --data-urlencode cmd=top \
  --data-urlencode "ignite.login=$IGNITE_USER" \
  --data-urlencode "ignite.password=$IGNITE2_PASS" \
  --data-urlencode attr=false \
  --data-urlencode mtr=false)
check_json "Ignite 2 three-node topology" "$IGNITE2_TOPOLOGY" \
  'import json,sys; d=json.load(sys.stdin); expected={"ignite2-node1","ignite2-node2","ignite2-node3"}; assert d.get("successStatus")==0; assert {str(x.get("consistentId")) for x in d.get("response",[])}==expected'

IGNITE2_STATE=$(fetch_json "Ignite 2 cluster state" -G \
  http://127.0.0.1:8080/ignite \
  --data-urlencode cmd=currentstate \
  --data-urlencode "ignite.login=$IGNITE_USER" \
  --data-urlencode "ignite.password=$IGNITE2_PASS")
check_json "Ignite 2 cluster ACTIVE" "$IGNITE2_STATE" \
  'import json,sys; d=json.load(sys.stdin); assert d.get("successStatus")==0 and d.get("response") is True'

if ! "$ROOT/scripts/ignite2-sql.sh"; then
  fail "Ignite 2 read-only SQL"
fi
pass "Ignite 2 read-only SQL"

IGNITE3_PORTS=(10300 10301 10302)
IGNITE3_NODES=(ignite3-node1 ignite3-node2 ignite3-node3)
for NODE_INDEX in "${!IGNITE3_PORTS[@]}"; do
  REST_PORT="${IGNITE3_PORTS[$NODE_INDEX]}"
  EXPECTED_NODE="${IGNITE3_NODES[$NODE_INDEX]}"
  NODE_PAYLOAD=$(fetch_json "Ignite 3 $EXPECTED_NODE" \
    -u "$IGNITE_USER:$IGNITE3_PASS" \
    "http://127.0.0.1:$REST_PORT/management/v1/node/state")
  check_json "Ignite 3 $EXPECTED_NODE STARTED" "$NODE_PAYLOAD" \
    'import json,sys; d=json.load(sys.stdin); assert d.get("name")==sys.argv[1] and d.get("state")=="STARTED"' \
    "$EXPECTED_NODE"
done

check_http_rejected "Ignite 3 rejects anonymous cluster access" \
  http://127.0.0.1:10300/management/v1/cluster/state

IGNITE3_CLUSTER=$(fetch_json "Ignite 3 cluster state" \
  -u "$IGNITE_USER:$IGNITE3_PASS" \
  http://127.0.0.1:10300/management/v1/cluster/state)
check_json "Ignite 3 three-node cluster" "$IGNITE3_CLUSTER" \
  'import json,sys; d=json.load(sys.stdin); expected={"ignite3-node1","ignite3-node2","ignite3-node3"}; assert set(d.get("cmgNodes",[]))==expected; assert set(d.get("msNodes",[]))==expected; assert d.get("clusterTag",{}).get("clusterName")=="ignite3-lab"'

check_http "Prometheus readiness" http://127.0.0.1:9090/-/ready

wait_for_prometheus_query "Prometheus exporter target" \
  'up{job="ignite-exporter"}' \
  'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); assert d.get("status")=="success" and len(r)==1 and float(r[0]["value"][1])==1'

wait_for_prometheus_query "Six exported Ignite nodes" \
  ignite_node_up \
  'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); expected={("ignite2",f"ignite2-node{i}") for i in range(1,4)}|{("ignite3",f"ignite3-node{i}") for i in range(1,4)}; actual={(x["metric"].get("stack"),x["metric"].get("node")) for x in r}; assert actual==expected and all(float(x["value"][1])==1 for x in r)'

wait_for_prometheus_query "Both Ignite clusters ready" \
  ignite_cluster_ready \
  'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); assert {x["metric"].get("stack") for x in r}=={"ignite2","ignite3"}; assert all(float(x["value"][1])==1 for x in r)'

wait_for_prometheus_rules "Prometheus alert rules loaded" \
  'import json,sys; d=json.load(sys.stdin); g=d.get("data",{}).get("groups",[]); assert d.get("status")=="success"; assert {x.get("name") for x in g}>={"ignite-lab-exporter","ignite-lab-cluster","ignite-lab-nodes"}; assert sum(len(x.get("rules",[])) for x in g)>=8'

# A healthy lab fires nothing. "pending" is tolerated: an alert can still be
# counting down from the seconds before the stacks finished starting.
wait_for_prometheus_rules "No Ignite alerts firing" \
  'import json,sys; d=json.load(sys.stdin); g=d.get("data",{}).get("groups",[]); firing=[r.get("name") for x in g for r in x.get("rules",[]) if r.get("state")=="firing"]; assert not firing, firing'

GRAFANA_HEALTH=$(fetch_json "Grafana health" http://127.0.0.1:3000/api/health)
check_json "Grafana database health" "$GRAFANA_HEALTH" \
  'import json,sys; d=json.load(sys.stdin); assert d.get("database")=="ok" and d.get("version")'

DATASOURCE_HEALTH=$(fetch_json "Grafana Prometheus datasource" \
  -u "$GRAFANA_USER:$GRAFANA_PASS" \
  http://127.0.0.1:3000/api/datasources/uid/prometheus/health)
check_json "Grafana Prometheus datasource" "$DATASOURCE_HEALTH" \
  'import json,sys; d=json.load(sys.stdin); assert d.get("status")=="OK"'

DASHBOARD_SEARCH=$(fetch_json "Grafana Ignite dashboard" \
  -u "$GRAFANA_USER:$GRAFANA_PASS" -G \
  http://127.0.0.1:3000/api/search \
  --data-urlencode 'query=Ignite Lab Overview')
check_json "Grafana Ignite dashboard provisioned" "$DASHBOARD_SEARCH" \
  'import json,sys; d=json.load(sys.stdin); assert any(x.get("uid")=="ignite-lab" and x.get("title")=="Ignite Lab Overview" for x in d)'

echo "Read-only smoke test passed ($CHECKS_PASSED checks)."
