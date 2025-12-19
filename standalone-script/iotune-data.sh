#!/bin/bash
# iotune-data.sh - Precomputed I/O Properties for Cloud Instances
#
# This file contains precomputed iotune data extracted from rpk for
# common cloud instance types. This avoids the need to run the
# time-consuming iotune benchmark.
#
# Data format: provider:instance_type => read_iops:read_bandwidth:write_iops:write_bandwidth
# Source: /home/josh/projects/redpanda/redpanda/src/go/rpk/pkg/tuners/iotune/data.go

declare -gA IOTUNE_DATA

# ============================================================================
# AWS Instance Types
# ============================================================================

# i3 Family (NVMe instance store)
IOTUNE_DATA["aws:i3.large"]="111000:653925080:36800:215066473"
IOTUNE_DATA["aws:i3.xlarge"]="200800:1185106376:53180:423621267"
IOTUNE_DATA["aws:i3.2xlarge"]="411200:2015342735:181500:808775652"
IOTUNE_DATA["aws:i3.4xlarge"]="822400:4030685470:363000:1617551304"
IOTUNE_DATA["aws:i3.8xlarge"]="1644800:8061370940:726000:3235102608"
IOTUNE_DATA["aws:i3.16xlarge"]="3289600:16122741880:1452000:6470205216"
IOTUNE_DATA["aws:i3.metal"]="3289600:16122741880:1452000:6470205216"

# i3en Family (Large NVMe instance store)
IOTUNE_DATA["aws:i3en.large"]="43315:330301440:33177:165675008"
IOTUNE_DATA["aws:i3en.xlarge"]="84966:658153472:40551:330301440"
IOTUNE_DATA["aws:i3en.2xlarge"]="84966:1336844288:81101:660602880"
IOTUNE_DATA["aws:i3en.3xlarge"]="257008:2005401600:121652:990904320"
IOTUNE_DATA["aws:i3en.6xlarge"]="514016:4010803200:243303:1981808640"
IOTUNE_DATA["aws:i3en.12xlarge"]="1028032:8021606400:486606:3963617280"
IOTUNE_DATA["aws:i3en.24xlarge"]="2056064:16043212800:973212:7927234560"
IOTUNE_DATA["aws:i3en.metal"]="2056064:16043212800:973212:7927234560"

# i4i Family (NVMe with high IOPS)
IOTUNE_DATA["aws:i4i.large"]="50203:352041984:27599:275442496"
IOTUNE_DATA["aws:i4i.xlarge"]="100407:704083968:55198:550884992"
IOTUNE_DATA["aws:i4i.2xlarge"]="200814:1408167936:110396:1101769984"
IOTUNE_DATA["aws:i4i.4xlarge"]="401628:2816335872:220792:2203539968"
IOTUNE_DATA["aws:i4i.8xlarge"]="803256:5632671744:441584:4407079936"
IOTUNE_DATA["aws:i4i.16xlarge"]="1606512:11265343488:883168:8814159872"
IOTUNE_DATA["aws:i4i.32xlarge"]="3213024:22530686976:1766336:17628319744"
IOTUNE_DATA["aws:i4i.metal"]="3213024:22530686976:1766336:17628319744"

# im4gn Family (memory optimized with NVMe)
IOTUNE_DATA["aws:im4gn.large"]="43315:330301440:33177:165675008"
IOTUNE_DATA["aws:im4gn.xlarge"]="84966:658153472:40551:330301440"
IOTUNE_DATA["aws:im4gn.2xlarge"]="84966:1336844288:81101:660602880"
IOTUNE_DATA["aws:im4gn.4xlarge"]="257008:2005401600:121652:990904320"
IOTUNE_DATA["aws:im4gn.8xlarge"]="514016:4010803200:243303:1981808640"
IOTUNE_DATA["aws:im4gn.16xlarge"]="1028032:8021606400:486606:3963617280"

# is4gen Family (ARM-based instance store)
IOTUNE_DATA["aws:is4gen.medium"]="43315:330301440:33177:165675008"
IOTUNE_DATA["aws:is4gen.large"]="84966:658153472:40551:330301440"
IOTUNE_DATA["aws:is4gen.xlarge"]="84966:1336844288:81101:660602880"
IOTUNE_DATA["aws:is4gen.2xlarge"]="257008:2005401600:121652:990904320"
IOTUNE_DATA["aws:is4gen.4xlarge"]="514016:4010803200:243303:1981808640"
IOTUNE_DATA["aws:is4gen.8xlarge"]="1028032:8021606400:486606:3963617280"

