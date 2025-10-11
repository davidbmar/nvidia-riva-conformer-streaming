#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 135: Deploy Parakeet from S3 Cache (FAST)
# ============================================================================
# Fast deployment using pre-built Triton models from S3 cache.
# No riva-build or riva-deploy needed - just download and start!
#
# Category: FAST DEPLOYMENT FROM S3 CACHE
# Timing:
#   - First run: ~15-20 minutes (includes 19GB RIVA image download)
#   - Subsequent runs: ~2-3 minutes (image already cached)
#
# What this does:
# 1. Download pre-built Triton models from S3 to build box (~10s)
# 2. Transfer models to GPU instance (~10s)
# 3. Pull RIVA Docker image if not present (~10-15 min first time only)
# 4. Start RIVA server with 8GB CUDA memory pool (~3s)
# 5. Wait for models to load and server ready (~3 min)
# 6. Health checks and validation
#
# Prerequisites:
# - S3 cache must be populated (run 116→117→118 first, one-time setup)
# - NGC_API_KEY configured in .env for docker image pull
# ============================================================================

echo "============================================"
echo "135: Deploy Parakeet from S3 Cache (FAST)"
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

# Load common functions if available
COMMON_FUNCTIONS="$SCRIPT_DIR/riva-common-functions.sh"
if [ -f "$COMMON_FUNCTIONS" ]; then
    source "$COMMON_FUNCTIONS"
fi

