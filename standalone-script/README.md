# Redpanda Standalone Node Tuner

A standalone bash script that replicates `rpk redpanda tune` functionality **without requiring rpk or Redpanda packages** to be installed.

## Features

- ✅ All 13 tuners from `rpk redpanda tune all`
- ✅ I/O configuration with precomputed values for 80+ AWS instance types
- ✅ No rpk dependency - pure bash with standard Linux tools
- ✅ Graceful degradation (works without hwloc/ethtool)
- ✅ Idempotent (safe to run multiple times)
- ✅ Cloud provider detection (AWS, GCP, Azure)
- ✅ Conservative defaults for unknown hardware
- ✅ Optional GRUB modifications (requires reboot)
- ✅ Check-only mode for validation

## Quick Start

```bash
# Download the scripts
wget https://path/to/redpanda-tune.sh
wget https://path/to/iotune-data.sh

# Make executable
chmod +x redpanda-tune.sh

# Run tuning (requires root)
sudo ./redpanda-tune.sh
```

## Usage

### Basic Tuning

```bash
# Tune with defaults (auto-detect everything)
sudo ./redpanda-tune.sh

# Tune specific directories
sudo ./redpanda-tune.sh --dirs /var/lib/redpanda,/mnt/data

# Tune specific devices
sudo ./redpanda-tune.sh --devices nvme0n1,nvme1n1

# Check current tuning status
sudo ./redpanda-tune.sh --check-only
```

### Advanced Options

```bash
# Enable GRUB modifications (requires reboot)
sudo ./redpanda-tune.sh --tune-grub

# Enable only specific tuners
sudo ./redpanda-tune.sh --enable aio_events,swappiness,disk_scheduler

# Disable specific tuners
sudo ./redpanda-tune.sh --disable coredump,ballast_file

# Override cloud detection
sudo ./redpanda-tune.sh --cloud-provider aws --instance-type i3.xlarge

# Debug logging
sudo ./redpanda-tune.sh --log-level debug
```

## What Gets Tuned?

### Kernel Parameters (Always Applied)

1. **aio_events** - Increases async I/O capacity to 10,000,137
2. **swappiness** - Sets to 1 (minimize swapping)
3. **transparent_hugepages** - Disables THP
4. **clocksource** - Sets to `tsc` (x86) or `arch_sys_counter` (ARM)

### Disk Tuning (Per Device)

5. **disk_scheduler** - Sets I/O scheduler to `none` or `noop`
6. **disk_nomerges** - Disables I/O request merging
7. **disk_irq** - Distributes disk IRQs across CPUs
13. **disk_write_cache** - Sets write-through cache (GCP only)

### CPU Tuning

8. **cpu** - Sets governor to `performance`, disables boost
   - Optional: GRUB modifications for C-states/P-states (requires reboot)

### Network Tuning

9. **network** - Tunes kernel network parameters
   - Optional: NIC queue configuration with ethtool

### Operational

10. **coredump** - Configures core dump handler
11. **ballast_file** - Creates 1GB emergency ballast file
12. **fstrim** - Installs weekly fstrim systemd timer

### I/O Configuration

- Uses precomputed values for common cloud instances (AWS i3/i4i/im4gn/is4gen, GCP n2)
- Falls back to conservative defaults for unknown hardware
- Creates `/etc/redpanda/io-config.yaml` for Redpanda to use

## Requirements

### Minimal Dependencies

- **bash** 4.0+
- **Standard utilities**: awk, grep, sed, cat, echo
- **sysctl** - For kernel parameter modification
- **systemctl** - For systemd service management
- **curl** - For cloud provider detection (optional)

### Optional Dependencies

- **hwloc** (`hwloc-calc`) - For better CPU topology detection (fallback available)
- **ethtool** - For NIC queue configuration (fallback available)
- **fallocate** - For ballast file creation (falls back to dd)

### Operating System

- Linux kernel 4.0+
- Tested on: Ubuntu 20.04/22.04/24.04, RHEL 8/9, Debian 11/12

## Comparison with rpk

| Feature | rpk tune | redpanda-tune.sh |
|---------|----------|-----------------|
| Requires rpk | ✅ Yes | ❌ No |
| Package size | ~200-500MB | ~150KB |
| Dependencies | Redpanda packages | Standard Linux utils |
| All 13 tuners | ✅ Yes | ✅ Yes |
| iotune benchmark | ✅ 10-60 min | ⚠️ Precomputed values |
| GRUB modifications | ✅ Yes | ✅ Yes (opt-in) |
| Cloud detection | ✅ Yes | ✅ Yes |
| hwloc fallback | ❌ No | ✅ Yes |
| ethtool fallback | ❌ No | ✅ Yes |

## Configuration File

Create `/etc/redpanda-tune.conf` to set defaults:

```bash
# Directories to tune
DIRS="/var/lib/redpanda"

# Devices to tune (empty = auto-detect)
DEVICES=""

# Network interfaces (empty = auto-detect)
NICS=""

# Enable GRUB modifications (requires reboot)
TUNE_GRUB=false

# Log level
LOG_LEVEL="info"

# Enabled tuners (all = enable all)
ENABLED_TUNERS="all"

# Disabled tuners (empty = none)
DISABLED_TUNERS=""
```

## Persistence After Reboot

Most tuning changes are **not persistent** across reboots. Options:

### Option 1: Run on Boot (Recommended)

