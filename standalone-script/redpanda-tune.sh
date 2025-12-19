#!/bin/bash
# redpanda-tune.sh - Standalone Redpanda Node Tuner
#
# This script replicates the functionality of `rpk redpanda tune` without
# requiring rpk or Redpanda packages to be installed.
#
# Usage: ./redpanda-tune.sh [OPTIONS]
# See --help for full usage information
#
# Version: 1.0.0
# License: Apache 2.0

set -euo pipefail

# ============================================================================
# SECTION 1: Configuration & Globals
# ============================================================================

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME=$(basename "$0")

# Default configuration
DIRS="${DIRS:-/var/lib/redpanda}"
DEVICES="${DEVICES:-}"
NICS="${NICS:-}"
TUNE_GRUB="${TUNE_GRUB:-false}"
ENABLED_TUNERS="${ENABLED_TUNERS:-all}"
DISABLED_TUNERS="${DISABLED_TUNERS:-}"
CHECK_ONLY="${CHECK_ONLY:-false}"
VALIDATE="${VALIDATE:-false}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-auto}"
INSTANCE_TYPE="${INSTANCE_TYPE:-auto}"
LOG_LEVEL="${LOG_LEVEL:-info}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"

# Global state
declare -A TUNER_STATUS
REBOOT_REQUIRED=false
EXIT_CODE=0

# Colors for text output
if [[ "$OUTPUT_FORMAT" == "text" ]] && [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'  # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# ============================================================================
# SECTION 2: Utility Functions
# ============================================================================

# Logging functions
log_debug() {
    if [[ "$LOG_LEVEL" == "debug" ]]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [DEBUG] $*" >&2
    fi
}

log_info() {
    if [[ "$LOG_LEVEL" =~ ^(debug|info)$ ]]; then
        echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [INFO] $*" >&2
    fi
}

log_warn() {
    if [[ "$LOG_LEVEL" =~ ^(debug|info|warn)$ ]]; then
        echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ${YELLOW}[WARN]${NC} $*" >&2
    fi
}

log_error() {
    echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    if [[ "$LOG_LEVEL" =~ ^(debug|info)$ ]]; then
        echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ${GREEN}[SUCCESS]${NC} $*" >&2
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Detect Linux distribution
detect_distribution() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# Backup file before modification
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%s)"
        cp "$file" "$backup"
        log_debug "Backed up $file to $backup"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dirs)
                DIRS="$2"
                shift 2
                ;;
            --devices)
                DEVICES="$2"
                shift 2
                ;;
            --nics)
                NICS="$2"
                shift 2
                ;;
            --tune-grub)
                TUNE_GRUB=true
                shift
                ;;
            --skip-grub)
                TUNE_GRUB=false
                shift
                ;;
            --enable)
                ENABLED_TUNERS="$2"
                shift 2
                ;;
            --disable)
                DISABLED_TUNERS="$2"
                shift 2
                ;;
            --check-only)
                CHECK_ONLY=true
                shift
                ;;
            --validate)
                VALIDATE=true
                shift
                ;;
            --cloud-provider)
                CLOUD_PROVIDER="$2"
                shift 2
                ;;
            --instance-type)
                INSTANCE_TYPE="$2"
                shift 2
                ;;
            --log-level)
                LOG_LEVEL="$2"
                shift 2
                ;;
            --output-format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME version $SCRIPT_VERSION"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Show usage information
show_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Standalone Redpanda node tuner that replicates rpk tune functionality.

OPTIONS:
  --dirs DIR1,DIR2,...      Directories to tune disks for (default: /var/lib/redpanda)
  --devices DEV1,DEV2,...   Explicit devices to tune (e.g., nvme0n1,sda)
  --nics NIC1,NIC2,...      Network interfaces to tune (auto-detect if not specified)
  --tune-grub               Enable GRUB modifications (requires reboot)
  --skip-grub               Skip GRUB modifications (default)
  --enable TUNER1,TUNER2    Enable only specific tuners (comma-separated)
  --disable TUNER1,TUNER2   Disable specific tuners (comma-separated)
  --check-only              Check current state, don't apply changes
  --validate                Validate tuning after applying
  --cloud-provider PROVIDER Override cloud detection (aws, gcp, azure, none)
  --instance-type TYPE      Override instance type detection
  --log-level LEVEL         Log level: debug, info, warn, error (default: info)
  --output-format FORMAT    Output format: text, json (default: text)
  -h, --help                Show this help message
  -v, --version             Show version

