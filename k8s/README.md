# Kubernetes

Two ways to run the Ignite 3 cluster on Kubernetes. Both describe the same
topology as [ignite3/docker-compose.yml](../ignite3/docker-compose.yml): three
nodes, static discovery, and the `rocksDbProfile` storage profile the examples
use.

| Path | Use it when |
|------|-------------|
| [helm/ignite-lab](../helm/ignite-lab) | You want to change replica count, memory, storage class, or resources without editing YAML |
| [k8s/ignite3](ignite3) | You want plain manifests to read or `kubectl apply` with no Helm involved |

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

## Reaching the cluster

Neither layout publishes a LoadBalancer. Port-forward instead:

```bash
kubectl -n ignite port-forward svc/ignite3 10300:10300 10800:10800
curl http://127.0.0.1:10300/management/v1/cluster/state
```

The Python and Java examples then work unchanged against `127.0.0.1:10800`.

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
- **No authentication is configured.** The Compose lab enables it through
  `ignite3-init.sh`; the chart does not. Enable it before exposing this
  anywhere real.
