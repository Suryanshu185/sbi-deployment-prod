#!/bin/bash
# SBI Production Deployment Bootstrap Script
# This script securely manages the deployment process for SBI production systems

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly CONFIG_FILE="${SCRIPT_DIR}/deployment.conf"
readonly VAULT_FILE="${SCRIPT_DIR}/vars/vault.yml"
readonly BACKUP_DIR="${SCRIPT_DIR}/backups"
readonly TMP_DIR="${SCRIPT_DIR}/tmp"

# Create required directories
mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$TMP_DIR"

readonly LOG_FILE="$LOG_DIR/sbi_deploy_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="$TMP_DIR/deployment.lock"

# Logging functions
log_info() {
    local message="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $message" | tee -a "$LOG_FILE"
}

log_warn() {
    local message="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $message" | tee -a "$LOG_FILE"
}

error_exit() {
    log_error "$*"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    log_info "Performing cleanup..."
    rm -f "$LOCK_FILE"
    # Clean up any temporary credentials
    unset ANSIBLE_VAULT_PASSWORD 2>/dev/null || true
}

# Signal handlers
trap cleanup EXIT
trap 'error_exit "Script interrupted by user"' INT TERM

# Lock mechanism to prevent concurrent deployments
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if ps -p "$lock_pid" > /dev/null 2>&1; then
            error_exit "Another deployment is already running (PID: $lock_pid)"
        else
            log_warn "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Deployment lock acquired"
}

# Validation functions
validate_environment() {
    log_info "Validating environment..."
    
    # Check if running as root (should not be)
    if [[ $EUID -eq 0 ]]; then
        error_exit "This script should not be run as root for security reasons"
    fi
    
    # Check required files
    local required_files=("$CONFIG_FILE" "$VAULT_FILE")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Required file not found: $file"
        fi
    done
    
    # Check disk space (minimum 5GB free)
    local available_space
    available_space=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 5242880 ]]; then  # 5GB in KB
        error_exit "Insufficient disk space. At least 5GB required."
    fi
    
    log_info "Environment validation completed"
}

