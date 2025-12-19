#!/bin/bash
# Redpanda Node Tuning Validation Script
# Checks if Redpanda tuning has been properly applied to a Kubernetes node
#
# Usage:
#   1. Run locally on node: ./validate-tuning.sh
#   2. Run via kubectl exec: kubectl exec -it NODE -- bash -c "$(cat validate-tuning.sh)"
#   3. Run via SSH: ssh NODE 'bash -s' < validate-tuning.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASS=0
FAIL=0
WARN=0

# ============================================================================
# Helper Functions
# ============================================================================

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARN++))
}

# ============================================================================
# Validation Checks
# ============================================================================

echo "========================================"
echo "Redpanda Node Tuning Validation"
echo "========================================"
echo ""

# Check 1: RPK installed
echo "1. Checking rpk installation..."
if command -v rpk &>/dev/null; then
    RPK_VERSION=$(rpk version | head -1)
    check_pass "rpk is installed: $RPK_VERSION"
else
    check_fail "rpk is not installed"
fi
echo ""

# Check 2: Tuning marker file
echo "2. Checking tuning marker..."
if [ -f "/var/lib/redpanda-tuned" ]; then
    TUNED_DATE=$(cat /var/lib/redpanda-tuned)
    check_pass "Tuning marker exists: $TUNED_DATE"
else
    check_warn "Tuning marker not found (may not have run node-image tuning)"
fi
echo ""

# Check 3: Disk scheduler
echo "3. Checking disk I/O scheduler..."
SCHEDULERS_OK=true
for disk in $(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}'); do
    if [ -f "/sys/block/$disk/queue/scheduler" ]; then
        SCHEDULER=$(cat "/sys/block/$disk/queue/scheduler")
        # Check for none, noop, or deadline
        if [[ "$SCHEDULER" =~ \[(none|noop|deadline)\] ]]; then
            check_pass "Disk $disk scheduler: $SCHEDULER"
        else
            check_fail "Disk $disk scheduler: $SCHEDULER (expected none/noop/deadline)"
            SCHEDULERS_OK=false
        fi
    fi
done
[ "$SCHEDULERS_OK" = false ] && echo "   Hint: Run 'rpk redpanda tune disk' or check startup script"
echo ""

# Check 4: Swappiness
echo "4. Checking swappiness..."
SWAPPINESS=$(cat /proc/sys/vm/swappiness)
if [ "$SWAPPINESS" -le 1 ]; then
    check_pass "Swappiness: $SWAPPINESS"
else
    check_fail "Swappiness: $SWAPPINESS (expected 1 or 0)"
    echo "   Hint: Run 'sysctl vm.swappiness=1' or add to /etc/sysctl.d/"
fi
echo ""

# Check 5: Transparent Huge Pages
echo "5. Checking Transparent Huge Pages..."
if [ -f "/sys/kernel/mm/transparent_hugepage/enabled" ]; then
    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
    if [[ "$THP" == *"[never]"* ]]; then
        check_pass "Transparent Huge Pages: $THP"
    else
        check_fail "Transparent Huge Pages: $THP (expected [never])"
        echo "   Hint: Run 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'"
    fi
else
    check_warn "Transparent Huge Pages: Not available on this system"
fi
echo ""

# Check 6: CPU Governor
echo "6. Checking CPU governor..."
GOVERNORS_OK=true
CPU_COUNT=$(nproc)
CHECKED_CPUS=0
for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    if [ -f "$cpu" ]; then
        GOVERNOR=$(cat "$cpu")
        CPU_NUM=$(echo "$cpu" | grep -o 'cpu[0-9]*' | grep -o '[0-9]*')

        # Only check first and last CPU to keep output concise
        if [ "$CPU_NUM" -eq 0 ] || [ "$CPU_NUM" -eq $((CPU_COUNT - 1)) ]; then
            if [ "$GOVERNOR" = "performance" ]; then
                check_pass "CPU $CPU_NUM governor: $GOVERNOR"
            else
                check_warn "CPU $CPU_NUM governor: $GOVERNOR (recommended: performance)"
                GOVERNORS_OK=false
            fi
        fi
        ((CHECKED_CPUS++))
    fi
