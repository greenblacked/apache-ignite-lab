#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_common.sh"
lab_load_env "$ROOT"
IMAGE="${IGNITE3_IMAGE:-apacheignite/ignite:3.1.0}"
docker run --rm -it \
  --network "$LAB_NETWORK" \
  -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 \
  "$IMAGE" cli
# After launch, connect with the built-in ignite user and the password from .env:
# connect http://ignite3-node1:10300 -u ignite -p <password>
