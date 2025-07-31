#!/bin/bash
# SBI Production Validation Script
# Validates deployment environment before running deployments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/validation_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" | tee -a "$LOG_FILE"
}

# Create logs directory
mkdir -p "$SCRIPT_DIR/logs"

log "Starting SBI production environment validation"

# Validation counters
ERRORS=0
WARNINGS=0

# Check system requirements
check_system_requirements() {
    log "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        ((ERRORS++))
    else
        local os_info
        os_info=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
        log "Operating System: $os_info"
    fi
    
    # Check disk space
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 80 ]]; then
        error "Disk usage is $disk_usage% - should be below 80%"
        ((ERRORS++))
    else
        log "Disk usage: $disk_usage% (OK)"
    fi
    
    # Check memory
    local memory_total memory_available
    memory_total=$(free -m | awk 'NR==2{print $2}')
    memory_available=$(free -m | awk 'NR==2{print $7}')
    if [[ $memory_available -lt 2048 ]]; then
        warn "Available memory is ${memory_available}MB - recommend at least 2GB"
        ((WARNINGS++))
    else
        log "Memory: ${memory_total}MB total, ${memory_available}MB available (OK)"
    fi
}

# Check required tools
check_tools() {
    log "Checking required tools..."
    
    local tools=("ansible-playbook" "docker" "kubectl" "helm" "git" "jq")
    for tool in "${tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            local version
            case $tool in
                "ansible-playbook")
                    version=$(ansible-playbook --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
                    ;;
                "docker")
                    version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
                    ;;
                "kubectl")
                    version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown")
                    ;;
                "helm")
                    version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
                    ;;
                "git")
                    version=$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
                    ;;
                "jq")
                    version=$(jq --version | grep -oE '[0-9]+\.[0-9]+')
                    ;;
            esac
            log "$tool: $version (OK)"
        else
            error "$tool is not installed"
            ((ERRORS++))
        fi
    done
}

# Check network connectivity
check_connectivity() {
    log "Checking network connectivity..."
    
    # Check external connectivity
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log "External connectivity: OK"
    else
        error "No external connectivity"
        ((ERRORS++))
    fi
    
    # Check DNS resolution
    if nslookup google.com >/dev/null 2>&1; then
        log "DNS resolution: OK"
    else
        error "DNS resolution failed"
        ((ERRORS++))
    fi
}

# Check Docker configuration
check_docker() {
    log "Checking Docker configuration..."
    
    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon is not running or accessible"
        ((ERRORS++))
        return
    fi
    
    # Check if user is in docker group
    if groups "$USER" | grep -q docker; then
        log "User is in docker group: OK"
    else
        warn "User $USER is not in docker group - may need sudo for docker commands"
        ((WARNINGS++))
    fi
    
    # Check Docker storage
    local docker_space
    docker_space=$(docker system df 2>/dev/null | grep 'Total' | awk '{print $4}' | sed 's/[^0-9.]//g' || echo "0")
    log "Docker storage usage: ${docker_space}GB"
}

# Check Kubernetes connectivity
check_kubernetes() {
    log "Checking Kubernetes connectivity..."
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "Cannot connect to Kubernetes cluster"
        ((ERRORS++))
        return
    fi
    
    # Check cluster version
    local k8s_version
    k8s_version=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")
    log "Kubernetes cluster version: $k8s_version"
    
    # Check node status
    local node_count ready_nodes
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo "0")
    
    if [[ $ready_nodes -eq $node_count && $node_count -gt 0 ]]; then
        log "Kubernetes nodes: $ready_nodes/$node_count Ready (OK)"
    else
        error "Kubernetes nodes: $ready_nodes/$node_count Ready - some nodes not ready"
        ((ERRORS++))
    fi
}

# Check configuration files
check_configuration() {
    log "Checking configuration files..."
    
    local required_files=(
        "$SCRIPT_DIR/deployment.conf"
        "$SCRIPT_DIR/vars/production.yml"
        "$SCRIPT_DIR/vars/vault.yml"
        "$SCRIPT_DIR/deploy-app.yml"
        "$SCRIPT_DIR/setup-environment.yml"
    )
    
    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log "Configuration file exists: $(basename "$file") (OK)"
        else
            error "Configuration file missing: $file"
            ((ERRORS++))
        fi
    done
    
    # Check vault access
    if [[ -f "$SCRIPT_DIR/.vault_pass" ]]; then
        if [[ $(stat -c "%a" "$SCRIPT_DIR/.vault_pass") == "600" ]]; then
            log "Vault password file permissions: OK"
        else
            warn "Vault password file has incorrect permissions"
            ((WARNINGS++))
        fi
    else
        warn "Vault password file not found - will be prompted during deployment"
        ((WARNINGS++))
    fi
}

# Check security settings
check_security() {
    log "Checking security settings..."
    
    # Check file permissions
    local secure_files=("vars/vault.yml" ".vault_pass")
    for file in "${secure_files[@]}"; do
        if [[ -f "$SCRIPT_DIR/$file" ]]; then
            local perms
            perms=$(stat -c "%a" "$SCRIPT_DIR/$file")
            if [[ "$perms" == "600" ]]; then
                log "File permissions for $file: $perms (OK)"
            else
                warn "File permissions for $file: $perms (should be 600)"
                ((WARNINGS++))
            fi
        fi
    done
    
    # Check for world-writable files
    local world_writable
    world_writable=$(find "$SCRIPT_DIR" -type f -perm -002 2>/dev/null | head -5)
    if [[ -n "$world_writable" ]]; then
        warn "Found world-writable files:"
        echo "$world_writable" | while read -r file; do
            warn "  $file"
        done
        ((WARNINGS++))
    else
        log "No world-writable files found: OK"
    fi
}

# Main validation function
run_validation() {
    log "==================== SBI PRODUCTION VALIDATION ===================="
    
    check_system_requirements
    check_tools
    check_connectivity
    check_docker
    check_kubernetes
    check_configuration
    check_security
    
    log "==================== VALIDATION SUMMARY ===================="
    log "Errors: $ERRORS"
    log "Warnings: $WARNINGS"
    
    if [[ $ERRORS -gt 0 ]]; then
        error "Validation failed with $ERRORS errors. Please fix errors before proceeding."
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        warn "Validation completed with $WARNINGS warnings. Review warnings before proceeding."
        exit 2
    else
        log "Validation completed successfully. Environment is ready for SBI production deployment."
        exit 0
    fi
}

# Execute validation
run_validation