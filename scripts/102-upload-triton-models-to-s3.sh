#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 102: Upload Triton Models to S3
# ============================================================================
# Uploads the built Triton models from GPU to S3 for caching.
# Future deployments will download from S3 instead of rebuilding.
#
# Category: ONE-TIME S3 POPULATION (Build & Cache - 30-50 min total)
# This script: ~2-3 minutes (transfer + upload)
#
# What this does:
# 1. SCP Triton models from GPU to build box
# 2. Upload to S3 riva_repository/ directory
# 3. Create completion marker
# 4. Cleanup local temp files
# ============================================================================

echo "============================================"
echo "102: Upload Triton Models to S3"
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
    "S3_CONFORMER_TRITON_CACHE"
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
TEMP_DIR="/tmp/conformer-triton-$$"

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
fi

# Use S3 Triton cache from .env
# Extract base URI (everything before /riva_repository/)
S3_BASE="${S3_CONFORMER_TRITON_CACHE%/riva_repository/*}"
if [ "$S3_BASE" = "$S3_CONFORMER_TRITON_CACHE" ]; then
    # If riva_repository/ not found, remove trailing slash
    S3_BASE="${S3_CONFORMER_TRITON_CACHE%/}"
fi
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • S3 Destination: $S3_CONFORMER_TRITON_CACHE"
echo "  • Temp Directory: $TEMP_DIR"
echo ""

# ============================================================================
# Step 1: Verify Triton models exist on GPU
# ============================================================================
echo "Step 1/4: Verifying Triton models on GPU..."

MODEL_CHECK=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'VERIFY_SCRIPT'
set -euo pipefail

if [ ! -d "/opt/riva/models_conformer_triton" ]; then
    echo "ERROR: Model directory not found"
    exit 1
fi

MODEL_COUNT=$(find /opt/riva/models_conformer_triton -maxdepth 1 -type d ! -path /opt/riva/models_conformer_triton | wc -l)
if [ "$MODEL_COUNT" -eq 0 ]; then
    echo "ERROR: No model directories found"
    exit 1
fi

TOTAL_SIZE=$(du -sm /opt/riva/models_conformer_triton | cut -f1)
echo "OK:$MODEL_COUNT:$TOTAL_SIZE"
VERIFY_SCRIPT
)

if [[ "$MODEL_CHECK" =~ ^OK:([0-9]+):([0-9]+)$ ]]; then
    MODEL_COUNT="${BASH_REMATCH[1]}"
    TOTAL_SIZE_MB="${BASH_REMATCH[2]}"
    echo "✅ Found $MODEL_COUNT model directories (${TOTAL_SIZE_MB}MB total)"
else
    echo "❌ Verification failed: $MODEL_CHECK"
    exit 1
fi

echo ""

# ============================================================================
# Step 2: Transfer from GPU to build box
# ============================================================================
echo "Step 2/4: Transferring Triton models from GPU to build box..."
echo "This may take 1-2 minutes for ${TOTAL_SIZE_MB}MB..."
echo ""

TRANSFER_START=$(date +%s)

mkdir -p "$TEMP_DIR"

