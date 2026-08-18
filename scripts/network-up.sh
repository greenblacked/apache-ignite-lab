#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"

if docker network inspect -- "$LAB_NETWORK" >/dev/null 2>&1; then
  echo "Network $LAB_NETWORK already exists"
else
  docker network create -- "$LAB_NETWORK"
  echo "Created network $LAB_NETWORK"
fi
