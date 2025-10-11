#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 117: Build Parakeet Triton Models
# ============================================================================
# Runs riva-build and riva-deploy on GPU to create Triton models.
# This is the heavy lifting step that takes 20-30 minutes.
#
# Category: ONE-TIME S3 POPULATION (Build & Cache - 30-50 min total)
# This script: ~20-30 minutes (GPU work)
#
# What this does:
# 1. SSH to GPU instance
# 2. Download source .tar.gz model from S3
# 3. Extract and find .riva files
# 4. Run riva-build: .riva → .riva optimized (15-20 min)
# 5. Run riva-deploy: .riva → Triton models (5-8 min)
# 6. Leave Triton models on GPU for upload step (118)
# ============================================================================

echo "============================================"
echo "117: Build Parakeet Triton Models"
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
    "S3_PARAKEET_SOURCE"
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
BUILD_TIMEOUT=2400  # 40 minutes
MODEL_REPO_DIR="/opt/riva/models_parakeet"

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
fi

# Load S3 base from previous step
if [ ! -f "$PROJECT_ROOT/artifacts/s3_parakeet_base_uri" ]; then
    echo "❌ S3 base URI not found. Run 116-prepare-parakeet-s3-artifacts.sh first."
    exit 1
fi

S3_BASE=$(cat "$PROJECT_ROOT/artifacts/s3_parakeet_base_uri")

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • RIVA Version: $RIVA_VERSION"
echo "  • Source Model: $S3_PARAKEET_SOURCE"
echo "  • Build Timeout: ${BUILD_TIMEOUT}s (~40 min)"
echo "  • Model Repository: $MODEL_REPO_DIR"
echo ""

# ============================================================================
# Step 1: Prepare GPU worker
# ============================================================================
echo "Step 1/5: Preparing GPU worker..."

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'PREP_SCRIPT'
set -euo pipefail

echo "Creating build directories..."
mkdir -p /tmp/riva-build/{input,output}
mkdir -p /opt/riva/models_parakeet

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
# Step 2: Download source model on build box and transfer to GPU
# ============================================================================
echo "Step 2/5: Downloading source model and transferring to GPU..."

# Download on build box (has S3 access)
LOCAL_TEMP="/tmp/parakeet-source-$$"
mkdir -p "$LOCAL_TEMP"

