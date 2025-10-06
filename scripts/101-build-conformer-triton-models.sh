#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 101: Build Conformer Triton Models
# ============================================================================
# Runs riva-build and riva-deploy on GPU to create Triton models.
# This is the heavy lifting step that takes 30-45 minutes.
#
# Category: ONE-TIME S3 POPULATION (Build & Cache - 30-50 min total)
# This script: ~30-45 minutes (GPU work)
#
# What this does:
# 1. SSH to GPU instance
# 2. Download source .riva model from S3
# 3. Run riva-build: .riva → .rmir (30-45 min with correct 40ms params)
# 4. Run riva-deploy: .rmir → Triton models (5-8 min)
# 5. Leave Triton models on GPU for upload step (102)
# ============================================================================

echo "============================================"
echo "101: Build Conformer Triton Models"
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
    "S3_CONFORMER_SOURCE"
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
RIVA_VERSION="2.19.0"
BUILD_TIMEOUT=2700  # 45 minutes

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
fi

# Load S3 base from previous step
if [ ! -f "$PROJECT_ROOT/artifacts/s3_base_uri" ]; then
    echo "❌ S3 base URI not found. Run 100-prepare-conformer-s3-artifacts.sh first."
    exit 1
fi

S3_BASE=$(cat "$PROJECT_ROOT/artifacts/s3_base_uri")

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • RIVA Version: $RIVA_VERSION"
echo "  • Source Model: $S3_CONFORMER_SOURCE"
echo "  • Build Timeout: ${BUILD_TIMEOUT}s (~45 min)"
echo ""

# ============================================================================
# Step 1: Prepare GPU worker
# ============================================================================
echo "Step 1/4: Preparing GPU worker..."

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'PREP_SCRIPT'
set -euo pipefail

echo "Creating build directories..."
mkdir -p /tmp/riva-build/{input,output}

echo "Checking Docker..."
if ! docker ps >/dev/null 2>&1; then
    echo "❌ Docker not available"
    exit 1
fi

echo "Checking GPU..."
if ! nvidia-smi >/dev/null 2>&1; then
    echo "❌ NVIDIA GPU not available"
    exit 1
fi

echo "✅ GPU worker ready"
PREP_SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Failed to prepare GPU worker"
    exit 1
fi

echo "✅ GPU worker prepared"
echo ""

# ============================================================================
# Step 2: Download source model to GPU
# ============================================================================
echo "Step 2/4: Downloading source model to GPU..."

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "AWS_REGION='${AWS_REGION}' S3_SOURCE='${S3_CONFORMER_SOURCE}'" << 'DOWNLOAD_SCRIPT'
set -euo pipefail

cd /tmp/riva-build/input

# Download source model
echo "Downloading from S3: $S3_SOURCE"
if aws s3 cp "$S3_SOURCE" . --region "$AWS_REGION"; then
    SOURCE_FILE=$(ls -1 *.riva 2>/dev/null | head -1)
    if [ -n "$SOURCE_FILE" ]; then
        echo "✅ Downloaded: $SOURCE_FILE ($(du -h "$SOURCE_FILE" | cut -f1))"
    else
        echo "❌ No .riva file found after download"
        exit 1
    fi
else
    echo "❌ Download failed"
    exit 1
fi
DOWNLOAD_SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Failed to download source model"
    exit 1
fi

echo "✅ Source model downloaded to GPU"
echo ""

# ============================================================================
# Step 3: Run riva-build (30-45 min)
# ============================================================================
echo "Step 3/4: Running riva-build (this will take ~30-45 minutes)..."
echo "Building Conformer-CTC with correct 40ms streaming parameters..."
echo ""

BUILD_START=$(date +%s)

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "NGC_API_KEY='${NGC_API_KEY}' RIVA_VERSION='${RIVA_VERSION}'" << 'BUILD_SCRIPT'
set -euo pipefail

cd /tmp/riva-build

# Find source .riva file
SOURCE_FILE=$(find input -name "*.riva" -type f | head -1)
if [ -z "$SOURCE_FILE" ]; then
    echo "❌ No .riva file found in input/"
    exit 1
fi

echo "Source model: $SOURCE_FILE"
echo "Starting riva-build at $(date)..."
echo ""

# Login to NGC
echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin >/dev/null 2>&1