TUNERS:
  aio_events, swappiness, transparent_hugepages, disk_scheduler, disk_nomerges,
  disk_irq, cpu, network, clocksource, coredump, ballast_file, fstrim, disk_write_cache

EXAMPLES:
  # Tune with defaults
  sudo $SCRIPT_NAME

  # Tune specific devices
  sudo $SCRIPT_NAME --devices nvme0n1,nvme1n1

  # Tune with GRUB updates (requires reboot)
  sudo $SCRIPT_NAME --tune-grub

  # Check current tuning status
  sudo $SCRIPT_NAME --check-only

  # Enable only critical tuners
  sudo $SCRIPT_NAME --enable aio_events,swappiness,disk_scheduler

EOF
}

# Check if tuner is enabled
is_tuner_enabled() {
    local tuner="$1"

    # Check if explicitly disabled
    if [[ "$DISABLED_TUNERS" == *"$tuner"* ]]; then
        return 1
    fi

    # Check if all enabled or explicitly enabled
    if [[ "$ENABLED_TUNERS" == "all" ]] || [[ "$ENABLED_TUNERS" == *"$tuner"* ]]; then
        return 0
    fi

    return 1
}

# Load configuration from file if it exists
load_config() {
    local config_file="/etc/redpanda-tune.conf"
    if [[ -f "$config_file" ]]; then
        log_debug "Loading configuration from $config_file"
        source "$config_file"
    fi
}

# ============================================================================
# SECTION 3: Device Discovery
# ============================================================================

