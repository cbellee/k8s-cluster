# Cilium upgrade and kube-proxy removal

## Summary

Completed on 19 November 2026 on `kube-cluster-01`:

1. Reviewed Cilium 1.19 and 1.20 compatibility and upgrade requirements.
2. Restored custom settings lost during the initial 1.18.3 to 1.18.15 upgrade.
3. Upgraded sequentially: **1.18.15 -> 1.18.17 -> 1.19.11 -> 1.20.5**.
4. Migrated LoadBalancer IP pool manifests to `cilium.io/v2`.
5. Updated the Terraform Cilium chart default to `1.20.5`.
6. Removed kube-proxy and cleaned its rules from all six nodes.

The operator reported successful application connectivity after each upgrade
and after kube-proxy removal. Subsequent read-only checks confirmed:

| Component | Final state |
| --- | --- |
| Helm release | `cilium`, namespace `kube-system`, revision 6 |
| Cilium chart, agents, operator and Hubble Relay | `1.20.5` |
| Cilium agents | 6/6 ready |
| Cilium Envoy | 6/6 ready, chart-selected image |
| Cilium operator | 2/2 ready |
| Hubble Relay and UI | Each 1/1 ready |
| Cluster pods managed by Cilium | 32/32 |
| kube-proxy DaemonSet and ConfigMap | Absent |
| Temporary preflight Helm release | Absent |

This is a record and runbook, not an instruction to rerun completed steps.
Commands below assume Bash and the repository root as the working directory.
Privileged cleanup affects cluster networking; use a maintenance window and
expect existing service connections to reset.

## Environment and compatibility assessment

- Three control-plane nodes: `kube-cp-01` through `kube-cp-03`.
- Three workers: `kube-wk-01` through `kube-wk-03`.
- Kubernetes `1.35.6`, Ubuntu 26.04, Linux 7.0 kernels.
- Direct Kubernetes API endpoint: `192.168.89.10:6443`.
- Cilium cluster-pool IPAM: `10.0.0.0/8`, per-node mask `/24`.
- LoadBalancer IP pool: `172.16.0.0/16`.
- BGP v2 resources peering with MikroTik at `192.168.89.1`.
- VXLAN tunneling and veth datapath.

Kubernetes 1.35 is listed as compatible with Cilium 1.19 and 1.20. The kernels
exceeded the documented base requirement.

The following potentially breaking changes were checked:

| Change | Assessment/action |
| --- | --- |
| Only consecutive minor upgrades are tested | Used the latest patch of each intermediate series available at the time |
| BGPv1 removal in 1.19 | Existing configuration used v2 BGP resources; no legacy `CiliumBGPPeeringPolicy` objects existed |
| LoadBalancer IP pool alpha API deprecated in 1.19 | Changed both repository manifests to `cilium.io/v2` |
| `fromRequires` / `toRequires` removed | No Cilium network policies existed |
| Kafka and custom proxylib L7 policy removal | No Cilium network policies existed |
| Alpha `CiliumNodeConfig` removal | No instances existed |
| Gateway API minimum version and TLSRoute migration | Cilium Gateway API disabled; Gateway API CRDs absent |
| ClusterMesh policy/certificate changes | ClusterMesh disabled |
| IPsec behavior changes | Encryption disabled |
| netkit/TPROXY incompatibility | veth datapath in use |
| 1.20 pod-to-NodePort load-balancing behavior | Relevant when socket LB is disabled or restricted to the host namespace; final replacement checks showed socket LB enabled |

These findings describe the cluster at migration time, not future workloads.
Reassess policy, Gateway API and encryption use before subsequent upgrades.

## Configuration recovery

The first upgrade, from 1.18.3 to 1.18.15, left only
`upgradeCompatibility: "1.18"` in Helm's user-supplied values. Read-only inspection
showed BGP, kube-proxy replacement, Hubble Relay/UI and custom metrics were no
longer enabled.

