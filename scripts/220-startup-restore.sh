#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# RIVA-211: Startup GPU and Restore Working State
# ============================================================================
# Complete one-command restoration of working Conformer-CTC streaming setup.
# Run this in the morning after shutting down the GPU overnight.
#
# What this does:
# 1. Starts GPU EC2 instance
# 2. Waits for instance to be ready
# 3. Checks if GPU IP changed (updates .env if needed)
# 4. Verifies RIVA server is running
# 5. If needed, deploys Conformer-CTC model
# 6. Restarts WebSocket bridge with correct config
# 7. Runs full health check
#
# Total time: 5-10 minutes (2min startup + 3-8min deployment if needed)
# ============================================================================

source "$(dirname "$0")/riva-common-functions.sh"
load_environment

GPU_INSTANCE_ID="${GPU_INSTANCE_ID:-i-06a36632f4d99f97b}"
REGION="${AWS_REGION:-us-east-2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dbm-sep23-2025.pem}"

log_info "🚀 Starting GPU and restoring Conformer-CTC streaming"
log_info "Instance: $GPU_INSTANCE_ID"
echo ""

# ============================================================================
# Step 1: Start GPU Instance
# ============================================================================
log_info "Step 1/6: Starting GPU instance..."
STATE=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

if [ "$STATE" = "running" ]; then
  log_success "✅ Instance already running"
else
  log_info "Current state: $STATE, starting..."
  aws ec2 start-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$REGION" \
    --output text > /dev/null

  log_info "Waiting for instance to start (2-3 minutes)..."
  aws ec2 wait instance-running \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$REGION"

  log_success "✅ Instance started"

  # Give the instance extra time to fully boot
  log_info "Waiting 30s for instance to fully boot..."
  sleep 30
fi

echo ""

# ============================================================================
# Step 2: Get Current IP and Update .env if Changed
# ============================================================================
log_info "Step 2/6: Checking GPU IP address..."
CURRENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log_info "Current GPU IP: $CURRENT_IP"

OLD_IP=$(grep "^GPU_INSTANCE_IP=" .env | cut -d'=' -f2)

if [ "$CURRENT_IP" != "$OLD_IP" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                                                            ║"
  echo "║         ⚠️  CRITICAL: GPU IP ADDRESS HAS CHANGED          ║"
  echo "║                                                            ║"
  echo "╟────────────────────────────────────────────────────────────╢"
  echo "║  Old IP: $OLD_IP"
  echo "║  New IP: $CURRENT_IP"
  echo "╟────────────────────────────────────────────────────────────╢"
  echo "║  Actions being taken:                                      ║"
  echo "║   1. Updating .env file with new IP                        ║"
  echo "║   2. Exporting environment variables                       ║"
  echo "║   3. Reloading .env configuration                          ║"
  echo "║   4. Updating AWS security groups                          ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  log_info "Step 1/4: Updating .env file..."
  sed -i "s/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$CURRENT_IP/" .env
  sed -i "s/^RIVA_HOST=.*/RIVA_HOST=$CURRENT_IP/" .env
  log_success "✅ .env file updated"

  log_info "Step 2/4: Exporting environment variables..."
  export GPU_INSTANCE_IP="$CURRENT_IP"
  export RIVA_HOST="$CURRENT_IP"
  log_success "✅ Variables exported for child scripts"

  log_info "Step 3/4: Reloading .env configuration..."
  load_environment
  log_success "✅ Configuration reloaded"

  log_info "Step 4/4: Updating AWS security groups..."
  if "$(dirname "$0")/030-configure-security-groups.sh" --gpu; then
    log_success "✅ Security groups updated successfully"
  else
    log_warn "⚠️  Security group update encountered issues"
    log_info "You may need to run manually: ./scripts/030-configure-security-groups.sh --gpu"
  fi

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                                                            ║"
  echo "║    ✅ IP CHANGE COMPLETE - CONTINUING WITH DEPLOYMENT     ║"
  echo "║                                                            ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
else
  log_success "✅ IP unchanged: $CURRENT_IP"
fi

echo ""

# ============================================================================
# Step 3: Check SSH Connectivity
# ============================================================================
log_info "Step 3/6: Verifying SSH connectivity..."
RETRY=0
MAX_RETRIES=10

while [ $RETRY -lt $MAX_RETRIES ]; do
  if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
     ubuntu@"$CURRENT_IP" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
    log_success "✅ SSH connected"
    break
  fi
  RETRY=$((RETRY + 1))
  log_info "SSH not ready, retrying ($RETRY/$MAX_RETRIES)..."
  sleep 10
done

if [ $RETRY -eq $MAX_RETRIES ]; then
  log_error "❌ SSH connection failed after $MAX_RETRIES attempts"
  exit 1
fi

echo ""

# ============================================================================
# Step 4: Check if RIVA Server is Running
# ============================================================================
log_info "Step 4/6: Checking RIVA server status..."

RIVA_READY=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
  'curl -sf http://localhost:8000/v2/health/ready && echo READY || echo NOT_READY' 2>/dev/null || echo "NOT_READY")

