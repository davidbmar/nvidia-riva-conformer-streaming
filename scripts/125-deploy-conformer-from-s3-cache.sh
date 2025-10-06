#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 125: Deploy Conformer from S3 Cache (FAST)
# ============================================================================
# Fast deployment using pre-built Triton models from S3 cache.
# No riva-build or riva-deploy needed - just download and start!
#
# Category: FAST DEPLOYMENT FROM S3 CACHE
# This script: ~2-3 minutes (vs 30-50 min rebuilding)
#
# What this does:
# 1. Download pre-built Triton models from S3 to build box
# 2. Transfer to GPU instance
# 3. Start RIVA server with start-riva command
# 4. Health checks and validation
#
# Prerequisites:
# - S3 cache must be populated (run 100→101→102 first)
# ============================================================================

echo "============================================"
echo "125: Deploy Conformer from S3 Cache (FAST)"
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

# Required variables
REQUIRED_VARS=(
    "AWS_REGION"
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_PORT"
    "RIVA_HTTP_PORT"
    "NGC_API_KEY"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required variable not set: $var"
        exit 1
    fi
done

# Configuration
SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
SSH_OPTS="-i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
REMOTE_USER="ubuntu"
TEMP_DIR="/tmp/conformer-deploy-$$"
RIVA_VERSION="2.19.0"
READY_TIMEOUT=180

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
fi

# Get S3 repository location from .env
if [ -z "${S3_CONFORMER_TRITON_CACHE:-}" ]; then
    echo "❌ S3_CONFORMER_TRITON_CACHE not configured in .env"
    echo "Run ./scripts/005-setup-configuration.sh to configure."
    exit 1
fi

S3_REPO="$S3_CONFORMER_TRITON_CACHE"

# Verify the S3 cache exists
if ! aws s3 ls "$S3_REPO" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "⚠️  S3 Triton cache not found at: $S3_REPO"
    echo ""
    echo "The cache needs to be populated first by running:"
    echo "  ./scripts/100-prepare-conformer-s3-artifacts.sh"
    echo "  ./scripts/101-build-conformer-triton-models.sh"
    echo "  ./scripts/102-upload-triton-models-to-s3.sh"
    echo ""
    echo "This is a one-time setup that takes 30-50 minutes."
    echo "After that, deployments will only take 2-3 minutes!"
    exit 1
fi

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • S3 Repository: $S3_REPO"
echo "  • RIVA Version: $RIVA_VERSION"
echo "  • gRPC Port: $RIVA_PORT"
echo "  • HTTP Port: $RIVA_HTTP_PORT"
echo ""

DEPLOY_START=$(date +%s)

# ============================================================================
# Step 1: Download Triton models from S3
# ============================================================================
echo "Step 1/5: Downloading pre-built Triton models from S3..."
echo "Source: $S3_REPO"
echo ""

DOWNLOAD_START=$(date +%s)

mkdir -p "$TEMP_DIR"

if aws s3 sync "$S3_REPO" "$TEMP_DIR/" --region "$AWS_REGION" --exclude "*.log"; then
    DOWNLOAD_END=$(date +%s)
    DOWNLOAD_DURATION=$((DOWNLOAD_END - DOWNLOAD_START))

    MODEL_COUNT=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | wc -l)
    TOTAL_SIZE=$(du -sm "$TEMP_DIR" | cut -f1)

    echo "✅ Downloaded $MODEL_COUNT model directories (${TOTAL_SIZE}MB) in ${DOWNLOAD_DURATION}s"
else
    echo "❌ Download from S3 failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""

# ============================================================================
# Step 2: Prepare GPU instance
# ============================================================================
echo "Step 2/5: Preparing GPU instance..."

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'PREP_SCRIPT'
set -euo pipefail

# Stop any existing RIVA server
echo "Stopping any existing RIVA containers..."
docker stop riva-server 2>/dev/null || true
docker rm riva-server 2>/dev/null || true