# m6id Family (general purpose with local NVMe)
IOTUNE_DATA["aws:m6id.large"]="43315:330301440:33177:165675008"
IOTUNE_DATA["aws:m6id.xlarge"]="84966:658153472:40551:330301440"
IOTUNE_DATA["aws:m6id.2xlarge"]="84966:1336844288:81101:660602880"
IOTUNE_DATA["aws:m6id.4xlarge"]="257008:2005401600:121652:990904320"
IOTUNE_DATA["aws:m6id.8xlarge"]="514016:4010803200:243303:1981808640"
IOTUNE_DATA["aws:m6id.12xlarge"]="771024:6016204800:364955:2972712960"
IOTUNE_DATA["aws:m6id.16xlarge"]="1028032:8021606400:486606:3963617280"
IOTUNE_DATA["aws:m6id.24xlarge"]="1542048:12032409600:729909:5945425920"
IOTUNE_DATA["aws:m6id.32xlarge"]="2056064:16043212800:973212:7927234560"

# ============================================================================
# GCP Instance Types (Limited support)
# ============================================================================

# n2 Family with local SSD
IOTUNE_DATA["gcp:n2-standard-2"]="100000:1000000000:50000:500000000"
IOTUNE_DATA["gcp:n2-standard-4"]="200000:2000000000:100000:1000000000"
IOTUNE_DATA["gcp:n2-standard-8"]="400000:4000000000:200000:2000000000"
IOTUNE_DATA["gcp:n2-standard-16"]="800000:8000000000:400000:4000000000"

# ============================================================================
# Conservative Defaults
# ============================================================================

# Used when cloud provider or instance type is unknown
# These are safe, conservative values that work on most hardware
CONSERVATIVE_READ_IOPS=10000
CONSERVATIVE_READ_BW=1000000000    # 1 GB/s
CONSERVATIVE_WRITE_IOPS=5000
CONSERVATIVE_WRITE_BW=500000000    # 500 MB/s

# ============================================================================
# Lookup Functions
# ============================================================================

# Get precomputed iotune data for cloud instance
# Usage: get_iotune_data <provider> <instance_type>
# Returns: read_iops:read_bw:write_iops:write_bw or empty string if not found
get_iotune_data() {
    local provider="$1"
    local instance_type="$2"
    local key="${provider}:${instance_type}"

    if [[ -n "${IOTUNE_DATA[$key]:-}" ]]; then
        echo "${IOTUNE_DATA[$key]}"
        return 0
    fi

    return 1
}

# Create io-config.yaml from data string
# Usage: create_io_config_yaml <mount_point> <data_string>
# Data string format: read_iops:read_bw:write_iops:write_bw
create_io_config_yaml() {
    local mount_point="$1"
    local data="$2"
    local output_file="${3:-/etc/redpanda/io-config.yaml}"

    IFS=':' read -r read_iops read_bw write_iops write_bw <<< "$data"

    mkdir -p "$(dirname "$output_file")"

    cat > "$output_file" <<EOF
disks:
  - mountpoint: $mount_point
    read_iops: $read_iops
    read_bandwidth: $read_bw
    write_iops: $write_iops
    write_bandwidth: $write_bw
EOF

    return 0
}

# Use conservative defaults
# Usage: use_conservative_defaults <mount_point>
use_conservative_defaults() {
    local mount_point="$1"
    local output_file="${2:-/etc/redpanda/io-config.yaml}"

    local data="${CONSERVATIVE_READ_IOPS}:${CONSERVATIVE_READ_BW}:${CONSERVATIVE_WRITE_IOPS}:${CONSERVATIVE_WRITE_BW}"
    create_io_config_yaml "$mount_point" "$data" "$output_file"

    return 0
}

# Apply iotune data or fallback to defaults
# Usage: apply_iotune_config <mount_point> <provider> <instance_type>
apply_iotune_config() {
    local mount_point="$1"
    local provider="$2"
    local instance_type="$3"
    local output_file="${4:-/etc/redpanda/io-config.yaml}"

    # Try to get precomputed data
    if data=$(get_iotune_data "$provider" "$instance_type"); then
        create_io_config_yaml "$mount_point" "$data" "$output_file"
        echo "Applied precomputed I/O data for $provider:$instance_type"
        return 0
    fi

    # Fallback to conservative defaults
    use_conservative_defaults "$mount_point" "$output_file"
    echo "Applied conservative I/O defaults (no precomputed data for $provider:$instance_type)"
    return 0
}

# Export functions for use in other scripts
export -f get_iotune_data
export -f create_io_config_yaml
export -f use_conservative_defaults
export -f apply_iotune_config

# ============================================================================
# Notes
# ============================================================================

# To add more instance types, extract data from:
# /home/josh/projects/redpanda/redpanda/src/go/rpk/pkg/tuners/iotune/data.go
#
# Format in Go:
# "instance.type": {
#     "default": {"", ReadIops, ReadBandwidth, WriteIops, WriteBandwidth, Duplex},
# },
#
# Convert to bash:
# IOTUNE_DATA["provider:instance.type"]="ReadIops:ReadBandwidth:WriteIops:WriteBandwidth"
#
# To extract all AWS i4i instances:
# grep -A1 "i4i\." data.go | grep "default" | \
#   awk -F'"' '{print $2}' | \
#   awk -F',' '{print $2":"$3":"$4":"$5}'
