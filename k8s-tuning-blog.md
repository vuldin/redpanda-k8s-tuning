# Three Ways to Tune Redpanda Nodes in Kubernetes (And How to Choose)

Running Redpanda in production requires careful kernel-level tuning to achieve the low-latency, high-throughput performance the platform is known for. But when you're deploying on Kubernetes, traditional tuning approaches hit a wall. SSH access to nodes is often restricted or impractical at scale. Manual tuning doesn't persist across node reboots or work with auto-scaling. Application teams may not have infrastructure access, while infrastructure teams don't manage individual applications.

We've built three production-ready solutions to this problem, each optimized for different organizational models and constraints. Whether you're a startup moving fast on managed Kubernetes, an enterprise with golden image pipelines, or running in a highly regulated environment, there's an approach that fits your operational model.

In this post, we'll explore what node tuning is, why it matters for Redpanda, and help you choose the right tuning strategy for your environment.

## What is Node Tuning and Why Does It Matter?

Node tuning optimizes Linux kernel parameters and system settings to maximize Redpanda's performance. Out of the box, general-purpose Linux distributions are configured for broad workload compatibility, not streaming data performance. Redpanda's architecture—built on the Seastar framework—requires specific kernel configurations to eliminate bottlenecks and achieve microsecond-level latencies.

The impact is substantial. Properly tuned nodes can see:
- **2-3x improvement** in throughput on the same hardware
- **Sub-millisecond p99 latencies** for produce/consume operations
- **Reduced tail latencies** under load
- **Better stability** during traffic spikes

Node tuning addresses multiple system layers:
- **Disk I/O**: Optimizing the I/O scheduler and tuning parameters for NVMe SSDs
- **Memory management**: Disabling features that cause latency spikes (like Transparent Huge Pages)
- **CPU scheduling**: Ensuring maximum clock speeds and minimizing context switches
- **Network stack**: Tuning kernel network parameters and NIC queue settings
- **Async I/O**: Expanding capacity for high-concurrency operations

### Required or Recommended?

Node tuning is **required for production deployments** where you expect predictable, low-latency performance. Without tuning, you may experience:
- Higher and more variable latencies (10-100x worse in some cases)
- Reduced maximum throughput (leaving hardware capacity on the table)
- Performance degradation under load
- Increased resource consumption for the same workload

For development or testing environments, you can skip tuning. But for any multi-node cluster handling production traffic, tuning should be considered mandatory infrastructure setup.

## What Gets Tuned?

All tuning approaches optimize the same set of kernel parameters. Here's what changes when you tune a node for Redpanda:

| Parameter | Default | Tuned Setting | Why It Matters |
|-----------|---------|---------------|----------------|
| **Disk I/O Scheduler** | mq-deadline | `none` (or `noop`) | Eliminates unnecessary scheduling overhead for NVMe SSDs that handle their own I/O optimization |
| **Transparent Huge Pages** | always/madvise | `never` | Prevents unpredictable memory allocation delays that cause latency spikes |
| **Swappiness** | 60 | `1` | Minimizes swapping to disk, keeping hot data in memory |
| **CPU Governor** | powersave | `performance` | Ensures CPUs run at maximum frequency with no power-saving throttling |
| **AIO Max Events** | 65536 | `1048576` | Expands async I/O capacity for high-concurrency operations (16x increase) |
| **Network Buffers** | Default | Optimized | Increases socket buffer sizes for high-throughput connections |
| **Clock Source** | varies | `tsc` (x86) | Uses the fastest available clock source for timestamp operations |

Beyond these kernel parameters, tuning also includes:
- **I/O benchmarking**: Measuring actual disk performance to configure Redpanda's I/O scheduler appropriately
- **IRQ affinity**: Distributing hardware interrupts across CPU cores to prevent bottlenecks
- **Network interface tuning**: Configuring NIC queue sizes and offloading features

Each parameter addresses a specific performance bottleneck. Disk I/O scheduler changes are critical for NVMe drives. Transparent Huge Pages can cause 10-100ms stalls when the kernel reallocates memory. Swappiness prevents the kernel from swapping out Redpanda's memory even when there's pressure. CPU governor eliminates frequency scaling delays. Together, these changes create a system optimized for consistent, high-performance streaming workloads.

