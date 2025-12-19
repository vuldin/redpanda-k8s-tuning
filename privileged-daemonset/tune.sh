#!/bin/bash
# Redpanda Kubernetes Node Tuner
# Main script that orchestrates node tuning and iotune benchmarking

set -euo pipefail

# Source helper library
source /opt/redpanda-tuner/tune-lib.sh

# ============================================================================
# Configuration from ConfigMap (set via environment variables)
# ============================================================================

ENABLE_TUNING="${ENABLE_TUNING:-true}"
ENABLE_IOTUNE="${ENABLE_IOTUNE:-true}"
IOTUNE_DURATION="${IOTUNE_DURATION:-10m}"
IOTUNE_DIRECTORY="${IOTUNE_DIRECTORY:-/mnt/vectorized}"
TUNING_TIMEOUT="${TUNING_TIMEOUT:-30m}"
FORCE_RETUNE="${FORCE_RETUNE:-false}"
RPK_TUNE_EXTRA_ARGS="${RPK_TUNE_EXTRA_ARGS:-}"

# ============================================================================
# Main Functions
# ============================================================================

run_iotune() {
    log_info "Starting iotune benchmark on ${NODE_NAME}"
    log_info "Duration: ${IOTUNE_DURATION}, Directory: ${IOTUNE_DIRECTORY}"

    # Check if iotune directory exists on host
    local host_iotune_dir=$(get_host_path "${IOTUNE_DIRECTORY}")
    if [[ ! -d "${host_iotune_dir}" ]]; then
        log_warn "iotune directory ${IOTUNE_DIRECTORY} does not exist on host, creating it"
        mkdir -p "${host_iotune_dir}"
    fi

    # Run iotune
    local iotune_output_file="/tmp/iotune-${NODE_NAME}.yaml"

    log_info "Running: rpk iotune --duration ${IOTUNE_DURATION} --directory ${IOTUNE_DIRECTORY}"

    if timeout "${TUNING_TIMEOUT}" rpk iotune \
        --duration "${IOTUNE_DURATION}" \
        --directory "${IOTUNE_DIRECTORY}" \
        --out "${iotune_output_file}"; then

        log_info "iotune completed successfully"

        # Store results in ConfigMap
        if [[ -f "${iotune_output_file}" ]]; then
            local iotune_results=$(cat "${iotune_output_file}")
            update_configmap "redpanda-iotune-results" "${NODE_NAME}.yaml" "${iotune_results}"
            log_info "iotune results stored in ConfigMap: redpanda-iotune-results[${NODE_NAME}.yaml]"

            # Mark iotune as completed
            mark_iotune_completed
            create_event "IotuneCompleted" "iotune benchmark completed successfully on ${NODE_NAME}" "Normal"
        else
            log_error "iotune output file not found: ${iotune_output_file}"
            return 1
        fi
    else
        log_error "iotune failed or timed out"
        create_event "IotuneFailed" "iotune benchmark failed on ${NODE_NAME}" "Warning"
        return 1
    fi

    return 0
}

run_rpk_tune() {
    log_info "Starting rpk redpanda tune on ${NODE_NAME}"

    # Set production mode first
    log_info "Setting Redpanda mode to production"
    if ! rpk redpanda mode production; then
        log_warn "Failed to set production mode, continuing anyway"
    fi

    # Run all tuners without allowing reboots
    log_info "Running: rpk redpanda tune all --reboot-allowed=false ${RPK_TUNE_EXTRA_ARGS}"

    local tune_output_file="/tmp/tune-output-${NODE_NAME}.txt"
    local tune_exit_code=0

    if timeout "${TUNING_TIMEOUT}" rpk redpanda tune all \
        --reboot-allowed=false \
        ${RPK_TUNE_EXTRA_ARGS} \
        2>&1 | tee "${tune_output_file}"; then

        tune_exit_code=${PIPESTATUS[0]}
    else
        tune_exit_code=$?
    fi

    # Check for reboot requirements in output
    if grep -qi "reboot" "${tune_output_file}"; then
        local reboot_message="Some tuners may require a node reboot to take full effect. Please review logs and schedule a maintenance window."
        mark_node_reboot_required "${reboot_message}"
        log_warn "${reboot_message}"
    fi

    # Check for failed tuners
    if grep -qi "failed\|error" "${tune_output_file}"; then
        log_warn "Some tuners may have failed, check logs for details"
        create_event "TuningWarning" "Some tuners completed with warnings on ${NODE_NAME}" "Warning"
    fi

    if [[ ${tune_exit_code} -eq 0 ]]; then
        log_info "rpk redpanda tune completed successfully"
        create_event "TuningCompleted" "Node tuning completed successfully on ${NODE_NAME}" "Normal"
        return 0
    else
        log_error "rpk redpanda tune failed with exit code ${tune_exit_code}"
        create_event "TuningFailed" "Node tuning failed on ${NODE_NAME} with exit code ${tune_exit_code}" "Error"
        return 1
    fi
}