echo "Downloading from S3 to build box: $S3_PARAKEET_SOURCE"
if aws s3 cp "$S3_PARAKEET_SOURCE" "$LOCAL_TEMP/" --region "$AWS_REGION"; then
    ARCHIVE_FILE=$(ls -1 "$LOCAL_TEMP"/*.tar.gz 2>/dev/null | head -1)
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_FILE" | cut -f1)
    echo "✅ Downloaded: $(basename "$ARCHIVE_FILE") ($ARCHIVE_SIZE)"
else
    echo "❌ Download from S3 failed"
    rm -rf "$LOCAL_TEMP"
    exit 1
fi

# Transfer to GPU
echo "Transferring $(basename "$ARCHIVE_FILE") to GPU..."
if scp $SSH_OPTS "$ARCHIVE_FILE" "${REMOTE_USER}@${GPU_INSTANCE_IP}:/tmp/riva-build/input/"; then
    echo "✅ Transfer completed"
else
    echo "❌ Transfer to GPU failed"
    rm -rf "$LOCAL_TEMP"
    exit 1
fi

# Extract on GPU
echo "Extracting on GPU..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'EXTRACT_SCRIPT'
set -euo pipefail
cd /tmp/riva-build/input
ARCHIVE_FILE=$(ls -1 *.tar.gz 2>/dev/null | head -1)
if [ -n "$ARCHIVE_FILE" ]; then
    echo "Extracting $ARCHIVE_FILE..."
    tar -xzf "$ARCHIVE_FILE"
    RIVA_FILES=$(find . -name "*.riva" -type f | wc -l)
    echo "✅ Extracted $RIVA_FILES .riva file(s)"
    find . -name "*.riva" -type f -exec ls -lh {} \;
else
    echo "❌ No .tar.gz file found"
    exit 1
fi
EXTRACT_SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Failed to extract source model"
    rm -rf "$LOCAL_TEMP"
    exit 1
fi

# Cleanup
rm -rf "$LOCAL_TEMP"

echo "✅ Source model downloaded and extracted"
echo ""

# ============================================================================
# Step 3: Run riva-build (15-20 min)
# ============================================================================
echo "Step 3/5: Running riva-build (this will take ~15-20 minutes)..."
echo "Building Parakeet RNNT with greedy decoder..."
echo ""

BUILD_START=$(date +%s)

# Create build script on GPU
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "cat > /tmp/run-riva-build.sh" << 'BUILD_SCRIPT_CONTENT'
#!/bin/bash
set -euo pipefail

cd /tmp/riva-build

# Find source .riva file
SOURCE_FILE=$(find input -name "*deployable*.riva" -type f | head -1)
if [ -z "$SOURCE_FILE" ]; then
    SOURCE_FILE=$(find input -name "*.riva" -type f | head -1)
fi

if [ -z "$SOURCE_FILE" ]; then
    echo "❌ No .riva file found in input/"
    exit 1
fi

MODEL_BASENAME=$(basename "$SOURCE_FILE" .riva)

echo "Source model: $SOURCE_FILE"
echo "Output name: ${MODEL_BASENAME}"
echo "Starting riva-build at $(date)..."
echo ""

# Login to NGC (NGC_API_KEY and RIVA_VERSION will be passed as env vars)
echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin >/dev/null 2>&1

# Run riva-build
echo "Running docker riva-build command..."
docker run --rm --gpus all \
    -v /tmp/riva-build:/workspace \
    -e NGC_API_KEY="${NGC_API_KEY}" \
    --workdir /workspace \
    nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION} \
    riva-build speech_recognition \
        "/workspace/output/${MODEL_BASENAME}.riva" \
        "/workspace/${SOURCE_FILE}" \
        --name="${MODEL_BASENAME}" \
        --language_code=en-US \
        --decoder_type=greedy

BUILD_EXIT_CODE=$?
echo "riva-build completed with exit code: $BUILD_EXIT_CODE at $(date)"

if [ $BUILD_EXIT_CODE -eq 0 ] && [ -f "output/${MODEL_BASENAME}.riva" ]; then
    echo "✅ riva-build completed successfully"
    echo "Output file: output/${MODEL_BASENAME}.riva"
    echo "Output size: $(du -h "output/${MODEL_BASENAME}.riva" | cut -f1)"
    exit 0
else
    echo "❌ riva-build failed"
    exit 1
fi
BUILD_SCRIPT_CONTENT

# Make script executable and run it
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "chmod +x /tmp/run-riva-build.sh && NGC_API_KEY='${NGC_API_KEY}' RIVA_VERSION='${RIVA_VERSION}' /tmp/run-riva-build.sh"

BUILD_EXIT=$?
BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

if [ $BUILD_EXIT -ne 0 ]; then
    echo "❌ riva-build failed after ${BUILD_DURATION}s"
    exit 1
fi

echo "✅ riva-build completed in ${BUILD_DURATION}s"
echo ""

# ============================================================================
# Step 4: Run riva-deploy (5-8 min)
# ============================================================================
echo "Step 4/5: Running riva-deploy (this will take ~5-8 minutes)..."
echo ""

DEPLOY_START=$(date +%s)

# Create deploy script on GPU
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "cat > /tmp/run-riva-deploy.sh" << 'DEPLOY_SCRIPT_CONTENT'
#!/bin/bash
set -euo pipefail

cd /tmp/riva-build

# Find built .riva file
BUILT_FILE=$(find output -name "*.riva" -type f | head -1)
if [ -z "$BUILT_FILE" ]; then
    echo "❌ No built .riva file found in output/"
    exit 1
fi

echo "Built model: $BUILT_FILE"
echo "Target repository: $MODEL_REPO_DIR"
echo "Starting riva-deploy at $(date)..."
echo ""

# Clear existing models
rm -rf ${MODEL_REPO_DIR:?}/*
mkdir -p "$MODEL_REPO_DIR"

# Run riva-deploy
echo "Running docker riva-deploy command..."
docker run --rm --gpus all \
    -v /tmp/riva-build:/workspace \
    -v ${MODEL_REPO_DIR}:${MODEL_REPO_DIR} \
    -e NGC_API_KEY="${NGC_API_KEY}" \
    --workdir /workspace \
    nvcr.io/nvidia/riva/riva-speech:${RIVA_VERSION} \
    riva-deploy \
        "/workspace/${BUILT_FILE}" \
        "${MODEL_REPO_DIR}"

DEPLOY_EXIT_CODE=$?
echo "riva-deploy completed with exit code: $DEPLOY_EXIT_CODE at $(date)"

if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
    echo "✅ riva-deploy completed successfully"
    echo "Model repository contents:"
    ls -la "$MODEL_REPO_DIR/"

    MODEL_COUNT=$(find "$MODEL_REPO_DIR" -maxdepth 1 -type d ! -path "$MODEL_REPO_DIR" | wc -l)
    echo "✅ Created $MODEL_COUNT model directories"
    exit 0
else
    echo "❌ riva-deploy failed"
    exit 1
fi
DEPLOY_SCRIPT_CONTENT

# Make script executable and run it
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "chmod +x /tmp/run-riva-deploy.sh && NGC_API_KEY='${NGC_API_KEY}' RIVA_VERSION='${RIVA_VERSION}' MODEL_REPO_DIR='${MODEL_REPO_DIR}' /tmp/run-riva-deploy.sh"

DEPLOY_EXIT=$?
DEPLOY_END=$(date +%s)
DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))

if [ $DEPLOY_EXIT -ne 0 ]; then
    echo "❌ riva-deploy failed after ${DEPLOY_DURATION}s"
    exit 1
fi

echo "✅ riva-deploy completed in ${DEPLOY_DURATION}s"
echo ""

# ============================================================================
# Step 5: Verify Triton models
# ============================================================================
echo "Step 5/5: Verifying Triton model structure..."

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "MODEL_REPO_DIR='${MODEL_REPO_DIR}'" << 'VERIFY_SCRIPT'
set -euo pipefail

MODEL_COUNT=$(find "$MODEL_REPO_DIR" -maxdepth 1 -type d ! -path "$MODEL_REPO_DIR" | wc -l)

if [ $MODEL_COUNT -eq 0 ]; then
    echo "❌ No model directories found"
    exit 1
fi

echo "Model repository structure:"
find "$MODEL_REPO_DIR" -maxdepth 2 -type d | head -20

echo ""
echo "✅ Verified $MODEL_COUNT model directories"
VERIFY_SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Model verification failed"
    exit 1
fi

# Save model location for next script
mkdir -p "$PROJECT_ROOT/artifacts"
echo "$MODEL_REPO_DIR" > "$PROJECT_ROOT/artifacts/parakeet_model_repo_dir"

# ============================================================================
# Summary
# ============================================================================
TOTAL_END=$(date +%s)
TOTAL_DURATION=$(($TOTAL_END - $BUILD_START))

echo ""
echo "========================================="
echo "✅ PARAKEET TRITON MODELS BUILT"
echo "========================================="
echo ""
echo "Build Duration: ${BUILD_DURATION}s (~$((BUILD_DURATION / 60)) min)"
echo "Deploy Duration: ${DEPLOY_DURATION}s (~$((DEPLOY_DURATION / 60)) min)"
echo "Total Duration: ${TOTAL_DURATION}s (~$((TOTAL_DURATION / 60)) min)"
echo ""
echo "Models Location: $MODEL_REPO_DIR (on GPU)"
echo ""
echo "Next Steps:"
echo "  1. Upload to S3: ./scripts/118-upload-parakeet-triton-to-s3.sh"
echo "  2. Deploy from cache: ./scripts/135-deploy-parakeet-from-s3-cache.sh"
echo ""
