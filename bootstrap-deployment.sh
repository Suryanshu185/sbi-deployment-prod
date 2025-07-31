#!/bin/bash
set -euo pipefail

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
CONFIG_FILE="./deployment.conf"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

error_exit() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOG_FILE"
  exit 1
}

check_dependencies() {
  command -v ansible-playbook >/dev/null 2>&1 || {
    log "Installing Ansible..."
    sudo apt-get update && sudo apt-get install -y ansible
  }
}

validate_config() {
  [ -f "$CONFIG_FILE" ] || error_exit "Configuration file $CONFIG_FILE not found."
  source "$CONFIG_FILE"
}

if [ ! -f ".env_setup_done" ]; then
  log "Running environment setup..."
  ansible-playbook setup-environment.yml || error_exit "Environment setup failed"
  touch .env_setup_done
fi

check_dependencies
validate_config

IMAGE_TAG="${1:-latest}"
log "Starting deployment for image tag: $IMAGE_TAG"

# Prompt for credentials
read -p "Enter Nexus Username: " NEXUS_USERNAME
read -s -p "Enter Nexus Password: " NEXUS_PASSWORD
echo
read -p "Enter Harbor Username: " HARBOR_USERNAME
read -s -p "Enter Harbor Password: " HARBOR_PASSWORD
echo

ansible-playbook deploy-app.yml \
  --extra-vars "image_tag=$IMAGE_TAG \
                nexus_username=$NEXUS_USERNAME nexus_password=$NEXUS_PASSWORD \
                harbor_username=$HARBOR_USERNAME harbor_password=$HARBOR_PASSWORD" \
  --extra-vars "@vars/production.yml" \
  | tee -a "$LOG_FILE"
