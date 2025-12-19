# Kubernetes Node Tuning for Redpanda

Production-ready solutions for tuning Kubernetes nodes to run Redpanda. This repository provides **three approaches** with different trade-offs.

## The Problem

Redpanda requires specific kernel-level tuning (`rpk redpanda tune`) for production performance. However, tuning Kubernetes nodes is challenging because:

- **Manual SSH access** is often restricted or impractical at scale
- **Tuning doesn't persist** across node reboots by default
- **Scaling challenges** - new nodes must be manually tuned
- **Team boundaries** - app teams may not have infrastructure access
- **Package dependencies** - Installing rpk just for tuning adds 200-500MB overhead

## Three Approaches

| Approach | Best For | Trade-offs |
|----------|----------|------------|
| **[Standalone Script](./standalone-script/)** | No rpk dependency, lightweight, flexible | No iotune benchmark (uses precomputed values) |
| **[Privileged DaemonSet](./privileged-daemonset/)** | App teams, multi-cloud, rapid iteration | Requires privileged pods + rpk, tuning may not persist |
| **[Node Image Pre-tuning](./node-image/)** | Infrastructure teams, single cloud, golden images | Requires image pipeline, cloud-specific, slower to update |

## Quick Comparison

### Standalone Script (NEW!)

**✅ Pros:**
- No rpk or Redpanda packages required (~150KB vs 200-500MB)
- Pure bash with standard Linux utilities
- Works with or without hwloc/ethtool (graceful degradation)
- Precomputed I/O data for 80+ AWS instance types
- Can be used in DaemonSets, cloud-init, or standalone
- Easy to audit and customize

**❌ Cons:**
- No live iotune benchmarking (uses precomputed values)
- Bash maintenance burden
- Updates not automatic from rpk

**When to use:** You want the lightest-weight solution without installing Redpanda packages, or your environment blocks rpk installation.

[→ Get Started with Standalone Script](./standalone-script/)

---

### Privileged DaemonSet

**✅ Pros:**
- Quick to deploy (kubectl apply)
- No infrastructure changes required
- Portable across cloud providers
- Easy to update configuration
- Works with managed node pools

**❌ Cons:**
- Requires privileged containers
- Runtime overhead (minimal)
- May not persist after reboot
- Security policies may block

**When to use:** You're an application team deploying to Kubernetes and need a solution that "just works" without touching infrastructure.

[→ Get Started with DaemonSet](./privileged-daemonset/)

---

### Node Image Pre-tuning

**✅ Pros:**
- No runtime overhead
- Tuning persists across reboots
- More secure (no privileged runtime)
- Infrastructure-as-code friendly
- Works in restricted environments

**❌ Cons:**
- Requires image building pipeline
- Cloud provider-specific
- Slower to iterate and update
- Needs infrastructure team coordination

**When to use:** You control infrastructure and already have golden image pipelines (Packer, etc.) or can use cloud provider startup scripts.

[→ Get Started with Node Images](./node-image/)

---

## Decision Matrix

Use this matrix to choose the right approach for your organization:

```
┌─────────────────────────────────────────────────────────────────┐
│                    DECISION FLOWCHART                           │
└─────────────────────────────────────────────────────────────────┘

Can you install rpk/Redpanda packages on nodes?
├─ NO (blocked, air-gapped, or prefer not to)
│  │
│  └─ Can you modify infrastructure (images/startup scripts)?
│     │
│     ├─ YES → Use Standalone Script + Node Image
│     │        (lightweight, no rpk dependency)
│     │
│     └─ NO → Use Standalone Script + DaemonSet
│              (if privileged containers allowed)
│
└─ YES (rpk installation is acceptable)
   │
   └─ Can you run privileged containers?
      │
      ├─ NO → Use Node Image approach
      │       (no other option)
      │
      └─ YES → Can you modify infrastructure (images/startup scripts)?
               │
               ├─ NO → Use Privileged DaemonSet
               │       (application-level solution)
               │
               └─ YES → What's more important?
                        │
                        ├─ Minimal dependencies/size
                        │  → Use Standalone Script
                        │     (~150KB vs 200-500MB)
                        │
                        ├─ Live I/O benchmarking
                        │  → Use Node Image with rpk
                        │     (iotune gives exact values)
                        │
                        ├─ Speed/Flexibility
                        │  → Use Privileged DaemonSet
                        │     (faster iteration)
                        │
                        └─ Persistence/Security
                           → Use Node Image
                              (better for production)
```

## Real-World Scenarios

### Scenario 1: Startup Using GKE

**Situation:** Small team, using GKE, need to move fast

**Recommendation:** **Privileged DaemonSet** or **Standalone Script**
- Deploy in minutes with kubectl or cloud-init
- No GCP IAM complexity
- Easy to experiment and iterate
- Standalone script avoids rpk dependency (~150KB vs 200-500MB)
- Migrate to node images later as you mature

### Scenario 2: Enterprise with Platform Team