The saved [old-values.yaml](../../old-values.yaml) retained the original settings,
but also contained all the old chart defaults, including 1.18.3 image tags and
digests. Rendering the 1.19.11 and 1.20.5 charts with that file still selected
1.18.3 agents, operator and Hubble Relay. It was therefore not safe to reuse
unchanged. The backup was preserved.

The canonical
[Cilium values](../ansible/cilium/cilium-values.yaml) were reduced
to intentional settings:

- `upgradeCompatibility: "1.18"`, matching the original installation.
- BGP and kube-proxy replacement enabled.
- Explicit API server host/port, independent of ClusterIP service routing.
- Existing IPAM CIDR and allocation mask.
- Hubble, Relay, UI, OpenMetrics and the saved Hubble metrics list.
- Agent Prometheus metrics enabled.

Old image pins, removed options and the ineffective `reuse-values: true` YAML
entry were omitted. Chart versions now select matching component images.
Do not use Helm's `--reuse-values` across Cilium minor upgrades.

The minimal values rendered successfully against 1.18.15, 1.18.17, 1.19.11 and
1.20.5. Checks covered the selected component versions, BGP, replacement mode,
IPAM and Hubble deployments. The current-version render also verified the API
endpoint and metrics configuration.

Custom settings were restored on 1.18.15 before changing versions:

```bash
helm upgrade cilium cilium \
  --repo https://helm.cilium.io \
  --namespace kube-system \
  --version 1.18.15 \
  --reset-values \
  --values tf-k8s-cluster/ansible/cilium/cilium-values.yaml \
  --wait --timeout 10m
```

The API host is a single control-plane address, not an HA VIP. Keep it reachable
from every node and update the values if the endpoint changes. Preserve existing
IPAM allocations during upgrades; do not casually change the CIDR or node mask.

## Staged Cilium upgrades

### Preflight and upgrade procedure

The following procedure was used separately for each target, with validation
between stages:

| Stage | Target | Helm revision after upgrade |
| --- | --- | --- |
| Latest 1.18 patch | `1.18.17` | 4 |
| Intermediate minor | `1.19.11` | 5 |
| Final minor | `1.20.5` | 6 |

Revision 1 was the original 1.18.3 installation, revision 2 the initial 1.18.15
upgrade, and revision 3 restored the custom settings.

Set `TARGET` to one stage only; do not automate all stages without validation:

```bash
TARGET=1.18.17

helm install cilium-preflight cilium \
  --repo https://helm.cilium.io \
  --namespace kube-system \
  --version "$TARGET" \
  --set preflight.enabled=true \
  --set agent=false \
  --set operator.enabled=false \
  --set k8sServiceHost=192.168.89.10 \
  --set k8sServicePort=6443 \
  --wait --timeout 10m

kubectl -n kube-system get \
  daemonset/cilium-pre-flight-check \
  deployment/cilium-pre-flight-check
```

Require the preflight DaemonSet to be **6/6 ready** and the validation Deployment
**1/1 ready**. Stop and investigate any failure.

After successful preflight:

```bash
helm uninstall cilium-preflight --namespace kube-system &&
helm upgrade cilium cilium \
  --repo https://helm.cilium.io \
  --namespace kube-system \
  --version "$TARGET" \
  --reset-values \
  --values tf-k8s-cluster/ansible/cilium/cilium-values.yaml \
  --wait --timeout 10m

cilium status --wait
```

Check BGP sessions/routes and external application URLs after every stage.
`cilium bgp peers` was used during the earlier stages; in 1.20 the older BGP
inspection commands are deprecated in favor of the `bgp/*` Hive shell commands
accessed through `cilium shell`.

All Cilium components were healthy after each stage. kube-proxy remained running
throughout the upgrades; its removal was deliberately a separate operation.
Proxy-handled traffic can reset during upgrades even when pod readiness is good.

### LoadBalancer pool migration before 1.19

Changed only `apiVersion` from `cilium.io/v2alpha1` to `cilium.io/v2` in:

- [GitOps pool](../../gitops/platform/cilium-bgp/cilium-ip-pool.yaml).
- [Ansible pool template](../ansible/cilium/bgp/cilium-ip-pool.yaml.j2).

