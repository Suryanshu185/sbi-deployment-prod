# SBI Deployment Automation

## Overview
This automation deploys containerized applications from Nexus to Harbor and into Tanzu Kubernetes using Helm.

The deployment tool is now implemented as a Go CLI application instead of Ansible, providing better performance, easier maintenance, and reduced dependencies.

## Prerequisites
- Go 1.19+ (for building the CLI)
- Docker
- kubectl
- Helm 3.x
- Access to Nexus and Harbor registries
- Kubernetes cluster access

## Usage

### Quick Start
```bash
chmod +x bootstrap-deployment.sh
./bootstrap-deployment.sh v1.2.3
```

### Manual Usage
```bash
# Build the CLI (done automatically by bootstrap script)
go build -o sbi-deploy .

# Run environment setup (first time only)
./sbi-deploy --setup

# Deploy with specific image tag
./sbi-deploy --tag=v1.2.3

# Deploy with verbose logging
./sbi-deploy --tag=v1.2.3 --verbose

# Use custom config file
./sbi-deploy --tag=v1.2.3 --config=./custom.conf
```

### Configuration
Edit `deployment.conf` to customize:
- Registry URLs (Nexus and Harbor)
- Helm chart path
- Kubernetes namespace
- Deployment settings

### Environment Variables
You can set credentials as environment variables to avoid interactive prompts:
```bash
export NEXUS_USERNAME=your_nexus_user
export NEXUS_PASSWORD=your_nexus_password
export HARBOR_USERNAME=your_harbor_user
export HARBOR_PASSWORD=your_harbor_password
```

## Features
- ✅ Pre-flight checks for required tools
- ✅ Automatic environment setup
- ✅ Docker registry authentication
- ✅ Image pull, tag, and push operations
- ✅ Helm-based Kubernetes deployment
- ✅ Automatic rollback on failure
- ✅ Health checks and cleanup
- ✅ Verbose logging and error handling
- ✅ Configuration file support