Use the systemd service generator:

```bash
./examples/systemd-service.sh > /etc/systemd/system/redpanda-tune.service
systemctl daemon-reload
systemctl enable redpanda-tune.service
```

### Option 2: Startup Script

Add to cloud-init or user-data:

```bash
#!/bin/bash
/opt/redpanda/redpanda-tune.sh --log-level info
```

### Option 3: Cron

```bash
@reboot root /opt/redpanda/redpanda-tune.sh >/var/log/redpanda-tune.log 2>&1
```

## Cloud Provider Support

### AWS

Precomputed I/O data for:
- i3 family (large to metal)
- i3en family (large to metal)
- i4i family (large to metal)
- im4gn family (large to 16xlarge)
- is4gen family (medium to 8xlarge)
- m6id family (large to 32xlarge)

**Total**: 50+ instance types

### GCP

Limited precomputed data:
- n2-standard (2 to 16)

Falls back to conservative defaults for other types.

### Azure

No precomputed data yet. Uses conservative defaults.

### Bare Metal / Other

Uses conservative I/O defaults:
- Read IOPS: 10,000
- Read Bandwidth: 1 GB/s
- Write IOPS: 5,000
- Write Bandwidth: 500 MB/s

## Troubleshooting

### Permission Errors

```bash
# Must run as root
sudo ./redpanda-tune.sh
```

### Tuner Failures

```bash
# Check which tuners failed
sudo ./redpanda-tune.sh --log-level debug

# Skip problematic tuners
sudo ./redpanda-tune.sh --disable disk_irq,network
```

### Validate Tuning

```bash
# Use check-only mode
sudo ./redpanda-tune.sh --check-only

# Or use validation script
sudo ./examples/validate.sh
```

### GRUB Issues

If GRUB modifications fail:

```bash
# Skip GRUB tuning
sudo ./redpanda-tune.sh --skip-grub

# Or manually update /etc/default/grub and run:
sudo update-grub    # Ubuntu/Debian
sudo grub2-mkconfig -o /boot/grub2/grub.cfg  # RHEL/CentOS
```

### Cloud Detection Fails

```bash
# Manually specify cloud provider
sudo ./redpanda-tune.sh --cloud-provider aws --instance-type i3.xlarge
```

## Integration Examples

### Kubernetes DaemonSet

Replace rpk with standalone script in `tune.sh`:

```bash
#!/bin/bash
/opt/redpanda/redpanda-tune.sh \
    --dirs /var/lib/redpanda \
    --log-level info
```

### Terraform

```hcl
resource "google_compute_instance" "redpanda" {
  metadata_startup_script = file("redpanda-tune.sh")
}
```

### Ansible

```yaml
- name: Run Redpanda tuning
  script: redpanda-tune.sh
  become: yes
```

### Docker

```dockerfile
FROM ubuntu:22.04
COPY redpanda-tune.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/redpanda-tune.sh && \
    /usr/local/bin/redpanda-tune.sh
```

## Files

```
standalone-script/
├── redpanda-tune.sh           # Main script (~1250 lines)
├── iotune-data.sh             # Precomputed I/O data (~250 lines)
├── README.md                  # This file
└── examples/
    ├── systemd-service.sh     # Generate systemd unit
    └── validate.sh            # Validation script
```

## Development

### Adding Instance Types

To add more precomputed I/O data:

1. Extract from rpk source:
   ```bash
   cd /home/josh/projects/redpanda/redpanda/src/go/rpk/pkg/tuners/iotune
   grep -A1 '"instance.type"' data.go | grep default
   ```

2. Convert to bash format:
   ```bash
   IOTUNE_DATA["provider:instance.type"]="read_iops:read_bw:write_iops:write_bw"
   ```

3. Add to `iotune-data.sh`

### Testing

```bash
# Test on different distributions
docker run --privileged -v $(pwd):/scripts ubuntu:22.04 /scripts/redpanda-tune.sh
docker run --privileged -v $(pwd):/scripts rockylinux:9 /scripts/redpanda-tune.sh
```

## FAQ

**Q: Do I still need to install Redpanda packages?**
A: No! This script is completely standalone.

**Q: Is this as good as rpk tune?**
A: For kernel tuning, yes. For I/O benchmarking, it uses precomputed values instead of running iotune.

**Q: What if my instance type isn't in iotune-data.sh?**
A: It will use conservative defaults that work on most hardware.

**Q: Can I run this multiple times?**
A: Yes, it's idempotent. Subsequent runs will be very fast.

**Q: Does this work with Kubernetes?**
A: Yes! Use it in cloud-init scripts or DaemonSets.

**Q: What about reboots?**
A: Most changes don't survive reboots. Use a systemd service or startup script.

**Q: Can I customize which tuners run?**
A: Yes, use `--enable` or `--disable` flags.

**Q: Is GRUB tuning safe?**
A: Yes, but it requires a reboot. It's opt-in via `--tune-grub`.

## License

Apache License 2.0

## See Also

- [rpk redpanda tune documentation](https://docs.redpanda.com/current/reference/rpk/rpk-redpanda/rpk-redpanda-tune/)
- [Redpanda production deployment guide](https://docs.redpanda.com/current/deploy/deployment-option/)
- [../privileged-daemonset/](../privileged-daemonset/) - Alternative approach using rpk in Kubernetes
- [../node-image/](../node-image/) - Node image pre-tuning approach