The pool name and CIDR were preserved; the pool was not deleted/recreated.
Server-side dry-run passed before application:

```bash
kubectl apply --dry-run=server \
  -f gitops/platform/cilium-bgp/cilium-ip-pool.yaml
kubectl apply -f gitops/platform/cilium-bgp/cilium-ip-pool.yaml
```

Keep the GitOps source change when committing/pushing so reconciliation does not
reintroduce the old API declaration.

### Terraform alignment

Updated `cilium_version` in
[variables.tf](../variables.tf) from `1.18.3` to `1.20.5`.
`terraform -chdir=tf-k8s-cluster validate -no-color` passed. No Terraform apply
was performed as part of this change.

## kube-proxy removal

### Prerequisites verified

After the final Cilium upgrade, every agent reported:

- `KubeProxyReplacement: True`.
- Socket LB enabled.
- ClusterIP, NodePort, LoadBalancer and HostPort support enabled.

This was checked on all six pods, not just one:

```bash
(
  set -euo pipefail
  for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    echo "$pod"
    kubectl -n kube-system exec "$pod" -- cilium-dbg status --verbose |
      grep -E '^KubeProxyReplacement:|Socket LB:|ClusterIP:|NodePort:|LoadBalancer:|HostPort:'
  done
)
```

kube-proxy was version `1.35.6`. Although its configuration had `mode: ""`,
logs confirmed it was using the **iptables** backend. Enabling Cilium replacement
had not automatically removed kube-proxy.

The operator ran the removal commands below and reported success. A later
read-only check confirmed both the kube-proxy DaemonSet and ConfigMap were absent,
with Cilium and Hubble still healthy.

### 1. Back up the DaemonSet and ConfigMap

This backup omits server-generated metadata/status and can be reapplied:

```bash
(
  set -euo pipefail
  umask 077
  kubectl -n kube-system get ds/kube-proxy cm/kube-proxy -o json |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
data["metadata"] = {}
for item in data["items"]:
    item.pop("status", None)
    item["metadata"] = {
        k: v for k, v in item["metadata"].items()
        if k in ("name", "namespace", "labels", "annotations")
    }
json.dump(data, sys.stdout, indent=2)
' > "$HOME/kube-proxy-backup-20261119.json"
)
```

Keep this backup. The commands were supplied for the operator to execute; the
backup's existence was not independently inspected.

Establish application connectivity before removal:

```bash
curl --fail --max-time 10 http://172.16.0.0/
curl --fail --max-time 10 http://192.168.89.20:31928/
```

These addresses were the blue colour server's LoadBalancer IP and a worker
NodePort at migration time.

### 2. Stop kube-proxy

```bash
kubectl -n kube-system delete daemonset kube-proxy --wait=true
kubectl -n kube-system wait --for=delete pod \
  -l k8s-app=kube-proxy --timeout=120s
```

### 3. Clean up rules on every node

Used the matching kube-proxy image's own `--cleanup` command in one-shot,
privileged, host-network Jobs. This avoids blanket flushing of host or Cilium
iptables rules. The Job definition passed server-side dry-run before use.

The image is deliberately pinned to the **removed kube-proxy version**, not the
Cilium version. Each Job must complete before proceeding to the next node.

```bash
(
  set -euo pipefail

  for node in kube-wk-01 kube-wk-02 kube-wk-03 kube-cp-01 kube-cp-02 kube-cp-03; do
    job="kube-proxy-cleanup-$node"

    kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: kube-system
spec:
  backoffLimit: 0
  template:
    spec:
      nodeName: $node
      hostNetwork: true
      dnsPolicy: Default
      restartPolicy: Never
      automountServiceAccountToken: false
      tolerations:
        - operator: Exists
      containers:
        - name: cleanup
          image: registry.k8s.io/kube-proxy:v1.35.6
          imagePullPolicy: IfNotPresent
          command: [/usr/local/bin/kube-proxy, --cleanup]
          securityContext:
            privileged: true
          volumeMounts:
            - {name: modules, mountPath: /lib/modules, readOnly: true}
            - {name: xtables, mountPath: /run/xtables.lock}
      volumes:
        - name: modules
          hostPath: {path: /lib/modules}
        - name: xtables
          hostPath: {path: /run/xtables.lock, type: FileOrCreate}
EOF

    if ! kubectl -n kube-system wait \
      --for=condition=complete "job/$job" --timeout=120s; then
      kubectl -n kube-system describe "job/$job"
      kubectl -n kube-system logs "job/$job"
      echo "Cleanup failed on $node; stop here." >&2
      exit 1
    fi

    kubectl -n kube-system logs "job/$job"
    kubectl -n kube-system delete "job/$job"
  done
)
```

