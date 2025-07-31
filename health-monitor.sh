#!/bin/bash
# SBI Production Health Monitor
# Continuous monitoring script for SBI production deployments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment.conf"
LOG_FILE="$SCRIPT_DIR/logs/health_monitor_$(date +%Y%m%d).log"
ALERT_LOG="$SCRIPT_DIR/logs/alerts_$(date +%Y%m%d).log"

# Create logs directory
mkdir -p "$SCRIPT_DIR/logs"

# Configuration defaults
CHECK_INTERVAL=60  # seconds
ALERT_THRESHOLD=3  # consecutive failures before alert
HEALTH_TIMEOUT=10  # seconds for health checks

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOG_FILE" "$ALERT_LOG"
}

alert() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ALERT] $*" | tee -a "$LOG_FILE" "$ALERT_LOG"
    send_alert "$*"
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        warn "Configuration file not found: $CONFIG_FILE"
    fi
    
    # Set defaults if not configured
    RELEASE_NAME="${RELEASE_NAME:-sbi-app}"
    NAMESPACE="${NAMESPACE:-sbi-production}"
    CHECK_INTERVAL="${MONITOR_CHECK_INTERVAL:-60}"
    ALERT_THRESHOLD="${MONITOR_ALERT_THRESHOLD:-3}"
}

# Send alert notification
send_alert() {
    local message="$1"
    
    # Log to alert file
    echo "$(date '+%Y-%m-%d %H:%M:%S') SBI Production Alert: $message" >> "$ALERT_LOG"
    
    # Integration points for alerting systems
    # Example integrations:
    
    # Slack notification
    # curl -X POST -H 'Content-type: application/json' \
    #     --data "{\"text\":\"SBI Production Alert: $message\"}" \
    #     "$SLACK_WEBHOOK_URL"
    
    # Email notification
    # echo "SBI Production Alert: $message" | mail -s "SBI Production Alert" "$ALERT_EMAIL"
    
    # PagerDuty integration
    # curl -X POST 'https://events.pagerduty.com/v2/enqueue' \
    #     -H 'Content-Type: application/json' \
    #     -d "{\"routing_key\":\"$PAGERDUTY_KEY\",\"event_action\":\"trigger\",\"payload\":{\"summary\":\"$message\",\"source\":\"SBI-Monitor\",\"severity\":\"error\"}}"
    
    log "Alert sent: $message"
}

# Check Kubernetes deployment health
check_deployment_health() {
    local status="OK"
    local message=""
    
    # Check if deployment exists
    if ! kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        status="CRITICAL"
        message="Deployment $RELEASE_NAME not found in namespace $NAMESPACE"
        return 1
    fi
    
    # Get deployment status
    local desired_replicas current_replicas ready_replicas available_replicas
    desired_replicas=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
    current_replicas=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    ready_replicas=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    available_replicas=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    
    # Check replica health
    if [[ "$ready_replicas" -lt "$desired_replicas" ]]; then
        status="WARNING"
        message="Only $ready_replicas/$desired_replicas replicas are ready"
    fi
    
    if [[ "$available_replicas" -eq 0 ]]; then
        status="CRITICAL"
        message="No replicas are available"
    fi
    
    log "Deployment health: $status - Desired: $desired_replicas, Ready: $ready_replicas, Available: $available_replicas"
    
    if [[ "$status" != "OK" ]]; then
        return 1
    fi
    
    return 0
}

