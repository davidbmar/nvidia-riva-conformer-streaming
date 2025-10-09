#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 130: Update WebSocket Bridge to Point to New RIVA Server
# ============================================================================
# Updates an existing WebSocket bridge deployment to use a different RIVA server.
# This is useful when you've deployed a new RIVA instance and want to redirect
# the WebSocket bridge without redeploying the entire bridge infrastructure.
#
# Category: INTEGRATION
# This script: ~10 seconds
#
# What this does:
# 1. Update RIVA_HOST in deployed bridge .env file
# 2. Fix file permissions (SSL certs, logs, .env)
# 3. Restart WebSocket bridge service
# 4. Validate connection to new RIVA server
#
# Prerequisites:
# - WebSocket bridge already deployed (usually at /opt/riva/nvidia-parakeet-ver-6/)
# - New RIVA server running and accessible
# ============================================================================

echo "============================================"
echo "130: Update WebSocket Bridge to New RIVA"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Configuration file not found: $ENV_FILE"
    exit 1
fi

# Load configuration
source "$ENV_FILE"

# Load common functions (for resolve_gpu_ip)
COMMON_FUNCTIONS="$SCRIPT_DIR/riva-common-functions.sh"
if [ -f "$COMMON_FUNCTIONS" ]; then
    source "$COMMON_FUNCTIONS"
fi

