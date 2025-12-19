#!/bin/bash
# AWS User-Data Script for Redpanda Node Tuning
# This script runs on first boot via EC2 user-data
#
# Usage: Add to EKS node group with:
#   --user-data file://aws-user-data.sh

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

LOG_FILE="/var/log/redpanda-tune.log"
LOCK_FILE="/var/run/redpanda-tune.lock"
RPK_VERSION="${RPK_VERSION:-latest}"
IOTUNE_DURATION="${IOTUNE_DURATION:-10m}"

# AWS-specific: Detect instance store vs EBS
# Instance store typically at /mnt or /local-ssd
# EBS typically mounted by Kubernetes at /var/lib/kubelet/plugins/...
IOTUNE_DIR="${IOTUNE_DIR:-/mnt/data}"

# ============================================================================
# Logging
# ============================================================================

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# ============================================================================
# AWS-Specific Functions
# ============================================================================

# Detect and mount instance store NVMe devices (i3/i3en/i4i instances)
setup_instance_store() {
    log "Checking for instance store NVMe devices..."

    local nvme_devices=$(lsblk -d -n -o NAME,TYPE | grep nvme | awk '{print $1}' | grep -v nvme0n1 || true)

    if [ -z "$nvme_devices" ]; then
        log "No instance store NVMe devices found"
        return 0
    fi

    log "Found instance store devices: $nvme_devices"

    # Format and mount first instance store device
    local device=$(echo "$nvme_devices" | head -1)
    local mount_point="/mnt/instance-store"

    log "Setting up instance store: /dev/$device -> $mount_point"

    # Check if already formatted
    if ! blkid "/dev/$device" &>/dev/null; then
        log "Formatting /dev/$device with ext4..."
        mkfs.ext4 -F "/dev/$device"
    fi

    # Create mount point and mount
    mkdir -p "$mount_point"

    if ! mountpoint -q "$mount_point"; then
        mount "/dev/$device" "$mount_point"
        log "Mounted /dev/$device to $mount_point"

        # Add to fstab for persistence
        echo "/dev/$device  $mount_point  ext4  defaults,nofail  0  2" >> /etc/fstab
    fi

    # Update IOTUNE_DIR to use instance store
    IOTUNE_DIR="$mount_point/redpanda"
    mkdir -p "$IOTUNE_DIR"
}

# ============================================================================
# Main Script
# ============================================================================

log "========================================"
log "Redpanda Node Tuning - AWS User-Data Script"
log "========================================"

# Get instance metadata
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
INSTANCE_TYPE=$(ec2-metadata --instance-type | cut -d " " -f 2)
AVAILABILITY_ZONE=$(ec2-metadata --availability-zone | cut -d " " -f 2)

log "Instance ID: $INSTANCE_ID"
log "Instance Type: $INSTANCE_TYPE"
log "Availability Zone: $AVAILABILITY_ZONE"

# Prevent concurrent execution
if [ -f "$LOCK_FILE" ]; then
    log "Another tuning process is running (lock file exists), exiting"
    exit 0
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Check if already tuned
TUNED_MARKER="/var/lib/redpanda-tuned"
if [ -f "$TUNED_MARKER" ] && [ "${FORCE_RETUNE:-false}" != "true" ]; then
    log "Node already tuned (marker file exists), skipping"
    exit 0
fi

# Setup instance store if available
setup_instance_store

# Install dependencies
log "Installing dependencies..."
if command -v yum &>/dev/null; then
    # Amazon Linux 2 / RHEL (EKS default)
    yum install -y -q curl
elif command -v apt-get &>/dev/null; then
    # Ubuntu
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
fi

# Install rpk if not present
if ! command -v rpk &>/dev/null; then
    log "Installing rpk..."

    if command -v yum &>/dev/null; then
        # Amazon Linux / RHEL
        curl -1sLf 'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.rpm.sh' | bash
        yum install -y -q redpanda
    elif command -v apt-get &>/dev/null; then
        # Ubuntu
        curl -1sLf 'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.deb.sh' | bash
        apt-get update -qq
        apt-get install -y -qq redpanda
    fi

    log "rpk installed: $(rpk version || echo 'version check failed')"
