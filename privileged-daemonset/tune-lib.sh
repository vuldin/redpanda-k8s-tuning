#!/bin/bash
# Redpanda Kubernetes Node Tuner - Helper Library
# Provides functions for Kubernetes API interactions and logging

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Kubernetes API server
KUBE_API_SERVER="${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}"
KUBE_API_PORT="${KUBERNETES_SERVICE_PORT:-443}"
KUBE_API_URL="https://${KUBE_API_SERVER}:${KUBE_API_PORT}"

# ServiceAccount token and namespace
KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBE_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
KUBE_CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# Node name (from downward API)
NODE_NAME="${NODE_NAME:-$(hostname)}"

# Log level
LOG_LEVEL="${LOG_LEVEL:-info}"

# ============================================================================
# Logging Functions
# ============================================================================

log_debug() {
    if [[ "$LOG_LEVEL" == "debug" ]]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [DEBUG] $*" >&2
    fi
}

log_info() {
    if [[ "$LOG_LEVEL" =~ ^(debug|info)$ ]]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [INFO] $*" >&2
    fi
}

log_warn() {
    if [[ "$LOG_LEVEL" =~ ^(debug|info|warn)$ ]]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [WARN] $*" >&2
    fi
}

log_error() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ERROR] $*" >&2
}

# ============================================================================
# Kubernetes API Functions
# ============================================================================

# Get node annotation value
# Usage: get_node_annotation "annotation-key"
get_node_annotation() {
    local annotation_key="$1"
    local annotation_path=".metadata.annotations[\"${annotation_key}\"]"

    kubectl get node "${NODE_NAME}" -o json 2>/dev/null | \
        jq -r "${annotation_path} // empty"
}

# Set node annotation
# Usage: set_node_annotation "annotation-key" "annotation-value"
set_node_annotation() {
    local annotation_key="$1"
    local annotation_value="$2"

    log_debug "Setting node annotation: ${annotation_key}=${annotation_value}"

    kubectl annotate node "${NODE_NAME}" \
        "${annotation_key}=${annotation_value}" \
        --overwrite
}

# Remove node annotation
# Usage: remove_node_annotation "annotation-key"
remove_node_annotation() {
    local annotation_key="$1"

    log_debug "Removing node annotation: ${annotation_key}"

    kubectl annotate node "${NODE_NAME}" \
        "${annotation_key}-" \
        --overwrite || true
}

# Create Kubernetes Event
# Usage: create_event "reason" "message" "type"
# type: Normal, Warning, Error
create_event() {
    local reason="$1"
    local message="$2"
    local event_type="${3:-Normal}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log_debug "Creating event: ${reason} (${event_type})"

    local event_json=$(cat <<EOF
{
  "apiVersion": "v1",
  "kind": "Event",
  "metadata": {
    "name": "redpanda-tuner.${NODE_NAME}.$(date +%s)",
    "namespace": "${KUBE_NAMESPACE}"
  },
  "involvedObject": {
    "kind": "Node",
    "name": "${NODE_NAME}",
    "namespace": "${KUBE_NAMESPACE}"
  },
  "reason": "${reason}",
  "message": "${message}",
  "type": "${event_type}",
  "firstTimestamp": "${timestamp}",
  "lastTimestamp": "${timestamp}",
  "count": 1,
  "source": {
    "component": "redpanda-tuner"
  }
}
EOF
)

    echo "${event_json}" | kubectl create -f - 2>/dev/null || true
}

# Update or create ConfigMap with data
# Usage: update_configmap "configmap-name" "key" "value"
update_configmap() {
    local configmap_name="$1"
    local key="$2"
    local value="$3"

    log_debug "Updating ConfigMap: ${configmap_name}[${key}]"

    # Check if ConfigMap exists
    if kubectl get configmap "${configmap_name}" -n "${KUBE_NAMESPACE}" &>/dev/null; then
        # Update existing ConfigMap
        kubectl get configmap "${configmap_name}" -n "${KUBE_NAMESPACE}" -o json | \
            jq --arg key "${key}" --arg value "${value}" '.data[$key] = $value' | \
            kubectl apply -f -
    else
        # Create new ConfigMap
        kubectl create configmap "${configmap_name}" \
            -n "${KUBE_NAMESPACE}" \
            --from-literal="${key}=${value}"
    fi
}

# Get ConfigMap data value
# Usage: get_configmap_value "configmap-name" "key"
get_configmap_value() {
    local configmap_name="$1"
    local key="$2"

    kubectl get configmap "${configmap_name}" -n "${KUBE_NAMESPACE}" -o json 2>/dev/null | \
        jq -r ".data[\"${key}\"] // empty"
}

# ============================================================================
# Node Status Functions
# ============================================================================

# Check if node is already tuned
is_node_tuned() {
    local tuned_annotation="redpanda.com/tuned"
    local tuned_value=$(get_node_annotation "${tuned_annotation}")

    if [[ "${tuned_value}" == "true" ]]; then
        log_debug "Node is already marked as tuned"
        return 0
    else
        log_debug "Node is not yet tuned"
        return 1
    fi
}

# Check if iotune has been completed
is_iotune_completed() {
    local iotune_annotation="redpanda.com/iotune-completed"
    local iotune_value=$(get_node_annotation "${iotune_annotation}")

    if [[ "${iotune_value}" == "true" ]]; then
        log_debug "iotune has already been completed"
        return 0
    else
        log_debug "iotune has not been completed"
        return 1
    fi
}

# Mark node as tuned
mark_node_tuned() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    set_node_annotation "redpanda.com/tuned" "true"
    set_node_annotation "redpanda.com/tuned-timestamp" "${timestamp}"

    log_info "Node marked as tuned at ${timestamp}"
}

# Mark node as requiring reboot
mark_node_reboot_required() {
    local message="$1"

    set_node_annotation "redpanda.com/reboot-required" "true"
    create_event "RebootRequired" "${message}" "Warning"

    log_warn "Node marked as requiring reboot: ${message}"
}

# Mark iotune as completed
mark_iotune_completed() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    set_node_annotation "redpanda.com/iotune-completed" "true"
    set_node_annotation "redpanda.com/iotune-timestamp" "${timestamp}"

    log_info "iotune marked as completed at ${timestamp}"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Get host path (for chroot operations)
get_host_path() {
    local path="$1"
    echo "/host${path}"
}

# Execute command in host context (using nsenter)
exec_on_host() {
    nsenter --target 1 --mount --uts --ipc --net --pid -- "$@"
}

# Export functions for use in other scripts
export -f log_debug log_info log_warn log_error
export -f get_node_annotation set_node_annotation remove_node_annotation
export -f create_event update_configmap get_configmap_value
export -f is_node_tuned is_iotune_completed
export -f mark_node_tuned mark_node_reboot_required mark_iotune_completed
export -f command_exists get_host_path exec_on_host
