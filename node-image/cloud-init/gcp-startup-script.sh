#!/bin/bash
# GCP Startup Script for Redpanda Node Tuning
# This script runs on every node boot via GCP metadata
#
# Usage: Add to node pool with:
#   --metadata-from-file=startup-script=gcp-startup-script.sh

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

LOG_FILE="/var/log/redpanda-tune.log"
LOCK_FILE="/var/run/redpanda-tune.lock"
RPK_VERSION="${RPK_VERSION:-latest}"
IOTUNE_DURATION="${IOTUNE_DURATION:-10m}"
IOTUNE_DIR="${IOTUNE_DIR:-/mnt/stateful_partition/kube-ephemeral-ssd/redpanda-data}"

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
# Main Script
# ============================================================================

log "========================================"
log "Redpanda Node Tuning - GCP Startup Script"
log "========================================"

# Prevent concurrent execution
if [ -f "$LOCK_FILE" ]; then
    log "Another tuning process is running (lock file exists), exiting"
    exit 0
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Check if already tuned (marker file)
TUNED_MARKER="/var/lib/redpanda-tuned"
if [ -f "$TUNED_MARKER" ] && [ "${FORCE_RETUNE:-false}" != "true" ]; then
    log "Node already tuned (marker file exists), skipping"
    log "To force re-tuning, set FORCE_RETUNE=true in metadata"
    exit 0
fi

# Install dependencies
log "Installing dependencies..."
if command -v apt-get &>/dev/null; then
    # Debian/Ubuntu (GKE default)
    apt-get update -qq
    apt-get install -y -qq curl gnupg2 ca-certificates lsb-release
elif command -v yum &>/dev/null; then
    # RHEL/CentOS
    yum install -y -q curl gnupg2 ca-certificates
else
    log_error "Unsupported package manager"
    exit 1
fi

# Install rpk if not present
if ! command -v rpk &>/dev/null; then
    log "Installing rpk..."

    # Add Redpanda repository
    if command -v apt-get &>/dev/null; then
        curl -1sLf 'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.deb.sh' | bash
        apt-get update -qq
        apt-get install -y -qq redpanda
    elif command -v yum &>/dev/null; then
        curl -1sLf 'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.rpm.sh' | bash
        yum install -y -q redpanda
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
    else
        log_error "iotune failed, continuing with tuning..."
    fi
else
    log "iotune directory not found: ${IOTUNE_DIR}"
    log "Skipping iotune benchmark"
fi

# Run rpk tune
log "Running rpk redpanda tune all..."
if rpk redpanda tune all --reboot-allowed=false 2>&1 | tee -a "$LOG_FILE"; then
    log "Tuning completed successfully"
else
    log_error "Tuning failed with exit code $?"
    exit 1
fi

# Check if reboot is required
if tail -100 "$LOG_FILE" | grep -qi "reboot"; then
    log "WARNING: Some tuners may require a node reboot to take full effect"
    log "Please review the logs and schedule a maintenance window if needed"
fi

# Create marker file
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$TUNED_MARKER"
log "Tuning marker file created: $TUNED_MARKER"

# Create systemd service for persistence (optional)
log "Creating systemd service for tuning persistence..."
cat > /etc/systemd/system/redpanda-tune.service <<'EOF'
[Unit]
Description=Redpanda Node Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rpk redpanda tune all --reboot-allowed=false
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
log "  - rpk version: $(rpk version | head -1 || echo 'unknown')"
log "  - Tuning: Completed"
log "  - iotune: $([ -f "$IOTUNE_OUTPUT" ] && echo 'Completed' || echo 'Skipped')"
log "  - Marker: $TUNED_MARKER"
log "  - Logs: $LOG_FILE"

# Export metadata for monitoring (GCP Cloud Logging)
logger -t redpanda-tune "Node tuning completed successfully"

exit 0
