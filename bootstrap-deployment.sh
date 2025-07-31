#!/bin/bash
set -euo pipefail

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
CONFIG_FILE="./deployment.conf"
CLI_BINARY="./sbi-deploy"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

error_exit() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOG_FILE"
  exit 1
}

build_cli() {
  if [ ! -f "$CLI_BINARY" ] || [ "main.go" -nt "$CLI_BINARY" ]; then
    log "Building Go CLI..."
    go build -o sbi-deploy . || error_exit "Failed to build Go CLI"
  fi
}

validate_config() {
  [ -f "$CONFIG_FILE" ] || error_exit "Configuration file $CONFIG_FILE not found."
}

# Check if environment setup is needed
if [ ! -f ".env_setup_done" ]; then
  log "Running environment setup..."
  build_cli
  "$CLI_BINARY" --setup || error_exit "Environment setup failed"
  touch .env_setup_done
fi

build_cli
validate_config

IMAGE_TAG="${1:-latest}"
log "Starting deployment for image tag: $IMAGE_TAG"

# Export credentials as environment variables if provided
if [ -n "${NEXUS_USERNAME:-}" ] && [ -n "${NEXUS_PASSWORD:-}" ] && \
   [ -n "${HARBOR_USERNAME:-}" ] && [ -n "${HARBOR_PASSWORD:-}" ]; then
  log "Using provided credentials from environment"
  export NEXUS_USERNAME NEXUS_PASSWORD HARBOR_USERNAME HARBOR_PASSWORD
else
  log "Credentials will be prompted interactively"
fi

# Run deployment with the Go CLI
"$CLI_BINARY" --tag="$IMAGE_TAG" --config="$CONFIG_FILE" --verbose | tee -a "$LOG_FILE"

log "Deployment script completed"