# Clear old models
echo "Clearing old model repository..."
sudo rm -rf /opt/riva/models_conformer_fast/*
sudo mkdir -p /opt/riva/models_conformer_fast
sudo chown -R ubuntu:ubuntu /opt/riva/models_conformer_fast

echo "✅ GPU instance prepared"
PREP_SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Failed to prepare GPU instance"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "✅ GPU instance prepared"
echo ""

# ============================================================================
# Step 3: Transfer models to GPU
# ============================================================================
echo "Step 3/5: Transferring models to GPU..."

TRANSFER_START=$(date +%s)

if scp -r $SSH_OPTS "$TEMP_DIR"/* "${REMOTE_USER}@${GPU_INSTANCE_IP}:/opt/riva/models_conformer_fast/"; then
    TRANSFER_END=$(date +%s)
    TRANSFER_DURATION=$((TRANSFER_END - TRANSFER_START))
    echo "✅ Transfer completed in ${TRANSFER_DURATION}s"
else
    echo "❌ Transfer failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""

# ============================================================================
# Step 4: Configure NGC access for Docker
# ============================================================================
echo "Step 4/6: Configuring NGC access..."

# Check if NGC API key is set
if [ -z "${NGC_API_KEY:-}" ]; then
    echo "❌ NGC_API_KEY not set in .env"
    echo "NVIDIA Container Registry access is required to pull RIVA images."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Login to NGC on GPU instance
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "NGC_API_KEY='${NGC_API_KEY}'" << 'NGC_LOGIN'
set -euo pipefail

# Check if already logged in
if docker images | grep -q "nvcr.io/nvidia/riva/riva-speech"; then
    echo "✅ RIVA image already available"
else
    echo "Logging into NVIDIA NGC..."
    echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ NGC login successful"
    else
        echo "❌ NGC login failed"
        exit 1
    fi
fi
NGC_LOGIN

if [ $? -ne 0 ]; then
    echo "❌ Failed to configure NGC access"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "✅ NGC access configured"
echo ""

# ============================================================================
# Step 5: Start RIVA server
# ============================================================================
echo "Step 5/6: Starting RIVA server..."

START_START=$(date +%s)

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "RIVA_VERSION='${RIVA_VERSION}' RIVA_PORT='${RIVA_PORT}' RIVA_HTTP_PORT='${RIVA_HTTP_PORT}'" << 'START_SCRIPT'
set -euo pipefail

echo "Starting RIVA server with start-riva command..."
echo "Command: docker run -d --gpus all --name riva-server -p ${RIVA_PORT}:50051 -p ${RIVA_HTTP_PORT}:8000 ..."

docker run -d --rm --gpus all --name riva-server \
    -p ${RIVA_PORT}:50051 \
    -p ${RIVA_HTTP_PORT}:8000 \
    -p 8001:8001 \
    -p 8002:8002 \
    -v /opt/riva/models_conformer_fast:/data/models \
    nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION} \
    start-riva \
        --asr_service=true \
        --nlp_service=false \
        --tts_service=false

# Wait a moment for container to initialize
sleep 3

# Check if container is running
if docker ps | grep -q riva-server; then
    echo "✅ RIVA server container started"
    CONTAINER_ID=$(docker ps --filter name=riva-server --format '{{.ID}}')
    echo "Container ID: $CONTAINER_ID"
else
    echo "❌ RIVA server failed to start"
    docker logs riva-server 2>&1 | tail -20 || true
    exit 1
fi
START_SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Failed to start RIVA server"
    rm -rf "$TEMP_DIR"
    exit 1
fi

START_END=$(date +%s)
START_DURATION=$((START_END - START_START))

echo "✅ RIVA server started in ${START_DURATION}s"
echo ""

# ============================================================================
# Step 6: Wait for RIVA ready
# ============================================================================
echo "Step 6/6: Waiting for RIVA server to be ready..."
echo "Timeout: ${READY_TIMEOUT}s"
echo ""

HEALTH_START=$(date +%s)
ELAPSED=0
INTERVAL=3

while [ $ELAPSED -lt $READY_TIMEOUT ]; do
    # Check HTTP health endpoint
    if curl -sf "http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}/v2/health/ready" >/dev/null 2>&1; then
        HEALTH_END=$(date +%s)
        HEALTH_DURATION=$((HEALTH_END - HEALTH_START))
        echo "✅ RIVA server is READY (health check passed in ${HEALTH_DURATION}s)"
        echo ""

        # Show loaded models
        echo "Loaded models:"
        curl -s "http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}/v2/models" 2>/dev/null | \
            python3 -c "import sys, json; data=json.load(sys.stdin) if sys.stdin.read(1) else []; [print(f'  • {m}') for m in (data if isinstance(data, list) else [])]" 2>/dev/null || \
            echo "  (model list unavailable)"
        echo ""

        break
    fi

    echo "⏳ Waiting for server ready... (${ELAPSED}s/${READY_TIMEOUT}s)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $READY_TIMEOUT ]; then
    echo "❌ RIVA server did not become ready within ${READY_TIMEOUT}s"
    echo ""
    echo "Container logs:"
    ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "docker logs riva-server --tail 50" || true
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Cleanup local temp directory
rm -rf "$TEMP_DIR"

DEPLOY_END=$(date +%s)
TOTAL_DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ FAST DEPLOYMENT COMPLETE"
echo "========================================="
echo ""
echo "GPU Instance: $GPU_INSTANCE_IP"
echo "Model Repository: /opt/riva/models_conformer_fast/"
echo ""
echo "Deployment Breakdown:"
echo "  • S3 Download: ${DOWNLOAD_DURATION}s"
echo "  • GPU Transfer: ${TRANSFER_DURATION}s"
echo "  • Server Start: ${START_DURATION}s"
echo "  • Health Check: ${HEALTH_DURATION}s"
echo "  • Total Time: ${TOTAL_DEPLOY_DURATION}s (~$((TOTAL_DEPLOY_DURATION / 60)) min)"
echo ""
echo "Endpoints:"
echo "  • gRPC: ${GPU_INSTANCE_IP}:${RIVA_PORT}"
echo "  • HTTP: http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}"
echo ""
echo "Next Steps:"
echo "  • Validate deployment: ./scripts/126-validate-conformer-deployment.sh"
echo "  • Test streaming: Connect WebSocket bridge to this RIVA instance"
echo ""
