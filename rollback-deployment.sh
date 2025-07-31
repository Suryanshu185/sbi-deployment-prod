#!/bin/bash
# SBI Production Rollback Script
# Provides rollback capabilities for failed deployments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/rollback_$(date +%Y%m%d_%H%M%S).log"
CONFIG_FILE="$SCRIPT_DIR/deployment.conf"

# Create logs directory
mkdir -p "$SCRIPT_DIR/logs"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" | tee -a "$LOG_FILE"
}

usage() {
    cat << EOF
SBI Production Rollback Script

Usage: $0 [OPTIONS]

Options:
    -r, --revision REVISION    Rollback to specific Helm revision (default: previous)
    -b, --backup BACKUP_FILE   Restore from specific backup file
    -f, --force                Force rollback without confirmation
    -h, --help                 Show this help message

Examples:
    $0                         # Rollback to previous revision
    $0 -r 5                    # Rollback to revision 5
    $0 -b backup.yaml          # Restore from backup file
    $0 -f                      # Force rollback without prompt

EOF
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    source "$CONFIG_FILE"
    
    if [[ -z "${RELEASE_NAME:-}" || -z "${NAMESPACE:-}" ]]; then
        error "RELEASE_NAME and NAMESPACE must be set in configuration"
        exit 1
    fi
}

# Check if deployment exists
check_deployment() {
    log "Checking if deployment exists..."
    
    if ! kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        error "Deployment $RELEASE_NAME not found in namespace $NAMESPACE"
        exit 1
    fi
    
    log "Deployment found: $RELEASE_NAME in namespace $NAMESPACE"
}

# Get Helm release history
get_release_history() {
    log "Getting Helm release history..."
    
    if ! helm list -n "$NAMESPACE" | grep -q "$RELEASE_NAME"; then
        error "Helm release $RELEASE_NAME not found in namespace $NAMESPACE"
        exit 1
    fi
    
    echo "Current Helm release history:"
    helm history "$RELEASE_NAME" -n "$NAMESPACE"
    echo
}

# Perform Helm rollback
helm_rollback() {
    local revision="${1:-0}"  # 0 means previous revision
    
    log "Starting Helm rollback for release: $RELEASE_NAME"
    
    if [[ "$revision" == "0" ]]; then
        log "Rolling back to previous revision..."
    else
        log "Rolling back to revision: $revision"
    fi
    
    # Create backup before rollback
    create_rollback_backup
    
    # Perform rollback
    if helm rollback "$RELEASE_NAME" "$revision" -n "$NAMESPACE" --wait --timeout=10m; then
        log "Helm rollback completed successfully"
    else
        error "Helm rollback failed"
        return 1
    fi
    
    # Verify rollback
    verify_rollback
}

# Restore from backup file
restore_from_backup() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        exit 1
    fi
    
    log "Restoring from backup file: $backup_file"
    
    # Validate backup file
    if ! kubectl apply --dry-run=client -f "$backup_file" >/dev/null 2>&1; then
        error "Invalid backup file: $backup_file"
        exit 1
    fi
    
    # Create backup of current state
    create_rollback_backup
    
    # Apply backup
    if kubectl apply -f "$backup_file"; then
        log "Backup restoration completed successfully"
    else
        error "Backup restoration failed"
        return 1
    fi
    
    # Verify restoration
    verify_rollback
}

# Create backup before rollback
create_rollback_backup() {
    local backup_file="$SCRIPT_DIR/backups/pre-rollback-$(date +%Y%m%d_%H%M%S).yaml"
    
    log "Creating backup before rollback: $backup_file"
    
    mkdir -p "$SCRIPT_DIR/backups"
    
    if kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o yaml > "$backup_file" 2>/dev/null; then
        log "Backup created successfully: $backup_file"
    else
        warn "Failed to create backup - proceeding anyway"
    fi
}

# Verify rollback success
verify_rollback() {
    log "Verifying rollback..."
    
    # Wait for rollout to complete
    if kubectl rollout status deployment/"$RELEASE_NAME" -n "$NAMESPACE" --timeout=600s; then
        log "Deployment rollout completed successfully"
    else
        error "Deployment rollout failed"
        return 1
    fi
    
    # Check pod status
    local ready_replicas available_replicas
    ready_replicas=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    available_replicas=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    
    if [[ "$ready_replicas" -gt 0 && "$available_replicas" -gt 0 ]]; then
        log "Deployment verification successful: $ready_replicas ready, $available_replicas available"
    else
        error "Deployment verification failed: $ready_replicas ready, $available_replicas available"
        return 1
    fi
    
    # Test application health if health endpoint exists
    test_application_health
}

# Test application health
test_application_health() {
    log "Testing application health..."
    
    # Get service endpoint
    local service_ip
    service_ip=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    
    if [[ -n "$service_ip" ]]; then
        # Try health check endpoint
        if kubectl run health-check --rm -i --restart=Never --image=curlimages/curl -- \
           curl -f "http://$service_ip:8080/health" --max-time 10 >/dev/null 2>&1; then
            log "Application health check passed"
        else
            warn "Application health check failed or endpoint not available"
        fi
    else
        warn "Service not found - skipping health check"
    fi
}

# Show available backups
list_backups() {
    log "Available backup files:"
    
    local backup_dir="$SCRIPT_DIR/backups"
    if [[ -d "$backup_dir" ]] && [[ $(ls -A "$backup_dir" 2>/dev/null) ]]; then
        ls -la "$backup_dir"/*.yaml 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    else
        log "No backup files found in $backup_dir"
    fi
}

# Confirm rollback action
confirm_rollback() {
    if [[ "${FORCE_ROLLBACK:-false}" == "true" ]]; then
        return 0
    fi
    
    echo
    warn "WARNING: This will rollback the SBI production deployment!"
    warn "Current deployment: $RELEASE_NAME in namespace $NAMESPACE"
    echo
    
    read -p "Are you sure you want to proceed? (yes/no): " confirmation
    case $confirmation in
        yes|YES|y|Y)
            log "Rollback confirmed by user"
            return 0
            ;;
        *)
            log "Rollback cancelled by user"
            exit 0
            ;;
    esac
}

# Main function
main() {
    local revision=""
    local backup_file=""
    local force=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--revision)
                revision="$2"
                shift 2
                ;;
            -b|--backup)
                backup_file="$2"
                shift 2
                ;;
            -f|--force)
                force=true
                FORCE_ROLLBACK=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    log "==================== SBI PRODUCTION ROLLBACK ===================="
    
    # Load configuration
    load_config
    
    # Check deployment exists
    check_deployment
    
    # Show current state
    get_release_history
    
    # Show available backups if requested
    if [[ -z "$revision" && -z "$backup_file" ]]; then
        list_backups
        echo
    fi
    
    # Confirm rollback
    confirm_rollback
    
    # Perform rollback
    if [[ -n "$backup_file" ]]; then
        restore_from_backup "$backup_file"
    else
        helm_rollback "$revision"
    fi
    
    log "==================== ROLLBACK COMPLETED ===================="
    log "SBI production rollback completed successfully"
    
    # Send notification
    log "Sending rollback notification..."
    # Integration point for alerting system
}

# Execute main function
main "$@"