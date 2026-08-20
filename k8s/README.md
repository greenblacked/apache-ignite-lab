# Kubernetes

Two ways to run the Ignite 3 cluster on Kubernetes. Both describe the same
topology as [ignite3/docker-compose.yml](../ignite3/docker-compose.yml): three
nodes, static discovery, and the `rocksDbProfile` storage profile the examples
use.

| Path | What it deploys |
|------|-----------------|
| [helm/ignite-lab](../helm/ignite-lab) | Ignite 3 StatefulSet, static discovery through a headless Service |
| [helm/ignite2](../helm/ignite2) | Ignite 2 StatefulSet using the Kubernetes IP finder, with the RBAC it needs |
| [helm/ignite-observability](../helm/ignite-observability) | Ignite REST exporter, Prometheus, and Grafana with the Ignite Lab Overview dashboard |
| [k8s/ignite3](ignite3) | Plain manifests to read or `kubectl apply` with no Helm involved |

Every chart ships `values-dev.yaml` (small, no persistence) and
`values-prod.yaml` (replicas, PVCs, anti-affinity, PDB).

The manifests in `k8s/ignite3/` are a rendered snapshot of the chart defaults,
so the two never drift. Regenerate them after changing the chart:

```bash
helm template ignite3 helm/ignite-lab \
  --set fullnameOverride=ignite3 \
  --set clusterInit.enabled=false
```

## Apply the raw manifests

```bash
kubectl create namespace ignite
kubectl -n ignite apply -f k8s/ignite3/
kubectl -n ignite rollout status statefulset/ignite3
```

The raw manifests deliberately omit the cluster-init job, so initialize once
the pods are running:

```bash
kubectl -n ignite exec -it ignite3-0 -- \
  /opt/ignite3cli/bin/ignite3 cluster init \
    --url http://localhost:10300 \
    --name=ignite3-lab \
    --metastorage-group=ignite3-0,ignite3-1,ignite3-2
```

Security is cluster configuration, not node configuration, so it is applied
after init. The manifests include a `Secret` holding the lab password; set the
password on the account first, then switch security on. Doing it in the other
order locks the account out:

```bash
PASSWORD=$(kubectl -n ignite get secret ignite3-auth \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl -n ignite exec -it ignite3-0 -- \
  /opt/ignite3cli/bin/ignite3 cluster config update --url http://localhost:10300 \
    "ignite.security.authentication.providers.default.users.ignite.password=\"$PASSWORD\""

kubectl -n ignite exec -it ignite3-0 -- \
  /opt/ignite3cli/bin/ignite3 cluster config update --url http://localhost:10300 \
    'ignite.security.enabled=true'
```

The chart's post-install job does exactly this; the raw manifests leave it to
you because they omit that job.

## Install the chart

```bash
helm install ignite3 helm/ignite-lab --namespace ignite --create-namespace
```

The chart runs `cluster init` for you as a post-install hook. Pick a profile
with `-f`:

```bash
helm install ignite3 helm/ignite-lab -f helm/ignite-lab/values-dev.yaml   # 1 node, no PVC
helm install ignite3 helm/ignite-lab -f helm/ignite-lab/values-prod.yaml  # 3 nodes, PVCs, PDB
```

### Authentication

`auth.enabled` is true by default, so the post-install job initializes the
cluster and then enables security for the built-in `ignite` user, matching what
`scripts/ignite3-init.sh` does for the Compose lab. The password comes from a
chart-managed `Secret` with the lab default in it. Replace it before anyone
else can reach the cluster:

```bash
# Your own password, stored in a chart-managed Secret.
helm install ignite3 helm/ignite-lab --set auth.password="$(openssl rand -base64 24)"

# Or a Secret you created out of band; it must hold a "password" key.
helm install ignite3 helm/ignite-lab --set auth.existingSecret=ignite3-credentials
```

Read the password back with:

```bash
kubectl -n ignite get secret ignite3-auth -o jsonpath='{.data.password}' | base64 -d
```

Keep `auth.user` as `ignite`: the bootstrap only sets a password on the
built-in account, exactly like the Compose lab. Setting `auth.enabled=false`
leaves the REST and client ports open to anything that can reach them.


## Ignite 2

Ignite 2 cannot use the static node list the Compose lab relies on, so the
chart switches discovery to `TcpDiscoveryKubernetesIpFinder`, which reads the
headless Service's Endpoints:

