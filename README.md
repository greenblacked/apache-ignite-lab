# Apache Ignite Practice Lab

[![CI](https://github.com/greenblacked/apache-ignite-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/greenblacked/apache-ignite-lab/actions/workflows/ci.yml)

Local, production-shaped Docker Compose lab for **Ignite 2.18** and **Ignite 3.1** on Apple Silicon: 3-node clusters, persistence, auth, Prometheus/Grafana, helper scripts, and starter clients.

## Prerequisites

- Docker Desktop or OrbStack with Docker Compose v2+
- ~8+ GB free RAM if running both stacks + ops
- Bash and `curl` for helper scripts; Python 3 for the full smoke test
- Optional: CPython 3.10–3.13, JDK 17+, Maven 3.8.6+ (for examples)

## Quick start

```bash
cp .env.example .env
chmod 600 .env
./scripts/network-up.sh

# Ignite 2
./scripts/ignite2-up.sh

# Ignite 3
./scripts/ignite3-up.sh
./scripts/ignite3-init.sh   # initialize/enable auth when needed; safe to rerun

# Observability
./scripts/ops-up.sh
```

Run either versioned stack independently, or execute both `*-up.sh` scripts to run them together.

After both Ignite stacks and observability are running, execute the read-only acceptance checks:

```bash
./scripts/smoke-test.sh
```

The smoke test verifies all six nodes, both cluster states, Ignite 2 SQL, exported Prometheus metrics, and the Grafana datasource/dashboard. It exits nonzero on the first failed check.

Stop (keep data): `./scripts/down-all.sh`  
Wipe volumes: `./scripts/down-all.sh --wipe`

## Ports

| Stack | Service | Host ports |
|-------|---------|------------|
| Ignite 2 | Thin client | 10800–10802 |
| Ignite 2 | REST | 8080–8082 |
| Ignite 3 | REST / management | 10300–10302 |
| Ignite 3 | Client | 10810–10812 |
| Ops | Prometheus | 9090 |
| Ops | Grafana | 3000 |
| Monitoring playground | Prometheus | 9091 |
| Monitoring playground | Grafana | 3001 |

All published ports bind to `127.0.0.1`; they are not exposed on every host interface.

### Access URLs

| Service | Use this (reliable) | Optional OrbStack |
|---------|---------------------|-------------------|
| Grafana | http://127.0.0.1:3000/ | https://grafana.ops.orb.local/ |
| Prometheus | http://127.0.0.1:9090/ | https://prometheus.ops.orb.local/ |

Prefer **localhost ports**. OrbStack `*.orb.local` domains often fail in Chrome/Edge when:
- **Local Network** permission is off: System Settings → Privacy & Security → Local Network → enable your browser (and its “Helper (GPU)” entry)
- **Secure DNS / DoH** is on: Chrome → Settings → Privacy and security → Security → Use secure DNS → Off
- Corporate VPN / MagicDNS overrides `.local` resolution

Also enable OrbStack → Settings → Network → **Allow access to container domains & IPs**.

DNS names on Docker network `ignite-lab`: `ignite2-node1..3`, `ignite3-node1..3`.

## Credentials

| Stack | Default |
|-------|---------|
| Ignite 2 | `ignite` / `IGNITE2_PASSWORD` from `.env` (fresh cluster: `ignite`) |
| Ignite 3 | `ignite` / `IGNITE_LAB_PASSWORD` from `.env` (`ignite-lab-pass`) |
| Grafana | `GF_SECURITY_ADMIN_*` from `.env` |

Keep `IGNITE_LAB_USER=ignite`; the bootstrap helpers support the built-in user only. Change the Ignite 3 and Grafana defaults before their first start. Updating a password in `.env` does not rotate an already-persisted cluster credential or Grafana admin account.

Ignite 3 REST check:

```bash
set -a; source .env; set +a
curl -u "${IGNITE_LAB_USER}:${IGNITE_LAB_PASSWORD}" \
  http://127.0.0.1:10300/management/v1/cluster/state
```

Ignite 3 CLI:

```bash
./scripts/ignite3-cli.sh
# then: connect http://ignite3-node1:10300 -u ignite -p <IGNITE_LAB_PASSWORD from .env>
```

## Persistence

- Named Docker volumes per node survive `restart` and `down` (without `-v`)
- Ignite 2 requires cluster activation after first start (`ignite2-up.sh` does this)
- Ignite 3 requires `cluster init` after fresh or wiped volumes; `ignite3-init.sh` is idempotent

## Observability

`ops-up.sh` rebuilds and recreates the observability containers while preserving their named volumes. The internal exporter converts authenticated Ignite REST health and topology responses into Prometheus metrics; it is not published on a host port.

Grafana provisions the **Ignite Lab Overview** dashboard with node health, cluster membership, versions, collection duration, and collection errors. If a panel is empty after startup, run `./scripts/smoke-test.sh`; it checks the exporter, Prometheus target, Grafana datasource, provisioned dashboard, and loaded alert rules without changing cluster data.

### Alerts

Prometheus loads the rules in [ops/prometheus/rules/](ops/prometheus/rules) over the exporter's metrics: exporter down or failing, either cluster not ready, a node missing from the topology, and unreachable or unhealthy nodes. Firing alerts appear at http://127.0.0.1:9090/alerts.

The lab ships no Alertmanager, so nothing is paged or emailed. Add a receiver when you want to practise notification routing. The `for` windows are short (1-2 minutes) so that killing a node shows an alert inside one exercise.

## Independent monitoring playground

The separate [monitoring playground](monitoring/README.md) runs Prometheus and Grafana without Ignite. It uses the `monitoring-lab` network and ports 9091/3001, so it can run beside the Ignite-coupled `ops/` stack on 9090/3000.

```bash
./scripts/monitoring-up.sh
./scripts/monitoring-down.sh
```

## Examples

See [examples/README.md](examples/README.md).

## Practice checklist

1. Start Ignite 2; run the read-only SQL check: `./scripts/ignite2-sql.sh`
2. Run the Ignite 2 Python example. It cleans up its values; use a separate practice key when testing persistence across `docker compose restart`
3. Start Ignite 3; init; enable auth; `cluster status`
4. Run the Ignite 3 Python or Java example to create a RocksDB zone/table and verify write/read behavior
5. Start ops; open Prometheus targets and Grafana dashboard **Ignite Lab Overview**
6. Kill one node container; observe cluster behavior; watch `IgniteNodeDown` and `IgniteClusterNodeMissing` at http://127.0.0.1:9090/alerts; bring it back

`./scripts/failure-drill.sh` automates step 6 end to end: it stops a node, waits for `IgniteNodeDown` to fire, restarts it, and checks the alert clears. Preview it with `--dry-run` first. It restores the node through a trap, so interrupting it never leaves the lab a node short.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to `master`, on pull requests, and on manual dispatch.

| Job | What it checks |
|-----|----------------|
| Static checks | `shellcheck` over `scripts/*.sh`; `docker compose config` for every Compose file; `promtool` over both Prometheus configs and the alert rules; JSON validation of both Grafana dashboards; a build of the exporter image |
| Python 3.10–3.13 | Mocked example tests and the exporter unit tests; no cluster or Ignite client packages needed |
| Java examples | `mvn verify` for both modules on Temurin 17 (`exec:java` is skipped because it needs a live cluster) |
| Lab smoke test | Boots Ignite 2, Ignite 3, and `ops/` on the runner, then runs `./scripts/smoke-test.sh` and tears the stacks down |
| Helm and manifests | `helm lint` and `helm template` for all three charts across every values file, `kubeconform` schema validation of the rendered output and `k8s/`, and drift checks on the raw manifests, the copied Grafana dashboard, and the copied alert rules |

The smoke-test job overrides `IGNITE2_IMAGE`/`IGNITE3_IMAGE` because GitHub runners are x86_64 while `.env` pins arm64 images for Apple Silicon. It supplies the lab defaults through job `env`, since `.env` is gitignored and absent in CI. Python 3.10 is the floor: `ops/exporter/exporter.py` evaluates a PEP 604 union at import time.

## Kubernetes

[k8s/README.md](k8s/README.md) covers running the lab on Kubernetes. Three
charts, each with `values-dev.yaml` and `values-prod.yaml` examples:

| Chart | Deploys |
|-------|---------|
| [helm/ignite-lab](helm/ignite-lab) | Ignite 3, static discovery via headless Service, authentication enabled by a post-install job |
| [helm/ignite2](helm/ignite2) | Ignite 2, Kubernetes IP finder plus RBAC |
| [helm/ignite-observability](helm/ignite-observability) | Exporter, Prometheus, Grafana with the Ignite Lab Overview dashboard |

Plain manifests for Ignite 3 live in [k8s/ignite3](k8s/ignite3) for use without
Helm.

```bash
helm install ignite3 helm/ignite-lab --namespace ignite --create-namespace
kubectl -n ignite port-forward svc/ignite3 10300:10300 10800:10800
```

Like the Compose lab, the Ignite 3 chart enables authentication for the built-in `ignite` user and ships a default lab password. Override it with `--set auth.password=...` or `--set auth.existingSecret=...` before the cluster is reachable by anyone else; see [k8s/README.md](k8s/README.md#authentication).

## Production parallels vs lab simplifications

| Production-like | Simplified for laptop |
|-----------------|------------------------|
| Multi-node discovery, persistence, auth, resource limits, healthchecks, restart policy | Single-host Docker network, self-contained lab passwords |
| Prometheus-format lab health/topology metrics, alert rules on them | A lightweight exporter polls authenticated Ignite REST APIs; it is not the full Ignite metrics catalog, and no Alertmanager routes the alerts |
| Separate stacks / unique DNS | No K8s, no mutual TLS PKI, no WAN/replication |

Optional TLS helper stub: `scripts/gen-certs.sh` (self-signed only; wire into clients when you are ready).

## License

[Apache-2.0](LICENSE), matching Apache Ignite itself.

## Troubleshooting

- **Apple Silicon:** use `apacheignite/ignite:2.18.0-arm64` (set in `.env`)
- **Ignite 2 REST missing `ignite-json`:** `OPTION_LIBS` must include `ignite-rest-http,ignite-json`
- **Ignite 3 stuck STARTING:** run `./scripts/ignite3-init.sh`
- **Port conflicts:** stop other local Ignite/Grafana/Prometheus or change published ports in compose files
- **Both stacks together:** always use `ignite2-node*` / `ignite3-node*` names (already configured)
