# Redpanda Kubernetes Node Tuner

Automated node tuning solution for running Redpanda in Kubernetes production environments.

## Overview

This solution provides a **privileged DaemonSet** that automatically runs `rpk redpanda tune` and `rpk iotune` on Kubernetes nodes designated for Redpanda workloads. It eliminates the need for manual SSH access to nodes and scales automatically as your cluster grows.

### Key Features

- ✅ Fully automated node tuning on startup
- ✅ Idempotent design (safe to re-run)
- ✅ Automatic I/O benchmarking with iotune
- ✅ Results stored in ConfigMap for Redpanda pods
- ✅ Reboot warnings via Kubernetes Events (no auto-reboot)
- ✅ Production-ready with proper RBAC and security
- ✅ Works across cloud providers (GKE, EKS, AKS)

## Prerequisites

- Kubernetes cluster (version 1.20+)
- `kubectl` configured with cluster admin access
- Nodes designated for Redpanda workloads
- Ability to run privileged containers (required for kernel tuning)
- Container registry to host the tuner image

## Quick Start

### 1. Build and Push Container Image

```bash
# Build the container image
docker build -t your-registry/redpanda-tuner:latest .

# Push to your container registry
docker push your-registry/redpanda-tuner:latest
```

### 2. Update DaemonSet Image

Edit `daemonset.yaml` and replace `your-registry/redpanda-tuner:latest` with your actual image location:

```yaml
containers:
  - name: tuner
    image: your-registry/redpanda-tuner:latest  # Update this
```

### 3. Deploy the Tuner

```bash
# Create namespace and resources
kubectl apply -f namespace.yaml
kubectl apply -f rbac.yaml
kubectl apply -f configmap.yaml
kubectl apply -f daemonset.yaml
```

### 4. Label Nodes for Redpanda

```bash
# Label specific nodes where Redpanda will run
kubectl label nodes node-1 node-2 node-3 redpanda.com/node=true

# Or label all nodes in a node pool (GKE example)
kubectl label nodes -l cloud.google.com/gke-nodepool=redpanda-pool redpanda.com/node=true
```

### 5. Verify Tuning

```bash
# Check DaemonSet pods are running
kubectl get pods -n redpanda-system -l app=redpanda-tuner

# View logs from a tuner pod
kubectl logs -n redpanda-system -l app=redpanda-tuner --tail=100

# Check node annotations
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
TUNED:.metadata.annotations.redpanda\\.com/tuned,\
TIMESTAMP:.metadata.annotations.redpanda\\.com/tuned-timestamp

# Check for any reboot warnings
kubectl get events -n redpanda-system --field-selector reason=RebootRequired

# View iotune results
kubectl get configmap redpanda-iotune-results -n redpanda-system -o yaml
```

### 6. Deploy Redpanda

Once tuning is complete, deploy Redpanda to the tuned nodes:

```bash
helm install redpanda redpanda/redpanda \
  --set nodeSelector.redpanda\\.com/node=true
```

## Configuration

All configuration is managed via the `redpanda-tuner-config` ConfigMap. Edit `configmap.yaml` before deploying, or update the ConfigMap after deployment:

```bash
kubectl edit configmap redpanda-tuner-config -n redpanda-system
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `enable-tuning` | `true` | Enable/disable rpk tune (set to `false` for iotune only) |
| `enable-iotune` | `true` | Enable/disable iotune benchmarking |
| `iotune-duration` | `10m` | Duration for iotune benchmark (use 30m-60m for production) |
| `iotune-directory` | `/mnt/vectorized` | Directory to test (must be on Redpanda data disk) |
| `tuning-timeout` | `30m` | Timeout for entire tuning process |
| `force-retune` | `false` | Force re-tuning even if already completed |
| `log-level` | `info` | Logging level: debug, info, warn, error |
| `rpk-tune-extra-args` | `""` | Additional flags for rpk tune (e.g., `--cpu-set 0-3`) |

### Applying Configuration Changes

After updating the ConfigMap, restart the DaemonSet pods to apply changes:

```bash
kubectl rollout restart daemonset/redpanda-tuner -n redpanda-system
```

## Node Annotations

The tuner tracks state using node annotations:

| Annotation | Values | Description |
|------------|--------|-------------|
| `redpanda.com/node` | `true` | **User-set**: Designates node for Redpanda |
| `redpanda.com/tuned` | `true` | Tuning completed successfully |
| `redpanda.com/tuned-timestamp` | ISO 8601 | When tuning was performed |
| `redpanda.com/reboot-required` | `true` | Node reboot needed for full effect |
| `redpanda.com/iotune-completed` | `true` | iotune benchmark completed |
| `redpanda.com/iotune-timestamp` | ISO 8601 | When iotune was performed |

View annotations:

```bash
kubectl describe node <node-name> | grep redpanda.com/
```

## Troubleshooting

### Pods Not Starting

**Problem**: DaemonSet pods are not starting on labeled nodes.

**Solution**:
```bash
# Check pod status
kubectl get pods -n redpanda-system -o wide

# View pod events
kubectl describe pod -n redpanda-system <pod-name>

# Common issues:
# - Image pull errors: verify image registry and credentials
# - Node selector: ensure nodes have label redpanda.com/node=true
# - PodSecurityPolicy: may need to add exception for privileged pods
```

### Tuning Failures

**Problem**: Tuning is failing or timing out.

**Solution**:
```bash
# View detailed logs
kubectl logs -n redpanda-system <pod-name> -f

