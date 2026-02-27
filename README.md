# setup-rook-ceph-cluster

A GitHub Action that deploys a minimal [Rook](https://rook.io/) + Ceph cluster on Ubuntu GitHub runners using Minikube.

## Usage

```yaml
steps:
  - name: Setup Rook Ceph Cluster
    uses: iPraveenParihar/setup-rook-ceph-cluster@main
    with:
      rook-version: 'v1.17.4'
      ceph-image: 'quay.io/ceph/ceph:v20'

  - name: Run tests against the cluster
    run: |
      kubectl -n rook-ceph get pods
      make e2e-test
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `rook-version` | No | `v1.17.4` | Rook release tag to fetch manifests from. Also used as the default operator image tag. |
| `rook-image` | No | `docker.io/rook/ceph:<rook-version>` | Full Rook operator container image. Overrides the version-derived default. |
| `ceph-image` | No | `quay.io/ceph/ceph:v20` | Ceph daemon container image. |
| `ceph-csi-image` | No | `""` | Ceph CSI driver image override. If empty, uses Rook's bundled default. |
| `ceph-csi-operator-image` | No | `""` | CSI operator image override. If empty, uses the manifest default. |
| `kubernetes-version` | No | `v1.35.0` | Kubernetes version for Minikube. |
| `minikube-version` | No | `1.38.0` | Minikube version to install. |
| `cluster-namespace` | No | `rook-ceph` | Kubernetes namespace for the Ceph cluster. |

## Outputs

| Output | Description |
|--------|-------------|
| `cluster-namespace` | The namespace where the Ceph cluster was deployed. |
| `ceph-cluster-name` | The CephCluster CR name (`my-cluster`). |

## Examples

### Basic usage with defaults

```yaml
- uses: iPraveenParihar/setup-rook-ceph-cluster@main
```

### Testing a specific ceph-csi image

```yaml
- uses: iPraveenParihar/setup-rook-ceph-cluster@main
  with:
    rook-version: 'v1.17.4'
    ceph-image: 'quay.io/ceph/ceph:v20'
    ceph-csi-image: 'quay.io/cephcsi/cephcsi:canary'
```

### Testing a custom CSI operator image

```yaml
- name: Build CSI Operator Image
  run: make docker-build  # produces a local image

- uses: iPraveenParihar/setup-rook-ceph-cluster@main
  with:
    rook-version: 'v1.17.4'
    ceph-csi-operator-image: 'quay.io/cephcsi/ceph-csi-operator:local-build'
```

### Pinning specific versions

```yaml
- uses: iPraveenParihar/setup-rook-ceph-cluster@main
  with:
    rook-version: 'v1.17.4'
    rook-image: 'docker.io/rook/ceph:v1.17.4'
    ceph-image: 'quay.io/ceph/ceph:v19.2.3'
    kubernetes-version: 'v1.30.14'
```

## What it does

1. **Frees disk space** on the Ubuntu runner
2. **Installs cri-dockerd** (required for Minikube `none` driver)
3. **Sets up Minikube** with the `none` driver (k8s runs directly on the runner)
4. **Prepares a local disk** for OSD use (finds an extra block device or creates a 75GB iSCSI disk)
5. **Downloads Rook manifests** from `rook/rook` at the specified version tag
6. **Deploys the Rook operator**, CSI operator, CephCluster, and Ceph toolbox
7. **Waits for the cluster** to be healthy (monitors, OSDs, CSI pods, Ceph quorum)

## Requirements

- **Runner**: `ubuntu-22.04` (or later)
- **Disk**: The action needs at least one available block device. On standard GitHub runners, it will find or create one automatically.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