## The Challenge: Traditional Approaches Don't Fit Kubernetes

The traditional approach to node tuning—SSH into each node, run configuration scripts, add systemd services—doesn't translate well to Kubernetes operational models:

**Manual SSH tuning doesn't scale**: In dynamic environments where nodes come and go, manual tuning creates operational burden. Auto-scaling node groups start untunned. Node replacements require re-tuning. Cluster upgrades mean re-tuning every node.

**Package installation becomes a burden**: The standard tuning tool, `rpk`, comes with the full Redpanda package—200-500MB of binaries you don't actually need on Kubernetes nodes. You're installing an entire database just to tune kernel parameters. This increases node image size, provisioning time, and attack surface.

**Team boundaries create friction**: Application teams deploying Redpanda often don't have access to modify node configurations or install packages. Infrastructure teams managing nodes may not be familiar with application-specific requirements. This organizational split means tuning either gets skipped or becomes a slow, ticket-driven process.

**Cloud restrictions add complexity**: Some environments prohibit privileged containers. Others restrict package repositories or internet access. Compliance requirements may require auditing every piece of software on nodes. Air-gapped environments can't easily install external packages.

**Persistence is not guaranteed**: Most kernel parameter changes don't survive reboots. Without proper systemd services or startup scripts, you need to re-apply tuning after every node restart—another manual step in an automated environment.

What's needed are solutions designed for Kubernetes operational patterns: automated, repeatable, and compatible with diverse infrastructure constraints.

## Three Production-Ready Solutions

We've developed three complementary approaches, each optimized for different organizational needs and constraints. All three apply the same kernel-level tuning, but differ in deployment model, dependencies, and operational characteristics.

### Approach 1: Standalone Script — Lightweight and Universal

**What it is**: A self-contained bash script (~150KB) that replicates `rpk redpanda tune all` functionality without requiring rpk or any Redpanda packages. Pure bash with standard Linux utilities.

**How it works**:
- All 13 tuners from `rpk redpanda tune all` implemented in bash
- Precomputed I/O performance data for 80+ AWS instance types (i3, i4i, im4gn, etc.)
- Cloud provider detection (AWS, GCP, Azure) to automatically apply appropriate settings
- Graceful degradation—works without optional dependencies like hwloc or ethtool
- Can be deployed via cloud-init scripts, Kubernetes DaemonSets, or run standalone

**Key advantages**:
- **Minimal footprint**: ~150KB total vs 200-500MB for rpk packages
- **No package dependencies**: Only requires standard Linux utilities (bash, sysctl, awk)
- **Easy to audit**: 1,500 lines of readable bash vs compiled Go binary
- **Air-gap friendly**: Single file to transfer, no external downloads
- **Cost-effective**: Reduces node image size, faster provisioning, lower storage costs

**Trade-offs**:
- **No live I/O benchmarking**: Uses precomputed values instead of running iotune (10-60 minute benchmark)
- **Bash maintenance**: Updates require bash script changes rather than package updates
- **Conservative defaults**: For unknown hardware, uses safe but potentially suboptimal values

**Best for**:
- Air-gapped or restricted environments that can't install external packages
- Organizations with strict package auditing requirements
- Cost-conscious deployments where every MB matters
- Security-focused environments preferring minimal dependencies
- Environments where rpk installation is blocked or impractical

**Getting started**:
```bash
# Download and run
wget https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/standalone-script/redpanda-tune.sh
chmod +x redpanda-tune.sh
sudo ./redpanda-tune.sh

# Or use in cloud-init
sudo ./redpanda-tune.sh --log-level info --dirs /var/lib/redpanda
```

### Approach 2: Privileged DaemonSet — Fast and Flexible

**What it is**: A Kubernetes DaemonSet that automatically runs `rpk redpanda tune all` on every node. Fully automated via standard Kubernetes primitives.

