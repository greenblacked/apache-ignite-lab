#!/usr/bin/env bash
set -euo pipefail
# Optional: generate self-signed certs for TLS experiments (not wired by default).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/certs"
mkdir -p "$OUT"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$OUT/lab.key" -out "$OUT/lab.crt" -days 365 \
  -subj "/CN=ignite-lab"
echo "Wrote $OUT/lab.crt and $OUT/lab.key"
echo "Mount/configure these in node and client TLS settings when practicing secure clients."