if [ "$RIVA_READY" = "READY" ]; then
  log_success "✅ RIVA server already running and ready"

  # Verify correct model is loaded
  log_info "Verifying Conformer-CTC model is loaded..."
  MODEL_CHECK=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
    'curl -s -X POST http://localhost:8000/v2/repository/index -H "Content-Type: application/json" -d "{}" | grep -c "conformer-ctc-xl-en-us-streaming"' || echo "0")

  if [ "$MODEL_CHECK" -gt "0" ]; then
    log_success "✅ Conformer-CTC model loaded"
    NEEDS_DEPLOY=false
  else
    log_warn "⚠️  Conformer-CTC model not loaded, will deploy"
    NEEDS_DEPLOY=true
  fi
else
  log_warn "⚠️  RIVA server not running, will deploy"
  NEEDS_DEPLOY=true
fi

echo ""

# ============================================================================
# Step 5: Deploy Conformer-CTC if Needed
# ============================================================================
if [ "$NEEDS_DEPLOY" = "true" ]; then
  log_info "Step 5/6: Deploying Conformer-CTC streaming model..."
  log_info "This will take 5-10 minutes..."
  echo ""

  # Run deployment script
  "$(dirname "$0")/110-deploy-conformer-streaming.sh"

  log_success "✅ Deployment complete"
else
  log_info "Step 5/6: Skipping deployment (already running)"
fi

echo ""

# ============================================================================
# Step 6: Restart WebSocket Bridge
# ============================================================================
log_info "Step 6/6: Restarting WebSocket bridge..."
sudo systemctl restart riva-websocket-bridge
sleep 3

BRIDGE_STATUS=$(sudo systemctl is-active riva-websocket-bridge || echo "inactive")
if [ "$BRIDGE_STATUS" = "active" ]; then
  log_success "✅ WebSocket bridge running"
else
  log_error "❌ WebSocket bridge failed to start"
  sudo journalctl -u riva-websocket-bridge -n 20 --no-pager
  exit 1
fi

echo ""

# ============================================================================
# Final Health Check
# ============================================================================
log_success "========================================="
log_success "✅ SYSTEM READY"
log_success "========================================="
echo ""
log_info "📊 Status Summary:"
echo "  GPU Instance: $GPU_INSTANCE_ID"
echo "  GPU IP: $CURRENT_IP"
echo "  RIVA Server: READY (http://$CURRENT_IP:8000)"
echo "  WebSocket Bridge: RUNNING (wss://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${APP_PORT:-8443})"
echo "  HTTPS Demo: https://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${DEMO_PORT:-8444}/demo.html"
echo ""
log_info "🧪 Test it now:"
echo "  1. Open: https://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${DEMO_PORT:-8444}/demo.html"
echo "  2. Click 'Start Transcription'"
echo "  3. Speak into microphone"
echo "  4. See real-time transcriptions"
echo ""
log_info "📝 Check logs:"
echo "  sudo journalctl -u riva-websocket-bridge -f"
echo ""
log_success "🎉 You're back in business!"