# Use scp to transfer the entire directory
if scp -r $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}:/opt/riva/models_conformer_triton/*" "$TEMP_DIR/"; then
    TRANSFER_END=$(date +%s)
    TRANSFER_DURATION=$((TRANSFER_END - TRANSFER_START))
    echo "✅ Transfer completed in ${TRANSFER_DURATION}s"
else
    echo "❌ Transfer failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Verify transfer
LOCAL_MODEL_COUNT=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | wc -l)
if [ "$LOCAL_MODEL_COUNT" -ne "$MODEL_COUNT" ]; then
    echo "❌ Model count mismatch: expected $MODEL_COUNT, got $LOCAL_MODEL_COUNT"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "✅ Verified $LOCAL_MODEL_COUNT model directories transferred"
echo ""

# ============================================================================
# Step 3: Upload to S3
# ============================================================================
echo "Step 3/4: Uploading Triton models to S3..."
echo "Destination: $S3_CONFORMER_TRITON_CACHE"
echo ""

UPLOAD_START=$(date +%s)

# Upload the entire repository directory
if aws s3 sync "$TEMP_DIR/" "$S3_CONFORMER_TRITON_CACHE" \
    --region "$AWS_REGION" \
    --delete; then
    UPLOAD_END=$(date +%s)
    UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))
    echo "✅ Upload completed in ${UPLOAD_DURATION}s"
else
    echo "❌ Upload failed"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""

# ============================================================================
# Step 4: Create completion manifest and upload
# ============================================================================
echo "Step 4/4: Creating completion manifest..."

# Get build/deploy durations if available
BUILD_DURATION=$(cat "$PROJECT_ROOT/artifacts/build_duration" 2>/dev/null || echo "unknown")
DEPLOY_DURATION=$(cat "$PROJECT_ROOT/artifacts/deploy_duration" 2>/dev/null || echo "unknown")
TOTAL_BUILD_DURATION=$(cat "$PROJECT_ROOT/artifacts/total_build_duration" 2>/dev/null || echo "unknown")

# Create completion manifest
COMPLETION_FILE="$TEMP_DIR/s3_cache_complete.json"
cat > "$COMPLETION_FILE" << EOF
{
  "cache_id": "conformer-ctc-xl-triton-cache",
  "created_at": "${TIMESTAMP}",
  "model": {
    "name": "conformer-ctc-xl-en-us-streaming",
    "type": "conformer-ctc",
    "streaming": true,
    "ms_per_timestep": 40
  },
  "triton_repository": {
    "s3_uri": "${S3_CONFORMER_TRITON_CACHE}",
    "model_count": ${MODEL_COUNT},
    "size_mb": ${TOTAL_SIZE_MB}
  },
  "build_info": {
    "build_duration_seconds": ${BUILD_DURATION},
    "deploy_duration_seconds": ${DEPLOY_DURATION},
    "total_duration_seconds": ${TOTAL_BUILD_DURATION}
  },
  "deployment": {
    "cache_ready": true,
    "fast_deploy_enabled": true,
    "next_step": "125-deploy-conformer-from-s3-cache.sh"
  }
}
EOF

# Upload completion manifest to S3 base (parent of riva_repository/)
aws s3 cp "$COMPLETION_FILE" "${S3_BASE}/s3_cache_complete.json" \
    --content-type "application/json" \
    --region "$AWS_REGION"

echo "✅ Completion manifest uploaded"
echo ""

# Cleanup
rm -rf "$TEMP_DIR"

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ S3 CACHE POPULATED"
echo "========================================="
echo ""
echo "S3 Location: $S3_CONFORMER_TRITON_CACHE"
echo "Model Count: $MODEL_COUNT directories"
echo "Total Size: ${TOTAL_SIZE_MB}MB"
echo ""
echo "Cache Stats:"
echo "  • Build Time: ${BUILD_DURATION}s (~$((BUILD_DURATION / 60)) min)"
echo "  • Deploy Time: ${DEPLOY_DURATION}s (~$((DEPLOY_DURATION / 60)) min)"
echo "  • Total Build: ${TOTAL_BUILD_DURATION}s (~$((TOTAL_BUILD_DURATION / 60)) min)"
echo "  • Transfer Time: ${TRANSFER_DURATION}s"
echo "  • Upload Time: ${UPLOAD_DURATION}s"
echo ""
echo "✅ Future deployments can now use fast S3 cache (2-3 min)!"
echo ""
echo "Next Steps:"
echo "  • Fast deploy: ./scripts/125-deploy-conformer-from-s3-cache.sh"
echo "  • This will download from S3 and start RIVA in 2-3 minutes"
echo ""