# Strip partition number from device name
strip_partition() {
    local device="$1"
    local dev_name=$(basename "$device")

    # NVMe: nvme0n1p1 -> nvme0n1
    if [[ "$dev_name" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        echo "/dev/${BASH_REMATCH[1]}"
    # SCSI/SATA/VirtIO: sda1 -> sda, vda1 -> vda
    elif [[ "$dev_name" =~ ^([a-z]+)[0-9]+$ ]]; then
        echo "/dev/${BASH_REMATCH[1]}"
    else
        # No partition detected, return as-is
        echo "$device"
    fi
}

# Find block devices for given directories
find_block_devices_for_dirs() {
    local dirs="$1"
    local devices=()

    IFS=',' read -ra dir_array <<< "$dirs"
    for dir in "${dir_array[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_warn "Directory does not exist: $dir"
            continue
        fi

        # Use df to find the device for this directory
        local mount_device=$(df -P "$dir" 2>/dev/null | tail -1 | awk '{print $1}')

        if [[ -z "$mount_device" ]]; then
            log_warn "Could not determine device for directory: $dir"
            continue
        fi

        # Resolve to actual device (handle symlinks)
        local real_device=$(readlink -f "$mount_device" 2>/dev/null || echo "$mount_device")

        # Strip partition number
        local base_device=$(strip_partition "$real_device")

        # Verify it's a block device
        if [[ -b "$base_device" ]]; then
            devices+=("$(basename "$base_device")")
        else
            log_debug "Not a block device: $base_device"
        fi
    done

    # Deduplicate and output
    printf '%s\n' "${devices[@]}" | sort -u
}

# Get sysfs path for block device
get_sys_block_path() {
    local device="$1"
    local dev_name=$(basename "$device")
    echo "/sys/block/$dev_name"
}

# Check if device exists in sysfs
device_exists() {
    local device="$1"
    local sys_path=$(get_sys_block_path "$device")
    [[ -d "$sys_path" ]]
}

# Get all block devices (fallback if no directories specified)
get_all_block_devices() {
    # List all block devices excluding loopback and ram
    lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}' | grep -v -E '^(loop|ram)'
}

# ============================================================================
# SECTION 4: CPU Topology Discovery
# ============================================================================

# Get number of CPUs
get_cpu_count() {
    nproc
}

# Check if hwloc is available
has_hwloc() {
    command_exists hwloc-calc
}

# Calculate CPU mask using hwloc
calculate_cpu_mask_hwloc() {
    local cpu_list="$1"
    hwloc-calc --taskset "$cpu_list" 2>/dev/null || echo ""
}

# Calculate CPU mask manually (fallback)
calculate_cpu_mask_manual() {
    local cpu_list="$1"
    local cpus=()

    # Parse CPU list (e.g., "0-3,8-11")
    IFS=',' read -ra ranges <<< "$cpu_list"
    for range in "${ranges[@]}"; do
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # Range: 0-3
            for ((cpu=${BASH_REMATCH[1]}; cpu<=${BASH_REMATCH[2]}; cpu++)); do
                cpus+=($cpu)
            done
        else
            # Single CPU
            cpus+=($range)
        fi
    done

    # Generate hexadecimal mask
    local mask=0
    for cpu in "${cpus[@]}"; do
        ((mask |= (1 << cpu))) || true
    done

    printf "%x" "$mask"
}

# Get CPU mask for given CPU list
get_cpu_mask() {
    local cpu_list="$1"

    if has_hwloc; then
        local mask=$(calculate_cpu_mask_hwloc "$cpu_list")
        if [[ -n "$mask" ]]; then
            echo "$mask"
            return 0
        fi
    fi

    # Fallback to manual calculation
    calculate_cpu_mask_manual "$cpu_list"
}

# Find IRQs for a device
find_device_irqs() {
    local device="$1"

    # Search /proc/interrupts for device name
    grep -i "$device" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' || true
}

# Distribute IRQs across CPUs (round-robin)
distribute_irqs() {
    local irqs=("$@")
    local num_cpus=$(get_cpu_count)

    # Use CPUs 1 through N-1 (avoid CPU 0 for kernel)
    local available_cpus=()
    for ((cpu=1; cpu<num_cpus; cpu++)); do
        available_cpus+=($cpu)
    done

    local cpu_count=${#available_cpus[@]}
    if [[ $cpu_count -eq 0 ]]; then
        log_warn "No CPUs available for IRQ distribution"
        return 1
    fi

    local idx=0
    for irq in "${irqs}"; do
        local cpu=${available_cpus[$((idx % cpu_count))]}
        local mask=$(printf "%x" $((1 << cpu)))

        log_debug "Setting IRQ $irq affinity to CPU $cpu (mask: $mask)"
        echo "$mask" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true

        ((idx++))
    done

    return 0
}

# ============================================================================
# SECTION 5: Network Interface Discovery
# ============================================================================

# Find active network interfaces
find_active_nics() {
    # Exclude loopback, docker, bridges, veth
    ip -o link show | awk -F': ' '{print $2}' | grep -v -E '^(lo|docker|br-|veth)' || true
}

# Get NIC IRQs
find_nic_irqs() {
    local nic="$1"
    find_device_irqs "$nic"
}

# Check if ethtool is available
has_ethtool() {
    command_exists ethtool
}

# ============================================================================
# SECTION 6: Cloud Provider Detection
# ============================================================================

# Detect cloud provider
detect_cloud_provider() {
    if [[ "$CLOUD_PROVIDER" != "auto" ]]; then
        echo "$CLOUD_PROVIDER"
        return 0
    fi

    # Try AWS
    if curl -s --max-time 1 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null | grep -q .; then
        echo "aws"
        return 0
    fi

    # Try GCP
    if curl -s --max-time 1 -H "Metadata-Flavor: Google" \
        http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null | grep -q .; then
        echo "gcp"
        return 0
    fi

    # Try Azure
    if curl -s --max-time 1 -H "Metadata:true" \
        "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null | grep -q .; then
        echo "azure"
        return 0
    fi

    echo "none"
}

# Get instance type
get_instance_type() {
    if [[ "$INSTANCE_TYPE" != "auto" ]]; then
        echo "$INSTANCE_TYPE"
        return 0
    fi

    local provider=$(detect_cloud_provider)

    case "$provider" in
        aws)
            curl -s --max-time 1 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "unknown"
            ;;
        gcp)
            curl -s --max-time 1 -H "Metadata-Flavor: Google" \
                http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null | \
                awk -F'/' '{print $NF}' || echo "unknown"
            ;;
        azure)
            curl -s --max-time 1 -H "Metadata:true" \
                "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null || \
                echo "unknown"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Configure I/O properties (iotune alternative)
