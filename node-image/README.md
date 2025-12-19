# Node Image Pre-tuning for Redpanda on Kubernetes

This approach bakes Redpanda tuning directly into custom node images or applies it via cloud provider startup scripts (cloud-init/user-data).

## When to Use This Approach

### ✅ Good Fit

- **Infrastructure Control**: Your organization manages custom node images
- **Persistence Required**: Tuning must survive node reboots without re-running
- **Golden Images**: You already have a golden image pipeline (Packer, etc.)
- **Compliance**: Security policies prohibit privileged containers
- **Performance**: Want zero runtime overhead from tuning pods
- **IaC Focused**: Infrastructure-as-code is your primary deployment model

### ❌ Not a Good Fit

- **Limited Access**: Application teams can't modify infrastructure
- **Multi-Cloud**: Need portable solution across different clouds
- **Rapid Iteration**: Image building adds deployment friction
- **Managed Services**: Using managed node pools you can't customize

## Approach Comparison

| Aspect | Node Image | Privileged DaemonSet |
|--------|-----------|---------------------|
| **Setup Complexity** | High (image pipeline) | Low (kubectl apply) |
| **Runtime Overhead** | None | Minimal (idle pods) |
| **Reboot Persistence** | ✅ Yes | ⚠️ Must re-run |
| **Cloud Portability** | ❌ Provider-specific | ✅ Works everywhere |
| **Update Speed** | Slow (rebuild image) | Fast (update config) |
| **Access Required** | Infrastructure team | Kubernetes RBAC |
| **Security Surface** | Build-time only | Runtime privileged |
| **Flexibility** | Less (baked in) | More (configurable) |

## Implementation Options

This directory provides three implementation paths:

### 1. Custom Node Images (Packer)

**Best for**: Organizations with established image pipelines

Build custom GKE/EKS/AKS node images with Redpanda tuning pre-applied.

**Location**: `packer/`

**Pros**:
- ✅ Tuning applied once at image build time
- ✅ Consistent across all nodes from same image
- ✅ Integrates with existing CI/CD pipelines
- ✅ Full control over base OS and packages

**Cons**:
- ❌ Requires image building infrastructure
- ❌ Slower to update (rebuild + redeploy)
- ❌ Different process per cloud provider

### 2. Cloud Provider Startup Scripts

**Best for**: Quick implementation without custom images

Use cloud-init (GCP), user-data (AWS), or custom-data (Azure) to run tuning on node boot.

**Location**: `cloud-init/`

**Pros**:
- ✅ No custom images required
- ✅ Easier to iterate and test
- ✅ Built into cloud provider APIs
- ✅ Can be managed via Terraform/CloudFormation

**Cons**:
- ❌ Runs on every boot (slower startup)
- ❌ Must install rpk on each boot
- ❌ Harder to validate before deployment

### 3. Hybrid: Image + Startup Script

**Best for**: Maximum flexibility and reliability

Base image with rpk installed, startup script runs tuning.

**Pros**:
- ✅ Fast boot (rpk pre-installed)
- ✅ Tuning re-applied after kernel updates
- ✅ Easier to update tuning parameters
- ✅ Best of both approaches

## Directory Structure

```
node-image/
├── README.md                        # This file
├── packer/                          # Custom image builders
│   ├── gcp-redpanda-node.pkr.hcl   # GCP image with Packer
│   ├── aws-redpanda-node.pkr.hcl   # AWS AMI with Packer
│   ├── azure-redpanda-node.pkr.hcl # Azure image with Packer
│   └── scripts/
│       └── install-and-tune.sh      # Common provisioning script
├── cloud-init/                      # Startup scripts
│   ├── gcp-startup-script.sh       # GCP metadata startup script
│   ├── aws-user-data.sh            # AWS EC2 user-data
│   ├── azure-custom-data.sh        # Azure custom-data
│   └── cloud-init.yaml             # Cloud-init format
├── terraform/                       # IaC examples
│   ├── gcp-node-pool/              # GCP node pool with custom image
│   ├── aws-node-group/             # EKS node group with custom AMI
│   └── azure-node-pool/            # AKS node pool with custom image
└── scripts/                         # Utilities
    ├── validate-tuning.sh          # Check if tuning is applied
    └── test-performance.sh         # Benchmark I/O performance
```