done

if [ "$CHECKED_CPUS" -eq 0 ]; then
    check_warn "CPU governor: Not configurable on this system"
elif [ "$CPU_COUNT" -gt 2 ]; then
    echo "   (Checked CPU 0 and CPU $((CPU_COUNT - 1)) of $CPU_COUNT total)"
fi
[ "$GOVERNORS_OK" = false ] && echo "   Hint: Run 'rpk redpanda tune cpu' or check BIOS settings"
echo ""

# Check 7: AIO limits
echo "7. Checking AIO limits..."
AIO_MAX_NR=$(cat /proc/sys/fs/aio-max-nr)
# Redpanda recommends at least 1048576
if [ "$AIO_MAX_NR" -ge 1048576 ]; then
    check_pass "AIO max nr: $AIO_MAX_NR"
else
    check_fail "AIO max nr: $AIO_MAX_NR (recommended: >= 1048576)"
    echo "   Hint: Run 'sysctl fs.aio-max-nr=1048576' or add to /etc/sysctl.d/"
fi
echo ""

# Check 8: Network interface settings (if applicable)
echo "8. Checking network interface settings..."
DEFAULT_NIC=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$DEFAULT_NIC" ]; then
    # Check if network interface tuning has been applied
    if ethtool -k "$DEFAULT_NIC" 2>/dev/null | grep -q "tcp-segmentation-offload: on"; then
        check_pass "Network interface $DEFAULT_NIC: TSO enabled"
    else
        check_warn "Network interface $DEFAULT_NIC: TSO not enabled (optional optimization)"
    fi
else
    check_warn "Could not detect default network interface"
fi
echo ""

# Check 9: iotune results
echo "9. Checking iotune results..."
if [ -f "/etc/redpanda/io-config.yaml" ]; then
    check_pass "iotune results found: /etc/redpanda/io-config.yaml"
    echo "   $(grep -E 'read_iops|write_iops' /etc/redpanda/io-config.yaml | head -2 | sed 's/^/   /')"
else
    check_warn "iotune results not found (run 'rpk iotune' to benchmark)"
fi
echo ""

# Check 10: Systemd service
echo "10. Checking systemd persistence..."
if systemctl is-enabled redpanda-tune.service &>/dev/null; then
    check_pass "Systemd service enabled: redpanda-tune.service"
else
    check_warn "Systemd service not found (tuning may not persist after reboot)"
    echo "   Hint: Create /etc/systemd/system/redpanda-tune.service"
fi
echo ""

# Check 11: Clock source
echo "11. Checking clock source..."
if [ -f "/sys/devices/system/clocksource/clocksource0/current_clocksource" ]; then
    CLOCKSOURCE=$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)
    if [ "$CLOCKSOURCE" = "tsc" ]; then
        check_pass "Clock source: $CLOCKSOURCE"
    else
        check_warn "Clock source: $CLOCKSOURCE (tsc recommended for best performance)"
    fi
else
    check_warn "Clock source: Cannot determine"
fi
echo ""

# ============================================================================
# Summary
# ============================================================================

echo "========================================"
echo "Validation Summary"
echo "========================================"
echo -e "${GREEN}Passed:${NC}  $PASS"
echo -e "${YELLOW}Warnings:${NC} $WARN"
echo -e "${RED}Failed:${NC}  $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}✓ Node appears to be properly tuned for Redpanda!${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ Node has $FAIL failed checks. Review the output above and apply fixes.${NC}"
    EXIT_CODE=1
fi

if [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Node has $WARN warnings. These are optional but recommended for optimal performance.${NC}"
fi

echo ""
echo "For more information on tuning, see:"
echo "  https://docs.redpanda.com/current/reference/rpk/rpk-redpanda/rpk-redpanda-tune/"
echo ""

exit $EXIT_CODE