```bash
helm install ignite2 helm/ignite2 --namespace ignite --create-namespace
```

Specific to this chart:

- **`ignite-kubernetes` is added to `OPTION_LIBS`** — the IP finder lives in
  that optional module and the node will not start without it.
- **RBAC is created by default** — a ServiceAccount plus a Role granting
  `get/list/watch` on `endpoints`, which is the only API access Ignite needs.
- **The headless Service sets `publishNotReadyAddresses`** — the IP finder's
  `includeNotReadyAddresses` is not a JavaBean setter and cannot be set from
  Spring XML. Without the Service flag, pods starting in parallel would see no
  peers and each would form its own cluster.
- **A post-install job runs `control.sh --set-state ACTIVE`** — a persistent
  Ignite 2 cluster stays INACTIVE until activated once.
- **`maxSize` is rendered with `int64`** — Helm turns large integers into
  float64, and Ignite rejects `2.68435456e+08` with a `NumberFormatException`.

The image defaults to `apacheignite/ignite:2.18.0` (linux/amd64). On Apple
Silicon set `image.tag=2.18.0-arm64`.

## Observability

```bash
helm install obs helm/ignite-observability --namespace ignite
kubectl -n ignite port-forward svc/obs-ignite-observability-grafana 3000:3000
```

The exporter has **no public image** — build and push it first, then point the
chart at it:

```bash
docker build -t <registry>/ignite-exporter:1.0.0 ops/exporter
docker push  <registry>/ignite-exporter:1.0.0
helm install obs helm/ignite-observability \
  --set exporter.image.repository=<registry>/ignite-exporter
```

The chart polls the Ignite pods over REST exactly as the Compose `ops/` stack
does, and provisions the same **Ignite Lab Overview** dashboard and the same
Prometheus alert rules. Both are copied into the chart because Helm cannot read
files outside a chart directory; CI fails if either copy drifts from
`ops/grafana/dashboards/` or `ops/prometheus/rules/`. Disable the rules with
`--set prometheus.alertRules.enabled=false`. As in the Compose lab there is no
Alertmanager, so firing alerts are visible on Prometheus' `/alerts` page and
through the Grafana datasource.

Defaults assume the Ignite releases are named `ignite2` and `ignite3` in the
same namespace. Override `ignite2.endpoints` / `ignite3.endpoints` otherwise.

## Reaching the cluster

Neither layout publishes a LoadBalancer. Port-forward instead:

```bash
kubectl -n ignite port-forward svc/ignite3 10300:10300 10800:10800
curl -u ignite:<password> http://127.0.0.1:10300/management/v1/cluster/state
```

The Python and Java examples then work unchanged against `127.0.0.1:10800`, as
long as `IGNITE_LAB_USER` and `IGNITE_LAB_PASSWORD` match the cluster's
credentials.

## Design notes

- **Headless Service with `publishNotReadyAddresses: true`** — peers must
  resolve each other *before* they are Ready, or the cluster can never form.
- **`podManagementPolicy: Parallel`** — nodes discover each other at startup, so
  starting them one at a time only delays the first quorum.
- **Init container copies the node config** — Ignite 3 merges defaults back into
  its config file at startup, and a ConfigMap mount is always read-only. Mounting
  the ConfigMap directly produces
  `NodeConfigWriteException: IGN-NODECFG-3 The configuration file is read-only`.
  The init container copies it to an emptyDir and `IGNITE_CONFIG_PATH` points
  there, which makes the ConfigMap the declarative source of truth.
- **`--node-name $(POD_NAME)`** — kubelet expands `$(POD_NAME)`, so each node
  registers under its stable pod name and the metastorage group is predictable.
- **Security is applied after `cluster init`, not in the node config.** Ignite
  3 keeps authentication in cluster configuration, so a node ConfigMap cannot
  carry it. The post-install job sets the account password first and only then
  sets `ignite.security.enabled=true`; the reverse order locks the account out.
- **The init job stores its credentials in the CLI profile.** Only
  `connect` takes `--username`/`--password`; commands invoked with `--url` read
  `ignite.auth.basic.*` from the CLI config instead. Setting them once means
  the same commands work before and after security is switched on, which is
  what makes the job re-runnable.
