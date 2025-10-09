#!/bin/bash
# Quick S3-based RIVA deployment test script
# Use this for fast testing before running the full 125 script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Configuration file not found: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# Load common functions (for resolve_gpu_ip)
COMMON_FUNCTIONS="$SCRIPT_DIR/riva-common-functions.sh"
if [ -f "$COMMON_FUNCTIONS" ]; then
    source "$COMMON_FUNCTIONS"
fi

# Auto-resolve GPU IP from instance ID
echo "Resolving GPU IP from instance ID: $GPU_INSTANCE_ID..."
GPU_IP=$(resolve_gpu_ip)
if [ $? -ne 0 ] || [ -z "$GPU_IP" ]; then
    echo "❌ Failed to resolve GPU IP address"
    echo "Make sure GPU_INSTANCE_ID is correct in .env"
    exit 1
fi

# Configuration
SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"

echo "🚀 Quick S3-Based RIVA Deployment Test"
echo "======================================="
echo "GPU: $GPU_IP"
echo "S3 Container: ${S3_RIVA_CONTAINER:-NOT SET}"
echo ""

# Step 1: Check GPU is reachable
echo "Step 1: Checking GPU connectivity..."
if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" "echo 'Connected'" >/dev/null 2>&1; then
    echo "✅ GPU is reachable"
else
    echo "❌ Cannot reach GPU at $GPU_IP"
    exit 1
fi

# Step 2: Check/Load Docker image
echo ""
echo "Step 2: Checking Docker image..."
if ssh -i "$SSH_KEY" ubuntu@"$GPU_IP" "docker images | grep -q 'riva-speech.*2.19.0'"; then
    echo "✅ RIVA image already present"
else
    echo "Loading RIVA image from S3 (2-3 minutes)..."
    ssh -i "$SSH_KEY" ubuntu@"$GPU_IP" \
        "aws s3 cp '${S3_RIVA_CONTAINER}' - 2>/dev/null | docker load"
    echo "✅ Image loaded"
fi

# Step 3: Start container
echo ""
echo "Step 3: Starting RIVA container..."
ssh -i "$SSH_KEY" ubuntu@"$GPU_IP" \
    "docker stop riva-server 2>/dev/null || true && \
     docker rm riva-server 2>/dev/null || true && \
     docker run -d --gpus all --name riva-server \
       -p 50051:50051 -p 8000:8000 -p 8001:8001 \
       -v /opt/riva/models_conformer_fast:/data/models \
       nvcr.io/nvidia/riva/riva-speech:2.19.0 \
       bash -c 'tritonserver --model-repository=/data/models --cuda-memory-pool-byte-size=0:8000000000 --log-info=true --exit-on-error=false & sleep 20 && /opt/riva/bin/riva_server --asr_service=true --nlp_service=false --tts_service=false & wait'"

echo "✅ Container started"

# Step 4: Wait for ready
echo ""
echo "Step 4: Waiting for RIVA ready (up to 180s)..."
ELAPSED=0
while [ $ELAPSED -lt 180 ]; do
    if curl -sf "http://${GPU_IP}:8000/v2/health/ready" >/dev/null 2>&1; then
        echo "✅ RIVA is READY in ${ELAPSED}s!"
        echo ""
        echo "Endpoints:"
        echo "  • gRPC: ${GPU_IP}:50051"
        echo "  • HTTP: http://${GPU_IP}:8000"
        exit 0
    fi
    echo "⏳ Waiting... (${ELAPSED}s/180s)"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo "❌ Timeout waiting for RIVA ready"
ssh -i "$SSH_KEY" ubuntu@"$GPU_IP" "docker logs riva-server --tail 50"
exit 1
