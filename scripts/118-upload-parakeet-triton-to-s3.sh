#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 118: Upload Parakeet Triton Models to S3
# ============================================================================
# Uploads the built Triton models from GPU to S3 for caching.
# Future deployments will download from S3 instead of rebuilding.
#
# Category: ONE-TIME S3 POPULATION (Build & Cache - 30-50 min total)
# This script: ~2-5 minutes (transfer + upload)
#
# What this does:
# 1. SCP Triton models from GPU to build box
# 2. Upload to S3 riva_repository/ directory
# 3. Create completion marker and manifest
# 4. Cleanup local temp files
# ============================================================================

echo "============================================"
echo "118: Upload Parakeet Triton Models to S3"
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
TEMP_DIR="/tmp/parakeet-triton-$$"
S3_BUCKET="${S3_MODEL_BUCKET:-dbm-cf-2-web}"
MODEL_VERSION="v8.1"
S3_TRITON_CACHE="s3://${S3_BUCKET}/bintarball/riva-repository/parakeet-rnnt-1.1b/${MODEL_VERSION}/"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
fi

# Load model repo dir from previous step
if [ ! -f "$PROJECT_ROOT/artifacts/parakeet_model_repo_dir" ]; then
    echo "❌ Model repository directory not found. Run 117-build-parakeet-triton-models.sh first."
    exit 1
fi

MODEL_REPO_DIR=$(cat "$PROJECT_ROOT/artifacts/parakeet_model_repo_dir")

# Load S3 base from artifact
if [ ! -f "$PROJECT_ROOT/artifacts/s3_parakeet_base_uri" ]; then
    echo "❌ S3 base URI not found. Run 116-prepare-parakeet-s3-artifacts.sh first."
    exit 1
fi

S3_BASE=$(cat "$PROJECT_ROOT/artifacts/s3_parakeet_base_uri")

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • Model Repository: $MODEL_REPO_DIR"
echo "  • S3 Destination: $S3_TRITON_CACHE"
echo "  • Temp Directory: $TEMP_DIR"
echo ""

# ============================================================================
# Step 1: Fix permissions and download models from GPU to build box
# ============================================================================
echo "Step 1/4: Fixing permissions and downloading Triton models from GPU..."

DOWNLOAD_START=$(date +%s)

# Fix permissions on GPU (Docker creates files as root)
echo "Changing ownership to ubuntu:ubuntu..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "sudo chown -R ubuntu:ubuntu ${MODEL_REPO_DIR}"

mkdir -p "$TEMP_DIR"

echo "Copying from GPU: ${GPU_INSTANCE_IP}:${MODEL_REPO_DIR}/* → $TEMP_DIR/"

if scp -r $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}:${MODEL_REPO_DIR}/*" "$TEMP_DIR/"; then
    DOWNLOAD_END=$(date +%s)
    DOWNLOAD_DURATION=$((DOWNLOAD_END - DOWNLOAD_START))

    MODEL_COUNT=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | wc -l)
    TOTAL_SIZE=$(du -sm "$TEMP_DIR" | cut -f1)

    echo "✅ Downloaded $MODEL_COUNT model directories (${TOTAL_SIZE}MB) in ${DOWNLOAD_DURATION}s"
else
    echo "❌ Failed to download models from GPU"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""

# ============================================================================
# Step 2: Verify model structure
# ============================================================================
echo "Step 2/4: Verifying model structure..."

if [ $MODEL_COUNT -eq 0 ]; then
    echo "❌ No model directories found"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Model directories:"
find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | while read dir; do
    MODEL_NAME=$(basename "$dir")
    MODEL_SIZE=$(du -sh "$dir" | cut -f1)
    echo "  • $MODEL_NAME ($MODEL_SIZE)"
done

echo "✅ Model structure verified"
echo ""

# ============================================================================
# Step 3: Upload to S3
# ============================================================================
echo "Step 3/4: Uploading Triton models to S3..."
echo "Destination: $S3_TRITON_CACHE"
echo ""

UPLOAD_START=$(date +%s)

if aws s3 sync "$TEMP_DIR/" "$S3_TRITON_CACHE" \
    --region "$AWS_REGION" \
    --exclude "*.log" \
    --exclude "*.tmp" \
    --delete; then

    UPLOAD_END=$(date +%s)
    UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))

    echo "✅ Upload completed in ${UPLOAD_DURATION}s"
else
    echo "❌ Upload to S3 failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""

# ============================================================================
# Step 4: Create completion marker and manifest
# ============================================================================
echo "Step 4/4: Creating completion marker and manifest..."

# Create completion marker
COMPLETION_FILE="/tmp/parakeet-triton-complete-$$.json"
cat > "$COMPLETION_FILE" << EOF
{
  "completion_timestamp": "${TIMESTAMP}",
  "model_version": "${MODEL_VERSION}",
  "model_count": ${MODEL_COUNT},
  "total_size_mb": ${TOTAL_SIZE},
  "s3_uri": "${S3_TRITON_CACHE}",
  "upload_duration_seconds": ${UPLOAD_DURATION},
  "models": [
EOF

# Add model list
FIRST=true
find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | while read dir; do
    MODEL_NAME=$(basename "$dir")
    MODEL_SIZE=$(du -sm "$dir" | cut -f1)

    if [ "$FIRST" = true ]; then
        echo "    {\"name\": \"$MODEL_NAME\", \"size_mb\": $MODEL_SIZE}" >> "$COMPLETION_FILE"
        FIRST=false
    else
        echo "    ,{\"name\": \"$MODEL_NAME\", \"size_mb\": $MODEL_SIZE}" >> "$COMPLETION_FILE"
    fi
done

cat >> "$COMPLETION_FILE" << EOF
  ],
  "ready_for_deployment": true
}
EOF

# Upload completion marker
aws s3 cp "$COMPLETION_FILE" "${S3_BASE}/triton_cache_complete.json" \
    --content-type "application/json" \
    --region "$AWS_REGION"

echo "✅ Completion marker uploaded: ${S3_BASE}/triton_cache_complete.json"

# Save S3 Triton cache location for future scripts
mkdir -p "$PROJECT_ROOT/artifacts"
echo "$S3_TRITON_CACHE" > "$PROJECT_ROOT/artifacts/s3_parakeet_triton_cache"

# Cleanup
rm -rf "$TEMP_DIR"
rm -f "$COMPLETION_FILE"

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ PARAKEET TRITON MODELS UPLOADED"
echo "========================================="
echo ""
echo "S3 Location: $S3_TRITON_CACHE"
echo "Model Count: $MODEL_COUNT"
echo "Total Size: ${TOTAL_SIZE}MB"
echo "Upload Duration: ${UPLOAD_DURATION}s"
echo ""
echo "Add to .env file:"
echo "S3_PARAKEET_TRITON_CACHE=$S3_TRITON_CACHE"
echo ""
echo "Next Steps:"
echo "  1. Add S3_PARAKEET_TRITON_CACHE to .env"
echo "  2. Fast deployment: ./scripts/135-deploy-parakeet-from-s3-cache.sh"
echo ""