validate_dependencies() {
    log_info "Validating dependencies..."
    
    local required_commands=("ansible-playbook" "docker" "kubectl" "helm")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "$cmd not found, attempting to install..."
            install_dependencies
            break
        fi
    done
    
    # Validate versions
    local ansible_version
    ansible_version=$(ansible-playbook --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    log_info "Ansible version: $ansible_version"
    
    local docker_version
    docker_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
    log_info "Docker version: $docker_version"
    
    local kubectl_version
    kubectl_version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown")
    log_info "kubectl version: $kubectl_version"
    
    local helm_version
    helm_version=$(helm version --short 2>/dev/null || echo "unknown")
    log_info "Helm version: $helm_version"
}

install_dependencies() {
    log_info "Installing missing dependencies..."
    
    if [ ! -f ".env_setup_done" ]; then
        log_info "Running environment setup playbook..."
        if ansible-playbook setup-environment.yml; then
            touch .env_setup_done
            log_info "Environment setup completed"
        else
            error_exit "Environment setup failed"
        fi
    fi
}

validate_vault_access() {
    log_info "Validating vault access..."
    
    # Check if vault password file exists
    if [[ ! -f ".vault_pass" ]]; then
        log_warn "Vault password file not found. Please create .vault_pass file with your vault password"
        read -s -p "Enter Ansible Vault password: " VAULT_PASSWORD
        echo
        echo "$VAULT_PASSWORD" > .vault_pass
        chmod 600 .vault_pass
        export ANSIBLE_VAULT_PASSWORD="$VAULT_PASSWORD"
    fi
    
    # Test vault decryption
    if ! ansible-vault view "$VAULT_FILE" >/dev/null 2>&1; then
        error_exit "Cannot decrypt vault file. Please check your vault password."
    fi
    
    log_info "Vault access validated"
}

validate_kubernetes_access() {
    log_info "Validating Kubernetes access..."
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error_exit "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    fi
    
    # Check if required namespace exists
    source "$CONFIG_FILE"
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_warn "Namespace $NAMESPACE does not exist, creating..."
        kubectl create namespace "$NAMESPACE"
    fi
    
    log_info "Kubernetes access validated"
}

validate_configuration() {
    log_info "Validating configuration..."
    
    source "$CONFIG_FILE"
    
    # Validate required variables
    local required_vars=(
        "NEXUS_REGISTRY" "HARBOR_REGISTRY" "IMAGE_NAME"
        "HELM_CHART_PATH" "RELEASE_NAME" "NAMESPACE"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error_exit "Required configuration variable $var is not set"
        fi
    done
    
    # Validate Helm chart
    if [[ ! -d "$HELM_CHART_PATH" ]]; then
        error_exit "Helm chart path does not exist: $HELM_CHART_PATH"
    fi
    
    if ! helm lint "$HELM_CHART_PATH" >/dev/null 2>&1; then
        error_exit "Helm chart validation failed for: $HELM_CHART_PATH"
    fi
    
    log_info "Configuration validation completed"
}

perform_security_checks() {
    log_info "Performing security checks..."
    
    # Check file permissions
    local sensitive_files=(".vault_pass" "$VAULT_FILE")
    for file in "${sensitive_files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms
            perms=$(stat -c "%a" "$file")
            if [[ "$perms" != "600" ]]; then
                log_warn "Fixing permissions for $file"
                chmod 600 "$file"
            fi
        fi
    done
    
    # Check for exposed secrets in environment
    if env | grep -i password >/dev/null 2>&1; then
        log_warn "Potential password exposed in environment variables"
    fi
    
    log_info "Security checks completed"
}

create_deployment_manifest() {
    local image_tag="$1"
    local manifest_file="$BACKUP_DIR/deployment-manifest-$(date +%Y%m%d_%H%M%S).json"
    
    cat > "$manifest_file" << EOF
{
    "deployment_id": "$(date +%Y%m%d_%H%M%S)",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "image_tag": "$image_tag",
    "git_commit": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
    "operator": "$(whoami)",
    "environment": "production",
    "region": "mumbai"
}
EOF
    
    log_info "Deployment manifest created: $manifest_file"
}

# Pre-deployment backup
create_backup() {
    log_info "Creating pre-deployment backup..."
    
    source "$CONFIG_FILE"
    local backup_file="$BACKUP_DIR/pre-deployment-backup-$(date +%Y%m%d_%H%M%S).yaml"
    
    if kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o yaml > "$backup_file"
        log_info "Current deployment backed up to: $backup_file"
    else
        log_info "No existing deployment found to backup"
    fi
}

# Main deployment function
run_deployment() {
    local image_tag="$1"
    
    log_info "Starting SBI production deployment for image tag: $image_tag"
    
    # Create deployment manifest
    create_deployment_manifest "$image_tag"
    
    # Create pre-deployment backup
    create_backup
    
    # Run the deployment playbook
    log_info "Executing deployment playbook..."
    if ansible-playbook deploy-app.yml \
        --extra-vars "image_tag=$image_tag" \
        --vault-password-file .vault_pass \
        -v | tee -a "$LOG_FILE"; then
        
        log_info "Deployment completed successfully!"
        
        # Send success notification
        send_notification "SUCCESS" "$image_tag"
        
        return 0
    else
        log_error "Deployment failed!"
        
        # Send failure notification
        send_notification "FAILED" "$image_tag"
        
        return 1
    fi
}

send_notification() {
    local status="$1"
    local image_tag="$2"
    
    # This would integrate with your notification system
    log_info "Sending notification: Deployment $status for $image_tag"
    
    # Example: Send to monitoring system
    # curl -X POST "$MONITORING_WEBHOOK" -d "{\"status\":\"$status\",\"tag\":\"$image_tag\"}"
}

# Main execution
main() {
    local image_tag="${1:-latest}"
    
    log_info "SBI Production Deployment Script Started"
    log_info "Deployment target: $image_tag"
    
    # Acquire deployment lock
    acquire_lock
    
    # Perform all validations
    validate_environment
    validate_dependencies
    validate_vault_access
    validate_kubernetes_access
    validate_configuration
    perform_security_checks
    
    # Run deployment
    if run_deployment "$image_tag"; then
        log_info "SBI deployment completed successfully!"
        exit 0
    else
        error_exit "SBI deployment failed!"
    fi
}

# Script usage
usage() {
    cat << EOF
SBI Production Deployment Script

Usage: $0 [IMAGE_TAG]

Arguments:
    IMAGE_TAG    The image tag to deploy (default: latest)

Examples:
    $0 v1.2.3
    $0 latest
    $0 release-2024-01

Environment:
    Ensure you have proper Kubernetes access and vault password configured.

EOF
}

# Check for help flag
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    usage
    exit 0
fi

# Execute main function
main "${@}"