main() {
    log_info "===================================================="
    log_info "Redpanda Kubernetes Node Tuner"
    log_info "Node: ${NODE_NAME}"
    log_info "Namespace: ${KUBE_NAMESPACE}"
    log_info "===================================================="

    # Check prerequisites
    if ! command_exists rpk; then
        log_error "rpk command not found"
        exit 1
    fi

    if ! command_exists kubectl; then
        log_error "kubectl command not found"
        exit 1
    fi

    # Check if force retune is enabled
    if [[ "${FORCE_RETUNE}" != "true" ]]; then
        # Check if node is already tuned
        if is_node_tuned; then
            log_info "Node ${NODE_NAME} is already tuned (use FORCE_RETUNE=true to retune)"
            log_info "Entering sleep mode for log access..."
            create_event "AlreadyTuned" "Node ${NODE_NAME} is already tuned, skipping" "Normal"

            # Keep container running for log access
            while true; do
                sleep 3600
            done
        fi
    else
        log_info "Force retune enabled, proceeding with tuning"
        remove_node_annotation "redpanda.com/tuned"
        remove_node_annotation "redpanda.com/iotune-completed"
        remove_node_annotation "redpanda.com/reboot-required"
    fi

    local tuning_success=true
    local iotune_success=true

    # Run iotune if enabled and not already completed
    if [[ "${ENABLE_IOTUNE}" == "true" ]]; then
        if [[ "${FORCE_RETUNE}" != "true" ]] && is_iotune_completed; then
            log_info "iotune already completed on ${NODE_NAME}, skipping"
        else
            if ! run_iotune; then
                log_error "iotune failed"
                iotune_success=false
                # Don't exit, continue with tuning
            fi
        fi
    else
        log_info "iotune is disabled, skipping"
    fi

    # Run rpk tune if enabled
    if [[ "${ENABLE_TUNING}" == "true" ]]; then
        if ! run_rpk_tune; then
            log_error "rpk tune failed"
            tuning_success=false
        fi
    else
        log_info "Tuning is disabled, skipping"
    fi

    # Mark node as tuned if everything succeeded
    if [[ "${tuning_success}" == "true" ]]; then
        mark_node_tuned

        if [[ "${iotune_success}" == "true" ]]; then
            log_info "===================================================="
            log_info "Tuning completed successfully!"
            log_info "Node: ${NODE_NAME}"
            log_info "iotune: ✓"
            log_info "rpk tune: ✓"
            log_info "===================================================="
        else
            log_warn "===================================================="
            log_warn "Tuning completed with warnings"
            log_warn "Node: ${NODE_NAME}"
            log_warn "iotune: ✗"
            log_warn "rpk tune: ✓"
            log_warn "===================================================="
        fi

        # Keep container running for log access
        log_info "Entering sleep mode for log access..."
        while true; do
            sleep 3600
        done
    else
        log_error "===================================================="
        log_error "Tuning failed!"
        log_error "Node: ${NODE_NAME}"
        log_error "Check logs for details"
        log_error "===================================================="
        exit 1
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

# Trap errors
trap 'log_error "Script failed at line $LINENO"' ERR

# Run main function
main "$@"
