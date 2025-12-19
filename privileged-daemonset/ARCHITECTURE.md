# Architecture: Redpanda Kubernetes Node Tuner

Technical deep dive into the design, implementation, and operation of the Redpanda Kubernetes Node Tuner.

## Table of Contents

1. [Overview](#overview)
2. [Architecture Diagram](#architecture-diagram)
3. [Component Details](#component-details)
4. [Workflow and Lifecycle](#workflow-and-lifecycle)
5. [Security Architecture](#security-architecture)
6. [Design Decisions](#design-decisions)
7. [Trade-offs and Limitations](#trade-offs-and-limitations)
8. [Future Enhancements](#future-enhancements)

## Overview

The Redpanda Kubernetes Node Tuner is a **privileged DaemonSet** that automates the execution of `rpk redpanda tune` and `rpk iotune` on Kubernetes nodes. It solves the operational challenge of preparing nodes for production Redpanda deployments without requiring manual SSH access or custom node images.

### Design Goals

1. **Zero Manual Intervention**: Fully automated tuning without SSH access
2. **Idempotent**: Safe to run multiple times, won't duplicate work
3. **Cloud-Agnostic**: Works across GKE, EKS, AKS, and bare-metal
4. **Production-Ready**: Proper error handling, logging, and observability
5. **Secure**: Minimal privileges, isolated to designated nodes
6. **Scalable**: Automatically tunes new nodes as cluster grows

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                          │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    redpanda-system namespace                  │ │
│  │                                                               │ │
│  │  ┌────────────────┐          ┌─────────────────────────┐    │ │
│  │  │   ConfigMap    │          │    DaemonSet            │    │ │
│  │  │ tuner-config   │─────────▶│  redpanda-tuner         │    │ │
│  │  └────────────────┘          │                         │    │ │
│  │                              │  Runs on labeled nodes  │    │ │
│  │  ┌────────────────┐          │  nodeSelector:          │    │ │
│  │  │   ConfigMap    │◀─────────│   redpanda.com/node=true│    │ │
│  │  │ iotune-results │          └─────────────────────────┘    │ │
│  │  │                │                      │                   │ │
│  │  │ Contains:      │                      │                   │ │
│  │  │ - node-1.yaml  │                      ▼                   │ │
│  │  │ - node-2.yaml  │          ┌───────────────────────┐      │ │
│  │  │ - node-3.yaml  │          │   Tuner Pod (node-1)  │      │ │
│  │  └────────────────┘          │                       │      │ │
│  │                              │  1. Check annotations │      │ │
│  │  ┌────────────────┐          │  2. Run iotune        │      │ │
│  │  │ ServiceAccount │          │  3. Run rpk tune      │      │ │
│  │  │ RBAC Resources │          │  4. Annotate node     │      │ │
│  │  │                │          │  5. Create events     │      │ │
│  │  │ Permissions:   │          │  6. Sleep (logs)      │      │ │
│  │  │ - nodes        │          └───────────────────────┘      │ │
│  │  │ - configmaps   │                      │                   │ │
│  │  │ - events       │                      │                   │ │
│  │  └────────────────┘                      │                   │ │
│  └───────────────────────────────────────────┼───────────────────┘ │
│                                              │                     │
│  ┌───────────────────────────────────────────▼──────────────────┐  │
│  │                    Kubernetes Node (node-1)                  │  │
│  │                                                              │  │
│  │  Node Annotations:                                          │  │
│  │  - redpanda.com/node: "true" (user-set)                     │  │
│  │  - redpanda.com/tuned: "true" (tuner-set)                   │  │
│  │  - redpanda.com/tuned-timestamp: "2025-01-15T..."           │  │
│  │  - redpanda.com/iotune-completed: "true"                    │  │
│  │  - redpanda.com/reboot-required: "true" (if needed)         │  │
│  │                                                              │  │
│  │  ┌────────────────────────────────────────────────────────┐ │  │
│  │  │              Tuner Container (Privileged)              │ │  │
│  │  │                                                        │ │  │
│  │  │  Host Mounts:                                         │ │  │
│  │  │  - /host → node root filesystem                       │ │  │
│  │  │  - /dev → device files                                │ │  │
│  │  │  - /sys → sysfs                                       │ │  │
│  │  │  - /proc → process info                               │ │  │
│  │  │                                                        │ │  │
│  │  │  Host Namespaces: Network, PID, IPC                   │ │  │
│  │  │                                                        │ │  │
│  │  │  ┌──────────────────────────────────────────────┐    │ │  │
│  │  │  │  tune.sh (main script)                       │    │ │  │
│  │  │  │  ├─ Check if already tuned (annotations)     │    │ │  │
│  │  │  │  ├─ Run rpk iotune (10-60 min)               │    │ │  │
│  │  │  │  │  └─ Store results in ConfigMap            │    │ │  │
│  │  │  │  ├─ Run rpk redpanda tune all                │    │ │  │
│  │  │  │  │  ├─ Disk I/O scheduler                    │    │ │  │
│  │  │  │  │  ├─ Network tuning                        │    │ │  │
│  │  │  │  │  ├─ CPU governor                          │    │ │  │
│  │  │  │  │  ├─ Memory (swappiness, THP)              │    │ │  │
│  │  │  │  │  └─ Check for reboot requirements         │    │ │  │
│  │  │  │  ├─ Annotate node (success/failure)          │    │ │  │
│  │  │  │  ├─ Create K8s Events                        │    │ │  │
│  │  │  │  └─ Sleep (keep logs accessible)             │    │ │  │
│  │  │  └──────────────────────────────────────────────┘    │ │  │
│  │  └────────────────────────────────────────────────────────┘ │  │
│  │                                                              │  │
│  │  Kernel Modifications:                                       │  │
│  │  - /sys/block/*/queue/scheduler → noop/none                 │  │
│  │  - /proc/sys/vm/swappiness → 1                              │  │
│  │  - /sys/kernel/mm/transparent_hugepage/enabled → never      │  │
│  │  - /proc/sys/fs/aio-max-nr → increased                      │  │
│  │  - /sys/devices/system/cpu/cpu*/cpufreq/governor → perf     │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. DaemonSet (daemonset.yaml)

**Purpose**: Ensures one tuner pod runs on each labeled node.

**Key Configuration**:
- **Node Selector**: `redpanda.com/node=true` - only runs on labeled nodes
- **Host Namespaces**: Uses host network, PID, and IPC namespaces
- **Privileged**: Required for kernel parameter modifications
- **Update Strategy**: RollingUpdate with maxUnavailable=1

**Volume Mounts**:
- `/host` - Node root filesystem (for file operations)
- `/dev` - Device files (for disk operations)
- `/sys` - Sysfs (for kernel parameter tuning)
- `/proc` - Process information (for system introspection)
- `/mnt/vectorized` - Redpanda data directory (for iotune)

### 2. Tuner Scripts

#### tune.sh (Main Script)

**Responsibilities**:
1. Load configuration from environment (ConfigMap)
2. Check node annotations for idempotency
3. Execute iotune benchmark
4. Execute rpk redpanda tune
5. Handle errors and timeouts
6. Report status via annotations and events
7. Keep container alive for log access

**Error Handling**:
- Timeouts: Configurable via `TUNING_TIMEOUT`
- Retries: Automatic retry on pod restart (if not annotated as tuned)
- Partial failures: Continues even if some tuners fail

#### tune-lib.sh (Helper Library)

**Provides**:
- Logging functions (debug, info, warn, error)
- Kubernetes API wrappers (annotations, ConfigMaps, events)
- Node status checks (is_node_tuned, is_iotune_completed)
- Utility functions (command_exists, exec_on_host)

### 3. RBAC Resources (rbac.yaml)

**ServiceAccount**: `redpanda-tuner`

**ClusterRole Permissions**:
```yaml
- nodes: [get, list, patch]        # Read nodes, write annotations
- configmaps: [get, list, create, update, patch]  # Store iotune results
- events: [create, patch]          # Status reporting
```

**Security Principle**: Minimal necessary permissions. No access to pods, secrets, or other sensitive resources.

### 4. ConfigMap: tuner-config

**Purpose**: Configuration without rebuilding container image.

**Key Settings**:
- `enable-tuning` / `enable-iotune`: Toggle features
- `iotune-duration`: Balance accuracy vs. time
- `iotune-directory`: Must match Redpanda data volume
- `force-retune`: Override idempotency for testing

### 5. ConfigMap: iotune-results

**Purpose**: Store and share iotune benchmarking results.

**Structure**:
```yaml
data:
  node-1.yaml: |
    # rpk iotune output
    disks:
      - mountpoint: /mnt/vectorized
        read_iops: 50000
        write_iops: 40000
        ...
```

**Consumption**: Redpanda pods can mount this ConfigMap to use optimal I/O settings.

## Workflow and Lifecycle

### Initial Deployment

```
1. Admin applies manifests
   └─▶ Namespace, RBAC, ConfigMaps, DaemonSet created

2. Admin labels nodes
   └─▶ DaemonSet scheduler places pods on labeled nodes

3. Tuner pod starts
   ├─▶ Check annotations (not tuned)
   ├─▶ Run iotune (10-60 min)
   │   └─▶ Store results in ConfigMap
   ├─▶ Run rpk tune all (1-2 min)
   │   ├─▶ Apply all tuners
   │   └─▶ Check for reboot requirements
   ├─▶ Annotate node (tuned=true, timestamp)
   └─▶ Sleep (keep logs accessible)

4. Node is ready for Redpanda
```

### Node Reboot Scenario

```
1. Node reboots (maintenance, crash, etc.)
   └─▶ Tuning changes may be lost

2. Kubelet restarts tuner pod
   ├─▶ Check annotations (tuned=true)
   └─▶ Skip tuning, enter sleep mode

Note: Tuning changes are typically not persistent across reboots.
The annotation prevents re-running, which is suboptimal.
Workaround: Use force-retune=true to re-tune after reboot.
```

### Adding New Nodes

```
1. Admin adds nodes to cluster
2. Admin labels new nodes (redpanda.com/node=true)
3. DaemonSet automatically schedules pod on new node
4. Tuner runs through full workflow
5. New node ready for Redpanda
```

### Configuration Changes

```
1. Admin updates ConfigMap (e.g., increase iotune-duration)
2. Admin restarts DaemonSet pods
   └─▶ kubectl rollout restart daemonset/redpanda-tuner -n redpanda-system
3. Pods restart with new configuration
4. If force-retune=false, skip already-tuned nodes
5. If force-retune=true, re-tune all nodes
```

## Security Architecture

### Threat Model

**Assumptions**:
- Attacker has access to Kubernetes API (authenticated user)
- Attacker may attempt to escalate privileges via tuner
- Nodes may run untrusted workloads

**Mitigations**:

1. **Namespace Isolation**
   - Dedicated `redpanda-system` namespace
   - Separate from application workloads
   - Can be monitored independently

2. **Node Selector Restriction**
   - Only runs on explicitly labeled nodes
   - Limits blast radius to Redpanda nodes
   - Prevents cluster-wide deployment

3. **Minimal RBAC**
   - No access to secrets, pods, or deployments
   - Can only modify nodes, configmaps, and events
   - Cannot create new pods or escalate privileges

4. **No Auto-Reboot**
   - Never reboots nodes automatically
   - Requires human intervention for reboots
   - Prevents availability attacks

5. **Audit Trail**
   - All actions logged to stdout (captured by K8s)
   - Kubernetes Events for important operations
   - Node annotations track tuning history

### Container Security

**Privileges Required**:
- `privileged: true` - Access to host kernel interfaces
- `CAP_SYS_ADMIN` - Modify kernel parameters
- `CAP_SYS_RESOURCE` - Adjust resource limits
- `CAP_NET_ADMIN` - Configure network interfaces
- `CAP_IPC_LOCK` - Lock memory

**Justification**: All required for `rpk redpanda tune` operations.

**Risk Acceptance**: Privileged access is inherent to kernel tuning. Mitigation via node selectors and RBAC.

## Design Decisions

### 1. DaemonSet vs. Job

**Decision**: DaemonSet

**Rationale**:
- ✅ Automatically tunes new nodes
- ✅ One pod per node (natural mapping)
- ✅ Easy to query status per node
- ✅ Persistent for re-tuning after reboot (future)
- ❌ Job would require manual creation per node

### 2. Privileged Container vs. Init Container

**Decision**: Standalone privileged container

**Rationale**:
- ✅ Separates tuning from Redpanda pods
- ✅ Can tune nodes before Redpanda deployment
- ✅ Easier to update tuning logic independently
- ❌ Init container would run on every Redpanda pod restart

### 3. Node Annotations vs. Custom Resource

**Decision**: Node annotations

**Rationale**:
- ✅ Simple, native Kubernetes mechanism
- ✅ No CRD installation required
- ✅ Easy to query with kubectl
- ✅ Visible in node metadata
- ❌ Custom Resource would require CRD and controller

### 4. ConfigMap for iotune Results vs. Volume

**Decision**: ConfigMap

**Rationale**:
- ✅ Easy to share across pods
- ✅ Can be mounted as file in Redpanda pods
- ✅ Queryable via kubectl
- ✅ Backed up with namespace backups
- ❌ Limited to 1MB (sufficient for iotune YAML)

### 5. Sleep vs. Exit After Tuning

**Decision**: Sleep indefinitely

**Rationale**:
- ✅ Keeps logs accessible via kubectl logs
- ✅ Pod status indicates successful tuning
- ✅ Can exec into pod for debugging
- ❌ Consumes minimal resources (idle container)

### 6. No Auto-Reboot

**Decision**: Alert but don't reboot

**Rationale**:
- ✅ Avoids unexpected downtime
- ✅ Gives admins control over maintenance windows
- ✅ Prevents cascading failures
- ❌ Requires manual intervention for some tuners

## Trade-offs and Limitations

### Privileges Required

**Trade-off**: Security vs. Functionality

- Tuning requires privileged access to kernel interfaces
- No way around this without sacrificing functionality
- Mitigation: Node selectors, RBAC, namespace isolation

### Non-Persistent Tuning

**Limitation**: Most tuning changes don't survive reboots

**Options**:
1. Keep DaemonSet running, re-tune after reboot (requires force-retune)
2. Use cloud provider startup scripts
3. Bake tuning into node images

**Current**: Relies on annotation to skip re-tuning (suboptimal after reboot)

### Managed Kubernetes Restrictions

**Limitation**: Some cloud providers restrict kernel modifications

**Impact**:
- Some tuners may fail (e.g., clock source, disk scheduler)
- Usually non-critical failures
- Documented in logs and events

**Workaround**: Test on target environment, adjust tuners as needed

### ConfigMap Size Limit

**Limitation**: ConfigMaps limited to 1MB

**Impact**:
- iotune results are small (~5-10 KB per node)
- Can store ~100-200 nodes in one ConfigMap
- Large clusters may need multiple ConfigMaps

**Workaround**: Shard by node pool or region if needed

### iotune Duration vs. Accuracy

**Trade-off**: Time vs. Accuracy

- Short duration (10m): Fast, less accurate
- Long duration (60m): Slow, more accurate
- Recommendation: 10m for dev, 30-60m for production

## Future Enhancements

### 1. Persistent Tuning

**Goal**: Survive node reboots without re-running

**Approach**:
- Convert tuning changes to systemd units
- Use cloud provider startup scripts
- Integrate with node bootstrapping tools

### 2. Helm Chart Integration

**Goal**: One-command deployment with Redpanda

**Approach**:
- Package as optional subchart
- Enable with `tuner.enabled=true`
- Automatic node labeling based on Redpanda affinity

### 3. Metrics and Observability

**Goal**: Better visibility into tuning status

**Approach**:
- Prometheus metrics (tuning_duration, tuner_failures)
- Grafana dashboard
- Alerting for failed tuning

### 4. Selective Tuner Control

**Goal**: Fine-grained control over which tuners run

**Approach**:
- ConfigMap with tuner enable/disable flags
- Per-cloud-provider tuner profiles
- Automated detection of restricted tuners

### 5. Validation and Testing

**Goal**: Verify tuning actually applied

**Approach**:
- Post-tuning validation checks
- Synthetic workload testing
- Comparison against known-good baselines

### 6. Multi-Cluster Support

**Goal**: Consistent tuning across multiple clusters

**Approach**:
- GitOps-friendly configuration
- Centralized iotune result repository
- Fleet management for large deployments

---

## Conclusion

The Redpanda Kubernetes Node Tuner provides a production-ready solution for automated node tuning without manual intervention. While it requires privileged access, security measures limit the blast radius and provide audit trails. The architecture is extensible for future enhancements while maintaining simplicity and cloud-agnostic operation.

For implementation details, see [README.md](README.md).
