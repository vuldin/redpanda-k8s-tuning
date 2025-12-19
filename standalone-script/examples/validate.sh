#!/bin/bash
# Validate Redpanda Node Tuning
# Checks if tuning has been properly applied

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
WARN=0

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

echo "========================================"
echo "Redpanda Node Tuning Validation"
echo "========================================"
echo ""

# Check 1: AIO Events
echo "1. Checking AIO events..."
AIO=$(cat /proc/sys/fs/aio-max-nr)
if [[ $AIO -ge 10000137 ]]; then
    check_pass "AIO max events: $AIO"
else
    check_fail "AIO max events: $AIO (expected >= 10000137)"
fi
echo ""

# Check 2: Swappiness
echo "2. Checking swappiness..."
SWAP=$(cat /proc/sys/vm/swappiness)
if [[ $SWAP -le 1 ]]; then
    check_pass "Swappiness: $SWAP"
else
    check_fail "Swappiness: $SWAP (expected <= 1)"
fi
echo ""

# Check 3: THP
echo "3. Checking Transparent Huge Pages..."
if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
    if [[ "$THP" == *"[never]"* ]]; then
        check_pass "THP: disabled"
    else
        check_fail "THP: $THP (expected [never])"
    fi
elif [[ -f /sys/kernel/mm/redhat_transparent_hugepage/enabled ]]; then
    THP=$(cat /sys/kernel/mm/redhat_transparent_hugepage/enabled)
    if [[ "$THP" == *"[never]"* ]]; then
        check_pass "THP: disabled"
    else
        check_fail "THP: $THP (expected [never])"
    fi
else
    check_warn "THP: not available on this system"
fi
echo ""

# Check 4: Disk Scheduler (sample first disk)
echo "4. Checking disk scheduler..."
FIRST_DISK=$(lsblk -d -n -o NAME,TYPE | grep disk | head -1 | awk '{print $1}')
if [[ -n "$FIRST_DISK" ]] && [[ -f "/sys/block/$FIRST_DISK/queue/scheduler" ]]; then
    SCHED=$(cat "/sys/block/$FIRST_DISK/queue/scheduler")
    if [[ "$SCHED" == *"[none]"* ]] || [[ "$SCHED" == *"[noop]"* ]]; then
        check_pass "Disk scheduler ($FIRST_DISK): $SCHED"
    else
        check_fail "Disk scheduler ($FIRST_DISK): $SCHED (expected none/noop)"
    fi
else
    check_warn "Disk scheduler: cannot check"
fi
echo ""

# Check 5: CPU Governor (sample first CPU)
echo "5. Checking CPU governor..."
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    if [[ "$GOV" == "performance" ]]; then
        check_pass "CPU governor: $GOV"
    else
        check_warn "CPU governor: $GOV (recommended: performance)"
    fi
else
    check_warn "CPU governor: not configurable on this system"
fi
echo ""

# Check 6: I/O Config
echo "6. Checking I/O configuration..."
if [[ -f /etc/redpanda/io-config.yaml ]]; then
    check_pass "I/O config found: /etc/redpanda/io-config.yaml"
else
    check_warn "I/O config not found (run redpanda-tune.sh)"
fi
echo ""

# Summary
echo "========================================"
echo "Validation Summary"
echo "========================================"
echo -e "${GREEN}Passed:${NC}  $PASS"
echo -e "${YELLOW}Warnings:${NC} $WARN"
echo -e "${RED}Failed:${NC}  $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✓ Node appears to be properly tuned!${NC}"
    exit 0
else
    echo -e "${RED}✗ Node has $FAIL failed checks. Run: sudo ./redpanda-tune.sh${NC}"
    exit 1
fi