**How it works**:
- DaemonSet pod runs on each node with hostPath mounts and privileged security context
- Executes full `rpk redpanda tune all` including live iotune benchmarking
- Stores I/O benchmark results in ConfigMap for Redpanda pods to consume
- Emits Kubernetes Events for reboot warnings and tuning status
- Configured via ConfigMap for easy updates (iotune duration, target directories, etc.)

**Key advantages**:
- **Rapid deployment**: `kubectl apply -f` and you're done—no infrastructure changes
- **Live I/O benchmarking**: Runs iotune to measure actual disk performance (most accurate)
- **Easy updates**: Change ConfigMap, restart DaemonSet—configuration propagates automatically
- **Multi-cloud portable**: Same manifests work on GKE, EKS, AKS, and on-premises
- **Kubernetes-native**: Fits standard Kubernetes operational patterns (RBAC, namespaces, observability)
- **Fast iteration**: Test configuration changes in minutes, not hours

**Trade-offs**:
- **Requires privileged containers**: Not all environments allow this security model
- **Runtime overhead**: Minimal but present (DaemonSet pods consume resources)
- **No persistence**: Tuning doesn't survive node reboots without re-running (use systemd for persistence)
- **Package size**: Node must download rpk (~200-500MB) on first run

**Best for**:
- Application teams deploying to managed Kubernetes (GKE, EKS, AKS)
- Organizations that can't or don't want to modify node images
- Multi-cloud deployments needing consistent approach
- Rapid iteration and experimentation
- Environments where privileged containers are permitted

**Getting started**:
```bash
# Deploy with kubectl
kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/configmap.yaml
kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/daemonset.yaml

# Check tuning status
kubectl logs -n redpanda-system -l app=redpanda-tuner
```

### Approach 3: Node Image Pre-tuning — Infrastructure as Code

**What it is**: Baking tuning into custom node images using tools like Packer, or applying tuning via cloud provider startup scripts (cloud-init, user-data).

**How it works**:
- **Custom images**: Use Packer templates to build node images with rpk installed and tuning pre-applied
- **Startup scripts**: Add tuning commands to cloud-init (GCP), user-data (AWS), or custom-data (Azure)
- **Terraform examples**: Infrastructure-as-code modules for creating tuned node pools
- Tuning runs during node provisioning, before any workloads start

**Key advantages**:
- **Zero runtime overhead**: Tuning happens at boot, no DaemonSet resources required
- **Persistence**: Most parameters persist across reboots; startup scripts re-apply the rest
- **Security**: No privileged containers running in production
- **Infrastructure-as-code**: Integrates with existing CI/CD and image pipelines
- **Consistency**: All nodes from the same image have identical tuning
- **Audit-friendly**: Tuning is part of the immutable infrastructure

**Trade-offs**:
- **Infrastructure complexity**: Requires Packer, Terraform, or cloud-specific tooling
- **Cloud-specific**: Different implementations for GCP, AWS, Azure
- **Slower iteration**: Image rebuilds + node pool rotations can take 30-60 minutes
- **Coordination**: Requires collaboration between infrastructure and application teams

**Best for**:
- Infrastructure teams with existing golden image pipelines
- Organizations that can't run privileged containers
- Regulated environments requiring build-time security
- Large-scale deployments (>10 nodes) where consistency matters
- Enterprises with infrastructure-as-code practices

**Getting started**:
```bash
# Using Packer
cd k8s-tuning/node-image/packer
packer build gcp-redpanda-node.pkr.hcl

# Or Terraform with startup script
cd k8s-tuning/node-image/terraform/gcp-node-pool
terraform init
terraform apply -var="startup_script_path=../../cloud-init/gcp-startup-script.sh"
```

## Decision Framework: Which Approach to Choose

Choosing the right approach depends on your organizational constraints, not just preferences. Use this framework to narrow down your options:

### Decision Flowchart

