# Monitoring Playground Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an independent `monitoring/{prometheus,grafana,dynatrace}` playground that runs locally without Ignite and without colliding with `ops/` ports.

**Architecture:** Per-tool Compose projects on network `monitoring-lab`, plus an umbrella compose and thin up/down scripts. Dynatrace folder is an OpenTelemetry Collector with optional SaaS export. Ignite `ops/` stays untouched.

**Tech Stack:** Docker Compose v2, Prometheus v2.55.1, Grafana 11.3.1, OpenTelemetry Collector contrib (pinned), Bash helpers

## Global Constraints

- Do not modify Ignite `ops/` smoke behavior or ports `9090` / `3000`
- Monitoring ports: Prometheus `9091`, Grafana `3001`, OTel `4317`/`4318` (optional `8889`)
- Network name: `monitoring-lab` (not `ignite-lab`)
- Dynatrace = OTel Collector + optional `DT_ENDPOINT` / `DT_API_TOKEN`
- Static CI only; no live monitoring smoke in Actions
- Secrets only in `.env` / `.env.example` placeholders

## File map

| Path | Responsibility |
|------|----------------|
| `monitoring/README.md` | How to run the playground |
| `monitoring/docker-compose.yml` | Umbrella include/compose of all tools |
| `monitoring/prometheus/docker-compose.yml` | Prometheus service |
| `monitoring/prometheus/prometheus.yml` | Scrape config (local demo only) |
| `monitoring/grafana/docker-compose.yml` | Grafana service |
| `monitoring/grafana/provisioning/**` | Datasource + dashboard providers |
| `monitoring/grafana/dashboards/*.json` | Demo dashboard |
| `monitoring/dynatrace/docker-compose.yml` | OTel Collector service |
| `monitoring/dynatrace/otel-collector-config.yml` | Pipelines; Dynatrace exporter gated by env |
| `monitoring/dynatrace/.env.example` | Optional Dynatrace vars |
| `scripts/monitoring-up.sh` | Create network + up |
| `scripts/monitoring-down.sh` | Down (optional wipe) |
| `README.md` | Short pointer to monitoring playground |
| `.github/workflows/validate.yml` | Compose config + promtool for monitoring |
| `docs/superpowers/specs/2026-08-11-monitoring-playground-design.md` | Design (already written) |

---

### Task 1: Prometheus tool stack

**Files:**
- Create: `monitoring/prometheus/docker-compose.yml`
- Create: `monitoring/prometheus/prometheus.yml`
- Create: `monitoring/README.md` (initial ports + Prometheus section)

**Interfaces:**
- Consumes: Docker network `monitoring-lab` (create if missing)
- Produces: Prometheus at `http://127.0.0.1:9091/`

- [x] **Step 1: Write `monitoring/prometheus/prometheus.yml`**

Scrape Prometheus itself only (or self + a documented local target). Do not reference Ignite exporter hosts.

- [x] **Step 2: Write `monitoring/prometheus/docker-compose.yml`**

Pinned `prom/prometheus:v2.55.1`, publish `127.0.0.1:9091:9090`, external network `monitoring-lab`, named volume, healthcheck `/-/healthy`, `--web.external-url=http://127.0.0.1:9091/`.

- [ ] **Step 3: Create network and start Prometheus alone**

```bash
docker network create monitoring-lab 2>/dev/null || true
docker compose -f monitoring/prometheus/docker-compose.yml up -d
curl -fsS http://127.0.0.1:9091/-/ready
```

- [ ] **Step 4: Commit**

```bash
git add monitoring/prometheus monitoring/README.md
git commit -m "feat: add local monitoring Prometheus playground"
```

---

### Task 2: Grafana tool stack

**Files:**
- Create: `monitoring/grafana/docker-compose.yml`
- Create: `monitoring/grafana/provisioning/datasources/datasource.yml`
- Create: `monitoring/grafana/provisioning/dashboards/dashboards.yml`
- Create: `monitoring/grafana/dashboards/monitoring-demo.json`
- Modify: `monitoring/README.md`

**Interfaces:**
- Consumes: Prometheus service DNS name `prometheus:9090` on `monitoring-lab`
- Produces: Grafana at `http://127.0.0.1:3001/`

- [x] **Step 1: Provision datasource**

UID e.g. `monitoring-prometheus`, URL `http://prometheus:9090`, type `prometheus`.

- [x] **Step 2: Add minimal demo dashboard JSON**

Title distinct from Ignite Lab Overview (e.g. "Monitoring Playground").

- [x] **Step 3: Write Grafana compose**

Image `grafana/grafana:11.3.1`, port `127.0.0.1:3001:3000`, admin from env defaults, depends_on healthy Prometheus if using umbrella later; for standalone file, document that Prometheus must be up. Healthcheck `/api/health`.

- [ ] **Step 4: Verify login and datasource**

```bash
docker compose -f monitoring/grafana/docker-compose.yml up -d
curl -fsS http://127.0.0.1:3001/api/health
# login admin / playground default; confirm datasource health
```

- [ ] **Step 5: Commit**