## Quick Start

### Option 1: Startup Script (Fastest)

**GCP:**
```bash
# Create node pool with startup script
gcloud container node-pools create redpanda-pool \
  --cluster=my-cluster \
  --machine-type=n2-standard-16 \
  --num-nodes=3 \
  --metadata-from-file=startup-script=cloud-init/gcp-startup-script.sh \
  --node-labels=redpanda.com/node=true
```

**AWS:**
```bash
# Create EKS node group with user-data
eksctl create nodegroup \
  --cluster=my-cluster \
  --name=redpanda-ng \
  --node-type=i3en.2xlarge \
  --nodes=3 \
  --node-ami-family=AmazonLinux2 \
  --user-data=cloud-init/aws-user-data.sh
```

**Azure:**
```bash
# Create AKS node pool with custom-data
az aks nodepool add \
  --cluster-name my-cluster \
  --name redpandapool \
  --resource-group my-rg \
  --node-count 3 \
  --node-vm-size Standard_D16s_v3 \
  --custom-data cloud-init/azure-custom-data.sh
```

### Option 2: Custom Image with Packer

```bash
# Build custom image
cd packer
packer init gcp-redpanda-node.pkr.hcl
packer build -var 'project_id=my-project' gcp-redpanda-node.pkr.hcl

# Deploy node pool with custom image
gcloud container node-pools create redpanda-pool \
  --cluster=my-cluster \
  --image-type=CUSTOM \
  --image=projects/my-project/global/images/redpanda-node-v1 \
  --machine-type=n2-standard-16 \
  --num-nodes=3
```

### Option 3: Terraform

```bash
# Use Terraform module
cd terraform/gcp-node-pool
terraform init
terraform apply \
  -var='cluster_name=my-cluster' \
  -var='image_name=redpanda-node-v1'
```

## Tuning Applied

All approaches apply the same tuning as `rpk redpanda tune all`:

- **Disk I/O Scheduler**: Set to `none`/`noop` for NVMe, `deadline` for others
- **Transparent Huge Pages**: Disabled
- **Swappiness**: Set to 1
- **CPU Governor**: Set to `performance`
- **Network Interface**: Tuned for high throughput
- **AIO Limits**: Increased `fs.aio-max-nr`
- **Clock Source**: Set to `tsc` if available
- **IRQ Affinity**: Distributed across CPUs

Additionally, `rpk iotune` is run to benchmark I/O performance.

## Validation

After deploying nodes, validate tuning was applied:

```bash
# SSH to node (GCP example)
gcloud compute ssh $(kubectl get nodes -l redpanda.com/node=true -o jsonpath='{.items[0].metadata.name}')

# Run validation script
curl -sSL https://raw.githubusercontent.com/.../validate-tuning.sh | bash

# Or manually check key parameters
cat /sys/block/nvme0n1/queue/scheduler       # Should show [none] or [noop]
cat /proc/sys/vm/swappiness                  # Should be 1
cat /sys/kernel/mm/transparent_hugepage/enabled  # Should be [never]
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # Should be performance
```

## Persistence After Reboot

**Startup Scripts**: Tuning is re-applied on every boot automatically.

**Custom Images**: Most tuning persists, but some parameters (like disk scheduler) may need re-application. Consider hybrid approach: image + lightweight startup script.

**Recommended**: Use systemd service to re-apply tuning on boot:

```bash
# /etc/systemd/system/redpanda-tune.service
[Unit]
Description=Redpanda Node Tuning
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpk redpanda tune all --reboot-allowed=false
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

### Startup Script Not Running

**GCP:**
```bash
# Check startup script logs
gcloud compute ssh NODE_NAME -- \
  sudo journalctl -u google-startup-scripts.service

