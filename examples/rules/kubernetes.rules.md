# Repository rules — Kubernetes manifests and Helm charts

This repository holds Kubernetes manifests (plain YAML, Kustomize overlays and Helm charts) for workloads on a shared cluster. Review `.yaml`/`.yml` manifests, Helm templates and `values*.yaml` changes according to the rules below.

## Kubernetes rules

### Pod security

1. `privileged: true`, `hostNetwork`, `hostPID` or `hostIPC: true`, or adding capabilities such as `SYS_ADMIN` or `NET_ADMIN`, is CRITICAL unless the workload is clearly a node-level system component.
2. A `hostPath` volume that mounts `/`, `/etc`, `/var/run/docker.sock`, `/run/containerd` or another host runtime path is CRITICAL.
3. A container that can run as root (`runAsUser: 0`, or no `runAsNonRoot: true` at pod or container level) is WARNING. Not setting `allowPrivilegeEscalation: false`, or not dropping `ALL` capabilities, is WARNING.
4. `readOnlyRootFilesystem` not set is SUGGESTION.

### Secrets and access

1. A secret value in a `ConfigMap`, an `env` literal, a committed `Secret` (`data` or `stringData`), or `values*.yaml` is CRITICAL; use an external secret store (External Secrets, CSI driver, sealed secrets).
2. A `ClusterRoleBinding` to `cluster-admin`, or a `Role`/`ClusterRole` with `"*"` in `verbs`, `resources` or `apiGroups`, for an application service account is CRITICAL.
3. Granting `get`/`list`/`watch` on `secrets` cluster-wide, or `create` on `pods/exec`, to an application is WARNING.
4. `automountServiceAccountToken` left on for a workload that does not call the Kubernetes API is SUGGESTION.

### Exposure

1. A `Service` of type `LoadBalancer` or `NodePort`, or an `Ingress`, that exposes an admin, metrics, debug or database port publicly is CRITICAL.
2. An `Ingress` for an authenticated app without TLS is WARNING.
3. Removing or loosening a `NetworkPolicy` (an empty `podSelector` with allow-all ingress or egress) is WARNING.

### Reliability

1. A container without CPU and memory `requests`, or without a memory `limit`, is WARNING.
2. An image with the `latest` tag or no tag is WARNING; pin a version or digest.
3. A long-running workload without a `readinessProbe` is WARNING. A `livenessProbe` that checks downstream dependencies is SUGGESTION (it restarts pods when a dependency is down).
4. Changing a `spec.selector.matchLabels` key or value on an existing `Deployment` or `StatefulSet`, or a `StatefulSet`'s `volumeClaimTemplates`, is WARNING: these fields are immutable and the apply fails.
5. Removing `helm.sh/resource-policy: keep` from a `PersistentVolumeClaim`, or changing a `StorageClass` `reclaimPolicy` to `Delete` for data that matters, is CRITICAL.
6. A production `Deployment` with one replica and no `PodDisruptionBudget` is SUGGESTION.

### Helm templates

1. A value rendered into YAML without `quote` or `toYaml`/`nindent` where it can contain special characters is SUGGESTION.
2. A change made in one environment's values file but not the others, when it is clearly meant for all of them, is WARNING.

## Conventions to respect

`kubeconform`, `helm lint` and the cluster's policy engine run in CI; do not comment on formatting or schema errors they already report. Prefer the label, annotation and naming conventions already used in the repository.