# Required variables
REQUIRED_VARS=(
    "AWS_REGION"
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_PORT"
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
TEMP_DIR="/tmp/parakeet-deploy-$$"
RIVA_VERSION="2.19.0"
DOCKER_PULL_TIMEOUT=900  # 15 minutes for 19GB image download
READY_TIMEOUT=300        # 5 minutes for model loading after container starts
MODEL_REPO_DIR="/opt/riva/models_parakeet"

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
fi

# Get S3 Triton cache location
S3_BUCKET="${S3_MODEL_BUCKET:-dbm-cf-2-web}"
MODEL_VERSION="v8.1"
S3_PARAKEET_TRITON_CACHE="${S3_PARAKEET_TRITON_CACHE:-s3://${S3_BUCKET}/bintarball/riva-repository/parakeet-rnnt-1.1b/${MODEL_VERSION}/}"

# Verify the S3 cache exists
if ! aws s3 ls "$S3_PARAKEET_TRITON_CACHE" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "⚠️  S3 Triton cache not found at: $S3_PARAKEET_TRITON_CACHE"
    echo ""
    echo "The cache needs to be populated first by running:"
    echo "  ./scripts/116-prepare-parakeet-s3-artifacts.sh"
    echo "  ./scripts/117-build-parakeet-triton-models.sh"
    echo "  ./scripts/118-upload-parakeet-triton-to-s3.sh"
    echo ""
    echo "This is a one-time setup that takes 30-50 minutes."
    echo "After that, deployments will only take 2-3 minutes!"
    exit 1
fi

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • S3 Cache: $S3_PARAKEET_TRITON_CACHE"
echo "  • RIVA Version: $RIVA_VERSION"
echo "  • gRPC Port: $RIVA_PORT"
echo "  • Model Repository: $MODEL_REPO_DIR"
echo ""

DEPLOY_START=$(date +%s)

# ============================================================================
# Step 1: Download Triton models from S3
# ============================================================================
echo "Step 1/6: Downloading pre-built Triton models from S3..."
echo "Source: $S3_PARAKEET_TRITON_CACHE"
echo ""

DOWNLOAD_START=$(date +%s)

mkdir -p "$TEMP_DIR"

if aws s3 sync "$S3_PARAKEET_TRITON_CACHE" "$TEMP_DIR/" --region "$AWS_REGION" --exclude "*.log"; then
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
echo "Step 2/6: Preparing GPU instance..."

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "MODEL_REPO_DIR='${MODEL_REPO_DIR}'" << 'PREP_SCRIPT'
set -euo pipefail

# Stop any existing RIVA server
echo "Stopping any existing RIVA containers..."
docker stop riva-server 2>/dev/null || true
docker rm riva-server 2>/dev/null || true

# Clear old models
echo "Clearing old model repository..."
sudo rm -rf ${MODEL_REPO_DIR}/*
sudo mkdir -p ${MODEL_REPO_DIR}
sudo chown -R ubuntu:ubuntu ${MODEL_REPO_DIR}

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
echo "Step 3/6: Transferring models to GPU..."

TRANSFER_START=$(date +%s)

if scp -r $SSH_OPTS "$TEMP_DIR"/* "${REMOTE_USER}@${GPU_INSTANCE_IP}:${MODEL_REPO_DIR}/"; then
    TRANSFER_END=$(date +%s)
    TRANSFER_DURATION=$((TRANSFER_END - TRANSFER_START))
    echo "✅ Transfer completed in ${TRANSFER_DURATION}s"
else
    echo "❌ Transfer failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Cleanup local temp directory
rm -rf "$TEMP_DIR"

echo ""

# ============================================================================
# Step 4: Load RIVA Docker Image (S3-first, NGC fallback)
# ============================================================================
echo "Step 4/6: Loading RIVA Docker image..."

PULL_START=$(date +%s)

# Check if image already exists on GPU
if ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "docker images | grep -q 'nvcr.io/nvidia/riva/riva-speech.*${RIVA_VERSION}'"; then
    echo "✅ RIVA image ${RIVA_VERSION} already present on GPU"
    PULL_DURATION=0
else
    echo "Checking disk space on GPU..."
    FREE_SPACE=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
        "df -BG / | tail -1 | awk '{print \$4}' | sed 's/G//'")

    if [ "$FREE_SPACE" -lt 25 ]; then
        echo "❌ Insufficient disk space: ${FREE_SPACE}GB free (need 25GB+)"
        echo "Run: ssh ubuntu@${GPU_INSTANCE_IP} 'docker system prune -af'"
        exit 1
    fi
    echo "✅ Disk space OK: ${FREE_SPACE}GB free"

    # Try S3 first (faster, no API key needed, streaming load)
    S3_RIVA_CONTAINER="${RIVA_SERVER_PATH:-s3://dbm-cf-2-web/bintarball/riva-containers/riva-speech-2.19.0.tar.gz}"

    if [ -n "${S3_RIVA_CONTAINER:-}" ]; then
        echo ""
        echo "Method 1: Loading from S3 (streaming, no disk storage needed)..."
        echo "Source: ${S3_RIVA_CONTAINER}"
        echo "This will take 2-3 minutes..."

        if ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
            "aws s3 cp '${S3_RIVA_CONTAINER}' - 2>/dev/null | docker load"; then
            echo "✅ RIVA image loaded from S3"
        else
            echo "⚠️  S3 load failed (aws cli may not be installed on GPU), trying NGC..."

            # Fallback to NGC
            if [ -z "${NGC_API_KEY:-}" ]; then
                echo "❌ NGC_API_KEY not set and S3 load failed"
                echo "Either install aws cli on GPU or set NGC_API_KEY in .env"
                exit 1
            fi

            echo "Logging into NGC and pulling image..."
            ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
                "echo '${NGC_API_KEY}' | docker login nvcr.io --username '\$oauthtoken' --password-stdin >/dev/null 2>&1 && \
                 docker pull nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION}"

            if [ $? -eq 0 ]; then
                echo "✅ RIVA image pulled from NGC"
            else
                echo "❌ Both S3 and NGC loading failed"
                exit 1
            fi
        fi
    else
        echo "⚠️  RIVA_SERVER_PATH not configured in .env, using NGC..."

        # NGC-only path
        if [ -z "${NGC_API_KEY:-}" ]; then
            echo "❌ NGC_API_KEY not set"
            echo "Set RIVA_SERVER_PATH or NGC_API_KEY in .env"
            exit 1
        fi

        echo "Logging into NGC and pulling image (this will take 10-15 minutes)..."
        ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
            "echo '${NGC_API_KEY}' | docker login nvcr.io --username '\$oauthtoken' --password-stdin >/dev/null 2>&1 && \
             docker pull nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION}"

        if [ $? -ne 0 ]; then
            echo "❌ NGC pull failed"
            exit 1
        fi
        echo "✅ RIVA image pulled from NGC"
    fi
fi

PULL_END=$(date +%s)
PULL_DURATION=$((PULL_END - PULL_START))

echo "✅ RIVA image ready (loaded in ${PULL_DURATION}s)"
echo ""

# ============================================================================
# Step 5: Start RIVA Server
# ============================================================================
echo "Step 5/6: Starting RIVA server..."

START_CMD="docker run -d --name riva-server --gpus all \\
  --restart unless-stopped \\
  -p ${RIVA_PORT}:${RIVA_PORT} \\
  -p 8000:8000 \\
  -v ${MODEL_REPO_DIR}:/opt/riva_models \\
  -e CUDA_VISIBLE_DEVICES=0 \\
  --shm-size=8g \\
  nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION} \\
  bash -c 'export LD_LIBRARY_PATH=/opt/tritonserver/lib:\$LD_LIBRARY_PATH && \\
  /opt/riva/bin/start-riva --riva-uri=0.0.0.0:${RIVA_PORT} \\
  --nlp_service=false --nmt_service=false --tts_service=false \\
  --asr_service=true --model_repo=/opt/riva_models'"

echo "Starting container..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "$START_CMD"

if [ $? -eq 0 ]; then
    echo "✅ RIVA container started"
else
    echo "❌ Failed to start RIVA container"
    exit 1
fi

echo ""

# ============================================================================
# Step 6: Wait for server ready and validate
# ============================================================================
echo "Step 6/6: Waiting for server ready (models loading, ~2-3 minutes)..."

READY_START=$(date +%s)
READY=false
CHECK_INTERVAL=10

while [ $(($(date +%s) - READY_START)) -lt $READY_TIMEOUT ]; do
    ELAPSED=$(($(date +%s) - READY_START))
    echo "Checking health (${ELAPSED}s elapsed)..."

    # Check if container is still running
    if ! ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
        "docker ps | grep -q riva-server"; then
        echo "❌ RIVA container stopped unexpectedly"
        echo "Container logs:"
        ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
            "docker logs riva-server 2>&1 | tail -50"
        exit 1
    fi

    # Try health check
    if ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
        "curl -s -f http://localhost:8000/v1/health/ready >/dev/null 2>&1"; then
        READY=true
        break
    fi

    sleep $CHECK_INTERVAL
done

READY_END=$(date +%s)
READY_DURATION=$((READY_END - READY_START))

if [ "$READY" = true ]; then
    echo "✅ RIVA server ready in ${READY_DURATION}s"
else
    echo "❌ RIVA server not ready after ${READY_TIMEOUT}s"
    echo "Container status:"
    ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "docker ps -a | grep riva-server"
    echo ""
    echo "Container logs:"
    ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
        "docker logs riva-server 2>&1 | tail -50"
    exit 1
fi

# ============================================================================
# Final validation and summary
# ============================================================================
echo ""
echo "Performing final health checks..."

# Get loaded models
MODELS=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "curl -s http://localhost:8000/v2/models" 2>/dev/null | grep -o '\"name\":\"[^\"]*\"' | cut -d'"' -f4 | sort -u)

if [ -n "$MODELS" ]; then
    echo "✅ Loaded models:"
    echo "$MODELS" | sed 's/^/     • /'
else
    echo "⚠️  Could not retrieve model list (server may still be initializing)"
fi

DEPLOY_END=$(date +%s)
DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================="
echo "✅ PARAKEET DEPLOYED SUCCESSFULLY"
echo "========================================="
echo ""
echo "Deployment Time: ${DEPLOY_DURATION}s (~$((DEPLOY_DURATION / 60)) min)"
echo "  • S3 Download: ${DOWNLOAD_DURATION}s"
echo "  • Model Transfer: ${TRANSFER_DURATION}s"
echo "  • Image Load: ${PULL_DURATION}s"
echo "  • Server Ready: ${READY_DURATION}s"
echo ""
echo "RIVA Endpoints:"
echo "  • gRPC: ${GPU_INSTANCE_IP}:${RIVA_PORT}"
echo "  • HTTP: http://${GPU_INSTANCE_IP}:8000"
echo "  • Health: http://${GPU_INSTANCE_IP}:8000/v1/health/ready"
echo ""
echo "Test transcription:"
echo "  grpcurl -plaintext -d '{\"config\": {\"encoding\": \"LINEAR_PCM\", \"sample_rate_hertz\": 16000, \"language_code\": \"en-US\"}}' ${GPU_INSTANCE_IP}:${RIVA_PORT} nvidia.riva.asr.v1.RivaSpeechRecognition/Recognize"
echo ""
echo "View logs:"
echo "  ssh ubuntu@${GPU_INSTANCE_IP} 'docker logs -f riva-server'"
echo ""