# Or check cloud-init logs
gcloud compute ssh NODE_NAME -- \
  sudo cat /var/log/syslog | grep cloud-init
```

**AWS:**
```bash
# Check user-data logs
ssh ec2-user@NODE_IP
sudo cat /var/log/cloud-init-output.log
```

**Azure:**
```bash
# Check custom-data logs
ssh azureuser@NODE_IP
sudo cat /var/log/cloud-init.log
```

### Tuning Not Persisting

Some kernel parameters don't persist across reboots. Solutions:

1. Use startup script to re-apply on boot
2. Add tuning to `/etc/sysctl.d/99-redpanda.conf`
3. Use systemd service (see above)

### Permission Errors

Startup scripts run as root, so permissions shouldn't be an issue. If you see errors:

```bash
# Check if running as root
whoami  # Should be root in startup script

# Check SELinux status (if applicable)
getenforce  # Should be Permissive or Disabled
```

## Security Considerations

### Startup Scripts

- Run as root during node boot
- Have full access to node
- Should validate downloads (checksum verification)
- Consider signed scripts or secure parameter store

### Custom Images

- More secure than runtime scripts
- Tuning baked in (no runtime changes)
- Can be scanned for vulnerabilities
- Integrate with image approval pipelines

### Best Practices

1. **Principle of Least Privilege**: Only apply tuning, don't install unnecessary packages
2. **Immutable Infrastructure**: Prefer custom images over mutable startup scripts
3. **Audit Trail**: Log all tuning actions to cloud logging
4. **Validation**: Test images in staging before production
5. **Versioning**: Tag images with version numbers for rollback

## Cost Considerations

### Custom Images

- **Storage**: Small cost for storing images (~$0.05/GB/month)
- **Compute**: Packer build time (usually <10 minutes)
- **Network**: Image distribution (usually free within region)

### Startup Scripts

- **Compute**: Slight increase in boot time (~1-2 minutes)
- **Network**: Download rpk on each boot (~50MB)
- **None**: No ongoing storage costs

**Recommendation**: Custom images are more cost-effective at scale (>10 nodes).

## Migration Path

### From Privileged DaemonSet to Node Image

1. Document current tuning configuration from DaemonSet
2. Build custom image or startup script with same tuning
3. Create new node pool with custom image
4. Migrate Redpanda pods to new nodes
5. Drain and remove old node pool
6. Remove DaemonSet

### From Node Image to Privileged DaemonSet

1. Create new node pool without custom image
2. Deploy privileged DaemonSet
3. Label nodes for tuning
4. Wait for tuning to complete
5. Migrate Redpanda pods to new nodes
6. Remove custom image infrastructure

## Support Matrix

| Cloud Provider | Custom Images | Startup Scripts | Terraform | Status |
|----------------|--------------|-----------------|-----------|--------|
| GCP (GKE) | ✅ Packer | ✅ Metadata | ✅ Yes | Tested |
| AWS (EKS) | ✅ Packer | ✅ User-data | ✅ Yes | Tested |
| Azure (AKS) | ✅ Packer | ✅ Custom-data | ✅ Yes | Tested |
| On-Prem | ✅ Custom | ⚠️ Varies | ⚠️ Limited | Partial |

## Further Reading

- [GCP Custom OS Images](https://cloud.google.com/compute/docs/images/create-delete-deprecate-private-images)
- [AWS EC2 AMI Builder](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIs.html)
- [Azure Custom Images](https://docs.microsoft.com/en-us/azure/virtual-machines/linux/imaging)
- [Packer Documentation](https://www.packer.io/docs)
- [Cloud-Init Documentation](https://cloudinit.readthedocs.io/)
- [rpk redpanda tune](https://docs.redpanda.com/current/reference/rpk/rpk-redpanda/rpk-redpanda-tune/)

## Contributing

Found an issue or have an improvement? Please contribute:

1. Test on your cloud provider
2. Document any provider-specific quirks
3. Submit improvements to scripts or documentation
4. Share performance benchmarks

## License

Apache License 2.0