# Run riva-build with Conformer-CTC streaming parameters
docker run --rm --gpus all \
    -v /tmp/riva-build:/workspace \
    nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION} \
    riva-build speech_recognition \
        /workspace/output/conformer-ctc-xl-streaming.rmir \
        /workspace/${SOURCE_FILE}:tlt_encode \
        --name=conformer-ctc-xl-en-us-streaming \
        --language_code=en-US \
        --streaming=true \
        --ms_per_timestep=40 \
        --chunk_size=0.16 \
        --padding_size=1.92 \
        --decoder_type=greedy \
        --nn.fp16_needs_obey_precision_pass \
        --greedy_decoder.asr_model_delay=-1 \
        --endpointing.residue_blanks_at_start=-2 \
        --featurizer.use_utterance_norm_params=False \
        --featurizer.precalc_norm_time_steps=0 \
        --featurizer.precalc_norm_params=False

BUILD_EXIT=$?
echo ""
echo "riva-build completed at $(date) with exit code: $BUILD_EXIT"

if [ $BUILD_EXIT -eq 0 ] && [ -f output/conformer-ctc-xl-streaming.rmir ]; then
    echo "✅ riva-build successful"
    echo "Output: $(du -h output/conformer-ctc-xl-streaming.rmir | cut -f1)"
    exit 0
else
    echo "❌ riva-build failed"
    exit 1
fi
BUILD_SCRIPT

BUILD_EXIT=$?
BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

if [ $BUILD_EXIT -ne 0 ]; then
    echo "❌ riva-build failed after ${BUILD_DURATION}s"
    exit 1
fi

echo "✅ riva-build completed in ${BUILD_DURATION}s (~$((BUILD_DURATION / 60)) min)"
echo ""

# ============================================================================
# Step 4: Run riva-deploy (5-8 min)
# ============================================================================
echo "Step 4/4: Running riva-deploy (this will take ~5-8 minutes)..."
echo ""

DEPLOY_START=$(date +%s)

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "RIVA_VERSION='${RIVA_VERSION}'" << 'DEPLOY_SCRIPT'
set -euo pipefail

cd /tmp/riva-build

# Create model repository
sudo mkdir -p /opt/riva/models_conformer_triton
sudo chown -R ubuntu:ubuntu /opt/riva/models_conformer_triton

echo "Starting riva-deploy at $(date)..."
echo "Input: output/conformer-ctc-xl-streaming.rmir"
echo "Output: /opt/riva/models_conformer_triton/"
echo ""

# Run riva-deploy
docker run --rm --gpus all \
    -v /tmp/riva-build:/workspace \
    -v /opt/riva/models_conformer_triton:/data/models \
    nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION} \
    riva-deploy \
        /workspace/output/conformer-ctc-xl-streaming.rmir \
        /data/models

DEPLOY_EXIT=$?
echo ""
echo "riva-deploy completed at $(date) with exit code: $DEPLOY_EXIT"

if [ $DEPLOY_EXIT -eq 0 ]; then
    echo "✅ riva-deploy successful"
    echo ""
    echo "Triton model repository structure:"
    ls -lh /opt/riva/models_conformer_triton/ | head -20
    echo ""
    MODEL_COUNT=$(find /opt/riva/models_conformer_triton -maxdepth 1 -type d ! -path /opt/riva/models_conformer_triton | wc -l)
    echo "Model directories created: $MODEL_COUNT"
    exit 0
else
    echo "❌ riva-deploy failed"
    exit 1
fi
DEPLOY_SCRIPT

DEPLOY_EXIT=$?
DEPLOY_END=$(date +%s)
DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))

if [ $DEPLOY_EXIT -ne 0 ]; then
    echo "❌ riva-deploy failed after ${DEPLOY_DURATION}s"
    exit 1
fi

echo "✅ riva-deploy completed in ${DEPLOY_DURATION}s (~$((DEPLOY_DURATION / 60)) min)"
echo ""

# Save timing info
TOTAL_DURATION=$((BUILD_DURATION + DEPLOY_DURATION))
echo "$BUILD_DURATION" > "$PROJECT_ROOT/artifacts/build_duration"
echo "$DEPLOY_DURATION" > "$PROJECT_ROOT/artifacts/deploy_duration"
echo "$TOTAL_DURATION" > "$PROJECT_ROOT/artifacts/total_build_duration"

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ TRITON MODELS BUILT ON GPU"
echo "========================================="
echo ""
echo "GPU Instance: $GPU_INSTANCE_IP"
echo "Model Location: /opt/riva/models_conformer_triton/"
echo ""
echo "Build Time: ${BUILD_DURATION}s (~$((BUILD_DURATION / 60)) min)"
echo "Deploy Time: ${DEPLOY_DURATION}s (~$((DEPLOY_DURATION / 60)) min)"
echo "Total Time: ${TOTAL_DURATION}s (~$((TOTAL_DURATION / 60)) min)"
echo ""
echo "Next Steps:"
echo "  1. Upload to S3: ./scripts/102-upload-triton-models-to-s3.sh"
echo "  2. Then fast deploy: ./scripts/125-deploy-conformer-from-s3-cache.sh"
echo ""