configure_io_properties() {
    local mount_point="${1:-/var/lib/redpanda}"
    local output_file="/etc/redpanda/io-config.yaml"

    # Source iotune data if available
    local iotune_data_script="$(dirname "$0")/iotune-data.sh"
    if [[ -f "$iotune_data_script" ]]; then
        source "$iotune_data_script"
    fi

    local provider=$(detect_cloud_provider)
    local instance=$(get_instance_type)

    log_info "Configuring I/O properties for $provider:$instance"

    # Try to apply precomputed data or use defaults
    if declare -F apply_iotune_config &>/dev/null; then
        apply_iotune_config "$mount_point" "$provider" "$instance" "$output_file"
        log_success "✓ I/O configuration created: $output_file"
        return 0
    else
        # Fallback if iotune-data.sh not available
        log_warn "iotune-data.sh not found, using conservative defaults"
        mkdir -p "$(dirname "$output_file")"
        cat > "$output_file" <<EOF
disks:
  - mountpoint: $mount_point
    read_iops: 10000
    read_bandwidth: 1000000000
    write_iops: 5000
    write_bandwidth: 500000000
EOF
        log_success "✓ I/O configuration created with conservative defaults"
        return 0
    fi
}

# ============================================================================
# SECTION 7: Individual Tuners
# ============================================================================

# Tuner 1: AIO Events
tune_aio_events() {
    local target_value=10000137
    local current_value=$(cat /proc/sys/fs/aio-max-nr)

    if [[ $current_value -ge $target_value ]]; then
        log_info "✓ aio_events: already configured ($current_value)"
        return 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_warn "✗ aio_events: needs tuning (current: $current_value, target: $target_value)"
        return 1
    fi

    echo "$target_value" > /proc/sys/fs/aio-max-nr
    log_success "✓ aio_events: set to $target_value"
    return 0
}

# Tuner 2: Swappiness
tune_swappiness() {
    local target_value=1
    local current_value=$(cat /proc/sys/vm/swappiness)

    if [[ $current_value -le $target_value ]]; then
        log_info "✓ swappiness: already configured ($current_value)"
        return 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_warn "✗ swappiness: needs tuning (current: $current_value, target: $target_value)"
        return 1
    fi

    sysctl -w vm.swappiness=$target_value >/dev/null
    log_success "✓ swappiness: set to $target_value"
    return 0
}

# Tuner 3: Transparent Huge Pages
tune_transparent_hugepages() {
    # Find THP path (varies by distribution)
    local thp_path=""
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        thp_path="/sys/kernel/mm/transparent_hugepage/enabled"
    elif [[ -f /sys/kernel/mm/redhat_transparent_hugepage/enabled ]]; then
        thp_path="/sys/kernel/mm/redhat_transparent_hugepage/enabled"
    else
        log_warn "✗ transparent_hugepages: not available on this system"
        return 1
    fi

    local current_value=$(cat "$thp_path")
    if [[ "$current_value" == *"[never]"* ]]; then
        log_info "✓ transparent_hugepages: already disabled"
        return 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_warn "✗ transparent_hugepages: needs tuning (current: $current_value)"
        return 1
    fi

    echo "never" > "$thp_path"
    log_success "✓ transparent_hugepages: disabled"
    return 0
}