```
Can you install rpk/Redpanda packages on nodes?
├─ NO (blocked, air-gapped, or prefer not to)
│  │
│  └─ Can you modify infrastructure (images/startup scripts)?
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
      │       (no other option with rpk)
      │
      └─ YES → Can you modify infrastructure (images/startup scripts)?
               │
               ├─ NO → Use Privileged DaemonSet
               │       (application-level solution)
               │
               └─ YES → What's most important?
                        │
                        ├─ Minimal dependencies/size
                        │  → Standalone Script
                        │     (~150KB vs 200-500MB)
                        │
                        ├─ Live I/O benchmarking
                        │  → Node Image with rpk
                        │     (iotune gives exact values)
                        │
                        ├─ Speed/Flexibility
                        │  → Privileged DaemonSet
                        │     (fastest iteration)
                        │
                        └─ Persistence/Security
                           → Node Image
                              (best for production)
```

### Real-World Scenarios

Let's look at specific situations and recommended approaches:

**Scenario 1: Startup on GKE**
- **Situation**: Small team, using managed GKE, need to move fast, iterating on deployment
- **Recommendation**: Privileged DaemonSet or Standalone Script
- **Why**: Deploy in minutes without touching infrastructure. No GCP IAM complexity or image pipelines needed. Easy to experiment. Migrate to node images later as you scale.

**Scenario 2: Enterprise with Platform Team**
- **Situation**: Large organization, platform team manages infrastructure, golden image pipelines already exist, strong infrastructure-as-code practices
- **Recommendation**: Node Image Pre-tuning (with Standalone Script or rpk)
- **Why**: Integrates seamlessly with existing pipelines. Platform team provides "Redpanda-ready" node pools. Application teams just reference them. Aligns with existing operational model.

**Scenario 3: Multi-Cloud Deployment**
- **Situation**: Running Redpanda on GKE, EKS, and AKS simultaneously
- **Recommendation**: Privileged DaemonSet or Standalone Script
- **Why**: Single solution works across all clouds. No need to maintain three separate image pipelines with cloud-specific quirks. Consistent configuration via ConfigMap or script parameters.

**Scenario 4: Highly Regulated Financial Services**
- **Situation**: Financial services, strict security policies, no privileged containers allowed, every package must be audited, compliance requirements
- **Recommendation**: Node Image Pre-tuning with Standalone Script
- **Why**: No privileged containers in production. Tuning at build time, not runtime. Pure bash script is easier to audit than compiled binaries. Meets security and compliance requirements.

**Scenario 5: Hybrid On-Premises + Cloud**
- **Situation**: Some clusters on-premises (no cloud APIs), some in cloud, need uniform approach
- **Recommendation**: Privileged DaemonSet or Standalone Script
- **Why**: Works identically in both environments. On-premises may lack image pipelines but can run DaemonSets. Uniform operational approach reduces complexity.

**Scenario 6: Air-Gapped Environment**
- **Situation**: No internet access, restricted package repositories, cannot easily install rpk
- **Recommendation**: Standalone Script
- **Why**: No external dependencies. Single ~150KB file to transfer via USB or bastion. Works with standard Linux utilities already on nodes. Self-contained solution.

**Scenario 7: Minimal Dependency Requirements**
- **Situation**: Security policy requires minimal software on nodes, every package audited, attack surface minimization
- **Recommendation**: Standalone Script
- **Why**: Only ~150KB of auditable bash code. No 200-500MB rpk package. Easy security review. Minimal attack surface. Works with existing Linux utilities.

**Scenario 8: Cost-Conscious Deployment**
- **Situation**: Limited node disk space, bandwidth costs matter, optimizing image size
- **Recommendation**: Standalone Script
- **Why**: Reduces node image size by 200-500MB. Faster provisioning (less to download). Lower storage costs. Same tuning effectiveness as rpk.

## At a Glance: Comparison Table