else
    log "rpk already installed: $(rpk version || echo 'version check failed')"
fi

# Set production mode
log "Setting Redpanda mode to production..."
rpk redpanda mode production || log "Warning: Failed to set production mode"

# Run iotune if directory exists
if [ -d "$IOTUNE_DIR" ]; then
    log "Running iotune benchmark (duration: ${IOTUNE_DURATION})..."
    log "Directory: ${IOTUNE_DIR}"

    IOTUNE_OUTPUT="/etc/redpanda/io-config.yaml"
    mkdir -p /etc/redpanda

    if rpk iotune --duration "$IOTUNE_DURATION" --directory "$IOTUNE_DIR" --out "$IOTUNE_OUTPUT" 2>&1 | tee -a "$LOG_FILE"; then
        log "iotune completed successfully"
        log "Results saved to: $IOTUNE_OUTPUT"

        # Tag instance with iotune completion (optional)
        if command -v aws &>/dev/null; then
            REGION=$(ec2-metadata --availability-zone | cut -d " " -f 2 | sed 's/[a-z]$//')
            aws ec2 create-tags \
                --region "$REGION" \
                --resources "$INSTANCE_ID" \
                --tags "Key=redpanda:iotune,Value=completed" || true
        fi
    else
        log_error "iotune failed, continuing with tuning..."
    fi
else
    log "iotune directory not found: ${IOTUNE_DIR}"
    log "Skipping iotune benchmark"
fi

# Run rpk tune
log "Running rpk redpanda tune all..."

# AWS-specific: Detect network interface
NIC=$(ip route | grep default | awk '{print $5}' | head -1)
log "Detected network interface: $NIC"

if rpk redpanda tune all --reboot-allowed=false --nic "$NIC" 2>&1 | tee -a "$LOG_FILE"; then
    log "Tuning completed successfully"
else
    log_error "Tuning failed with exit code $?"
    exit 1
fi

# Check if reboot is required
if tail -100 "$LOG_FILE" | grep -qi "reboot"; then
    log "WARNING: Some tuners may require a node reboot to take full effect"

    # Tag instance for reboot notification (optional)
    if command -v aws &>/dev/null; then
        REGION=$(ec2-metadata --availability-zone | cut -d " " -f 2 | sed 's/[a-z]$//')
        aws ec2 create-tags \
            --region "$REGION" \
            --resources "$INSTANCE_ID" \
            --tags "Key=redpanda:reboot-required,Value=true" || true
    fi
fi

# Create marker file
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$TUNED_MARKER"
log "Tuning marker file created: $TUNED_MARKER"

# Create systemd service for persistence
log "Creating systemd service for tuning persistence..."
cat > /etc/systemd/system/redpanda-tune.service <<EOF
[Unit]
Description=Redpanda Node Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rpk redpanda tune all --reboot-allowed=false --nic $NIC
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable redpanda-tune.service
log "Systemd service created and enabled"

log "========================================"
log "Redpanda Node Tuning Complete!"
log "========================================"

# Summary
log "Summary:"
log "  - Instance ID: $INSTANCE_ID"
log "  - Instance Type: $INSTANCE_TYPE"
log "  - rpk version: $(rpk version | head -1 || echo 'unknown')"
log "  - Tuning: Completed"
log "  - iotune: $([ -f "$IOTUNE_OUTPUT" ] && echo 'Completed' || echo 'Skipped')"
log "  - Marker: $TUNED_MARKER"
log "  - Logs: $LOG_FILE"

# Send CloudWatch log (if AWS CLI is available)
if command -v aws &>/dev/null; then
    REGION=$(ec2-metadata --availability-zone | cut -d " " -f 2 | sed 's/[a-z]$//')
    aws logs put-log-events \
        --region "$REGION" \
        --log-group-name "/aws/ec2/redpanda-tune" \
        --log-stream-name "$INSTANCE_ID" \
        --log-events "timestamp=$(date +%s)000,message='Node tuning completed successfully'" 2>/dev/null || true
fi

exit 0