```bash
git add monitoring/grafana monitoring/README.md
git commit -m "feat: add local monitoring Grafana playground"
```

---

### Task 3: Dynatrace folder (OTel Collector)

**Files:**
- Create: `monitoring/dynatrace/docker-compose.yml`
- Create: `monitoring/dynatrace/otel-collector-config.yml`
- Create: `monitoring/dynatrace/.env.example`
- Modify: `monitoring/README.md`

**Interfaces:**
- Consumes: optional `DT_ENDPOINT`, `DT_API_TOKEN`
- Produces: OTLP on `4317`/`4318`; healthy collector without tokens

- [x] **Step 1: Write collector config**

Receivers: OTLP. Exporters: logging (or debug) always; Dynatrace exporter only when documented env vars are present (use collector config pattern that works with empty optional export — if true conditional config is awkward, document two-file approach or envsubst; prefer one config that no-ops Dynatrace when token unset, or ship `otel-collector-config.yml` + `otel-collector-config.dynatrace.yml` and select via compose override).

Pick the simplest reliable pattern and document it in README.

- [x] **Step 2: Write compose**

Pinned `otel/opentelemetry-collector-contrib` image tag. Publish `127.0.0.1:4317:4317`, `127.0.0.1:4318:4318`. Join `monitoring-lab`.

- [x] **Step 3: `.env.example`**

```bash
# Optional — leave empty for local-only collector
DT_ENDPOINT=
DT_API_TOKEN=
```

- [ ] **Step 4: Verify start without tokens**

```bash
docker compose --env-file monitoring/dynatrace/.env.example \
  -f monitoring/dynatrace/docker-compose.yml up -d
docker compose -f monitoring/dynatrace/docker-compose.yml ps
```

- [ ] **Step 5: Commit**

```bash
git add monitoring/dynatrace monitoring/README.md
git commit -m "feat: add local OTel collector under monitoring/dynatrace"
```

---

### Task 4: Umbrella compose + scripts + root docs

**Files:**
- Create: `monitoring/docker-compose.yml`
- Create: `scripts/monitoring-up.sh`
- Create: `scripts/monitoring-down.sh`
- Modify: `README.md`
- Modify: `monitoring/README.md`

**Interfaces:**
- Consumes: tool compose files / includes
- Produces: one-command playground start/stop

- [x] **Step 1: Umbrella compose**

Use Compose `include:` (or equivalent) so one file brings up prometheus + grafana + dynatrace on `monitoring-lab`.

- [x] **Step 2: Scripts**

Mirror `ops-up` / `down-all` style: ensure network, `up -d`, print URLs/ports; down without wipe by default.

- [x] **Step 3: Root README pointer**

Short section: Ignite ops vs monitoring playground; link to `monitoring/README.md`.

- [ ] **Step 4: End-to-end local check**

```bash
./scripts/monitoring-up.sh
curl -fsS http://127.0.0.1:9091/-/ready
curl -fsS http://127.0.0.1:3001/api/health
# if ops running:
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:3000/api/health
./scripts/monitoring-down.sh
```

- [ ] **Step 5: Commit**

```bash
git add monitoring/docker-compose.yml scripts/monitoring-up.sh scripts/monitoring-down.sh README.md monitoring/README.md
git commit -m "feat: add monitoring playground umbrella and helper scripts"
```

---

### Task 5: Static CI for monitoring

**Files:**
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Consumes: monitoring compose + prometheus.yml
- Produces: PR failures on invalid compose/prom config

- [x] **Step 1: Add compose config checks**

```bash
docker compose -f monitoring/prometheus/docker-compose.yml config --quiet
docker compose -f monitoring/grafana/docker-compose.yml config --quiet
docker compose -f monitoring/dynatrace/docker-compose.yml config --quiet
docker compose -f monitoring/docker-compose.yml config --quiet
```

(Adjust env-file flags to match how compose expects `.env.example`.)

- [x] **Step 2: Add promtool check**

Same pattern as ops: `prom/prometheus:v2.55.1` with `--entrypoint promtool` against `monitoring/prometheus/prometheus.yml`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/validate.yml
git commit -m "ci: validate monitoring playground compose and Prometheus config"
```

---

### Task 6: Spec status + final verify

**Files:**
- Modify: `docs/superpowers/specs/2026-08-11-monitoring-playground-design.md` (status → implemented)

- [x] **Step 1: Mark design implemented**
- [ ] **Step 2: Re-run monitoring-up and URL checks**
- [ ] **Step 3: Confirm Ignite `scripts/smoke-test.sh` still works if ops+Ignite are up (optional but preferred)**
- [ ] **Step 4: Final commit if status/docs drifted**

## Implementation record

Implemented on 2026-08-11. All standalone Compose models, the umbrella model, the Dynatrace opt-in override, Bash syntax, dashboard JSON, workflow YAML, and whitespace checks pass locally. Runtime start/URL checks and commit steps remain unchecked because the local Docker daemon was intentionally left stopped; no Ignite or monitoring containers were started and no volumes were changed.