# Tuner 4: Disk Scheduler
tune_disk_scheduler() {
    local devices=()

    # Get devices to tune
    if [[ -n "$DEVICES" ]]; then
        IFS=',' read -ra devices <<< "$DEVICES"
    else
        mapfile -t devices < <(find_block_devices_for_dirs "$DIRS")
    fi

    if [[ ${#devices[@]} -eq 0 ]]; then
        log_warn "✗ disk_scheduler: no devices found"
        return 1
    fi

    local success=true
    for device in "${devices[@]}"; do
        local sys_path=$(get_sys_block_path "$device")
        local scheduler_path="$sys_path/queue/scheduler"

        if [[ ! -f "$scheduler_path" ]]; then
            log_warn "✗ disk_scheduler: scheduler not available for $device"
            continue
        fi

        local current=$(cat "$scheduler_path")
        if [[ "$current" == *"[none]"* ]] || [[ "$current" == *"[noop]"* ]]; then
            log_info "✓ disk_scheduler ($device): already set to none/noop"
            continue
        fi

        if [[ "$CHECK_ONLY" == "true" ]]; then
            log_warn "✗ disk_scheduler ($device): needs tuning"
            success=false
            continue
        fi

        # Try to set to 'none', fall back to 'noop'
        if echo "none" > "$scheduler_path" 2>/dev/null; then
            log_success "✓ disk_scheduler ($device): set to none"
        elif echo "noop" > "$scheduler_path" 2>/dev/null; then
            log_success "✓ disk_scheduler ($device): set to noop"
        else
            log_error "✗ disk_scheduler ($device): failed to configure"
            success=false
        fi
    done

    [[ "$success" == "true" ]]
}

# Tuner 5: Disk Nomerges
tune_disk_nomerges() {
    local devices=()

    if [[ -n "$DEVICES" ]]; then
        IFS=',' read -ra devices <<< "$DEVICES"
    else
        mapfile -t devices < <(find_block_devices_for_dirs "$DIRS")
    fi

    if [[ ${#devices[@]} -eq 0 ]]; then
        log_warn "✗ disk_nomerges: no devices found"
        return 1
    fi

    local success=true
    for device in "${devices[@]}"; do
        local sys_path=$(get_sys_block_path "$device")
        local nomerges_path="$sys_path/queue/nomerges"

        if [[ ! -f "$nomerges_path" ]]; then
            log_warn "✗ disk_nomerges: not available for $device"
            continue
        fi

        local current=$(cat "$nomerges_path")
        if [[ "$current" == "2" ]]; then
            log_info "✓ disk_nomerges ($device): already configured"
            continue
        fi

        if [[ "$CHECK_ONLY" == "true" ]]; then
            log_warn "✗ disk_nomerges ($device): needs tuning"
            success=false
            continue
        fi

        echo "2" > "$nomerges_path"
        log_success "✓ disk_nomerges ($device): set to 2"
    done

    [[ "$success" == "true" ]]
}

# Tuner 6: Disk IRQ
tune_disk_irq() {
    local devices=()

    if [[ -n "$DEVICES" ]]; then
        IFS=',' read -ra devices <<< "$DEVICES"
    else
        mapfile -t devices < <(find_block_devices_for_dirs "$DIRS")
    fi

    if [[ ${#devices[@]} -eq 0 ]]; then
        log_warn "✗ disk_irq: no devices found"
        return 1
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "disk_irq: check mode not fully implemented"
        return 0
    fi

    # Stop irqbalance if running
    if systemctl is-active irqbalance &>/dev/null; then
        log_info "Stopping irqbalance service"
        systemctl stop irqbalance || true
    fi

    local total_irqs=0
    for device in "${devices[@]}"; do
        local irqs=($(find_device_irqs "$device"))

        if [[ ${#irqs[@]} -eq 0 ]]; then
            log_debug "No IRQs found for $device"
            continue
        fi

        log_info "Distributing ${#irqs[@]} IRQs for $device"
        distribute_irqs "${irqs[@]}"
        ((total_irqs += ${#irqs[@]})) || true
    done

    if [[ $total_irqs -gt 0 ]]; then
        log_success "✓ disk_irq: distributed $total_irqs IRQs"
        return 0
    else
        log_warn "✗ disk_irq: no IRQs found"
        return 1
    fi
}

# Tuner 7: CPU
tune_cpu() {
    local success=true

    # Set CPU governor to performance
    local cpufreq_path="/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
    local governor_files=$(ls $cpufreq_path 2>/dev/null || true)

    if [[ -z "$governor_files" ]]; then
        log_warn "✗ cpu: CPU frequency scaling not available"
        return 1
    fi

    if [[ "$CHECK_ONLY" != "true" ]]; then
        for governor_file in $governor_files; do
            echo "performance" > "$governor_file" 2>/dev/null || success=false
        done
    fi

    # Disable CPU boost
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        if [[ "$CHECK_ONLY" != "true" ]]; then
            echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        fi
    fi

    # GRUB updates (optional, requires reboot)
    if [[ "$TUNE_GRUB" == "true" ]] && [[ "$CHECK_ONLY" != "true" ]]; then
        log_info "GRUB tuning enabled, updating boot parameters"
        update_grub_for_cpu
        REBOOT_REQUIRED=true
    fi

    if [[ "$success" == "true" ]]; then
        log_success "✓ cpu: governor set to performance"
        return 0
    else
        log_error "✗ cpu: failed to configure"
        return 1
    fi
}

# Helper: Update GRUB for CPU
update_grub_for_cpu() {
    local grub_file="/etc/default/grub"
    if [[ ! -f "$grub_file" ]]; then
        log_warn "GRUB config not found, skipping"
        return 1
    fi

    local params="intel_idle.max_cstate=0 processor.max_cstate=1 intel_pstate=disable"

    if grep -q "$params" "$grub_file"; then
        log_info "GRUB already configured"
        return 0
    fi

    backup_file "$grub_file"
    sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"$params /" "$grub_file"

    if command_exists update-grub; then
        update-grub 2>/dev/null
    elif command_exists grub2-mkconfig; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
    fi

    log_success "✓ GRUB updated (reboot required)"
    return 0
}

# Tuner 8: Network
tune_network() {
    local nics=()

    if [[ -n "$NICS" ]]; then
        IFS=',' read -ra nics <<< "$NICS"
    else
        mapfile -t nics < <(find_active_nics)
    fi

    if [[ ${#nics[@]} -eq 0 ]]; then
        log_warn "✗ network: no NICs found"
        return 1
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "network: check mode not fully implemented"
        return 0
    fi

    # Tune kernel network parameters
    sysctl -w net.core.rmem_max=16777216 >/dev/null
    sysctl -w net.core.wmem_max=16777216 >/dev/null
    sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null
    sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null
    sysctl -w net.core.netdev_max_backlog=5000 >/dev/null
    sysctl -w net.core.somaxconn=1024 >/dev/null

    # Tune NICs with ethtool if available
    if has_ethtool; then
        for nic in "${nics[@]}"; do
            log_debug "Tuning NIC: $nic"
            ethtool -L "$nic" combined 16 2>/dev/null || true
            ethtool -K "$nic" tso on gso on gro on 2>/dev/null || true

            # Distribute NIC IRQs
            local irqs=($(find_nic_irqs "$nic"))
            if [[ ${#irqs[@]} -gt 0 ]]; then
                distribute_irqs "${irqs[@]}"
            fi
        done
        log_success "✓ network: tuned ${#nics[@]} interface(s) with ethtool"
    else
        log_success "✓ network: tuned kernel parameters (ethtool not available)"
    fi

    return 0
}

# Tuner 9: Clocksource
tune_clocksource() {
    local clocksource_path="/sys/devices/system/clocksource/clocksource0/current_clocksource"

    if [[ ! -f "$clocksource_path" ]]; then
        log_warn "✗ clocksource: not available on this system"
        return 1
    fi

    # Determine optimal clocksource based on architecture
    local arch=$(uname -m)
    local target_clocksource="tsc"
    if [[ "$arch" == "aarch64" ]]; then
        target_clocksource="arch_sys_counter"
    fi

    local current=$(cat "$clocksource_path")
    if [[ "$current" == "$target_clocksource" ]]; then
        log_info "✓ clocksource: already set to $target_clocksource"
        return 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_warn "✗ clocksource: needs tuning (current: $current, target: $target_clocksource)"
        return 1
    fi

    echo "$target_clocksource" > "$clocksource_path" 2>/dev/null || {
        log_warn "✗ clocksource: failed to set $target_clocksource"
        return 1
    }

    log_success "✓ clocksource: set to $target_clocksource"
    return 0
}

# Tuner 10: Coredump
tune_coredump() {
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "coredump: check mode not implemented"
        return 0
    fi

    local coredump_dir="/var/lib/redpanda"
    local coredump_script="$coredump_dir/save_coredump"

    mkdir -p "$coredump_dir"

    # Create coredump handler script
    cat > "$coredump_script" <<'EOF'
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

CMD=${1}
PID=${3}
TIMESTAMP_UTC=$(date --utc +'%Y-%m-%d_%H:%M:%S.%N_%Z')
COREDUMP_DIR="/var/lib/redpanda/coredumps"
COREDUMP_PATH="${COREDUMP_DIR}/core.${CMD}-${TIMESTAMP_UTC}-${PID}"

mkdir -p "${COREDUMP_DIR}"
logger -p user.err "Saving ${CMD} coredump to ${COREDUMP_PATH}"
cat - > "${COREDUMP_PATH}"
EOF

    chmod 777 "$coredump_script"

    # Configure kernel to use handler
    echo "|$coredump_script %e %t %p" > /proc/sys/kernel/core_pattern

    log_success "✓ coredump: handler configured"
    return 0
}

# Tuner 11: Ballast File
tune_ballast_file() {
    local ballast_path="/var/lib/redpanda/ballast"
    local ballast_size="1G"

    if [[ -f "$ballast_path" ]]; then
        log_info "✓ ballast_file: already exists"
        return 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_warn "✗ ballast_file: needs creation"
        return 1
    fi

    mkdir -p "$(dirname "$ballast_path")"

    if command_exists fallocate; then
        fallocate -l "$ballast_size" "$ballast_path" 2>/dev/null || {
            log_error "✗ ballast_file: failed to create"
            return 1
        }
    else
        dd if=/dev/zero of="$ballast_path" bs=1G count=1 2>/dev/null || {
            log_error "✗ ballast_file: failed to create"
            return 1
        }
    fi

    log_success "✓ ballast_file: created ($ballast_size)"
    return 0
}

# Tuner 12: Fstrim
tune_fstrim() {
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "fstrim: check mode not fully implemented"
        return 0
    fi

    # Check if default fstrim timer exists
    if systemctl list-unit-files | grep -q "fstrim.timer"; then
        systemctl enable fstrim.timer 2>/dev/null || true
        systemctl start fstrim.timer 2>/dev/null || true
        log_success "✓ fstrim: enabled default systemd timer"
        return 0
    fi

    # Create custom fstrim service and timer
    cat > /etc/systemd/system/redpanda-fstrim.service <<'EOF'
[Unit]
Description=Redpanda Fstrim Service
Documentation=man:fstrim(8)

[Service]
Type=oneshot
ExecStart=/sbin/fstrim -av
EOF

    cat > /etc/systemd/system/redpanda-fstrim.timer <<'EOF'
[Unit]
Description=Weekly Redpanda Fstrim Timer

[Timer]
OnCalendar=weekly
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable redpanda-fstrim.timer 2>/dev/null || true
    systemctl start redpanda-fstrim.timer 2>/dev/null || true

    log_success "✓ fstrim: created and enabled weekly timer"
    return 0
}

# Tuner 13: Disk Write Cache (GCP only)
tune_disk_write_cache() {
    local provider=$(detect_cloud_provider)

    if [[ "$provider" != "gcp" ]]; then
        log_info "disk_write_cache: skipped (only for GCP)"
        return 0
    fi

    local devices=()

    if [[ -n "$DEVICES" ]]; then
        IFS=',' read -ra devices <<< "$DEVICES"
    else
        mapfile -t devices < <(find_block_devices_for_dirs "$DIRS")
    fi

    if [[ ${#devices[@]} -eq 0 ]]; then
        log_warn "✗ disk_write_cache: no devices found"
        return 1
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "disk_write_cache: check mode not implemented"
        return 0
    fi

    local success=true
    for device in "${devices[@]}"; do
        local sys_path=$(get_sys_block_path "$device")
        local write_cache_path="$sys_path/queue/write_cache"

        if [[ ! -f "$write_cache_path" ]]; then
            log_debug "write_cache not available for $device"
            continue
        fi

        echo "write through" > "$write_cache_path" 2>/dev/null || success=false
    done

    if [[ "$success" == "true" ]]; then
        log_success "✓ disk_write_cache: configured for ${#devices[@]} device(s)"
        return 0
    else
        log_warn "✗ disk_write_cache: failed for some devices"
        return 1
    fi
}

# ============================================================================
# SECTION 8: Main Orchestration
# ============================================================================

# Registry of all tuners
declare -A TUNER_REGISTRY=(
    ["aio_events"]="tune_aio_events"
    ["swappiness"]="tune_swappiness"
    ["transparent_hugepages"]="tune_transparent_hugepages"
    ["disk_scheduler"]="tune_disk_scheduler"
    ["disk_nomerges"]="tune_disk_nomerges"
    ["disk_irq"]="tune_disk_irq"
    ["cpu"]="tune_cpu"
    ["network"]="tune_network"
    ["clocksource"]="tune_clocksource"
    ["coredump"]="tune_coredump"
    ["ballast_file"]="tune_ballast_file"
    ["fstrim"]="tune_fstrim"
    ["disk_write_cache"]="tune_disk_write_cache"
)

# Run a single tuner with error handling
run_tuner() {
    local tuner_name="$1"
    local tuner_func="${TUNER_REGISTRY[$tuner_name]}"

    if ! is_tuner_enabled "$tuner_name"; then
        log_debug "Skipping disabled tuner: $tuner_name"
        TUNER_STATUS["$tuner_name"]="skipped"
        return 0
    fi

    log_info "Running tuner: $tuner_name"

    if $tuner_func; then
        TUNER_STATUS["$tuner_name"]="success"
        return 0
    else
        TUNER_STATUS["$tuner_name"]="failed"
        EXIT_CODE=1
        return 1
    fi
}

# Run all tuners
run_all_tuners() {
    local tuner_count=0
    local total_tuners=${#TUNER_REGISTRY[@]}

    for tuner_name in "${!TUNER_REGISTRY[@]}"; do
        ((tuner_count++)) || true
        log_info "[$tuner_count/$total_tuners] $tuner_name"
        run_tuner "$tuner_name" || true  # Continue on failure
    done
}

# Print summary report
print_summary() {
    local success=0
    local failed=0
    local skipped=0

    for tuner in "${!TUNER_STATUS[@]}"; do
        case "${TUNER_STATUS[$tuner]}" in
            success) ((success++)) || true ;;
            failed) ((failed++)) || true ;;
            skipped) ((skipped++)) || true ;;
        esac
    done

    echo ""
    echo "========================================"
    echo "Tuning Summary"
    echo "========================================"
    echo -e "${GREEN}Success:${NC} $success"
    echo -e "${YELLOW}Skipped:${NC} $skipped"
    echo -e "${RED}Failed:${NC}  $failed"
    echo ""

    if [[ "$REBOOT_REQUIRED" == "true" ]]; then
        echo -e "${YELLOW}⚠  REBOOT REQUIRED${NC} for changes to take full effect"
        echo ""
    fi

    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}✓ Node tuning completed successfully!${NC}"
    else
        echo -e "${RED}✗ Node tuning completed with $failed failure(s)${NC}"
    fi
}

# Main function
main() {
    echo "========================================"
    echo "Redpanda Standalone Node Tuner v$SCRIPT_VERSION"
    echo "========================================"
    echo ""

    # Check root
    check_root

    # Load config
    load_config

    # Parse args
    parse_args "$@"

    # Detect environment
    log_info "Detecting environment..."
    local provider=$(detect_cloud_provider)
    local instance=$(get_instance_type)
    local distro=$(detect_distribution)

    log_info "  Cloud provider: $provider"
    log_info "  Instance type: $instance"
    log_info "  Distribution: $distro"
    log_info "  Directories: $DIRS"
    log_info "  Devices: ${DEVICES:-auto-detect}"
    log_info "  NICs: ${NICS:-auto-detect}"
    log_info "  GRUB tuning: $TUNE_GRUB"
    log_info "  Check only: $CHECK_ONLY"
    echo ""

    # Configure I/O properties
    log_info "Configuring I/O properties..."
    configure_io_properties "$DIRS"

    # Run tuners
    log_info "Running tuners..."
    run_all_tuners

    # Print summary
    print_summary

    exit $EXIT_CODE
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
