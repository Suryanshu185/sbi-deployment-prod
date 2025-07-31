# SBI Production Deployment System

## Overview
This repository contains the production-ready deployment automation system for **State Bank of India (SBI)** containerized applications. The system provides secure, monitored, and reliable deployment capabilities using Ansible, Kubernetes, and Helm.

## Features

### 🔐 Security
- **Ansible Vault integration** for credential management
- **Secure credential handling** with no plaintext passwords
- **File permission validation** and automatic fixing
- **Security scanning integration** points
- **Compliance checking** capabilities

### 🚀 Deployment
- **Zero-downtime deployments** with Helm
- **Automatic rollback** on failure
- **Pre-deployment validation** and health checks
- **Image synchronization** from Nexus to Harbor
- **Backup creation** before deployments

### 📊 Monitoring
- **Continuous health monitoring** with alerting
- **Resource usage tracking** and thresholds
- **Application health checks** via HTTP endpoints
- **Comprehensive logging** with structured format
- **Integration points** for external monitoring systems

### 🔄 Operations
- **Production rollback capabilities** with multiple restore options
- **Environment validation** scripts
- **Backup and recovery** procedures
- **Diagnostic collection** for troubleshooting

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Nexus Registry│────│  Harbor Registry│────│ Kubernetes      │
│   (Source)      │    │   (Target)      │    │ (Runtime)       │
└─────────────────┘    └─────────────────┘    └─────────────────┘
          │                       │                       │
          └───────────────────────┼───────────────────────┘
                                  │
                    ┌─────────────────┐
                    │ Ansible Control │
                    │ & Helm Charts   │
                    └─────────────────┘
```

## Quick Start

### Prerequisites
- Ubuntu 18.04+ or RHEL 7+
- Ansible 2.9+
- Docker 20.03+
- kubectl 1.20+
- Helm 3.8+
- Access to SBI Kubernetes cluster
- Valid credentials for Nexus and Harbor registries

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Suryanshu185/sbi-deployment-prod.git
   cd sbi-deployment-prod
   ```

2. **Validate environment:**
   ```bash
   ./validate-environment.sh
   ```

3. **Configure credentials:**
   ```bash
   # Create vault password file
   echo "your-vault-password" > .vault_pass
   chmod 600 .vault_pass
   
   # Edit encrypted credentials
   ansible-vault edit vars/vault.yml
   ```

4. **Deploy application:**
   ```bash
   ./bootstrap-deployment.sh v1.2.3
   ```

## Configuration

### Environment Configuration
Edit `deployment.conf` for environment-specific settings:

```bash
# Registry Configuration
NEXUS_REGISTRY=nexus.sbi.co.in
HARBOR_REGISTRY=harbor.sbi.co.in

# Application Settings
IMAGE_NAME=sbi-banking-app
RELEASE_NAME=sbi-app
NAMESPACE=sbi-production

# Operational Settings
TIMEOUT=600
ENABLE_ROLLBACK=true
ENABLE_MONITORING=true
```

### Security Configuration
All sensitive data is stored in `vars/vault.yml` (encrypted):

```yaml
# Encrypted with ansible-vault
vault_nexus_username: "sbi-nexus-user"
vault_nexus_password: "secure-password"
vault_harbor_username: "sbi-harbor-user"
vault_harbor_password: "secure-password"
```

## Operations Guide

### Deployment

#### Standard Deployment
```bash
# Deploy specific version
./bootstrap-deployment.sh v2.1.0

# Deploy latest
./bootstrap-deployment.sh latest
```

#### Validation Before Deployment
```bash
# Validate environment
./validate-environment.sh

# Test configuration
ansible-playbook deploy-app.yml --check --diff
```

### Monitoring

#### Continuous Monitoring
```bash
# Start health monitor
./health-monitor.sh monitor

# Single health check
./health-monitor.sh check

# Generate health report
./health-monitor.sh report
```