| Feature | Standalone Script | Privileged DaemonSet | Node Image Pre-tuning |
|---------|-------------------|----------------------|----------------------|
| **Setup Complexity** | Low | Very Low | High |
| **Package Size** | ~150KB | 200-500MB (rpk) | Varies |
| **Dependencies** | Standard Linux only | rpk + Redpanda | rpk + Redpanda |
| **I/O Benchmarking** | Precomputed values | Live iotune | Live iotune |
| **Deployment Time** | 1-2 minutes | 10-65 minutes (with iotune) | Varies (image build) |
| **Tuning Persistence** | No (use systemd) | No (must re-run) | Yes (most params) |
| **Cloud Portability** | Excellent | Excellent | Poor (cloud-specific) |
| **Update Iteration** | Fast | Very Fast | Slow |
| **Privileged Pods** | No | Yes (required) | No |
| **Runtime Overhead** | None | Minimal | None |
| **Air-gap Support** | Excellent | Poor | Good (if cached) |
| **Audit Friendliness** | Excellent (bash) | Moderate (binary) | Excellent |
| **Best Production Fit** | Constrained envs | App teams | Infrastructure teams |

## Hybrid Approaches: Best of Both Worlds

You're not limited to one approach. Combining methods can provide flexibility:

**Hybrid Option 1: Node Image + DaemonSet**
- **Setup**: Pre-install rpk in custom node image, then use DaemonSet to apply tuning
- **Benefits**: Fast node boot (rpk already present), flexible configuration updates (via ConfigMap), no per-node rpk download
- **Use case**: Organizations with image pipelines who want rapid configuration iteration

**Hybrid Option 2: Standalone Script Everywhere**
- **Setup**: Embed standalone script in node image cloud-init, also available in DaemonSet for re-tuning
- **Benefits**: Minimal image size, no rpk dependency, can re-tune without rebuilding images
- **Use case**: Maximum flexibility with minimal dependencies, works across restricted and open environments

## Getting Started

Ready to implement node tuning? Here's how to begin with each approach:

### Standalone Script
1. Download: `wget https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/standalone-script/redpanda-tune.sh`
2. Make executable: `chmod +x redpanda-tune.sh`
3. Run with sudo: `sudo ./redpanda-tune.sh --log-level info`
4. For persistence, set up systemd service: `./examples/systemd-service.sh > /etc/systemd/system/redpanda-tune.service`
5. Validate: `sudo ./examples/validate.sh`

### Privileged DaemonSet
1. Apply manifests:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/namespace.yaml
   kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/rbac.yaml
   kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/configmap.yaml
   kubectl apply -f https://raw.githubusercontent.com/redpanda-data/k8s-tuning/main/privileged-daemonset/daemonset.yaml
   ```
2. Check status: `kubectl logs -n redpanda-system -l app=redpanda-tuner`
3. Verify I/O config: `kubectl get configmap -n redpanda-system redpanda-iotune-results -o yaml`

### Node Image Pre-tuning
1. **Using Packer**: Customize templates in `k8s-tuning/node-image/packer/` for your cloud provider
2. **Using startup scripts**: Add `k8s-tuning/node-image/cloud-init/gcp-startup-script.sh` to your node pool
3. **Using Terraform**: Use modules in `k8s-tuning/node-image/terraform/` as starting points
4. Build image, create node pool, verify tuning on first node boot

For complete documentation, examples, and troubleshooting:
**[github.com/redpanda-data/k8s-tuning](https://github.com/redpanda-data/k8s-tuning)**

## Conclusion

Node tuning is essential infrastructure for production Redpanda deployments on Kubernetes, but traditional approaches don't fit Kubernetes operational models. The three solutions we've presented—standalone script, privileged DaemonSet, and node image pre-tuning—provide production-ready options for every organizational constraint.

**Choose standalone script** when you need minimal dependencies, work in air-gapped environments, or have strict security requirements.

**Choose privileged DaemonSet** when you're an application team on managed Kubernetes, need rapid iteration, or deploy across multiple clouds.

**Choose node image pre-tuning** when you have infrastructure pipelines, can't run privileged containers, or need maximum production robustness.

All three approaches apply the same kernel-level optimizations and deliver the performance Redpanda is built for. The "best" choice depends entirely on your organizational model, infrastructure constraints, and operational priorities.

Start with the approach that matches your current constraints, validate the performance gains, and iterate as your infrastructure matures. Production-grade streaming performance is within reach—no manual SSH sessions required.

---

*For complete implementation guides, cloud-specific examples, troubleshooting, and updates, visit the [k8s-tuning repository](https://github.com/redpanda-data/k8s-tuning).*