# Required variables
REQUIRED_VARS=(
    "GPU_INSTANCE_ID"
    "RIVA_PORT"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required variable not set: $var"
        exit 1
    fi
done

# Auto-resolve GPU IP from instance ID
echo "Resolving GPU IP from instance ID: $GPU_INSTANCE_ID..."
GPU_INSTANCE_IP=$(resolve_gpu_ip)
if [ $? -ne 0 ] || [ -z "$GPU_INSTANCE_IP" ]; then
    echo "❌ Failed to resolve GPU IP address"
    exit 1
fi
echo "✅ Resolved GPU IP: $GPU_INSTANCE_IP"
echo ""

# Configuration
BRIDGE_DEPLOY_DIR="/opt/riva/nvidia-parakeet-ver-6"
BRIDGE_ENV="$BRIDGE_DEPLOY_DIR/.env"
BRIDGE_SERVICE="riva-websocket-bridge"

echo "Configuration:"
echo "  • New RIVA Host: $GPU_INSTANCE_IP"
echo "  • New RIVA Port: $RIVA_PORT"
echo "  • Bridge Directory: $BRIDGE_DEPLOY_DIR"
echo ""

# ============================================================================
# Step 1: Verify bridge deployment exists
# ============================================================================
echo "Step 1/5: Verifying WebSocket bridge deployment..."

if [ ! -d "$BRIDGE_DEPLOY_DIR" ]; then
    echo "❌ Bridge directory not found: $BRIDGE_DEPLOY_DIR"
    echo ""
    echo "Please deploy WebSocket bridge first using:"
    echo "  • scripts from nvidia-parakeet-ver-6 (140-149 series)"
    exit 1
fi

if [ ! -f "$BRIDGE_ENV" ]; then
    echo "❌ Bridge .env not found: $BRIDGE_ENV"
    exit 1
fi

if ! systemctl is-enabled "$BRIDGE_SERVICE" >/dev/null 2>&1; then
    echo "❌ Service not found: $BRIDGE_SERVICE"
    echo "Bridge service is not installed as systemd service"
    exit 1
fi

echo "✅ Bridge deployment found"
echo ""

# ============================================================================
# Step 2: Update RIVA_HOST and model config in bridge .env
# ============================================================================
echo "Step 2/5: Updating RIVA configuration in bridge..."

# Get old RIVA host for logging
OLD_RIVA_HOST=$(grep "^RIVA_HOST=" "$BRIDGE_ENV" | cut -d= -f2)

echo "  Old RIVA_HOST: ${OLD_RIVA_HOST:-not set}"
echo "  New RIVA_HOST: $GPU_INSTANCE_IP"

# Update RIVA_HOST
sudo sed -i "s/^RIVA_HOST=.*/RIVA_HOST=$GPU_INSTANCE_IP/" "$BRIDGE_ENV"

# Disable word time offsets (Conformer-CTC has segfault bug with this enabled)
sudo sed -i "s/^RIVA_ENABLE_WORD_TIME_OFFSETS=.*/RIVA_ENABLE_WORD_TIME_OFFSETS=false/" "$BRIDGE_ENV"
echo "  Set RIVA_ENABLE_WORD_TIME_OFFSETS=false (Conformer-CTC compatibility)"

# Verify updates
NEW_RIVA_HOST=$(sudo grep "^RIVA_HOST=" "$BRIDGE_ENV" | cut -d= -f2)
if [ "$NEW_RIVA_HOST" = "$GPU_INSTANCE_IP" ]; then
    echo "✅ RIVA_HOST updated successfully"
else
    echo "❌ Failed to update RIVA_HOST"
    exit 1
fi

echo ""

# ============================================================================
# Step 3: Fix speech_contexts compatibility
# ============================================================================
echo "Step 3/6: Fixing Conformer-CTC compatibility in riva_client.py..."

# Fix speech_contexts: change "None" to "[]" to prevent gRPC errors
RIVA_CLIENT_PY="$BRIDGE_DEPLOY_DIR/src/asr/riva_client.py"

if [ -f "$RIVA_CLIENT_PY" ]; then
    # Check if fix is needed
    if sudo grep -q '] if hotwords else None' "$RIVA_CLIENT_PY"; then
        sudo sed -i 's/] if hotwords else None/] if hotwords else []/g' "$RIVA_CLIENT_PY"
        echo "  ✅ Fixed speech_contexts: None → [] (prevents gRPC errors)"
    else
        echo "  ℹ️  speech_contexts already fixed or different version"
    fi
else
    echo "  ⚠️  riva_client.py not found at expected location"
fi

echo ""

# ============================================================================
# Step 4: Fix file permissions
# ============================================================================
echo "Step 4/6: Fixing file permissions for riva user..."

# Get the service user
SERVICE_USER=$(sudo grep "^User=" /etc/systemd/system/$BRIDGE_SERVICE.service | cut -d= -f2 || echo "riva")

echo "  Service runs as user: $SERVICE_USER"

# Fix .env permissions (readable by all)
sudo chmod 644 "$BRIDGE_ENV"

# Fix SSL cert ownership and permissions
if [ -d "/opt/riva/certs" ]; then
    sudo chown -R $SERVICE_USER:$SERVICE_USER /opt/riva/certs/
    echo "  ✅ SSL cert ownership: $SERVICE_USER:$SERVICE_USER"
fi

# Fix logs directory ownership
if [ -d "/opt/riva/logs" ]; then
    sudo chown -R $SERVICE_USER:$SERVICE_USER /opt/riva/logs/
    echo "  ✅ Logs ownership: $SERVICE_USER:$SERVICE_USER"
fi

echo "✅ Permissions fixed"
echo ""

# ============================================================================
# Step 5: Restart WebSocket bridge service
# ============================================================================
echo "Step 5/6: Restarting WebSocket bridge service..."

# Stop service
sudo systemctl stop $BRIDGE_SERVICE || true
sleep 2

# Start service (with pre-start validation)
if sudo systemctl start $BRIDGE_SERVICE; then
    echo "✅ Service started successfully"
else
    echo "❌ Service failed to start"
    echo ""
    echo "Recent logs:"
    sudo journalctl -u $BRIDGE_SERVICE -n 20 --no-pager
    exit 1
fi

sleep 3
echo ""

# ============================================================================
# Step 5: Validate service is running
# ============================================================================
echo "Step 5/5: Validating service status..."

if systemctl is-active --quiet $BRIDGE_SERVICE; then
    echo "✅ Service is active and running"

    # Show service info
    echo ""
    echo "Service Status:"
    sudo systemctl status $BRIDGE_SERVICE --no-pager | head -15

    echo ""
    echo "Recent Logs:"
    sudo journalctl -u $BRIDGE_SERVICE --since "30 seconds ago" --no-pager | tail -10
else
    echo "❌ Service is not active"
    sudo systemctl status $BRIDGE_SERVICE --no-pager
    exit 1
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ WEBSOCKET BRIDGE UPDATED"
echo "========================================="
echo ""
echo "Bridge Configuration:"
echo "  • Old RIVA: ${OLD_RIVA_HOST}:${RIVA_PORT}"
echo "  • New RIVA: ${GPU_INSTANCE_IP}:${RIVA_PORT}"
echo "  • Bridge Service: $BRIDGE_SERVICE"
echo "  • Service Status: $(systemctl is-active $BRIDGE_SERVICE 2>/dev/null || echo 'unknown')"
echo ""
echo "WebSocket Endpoint:"
echo "  • wss://$(curl -s http://checkip.amazonaws.com):${APP_PORT:-8443}"
echo ""
echo "Next Steps:"
echo "  • Test demo: https://$(curl -s http://checkip.amazonaws.com):${DEMO_PORT:-8444}/demo.html"
echo "  • Monitor logs: sudo journalctl -u $BRIDGE_SERVICE -f"
echo ""
