# Monitoring Playground

This stack is an independent local playground for Prometheus, Grafana, and OpenTelemetry. It does not require Ignite, does not join `ignite-lab`, and can run alongside the Ignite `ops/` stack.

## Ports and credentials

| Service | Local address | Default login |
|---------|---------------|---------------|
| Prometheus | http://127.0.0.1:9091/ | none |
| Grafana | http://127.0.0.1:3001/ | `admin` / `playground` |
| OTLP/gRPC | `127.0.0.1:4317` | none |
| OTLP/HTTP | `http://127.0.0.1:4318/` | none |

All published ports bind to localhost. Change the Grafana defaults with `MONITORING_GF_ADMIN_USER` and `MONITORING_GF_ADMIN_PASSWORD` before the first start; a persisted Grafana volume keeps the original admin credential.

## Start and stop everything

```bash
./scripts/monitoring-up.sh
./scripts/monitoring-down.sh          # keep Prometheus and Grafana data
./scripts/monitoring-down.sh --wipe   # delete playground volumes
```

The up script creates the external `monitoring-lab` network, starts all three services, waits for their health checks, and prints the local URLs. Override the network name with `MONITORING_LAB_NETWORK` if needed.

Do not run the umbrella and per-tool projects at the same time: they publish the same host ports and use separate Compose project volumes.

## Run tools independently

Create the shared network once:

```bash
docker network inspect monitoring-lab >/dev/null 2>&1 || docker network create monitoring-lab
```

Prometheus scrapes only itself; it has no Ignite targets:

```bash
docker compose -f monitoring/prometheus/docker-compose.yml up -d
curl -fsS http://127.0.0.1:9091/-/ready
```

Start Prometheus before standalone Grafana so the provisioned `Monitoring Prometheus` datasource at `http://prometheus:9090` can resolve. Grafana provisions the **Monitoring Playground** dashboard automatically.

```bash
docker compose -f monitoring/grafana/docker-compose.yml up -d
curl -fsS http://127.0.0.1:3001/api/health
```

The collector accepts traces, metrics, and logs over OTLP and writes a compact debug representation to its logs. It starts without Dynatrace credentials:

```bash
docker compose -f monitoring/dynatrace/docker-compose.yml up -d
docker compose -f monitoring/dynatrace/docker-compose.yml ps
```

## Optional Dynatrace SaaS export

The base collector is deliberately token-free. To send all three signal types to Dynatrace, copy the placeholder file, set a Dynatrace OTLP base endpoint ending in `/api/v2/otlp`, and add a scoped API token:

```bash
cp monitoring/dynatrace/.env.example monitoring/dynatrace/.env
chmod 600 monitoring/dynatrace/.env

docker compose \
  --env-file monitoring/dynatrace/.env \
  -f monitoring/dynatrace/docker-compose.yml \
  -f monitoring/dynatrace/docker-compose.dynatrace.yml \
  up -d
```

The token needs the Dynatrace scopes for the signals you send: `openTelemetryTrace.ingest`, `metrics.ingest`, and `logs.ingest`. The override refuses to render when either variable is missing, which prevents an accidentally half-configured exporter.

Stop the optional-export project with the same two compose files and `down`.

## Relationship to Ignite observability

| Playground | Network | Prometheus | Grafana | Data source |
|------------|---------|------------|---------|-------------|
| This directory | `monitoring-lab` | 9091 | 3001 | Prometheus self-metrics |
| Ignite `ops/` | `ignite-lab` | 9090 | 3000 | Ignite REST exporter |

Neither stack changes or depends on the other.