Do not continue on a failed cleanup or substitute a blanket iptables flush.
Retain failed Jobs for investigation; successful temporary Jobs are deleted.

### 4. Validate and remove the ConfigMap

```bash
cilium status --wait
kubectl -n kube-system get pods -l k8s-app=kube-proxy

curl --fail --max-time 10 http://172.16.0.0/
curl --fail --max-time 10 http://192.168.89.20:31928/
```

Also check pod DNS, cross-node application traffic, BGP routes and normal
external application URLs. Healthy agent pods alone do not prove these paths.
After successful checks:

```bash
kubectl -n kube-system delete configmap kube-proxy
```

## Rollback

### Cilium

Inspect Helm history and roll back only one minor version at a time:

```bash
helm history cilium --namespace kube-system
# Example for this recorded history: 1.20.5 back to 1.19.11.
helm rollback cilium 5 --namespace kube-system --wait --timeout 10m
cilium status --wait
```

Recheck version-specific downgrade notes if new features have been used.
The history recorded here is specific to this operation; inspect current history
before choosing a revision. Do not roll directly from 1.20 to 1.18.

### kube-proxy

Stop any running cleanup Jobs before restoring kube-proxy so they cannot remove
rules while the restored proxy rebuilds them. Then restore the retained backup:

```bash
kubectl apply -f "$HOME/kube-proxy-backup-20261119.json"
kubectl -n kube-system rollout status ds/kube-proxy --timeout=5m
```

Restoring kube-proxy returns to coexistence with Cilium replacement; it does not
automatically disable Cilium's replacement. Expect connection resets and validate
connectivity again.

## Remaining follow-ups and caveats

- Update [bootstrap-cluster.yml](../ansible/playbooks/bootstrap-cluster.yml)
  to use `kubeadm init --skip-phases=addon/kube-proxy` for future cluster builds.
  This bootstrap change was **not** part of the completed migration.
- Review persisted kubeadm configuration before future Kubernetes upgrades.
  At inspection time it had `proxy: {}`. Do not assume deleting the DaemonSet
  alone prevents recreation; the ConfigMap was also removed as directed by the
  Cilium guide. Consider explicitly persisting `proxy.disabled: true` using the
  supported kubeadm configuration workflow.
- Preserve the minimal values, pool API migrations and Terraform default in
  version control. No Git commit was created during these activities.
- The direct API endpoint is not highly available; replacing it with an HA
  endpoint is a separate task.
- An SSH probe of `192.168.89.20` reported a changed host key. It was not bypassed
  or accepted. Cleanup used Kubernetes Jobs instead. Verify the host fingerprint
  through a trusted channel before changing SSH known-host entries.

## References

- [Cilium 1.18 upgrade guide](https://docs.cilium.io/en/v1.18/operations/upgrade/)
- [Cilium 1.19 upgrade guide](https://docs.cilium.io/en/v1.19/operations/upgrade/)
- [Cilium 1.20 upgrade guide](https://docs.cilium.io/en/v1.20/operations/upgrade/)
- [Kubernetes without kube-proxy](https://docs.cilium.io/en/v1.20/network/kubernetes/kubeproxy-free/)
- [Kubernetes compatibility](https://docs.cilium.io/en/v1.20/network/kubernetes/compatibility/)
- [kubeadm v1beta4 configuration](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/)
