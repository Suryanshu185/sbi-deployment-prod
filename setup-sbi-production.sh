#!/bin/bash
# SBI Production Setup Script
# Initial setup for SBI production deployment environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/setup_$(date +%Y%m%d_%H%M%S).log"

# Create logs directory
mkdir -p "$SCRIPT_DIR/logs"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" | tee -a "$LOG_FILE"
}

# Check if running as root
check_user() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for security reasons"
    fi
    log "Running as user: $(whoami)"
}

# Create required directories
create_directories() {
    log "Creating required directories..."
    
    local directories=(
        "logs"
        "tmp" 
        "backups"
        "helm-charts"
        "docs"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$SCRIPT_DIR/$dir" ]]; then
            mkdir -p "$SCRIPT_DIR/$dir"
            log "Created directory: $dir"
        fi
    done
    
    # Set proper permissions
    chmod 755 "$SCRIPT_DIR"/{logs,tmp,backups,helm-charts,docs}
}

# Initialize vault if not exists
initialize_vault() {
    log "Initializing Ansible Vault configuration..."
    
    if [[ ! -f "$SCRIPT_DIR/.vault_pass" ]]; then
        warn "Vault password file not found"
        echo
        echo "For security, you need to create a vault password file."
        echo "This will be used to encrypt/decrypt sensitive credentials."
        echo
        
        read -s -p "Enter a secure vault password: " vault_password
        echo
        read -s -p "Confirm vault password: " vault_password_confirm
        echo
        
        if [[ "$vault_password" != "$vault_password_confirm" ]]; then
            error "Passwords do not match"
        fi
        
        echo "$vault_password" > "$SCRIPT_DIR/.vault_pass"
        chmod 600 "$SCRIPT_DIR/.vault_pass"
        log "Vault password file created"
        
        # Encrypt the vault file if it's not already encrypted
        if [[ -f "$SCRIPT_DIR/vars/vault.yml" ]] && ! ansible-vault view "$SCRIPT_DIR/vars/vault.yml" >/dev/null 2>&1; then
            ansible-vault encrypt "$SCRIPT_DIR/vars/vault.yml"
            log "Encrypted vars/vault.yml"
        fi
    else
        log "Vault password file already exists"
    fi
}

# Validate and fix file permissions
fix_permissions() {
    log "Fixing file permissions..."
    
    # Make scripts executable
    local scripts=(
        "bootstrap-deployment.sh"
        "validate-environment.sh"
        "rollback-deployment.sh"
        "health-monitor.sh"
        "setup-sbi-production.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [[ -f "$SCRIPT_DIR/$script" ]]; then
            chmod +x "$SCRIPT_DIR/$script"
            log "Made executable: $script"
        fi
    done
    
    # Secure sensitive files
    local sensitive_files=(
        ".vault_pass"
        "vars/vault.yml"
    )
    
    for file in "${sensitive_files[@]}"; do
        if [[ -f "$SCRIPT_DIR/$file" ]]; then
            chmod 600 "$SCRIPT_DIR/$file"
            log "Secured permissions: $file"
        fi
    done
}

# Create sample Helm chart structure
create_helm_chart_template() {
    local chart_dir="$SCRIPT_DIR/helm-charts/sbi-app"
    
    if [[ ! -d "$chart_dir" ]]; then
        log "Creating sample Helm chart structure..."
        
        mkdir -p "$chart_dir"/{templates,charts}
        
        # Create Chart.yaml
        cat > "$chart_dir/Chart.yaml" << EOF
apiVersion: v2
name: sbi-app
description: State Bank of India Production Application
type: application
version: 1.0.0
appVersion: "1.0.0"
keywords:
  - sbi
  - banking
  - production
maintainers:
  - name: SBI DevOps Team
    email: devops@sbi.co.in
EOF

        # Create values.yaml
        cat > "$chart_dir/values.yaml" << EOF
# SBI Application Configuration
replicaCount: 3

image:
  repository: harbor.sbi.co.in/sbi-banking-app
  pullPolicy: IfNotPresent
  tag: ""

imagePullSecrets:
  - name: harbor-registry-secret

nameOverride: ""
fullnameOverride: ""

serviceAccount:
  create: true
  annotations: {}
  name: ""

podAnnotations: {}

podSecurityContext:
  fsGroup: 2000

securityContext:
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1000

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: sbi-app.local
      paths:
        - path: /
          pathType: Prefix
  tls: []

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

nodeSelector: {}

tolerations: []

affinity: {}

# SBI specific configurations
sbi:
  environment: production
  region: mumbai
  datacenter: primary
  
monitoring:
  enabled: true
  
backup:
  enabled: true
  schedule: "0 2 * * *"
EOF

        # Create basic deployment template
        cat > "$chart_dir/templates/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "sbi-app.fullname" . }}
  labels:
    {{- include "sbi-app.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "sbi-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "sbi-app.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "sbi-app.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          env:
            - name: SBI_ENVIRONMENT
              value: {{ .Values.sbi.environment }}
            - name: SBI_REGION
              value: {{ .Values.sbi.region }}
            - name: SBI_DATACENTER
              value: {{ .Values.sbi.datacenter }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
EOF

        # Create _helpers.tpl
        cat > "$chart_dir/templates/_helpers.tpl" << 'EOF'
{{/*
Expand the name of the chart.
*/}}
{{- define "sbi-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "sbi-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "sbi-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "sbi-app.labels" -}}
helm.sh/chart: {{ include "sbi-app.chart" . }}
{{ include "sbi-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
sbi.co.in/environment: {{ .Values.sbi.environment }}
sbi.co.in/region: {{ .Values.sbi.region }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "sbi-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sbi-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "sbi-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sbi-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
EOF

        log "Created sample Helm chart at $chart_dir"
    else
        log "Helm chart directory already exists"
    fi
}

# Setup systemd service for health monitoring
setup_monitoring_service() {
    log "Setting up health monitoring service..."
    
    local service_file="/tmp/sbi-health-monitor.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=SBI Production Health Monitor
After=network.target
Wants=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/health-monitor.sh monitor
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log "Systemd service template created at $service_file"
    echo
    warn "To enable the monitoring service, run as root:"
    echo "  sudo cp $service_file /etc/systemd/system/"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable sbi-health-monitor"
    echo "  sudo systemctl start sbi-health-monitor"
}

# Create documentation structure
create_documentation() {
    log "Creating documentation structure..."
    
    local docs_dir="$SCRIPT_DIR/docs"
    mkdir -p "$docs_dir"/{runbooks,architecture,troubleshooting}
    
    # Create runbook template
    cat > "$docs_dir/runbooks/deployment-runbook.md" << 'EOF'
# SBI Production Deployment Runbook

## Pre-deployment Checklist
- [ ] Validate environment with `./validate-environment.sh`
- [ ] Confirm image exists in Nexus registry
- [ ] Check cluster capacity and resources
- [ ] Verify backup systems are operational
- [ ] Confirm monitoring systems are active

## Deployment Steps
1. Execute deployment: `./bootstrap-deployment.sh <version>`
2. Monitor progress in logs: `tail -f logs/sbi_deploy_*.log`
3. Verify health: `./health-monitor.sh check`
4. Confirm application functionality

## Post-deployment Verification
- [ ] All pods are running and ready
- [ ] Service endpoints are accessible
- [ ] Health checks are passing
- [ ] Monitoring alerts are configured
- [ ] Documentation is updated

## Rollback Procedures
If deployment fails:
1. Execute rollback: `./rollback-deployment.sh`
2. Verify rollback success: `./health-monitor.sh check`
3. Investigate root cause
4. Update deployment procedures if needed
EOF

    log "Created documentation structure in $docs_dir"
}

# Main setup function
main() {
    log "==================== SBI PRODUCTION SETUP ===================="
    log "Starting SBI production environment setup"
    
    check_user
    create_directories
    initialize_vault
    fix_permissions
    create_helm_chart_template
    setup_monitoring_service
    create_documentation
    
    log "==================== SETUP COMPLETED ===================="
    echo
    echo "✅ SBI Production deployment environment is now set up!"
    echo
    echo "Next steps:"
    echo "1. Review and update vars/vault.yml with your credentials"
    echo "2. Customize helm-charts/sbi-app for your application"
    echo "3. Run ./validate-environment.sh to verify setup"
    echo "4. Test deployment with ./bootstrap-deployment.sh <version>"
    echo
    echo "For monitoring service setup, see the systemd commands above."
    echo
    log "Setup completed successfully"
}

# Execute main function
main "$@"