**Situation:** Large org, platform team manages infrastructure, golden images already exist

**Recommendation:** **Node Image Pre-tuning** (with Standalone Script or rpk)
- Integrate tuning into existing image pipeline
- Aligns with infrastructure-as-code practices
- Platform team provides "Redpanda-ready" node pools
- Use standalone script to minimize image size
- App teams just label nodes

### Scenario 3: Multi-Cloud Deployment

**Situation:** Running on GKE, EKS, and AKS

**Recommendation:** **Privileged DaemonSet** or **Standalone Script**
- Single solution works across all clouds
- Consistent configuration via ConfigMap or script parameters
- No need to maintain 3 image pipelines
- Standalone script works in DaemonSets or cloud-init

### Scenario 4: Highly Regulated Environment

**Situation:** Financial services, strict security policies, no privileged containers allowed

**Recommendation:** **Node Image Pre-tuning with Standalone Script**
- Tuning done at build time, not runtime
- No privileged workloads in production
- No rpk dependency (easier security audit)
- Pure bash script (~150KB, easy to review)
- Meets compliance requirements

### Scenario 5: Hybrid On-Prem + Cloud

**Situation:** Some clusters on-prem, some in cloud

**Recommendation:** **Privileged DaemonSet** or **Standalone Script**
- Works across both environments
- On-prem may not have image pipeline
- Standalone script reduces package dependencies
- Uniform approach reduces operational complexity

### Scenario 6: Air-Gapped Environment

**Situation:** No internet access, restricted package repositories, cannot install rpk

**Recommendation:** **Standalone Script**
- No rpk or Redpanda packages required
- Single bash script (~150KB) + precomputed I/O data
- Easy to transfer via USB or bastion host
- Works in cloud-init, DaemonSets, or standalone
- No external dependencies except standard Linux tools

### Scenario 7: Minimal Dependency Requirements

**Situation:** Security policy requires minimal software on nodes, every package must be audited

**Recommendation:** **Standalone Script**
- Pure bash with standard Linux utilities only
- No rpk packages (~200-500MB avoided)
- Easy to audit (1,500 lines of bash vs complex Go binary)
- Precomputed I/O values (no iotune benchmark binary)
- Graceful degradation (works without hwloc/ethtool)

### Scenario 8: Cost-Conscious Deployment

**Situation:** Limited node disk space or bandwidth, every MB matters

**Recommendation:** **Standalone Script**
- ~150KB total vs 200-500MB for rpk packages
- Reduces node image size significantly
- Faster node provisioning (less to download)
- Lower storage costs for images
- Same tuning effectiveness as rpk

## Hybrid Approach

You can combine approaches for the best of both worlds:

### Option 1: Node Image + DaemonSet
1. **Node Image**: Install rpk in base image (fast startup)
2. **DaemonSet**: Apply tuning with latest configuration (flexible)

This gives you:
- Fast node boot (rpk pre-installed)
- Easy configuration updates (ConfigMap)
- Flexibility to re-tune without rebuilding images

### Option 2: Standalone Script in Both
1. **Node Image**: Embed standalone script in cloud-init (lightweight)
2. **DaemonSet**: Use same script for re-tuning (consistent)

This gives you:
- Minimal image size (~150KB overhead)
- No rpk package dependencies
- Easy to audit and maintain
- Works across restricted and open environments

Example:
```yaml
# Custom node image with standalone script in cloud-init
# + Optional DaemonSet using same script for re-tuning
# = Lightweight + Flexible
```

## Getting Started

### 1. Choose Your Approach

Based on the decision matrix above, choose:
- **[Standalone Script](./standalone-script/)** - Lightweight, no rpk dependency (~150KB)
- **[Privileged DaemonSet](./privileged-daemonset/)** - Quick start, app team friendly
- **[Node Image](./node-image/)** - Infrastructure as code, production-ready

### 2. Follow the Guide

Each approach has comprehensive documentation:
- Prerequisites and requirements
- Step-by-step deployment instructions
- Cloud provider-specific examples
- Troubleshooting guide
- Validation scripts

### 3. Validate Tuning

After deploying either approach, validate tuning was applied:

```bash
# SSH to a node
kubectl get nodes -l redpanda.com/node=true
gcloud compute ssh NODE_NAME  # or aws/azure equivalent

# Run validation script
curl -sSL https://raw.githubusercontent.com/.../validate-tuning.sh | bash
```

Expected output:
```
========================================
Redpanda Node Tuning Validation
========================================

✓ rpk is installed: v24.2.1
✓ Disk nvme0n1 scheduler: [none]
✓ Swappiness: 1
✓ Transparent Huge Pages: [never]
✓ CPU 0 governor: performance
✓ AIO max nr: 1048576
✓ iotune results found

========================================
Validation Summary
========================================
Passed:  8
Warnings: 1
Failed:  0

✓ Node appears to be properly tuned for Redpanda!
```