# Common issues:
# - Timeout: increase tuning-timeout in ConfigMap
# - Disk access: verify iotune-directory exists and has write permissions
# - Kernel restrictions: some managed K8s services restrict certain tuners
```

### Reboot Warnings

**Problem**: Node shows `redpanda.com/reboot-required=true` annotation.

**Solution**:
```bash
# Check which tuners require reboot
kubectl get events -n redpanda-system --field-selector reason=RebootRequired

# Schedule maintenance window and reboot nodes
# After reboot, verify tuning persists:
kubectl logs -n redpanda-system -l app=redpanda-tuner
```

### iotune Results Not Available

**Problem**: ConfigMap `redpanda-iotune-results` is empty or missing.

**Solution**:
```bash
# Check if iotune is enabled
kubectl get configmap redpanda-tuner-config -n redpanda-system -o yaml | grep enable-iotune

# Check iotune logs
kubectl logs -n redpanda-system <pod-name> | grep iotune

# Verify iotune directory
kubectl exec -n redpanda-system <pod-name> -- ls -la /mnt/vectorized
```

### Force Re-tuning

**Problem**: Need to re-run tuning after hardware or configuration changes.

**Solution**:
```bash
# Option 1: Update ConfigMap
kubectl patch configmap redpanda-tuner-config -n redpanda-system \
  -p '{"data":{"force-retune":"true"}}'

# Option 2: Remove node annotations
kubectl annotate node <node-name> \
  redpanda.com/tuned- \
  redpanda.com/iotune-completed-

# Restart DaemonSet pods
kubectl rollout restart daemonset/redpanda-tuner -n redpanda-system
```

## FAQ

### Do I need to tune every node?

Only tune nodes where Redpanda pods will run. Use node labels to designate these nodes:

```bash
kubectl label nodes <node-name> redpanda.com/node=true
```

### What tuners are applied?

The tuner runs `rpk redpanda tune all` which applies:
- Disk I/O scheduler optimization
- Network interface tuning
- CPU governor settings
- Memory management (swappiness, transparent hugepages)
- AIO event limits
- Clock source configuration

See [rpk redpanda tune documentation](https://docs.redpanda.com/current/reference/rpk/rpk-redpanda/rpk-redpanda-tune/) for details.

### Are tuning changes persistent across reboots?

Most kernel tuning changes are **not persistent** across reboots. Options:

1. **Recommended**: Keep DaemonSet running - it will re-tune nodes after reboot
2. Use cloud provider startup scripts to run tuning on boot
3. Bake tuning into custom node images

### Can I run this on managed Kubernetes services?

Yes, but some services restrict certain kernel parameters:

- **GKE**: Works with privileged pods enabled
- **EKS**: Works on most node types
- **AKS**: May require custom node pools with fewer restrictions

Some tuners may fail on managed services - check logs for warnings.

### How long does tuning take?

- **rpk tune**: ~1-2 minutes
- **iotune (10m)**: ~10-12 minutes
- **iotune (60m)**: ~60-65 minutes

Total time depends on iotune duration configuration.

### Can I tune nodes with zero downtime?

Yes! The DaemonSet tunes nodes without affecting running workloads:

1. Label nodes incrementally (one at a time)
2. Wait for tuning to complete
3. Deploy/migrate Redpanda pods to tuned nodes
4. Drain and tune remaining nodes

### What if some tuners fail?

The script continues even if some tuners fail. Check logs for warnings:

```bash
kubectl logs -n redpanda-system <pod-name> | grep -i "failed\|error"
```

Common failures on managed Kubernetes:
- Clock source tuner (may require specific kernel modules)
- Disk scheduler tuner (some cloud providers override settings)

These failures are usually non-critical for most workloads.

### How do I customize tuning for specific hardware?

Use `rpk-tune-extra-args` in ConfigMap:

```yaml
rpk-tune-extra-args: "--cpu-set 0-7 --nic eth1 --disks /dev/nvme0n1"
```

See `rpk redpanda tune --help` for available options.

### Can I use this with Helm?

This is a standalone deployment. To integrate with Redpanda Helm chart:

1. Deploy tuner before Redpanda chart
2. Or package as a subchart with `tuner.enabled` flag

Future enhancement: official Helm chart integration.

## Security Considerations

This DaemonSet requires **privileged access** to modify kernel parameters. Security measures:

1. **Isolated Namespace**: Runs in dedicated `redpanda-system` namespace
2. **Node Selectors**: Only runs on labeled nodes (limits blast radius)
3. **RBAC**: Minimal permissions (nodes, configmaps, events only)
4. **No Auto-Reboot**: Never reboots nodes automatically
5. **Read-Only Root**: Container filesystem is read-only except mounted volumes

### PodSecurityPolicy / PodSecurityStandards

If your cluster enforces PSP/PSS, you may need to:

1. Create a privileged PSP for `redpanda-system` namespace
2. Or exempt the namespace from PSS enforcement:

```bash
kubectl label namespace redpanda-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
```

## Cloud Provider Examples

See the `examples/` directory for cloud-specific configurations:

- **GKE**: `examples/gke.yaml` - Node pools and workload identity
- **EKS**: `examples/eks.yaml` - Node groups and instance types
- **Custom**: `examples/custom-config.yaml` - Advanced configuration

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for technical details about:

- How the tuner works
- DaemonSet workflow and lifecycle
- Security architecture
- Design decisions and trade-offs

## Support

For issues or questions:

1. Check logs: `kubectl logs -n redpanda-system -l app=redpanda-tuner`
2. Review [Troubleshooting](#troubleshooting) section
3. Consult [Redpanda documentation](https://docs.redpanda.com/)
4. Open an issue in the Redpanda repository

## License

Apache License 2.0
