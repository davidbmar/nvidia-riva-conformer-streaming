#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# RIVA-210: Safely Shutdown GPU Instance
# ============================================================================
# Stops the GPU worker instance to save costs while preserving all state.
# All models and configuration remain intact for quick startup.
#
# What this does:
# 1. Verifies GPU instance is running
# 2. Stops the GPU EC2 instance
# 3. Confirms shutdown
#
# Cost savings: ~$0.526/hour when stopped (only EBS storage)
# ============================================================================

source "$(dirname "$0")/riva-common-functions.sh"
load_environment

GPU_INSTANCE_ID="${GPU_INSTANCE_ID:-i-06a36632f4d99f97b}"
REGION="${AWS_REGION:-us-east-2}"

if [ -z "$GPU_INSTANCE_ID" ]; then
  echo "ERROR: GPU_INSTANCE_ID not set"
  exit 1
fi

log_info "🛑 Shutting down GPU instance"
log_info "Instance: $GPU_INSTANCE_ID"
log_info "Region: $REGION"
echo ""

# Check current state
log_info "Checking instance state..."
STATE=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

if [ "$STATE" = "stopped" ]; then
  log_success "✅ Instance already stopped"
  exit 0
fi

if [ "$STATE" != "running" ]; then
  log_warn "⚠️  Instance in state: $STATE (not running or stopped)"
  exit 1
fi

log_info "Current state: $STATE"
echo ""

# Stop instance
log_info "Stopping instance..."
aws ec2 stop-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --output text

echo ""
log_info "Waiting for instance to stop (this may take 30-60 seconds)..."
aws ec2 wait instance-stopped \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION"

log_success "✅ GPU instance stopped successfully"
echo ""
log_info "💰 Cost savings: ~\$0.526/hour (only EBS storage charges apply)"
log_info "📁 All data preserved: /opt/riva/models_conformer_ctc_streaming/"
echo ""
log_info "To restart tomorrow: ./scripts/riva-211-startup-and-restore.sh"
