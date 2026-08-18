# Monitoring playground (tool-named folders)

**Date:** 2026-08-11  
**Status:** Implemented  
**Constraint:** Sibling of Ignite `ops/`; must not break Ignite observability or smoke tests

## Goal

Add an independent local monitoring playground under `monitoring/` with per-tool folders (`prometheus`, `grafana`, `dynatrace`) that run on a laptop without Ignite. Keep the existing Ignite-coupled stack in `ops/` unchanged.

## Decisions

| Choice | Decision |
|--------|----------|
| Relationship to `ops/` | Sibling playground; do not migrate or replace Ignite ops |
| Dynatrace meaning | OpenTelemetry Collector under `monitoring/dynatrace/`; optional Dynatrace SaaS exporter when tokens are set |
| Host ports | Distinct from ops so both stacks can run together |
| Layout | Per-tool compose + optional umbrella compose (approach 1) |

## Non-goals

- Dynatrace OneAgent, Managed, or a local Dynatrace UI
- Wiring Ignite metrics into this playground
- Changing `ops/`, `scripts/ops-up.sh`, or `scripts/smoke-test.sh` behavior
- Full-lab smoke for monitoring in GitHub Actions

## Architecture

```
monitoring/
  README.md
  docker-compose.yml              # umbrella: starts all three tools
  prometheus/
    docker-compose.yml
    prometheus.yml
  grafana/
    docker-compose.yml
    provisioning/...
    dashboards/...                # demo dashboard (not Ignite Lab Overview)
  dynatrace/
    docker-compose.yml
    docker-compose.dynatrace.yml  # optional SaaS export override
    otel-collector-config.yml
    otel-collector-config.dynatrace.yml
    .env.example                  # optional DT_ENDPOINT / DT_API_TOKEN
```

### Network

- Dedicated Docker network: `monitoring-lab`
- Do **not** join `ignite-lab`

### Host ports (localhost only)

| Service | Host | Notes |
|---------|------|-------|
| Prometheus | `127.0.0.1:9091` | ops keeps `9090` |
| Grafana | `127.0.0.1:3001` | ops keeps `3000` |
| OTel Collector gRPC | `127.0.0.1:4317` | |
| OTel Collector HTTP | `127.0.0.1:4318` | |
| OTel self-metrics (optional) | `127.0.0.1:8889` | if exposed |

### Tool behavior

**Prometheus**

- Pinned image (same generation as ops, e.g. `prom/prometheus:v2.55.1`, or explicitly documented pin)
- Scrapes local demo targets only (e.g. Prometheus itself and/or a small generator) — **not** the Ignite exporter
- Named volume for TSDB data
- Healthcheck on `/-/healthy`

**Grafana**

- Pinned image (same generation as ops, e.g. `grafana/grafana:11.3.1`)
- Provisions Prometheus datasource at `http://prometheus:9090` on `monitoring-lab`
- Ships a minimal demo dashboard (not Ignite Lab Overview)
- Admin credentials from env (`GF_SECURITY_ADMIN_*` with playground defaults)
- Healthcheck on `/api/health`

**Dynatrace (OTel Collector)**

- Always starts with a local pipeline (logging and/or local OTLP receive)
- A second config file and Compose override enable the Dynatrace OTLP/HTTP exporter only when both `DT_ENDPOINT` and `DT_API_TOKEN` are set
- Without tokens, collector remains healthy and useful for local OTLP experiments
- Secrets never committed; only `.env.example`

### Scripts and docs

- Thin helpers: `scripts/monitoring-up.sh`, `scripts/monitoring-down.sh` (reuse `scripts/_common.sh` patterns where useful)
- `monitoring/README.md` is the operator guide
- Root `README.md` gets a short pointer section only

### CI

- Static only: `docker compose … config` for monitoring compose files
- `promtool check config` for `monitoring/prometheus/prometheus.yml`
- No Dynatrace SaaS or live OTel e2e in Actions

## Success criteria

- `monitoring` starts without Ignite running
- Prometheus UI on `:9091`, Grafana on `:3001`
- Ops can still run on `:9090` / `:3000` at the same time
- Dynatrace folder collector starts with empty optional tokens
- Existing Ignite smoke path unchanged