### 4. Deploy Redpanda

Once nodes are tuned, deploy Redpanda:

```bash
# Add Redpanda Helm repo
helm repo add redpanda https://charts.redpanda.com
helm repo update

# Install with node selector for tuned nodes
helm install redpanda redpanda/redpanda \
  --set nodeSelector.redpanda\\.com/node=true \
  --set storage.persistentVolume.size=100Gi
```

## Documentation Structure

```
k8s-tuning/
├── README.md                    # This file - choose your approach
│
├── standalone-script/           # Approach 1: Standalone bash script (no rpk)
│   ├── README.md               # Full standalone script guide
│   ├── redpanda-tune.sh        # Main tuning script (~1250 lines)
│   ├── iotune-data.sh          # Precomputed I/O data
│   └── examples/               # Usage examples
│       ├── systemd-service.sh  # Generate systemd unit
│       └── validate.sh         # Validation script
│
├── privileged-daemonset/        # Approach 2: Runtime tuning with rpk
│   ├── README.md               # Full DaemonSet guide
│   ├── ARCHITECTURE.md         # Technical deep dive
│   ├── namespace.yaml          # Kubernetes manifests
│   ├── rbac.yaml
│   ├── configmap.yaml
│   ├── daemonset.yaml
│   ├── Dockerfile              # Container image build
│   ├── tune.sh                 # Tuning orchestration
│   ├── tune-lib.sh             # Helper functions
│   └── examples/               # Cloud-specific configs
│       ├── gke.yaml
│       ├── eks.yaml
│       └── custom-config.yaml
│
└── node-image/                  # Approach 3: Build-time tuning
    ├── README.md               # Full node image guide
    ├── packer/                 # Custom image builders
    │   ├── gcp-redpanda-node.pkr.hcl
    │   ├── aws-redpanda-node.pkr.hcl
    │   └── scripts/
    ├── cloud-init/             # Startup scripts
    │   ├── gcp-startup-script.sh
    │   ├── aws-user-data.sh
    │   └── azure-custom-data.sh
    ├── terraform/              # IaC examples
    │   ├── gcp-node-pool/
    │   ├── aws-node-group/
    │   └── azure-node-pool/
    └── scripts/                # Utilities
        ├── validate-tuning.sh
        └── test-performance.sh
```

## What Gets Tuned?

All three approaches apply the same kernel-level tuning (equivalent to `rpk redpanda tune all`):

| Parameter | Setting | Why |
|-----------|---------|-----|
| **Disk I/O Scheduler** | `none`/`noop` | Reduce latency for NVMe SSDs |
| **Transparent Huge Pages** | `never` | Prevent memory fragmentation |
| **Swappiness** | `1` | Minimize swapping to disk |
| **CPU Governor** | `performance` | Maximum clock speed |
| **AIO Limits** | `1048576` | Support high I/O concurrency |
| **Network** | Optimized | Increase throughput |
| **Clock Source** | `tsc` | Lowest latency timestamps |

Plus **iotune benchmarking** to measure actual I/O performance.

## FAQ

### Can I combine approaches?

Yes! See the "Hybrid Approach" section above. Common combinations:
- **Standalone Script + Node Image**: Embed script in cloud-init for lightweight solution
- **rpk + Node Image + DaemonSet**: Pre-install rpk, then use DaemonSet for flexibility
- **Standalone Script in both**: Use same script in cloud-init and DaemonSet

### What if some tuning fails?

All approaches continue even if some tuners fail. Check logs to see which tuners succeeded. Some cloud providers restrict certain kernel parameters.

### How do I update tuning configuration?

- **Standalone Script**: Update script file, re-run (manually or via systemd/DaemonSet)
- **DaemonSet**: Update ConfigMap, restart pods
- **Node Image**: Rebuild image, rotate nodes

### Does tuning persist after node reboot?

- **Standalone Script**: No by default, use systemd service or cloud-init to re-apply
- **DaemonSet**: No by default, needs re-run (use systemd service)
- **Node Image**: Yes for most parameters (startup script re-applies rest)

### What about Windows nodes?

Redpanda tuning is Linux-specific. Windows nodes are not supported.

### Can I tune only specific nodes?

Yes! All approaches support targeting specific nodes:
- **Standalone Script**: Run only on desired nodes via cloud-init or manual execution
- **DaemonSet/Node Image**: Use node selectors (e.g., `redpanda.com/node=true`)

## Support & Contributing

- **Issues**: Report bugs or request features
- **Documentation**: Improve guides and examples
- **Cloud Providers**: Add support for new platforms
- **Performance**: Share benchmarks and optimizations

## License

Apache License 2.0

---

**Ready to get started?** Choose your approach:

→ **[Standalone Script](./standalone-script/)** for lightweight, no rpk dependency

→ **[Privileged DaemonSet](./privileged-daemonset/)** for quick deployment

→ **[Node Image](./node-image/)** for infrastructure as code