#### Log Monitoring
```bash
# View deployment logs
tail -f logs/sbi_deploy_*.log

# View health monitor logs
tail -f logs/health_monitor_*.log

# View alerts
tail -f logs/alerts_*.log
```

### Rollback

#### Automatic Rollback
```bash
# Rollback to previous version
./rollback-deployment.sh

# Rollback to specific revision
./rollback-deployment.sh -r 5

# Force rollback without confirmation
./rollback-deployment.sh -f
```

#### Manual Recovery
```bash
# List available backups
ls -la backups/

# Restore from backup
./rollback-deployment.sh -b backups/backup-file.yaml
```

## Security

### Credential Management
- All credentials are encrypted using Ansible Vault
- Vault password is stored in `.vault_pass` with 600 permissions
- No credentials are passed via command line arguments
- Regular credential rotation is recommended

### Access Control
- Script requires non-root user execution
- Kubernetes RBAC controls cluster access
- File permissions are automatically validated and corrected

### Compliance
- Security scanning integration points available
- Audit logging for all operations
- Backup retention for compliance requirements

## Troubleshooting

### Common Issues

#### Deployment Failures
```bash
# Check deployment status
kubectl get deployment sbi-app -n sbi-production

# View pod logs
kubectl logs -l app=sbi-app -n sbi-production

# Check events
kubectl get events -n sbi-production --sort-by=.metadata.creationTimestamp
```

#### Registry Issues
```bash
# Test registry connectivity
docker pull nexus.sbi.co.in/sbi-banking-app:latest

# Check credentials
ansible-vault view vars/vault.yml
```

#### Health Check Failures
```bash
# Manual health check
./health-monitor.sh check

# View detailed diagnostics
cat logs/*-diagnostics.log
```

### Recovery Procedures

#### Complete System Recovery
1. **Assess the situation:**
   ```bash
   kubectl get all -n sbi-production
   ./health-monitor.sh check
   ```

2. **Restore from backup:**
   ```bash
   ./rollback-deployment.sh -b backups/latest-backup.yaml
   ```

3. **Verify recovery:**
   ```bash
   ./validate-environment.sh
   ./health-monitor.sh check
   ```

#### Data Recovery
```bash
# List available backups
ls -la backups/

# Restore specific backup
kubectl apply -f backups/specific-backup.yaml
```

## Integration

### Monitoring Systems
Integration points for external monitoring:
- Prometheus metrics endpoint
- Grafana dashboard templates
- Alert manager webhooks
- Custom monitoring APIs

### CI/CD Integration
```bash
# Jenkins pipeline example
./validate-environment.sh
./bootstrap-deployment.sh ${BUILD_NUMBER}
./health-monitor.sh check
```

### Alerting
Configure alerts in your monitoring system:
- Deployment failures
- Health check failures
- Resource thresholds
- Security violations

## Maintenance

### Regular Tasks

#### Daily
- Monitor application health
- Check resource usage
- Review deployment logs

#### Weekly
- Validate backups
- Check disk space
- Review security logs

#### Monthly
- Rotate credentials
- Update system components
- Backup cleanup

### Backup Management
```bash
# Automated backup cleanup (7 days retention)
find backups/ -name "*.yaml" -mtime +7 -delete

# Manual backup creation
kubectl get deployment sbi-app -n sbi-production -o yaml > manual-backup.yaml
```

## Support

### Contact Information
- **SBI IT Operations:** sbi-it-ops@sbi.co.in
- **Emergency Hotline:** +91-XXXX-XXXX-XXXX
- **DevOps Team:** devops@sbi.co.in

### Escalation Matrix
1. **Level 1:** Application Team
2. **Level 2:** Platform Team
3. **Level 3:** Infrastructure Team
4. **Level 4:** Vendor Support

### Documentation
- Internal Wiki: `https://wiki.sbi.co.in/deployment`
- Runbooks: `./docs/runbooks/`
- Architecture: `./docs/architecture/`

---

## License
Internal use only - State Bank of India
© 2024 State Bank of India. All rights reserved.