# Check pod health
check_pod_health() {
    local unhealthy_pods=0
    local total_pods=0
    
    # Get all pods for the deployment
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app="$RELEASE_NAME" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        error "No pods found for deployment $RELEASE_NAME"
        return 1
    fi
    
    for pod in $pods; do
        ((total_pods++))
        
        # Check pod status
        local pod_status
        pod_status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        if [[ "$pod_status" != "Running" ]]; then
            warn "Pod $pod is in $pod_status state"
            ((unhealthy_pods++))
            
            # Get pod events for debugging
            kubectl describe pod "$pod" -n "$NAMESPACE" | tail -10 >> "$LOG_FILE"
        fi
        
        # Check pod readiness
        local ready_condition
        ready_condition=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [[ "$ready_condition" != "True" ]]; then
            warn "Pod $pod is not ready"
            ((unhealthy_pods++))
        fi
    done
    
    log "Pod health: $((total_pods - unhealthy_pods))/$total_pods pods healthy"
    
    if [[ $unhealthy_pods -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# Check service health
check_service_health() {
    # Check if service exists
    if ! kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        warn "Service $RELEASE_NAME not found in namespace $NAMESPACE"
        return 1
    fi
    
    # Check service endpoints
    local endpoints
    endpoints=$(kubectl get endpoints "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    
    if [[ -z "$endpoints" ]]; then
        error "Service $RELEASE_NAME has no endpoints"
        return 1
    fi
    
    local endpoint_count
    endpoint_count=$(echo "$endpoints" | wc -w)
    log "Service health: $endpoint_count endpoints available"
    
    return 0
}

# Check application health endpoint
check_application_health() {
    # Get service cluster IP
    local service_ip
    service_ip=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    
    if [[ -z "$service_ip" ]]; then
        warn "Cannot get service IP for health check"
        return 1
    fi
    
    # Try health check endpoint
    local health_status
    if kubectl run health-check-$$-$RANDOM --rm -i --restart=Never --image=curlimages/curl --timeout="${HEALTH_TIMEOUT}s" -- \
       curl -f "http://$service_ip:8080/health" --max-time "$HEALTH_TIMEOUT" >/dev/null 2>&1; then
        log "Application health check: OK"
        return 0
    else
        warn "Application health check failed"
        return 1
    fi
}

# Check resource usage
check_resource_usage() {
    local cpu_usage memory_usage
    
    # Get resource usage for all pods
    local resource_data
    resource_data=$(kubectl top pods -n "$NAMESPACE" -l app="$RELEASE_NAME" --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$resource_data" ]]; then
        warn "Cannot get resource usage data"
        return 1
    fi
    
    local total_cpu=0 total_memory=0 pod_count=0
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            ((pod_count++))
            cpu=$(echo "$line" | awk '{print $2}' | sed 's/m$//')
            memory=$(echo "$line" | awk '{print $3}' | sed 's/Mi$//')
            total_cpu=$((total_cpu + cpu))
            total_memory=$((total_memory + memory))
        fi
    done <<< "$resource_data"
    
    if [[ $pod_count -gt 0 ]]; then
        log "Resource usage: $total_cpu mCPU, ${total_memory}Mi memory across $pod_count pods"
        
        # Check for high resource usage
        local avg_cpu avg_memory
        avg_cpu=$((total_cpu / pod_count))
        avg_memory=$((total_memory / pod_count))
        
        if [[ $avg_cpu -gt 800 ]]; then  # 80% of 1 CPU
            warn "High CPU usage detected: ${avg_cpu}m per pod"
            return 1
        fi
        
        if [[ $avg_memory -gt 800 ]]; then  # 800Mi memory threshold
            warn "High memory usage detected: ${avg_memory}Mi per pod"
            return 1
        fi
    fi
    
    return 0
}

# Check persistent volumes (if any)
check_storage_health() {
    local pvcs
    pvcs=$(kubectl get pvc -n "$NAMESPACE" -l app="$RELEASE_NAME" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$pvcs" ]]; then
        for pvc in $pvcs; do
            local pvc_status
            pvc_status=$(kubectl get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [[ "$pvc_status" == "Bound" ]]; then
                log "PVC $pvc: Bound (OK)"
            else
                warn "PVC $pvc: $pvc_status"
                return 1
            fi
        done
    else
        log "No persistent volumes to check"
    fi
    
    return 0
}

# Perform comprehensive health check
perform_health_check() {
    local checks_passed=0
    local total_checks=6
    
    log "Starting comprehensive health check for $RELEASE_NAME"
    
    # Run all health checks
    if check_deployment_health; then
        ((checks_passed++))
    fi
    
    if check_pod_health; then
        ((checks_passed++))
    fi
    
    if check_service_health; then
        ((checks_passed++))
    fi
    
    if check_application_health; then
        ((checks_passed++))
    fi
    
    if check_resource_usage; then
        ((checks_passed++))
    fi
    
    if check_storage_health; then
        ((checks_passed++))
    fi
    
    local health_percentage
    health_percentage=$((checks_passed * 100 / total_checks))
    
    log "Health check completed: $checks_passed/$total_checks checks passed ($health_percentage%)"
    
    if [[ $checks_passed -eq $total_checks ]]; then
        return 0  # All healthy
    elif [[ $health_percentage -ge 80 ]]; then
        return 1  # Warning state
    else
        return 2  # Critical state
    fi
}

# Monitor loop
start_monitoring() {
    log "Starting SBI production monitoring for $RELEASE_NAME in namespace $NAMESPACE"
    log "Check interval: ${CHECK_INTERVAL}s, Alert threshold: $ALERT_THRESHOLD consecutive failures"
    
    local consecutive_failures=0
    local last_alert_time=0
    local alert_cooldown=1800  # 30 minutes between alerts
    
    while true; do
        local check_result
        perform_health_check
        check_result=$?
        
        case $check_result in
            0)
                # All healthy
                if [[ $consecutive_failures -gt 0 ]]; then
                    log "Health recovered after $consecutive_failures consecutive failures"
                    consecutive_failures=0
                fi
                ;;
            1)
                # Warning state
                warn "Health check warnings detected"
                consecutive_failures=0  # Don't count warnings as failures
                ;;
            2)
                # Critical state
                ((consecutive_failures++))
                error "Health check failed ($consecutive_failures consecutive failures)"
                
                if [[ $consecutive_failures -ge $ALERT_THRESHOLD ]]; then
                    local current_time
                    current_time=$(date +%s)
                    
                    if [[ $((current_time - last_alert_time)) -ge $alert_cooldown ]]; then
                        alert "SBI Production deployment $RELEASE_NAME is unhealthy ($consecutive_failures consecutive failures)"
                        last_alert_time=$current_time
                    fi
                fi
                ;;
        esac
        
        sleep "$CHECK_INTERVAL"
    done
}

# Generate health report
generate_health_report() {
    local report_file="$SCRIPT_DIR/logs/health_report_$(date +%Y%m%d_%H%M%S).json"
    
    log "Generating health report: $report_file"
    
    # Perform health check and capture results
    local deployment_health pod_health service_health app_health resource_health storage_health
    
    check_deployment_health && deployment_health="OK" || deployment_health="FAILED"
    check_pod_health && pod_health="OK" || pod_health="FAILED"
    check_service_health && service_health="OK" || service_health="FAILED"
    check_application_health && app_health="OK" || app_health="FAILED"
    check_resource_usage && resource_health="OK" || resource_health="FAILED"
    check_storage_health && storage_health="OK" || storage_health="FAILED"
    
    # Generate JSON report
    cat > "$report_file" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "deployment": "$RELEASE_NAME",
    "namespace": "$NAMESPACE",
    "health_checks": {
        "deployment": "$deployment_health",
        "pods": "$pod_health",
        "service": "$service_health",
        "application": "$app_health",
        "resources": "$resource_health",
        "storage": "$storage_health"
    },
    "details": {
        "replicas": $(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0),
        "ready_replicas": $(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0),
        "available_replicas": $(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
    }
}
EOF
    
    log "Health report generated: $report_file"
}

# Main function
main() {
    local command="${1:-monitor}"
    
    load_config
    
    case "$command" in
        monitor)
            start_monitoring
            ;;
        check)
            perform_health_check
            exit $?
            ;;
        report)
            generate_health_report
            ;;
        *)
            echo "Usage: $0 [monitor|check|report]"
            echo "  monitor  - Start continuous monitoring (default)"
            echo "  check    - Perform single health check"
            echo "  report   - Generate health report"
            exit 1
            ;;
    esac
}

# Handle signals
trap 'log "Health monitor stopping..."; exit 0' INT TERM

# Execute main function
main "$@"