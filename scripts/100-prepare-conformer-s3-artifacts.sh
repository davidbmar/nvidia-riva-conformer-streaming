#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 100: Prepare Conformer S3 Artifacts
# ============================================================================
# Lightweight metadata staging for Conformer-CTC streaming model.
# Verifies source model exists in S3 and creates deployment manifest.
#
# Category: ONE-TIME S3 POPULATION (Build & Cache - 30-50 min total)
# This script: ~2-4 seconds
#
# What this does:
# 1. Verifies source .riva model exists in S3
# 2. Creates deployment metadata/manifest
# 3. Prepares for riva-build in next step (101)
# ============================================================================

echo "============================================"
echo "100: Prepare Conformer S3 Artifacts"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Configuration file not found: $ENV_FILE"
    echo "Please run: ./scripts/005-setup-configuration.sh"
    exit 1
fi

# Load configuration
source "$ENV_FILE"

# Required variables
REQUIRED_VARS=(
    "AWS_REGION"
    "S3_CONFORMER_SOURCE"
    "RIVA_MODEL"
    "RIVA_LANGUAGE_CODE"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required variable not set: $var"
        exit 1
    fi
done

# Configuration
S3_BUCKET="${S3_MODEL_BUCKET:-dbm-cf-2-web}"
MODEL_VERSION="v1.0"
S3_BASE="s3://${S3_BUCKET}/conformer-ctc-xl/${MODEL_VERSION}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Configuration:"
echo "  • Model: $RIVA_MODEL"
echo "  • Language: $RIVA_LANGUAGE_CODE"
echo "  • Source: $S3_CONFORMER_SOURCE"
echo "  • S3 Base: $S3_BASE"
echo ""

# ============================================================================
# Step 1: Verify source model exists in S3
# ============================================================================
echo "Step 1/3: Verifying source model in S3..."

if ! aws s3 ls "$S3_CONFORMER_SOURCE" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "❌ Source model not found in S3: $S3_CONFORMER_SOURCE"
    exit 1
fi

# Get file size
SOURCE_SIZE=$(aws s3api head-object \
    --bucket "$(echo "$S3_CONFORMER_SOURCE" | sed 's|s3://||' | cut -d'/' -f1)" \
    --key "$(echo "$S3_CONFORMER_SOURCE" | sed 's|s3://[^/]*/||')" \
    --region "$AWS_REGION" \
    --query 'ContentLength' \
    --output text)
SOURCE_SIZE_MB=$((SOURCE_SIZE / 1024 / 1024))

echo "✅ Source model verified: ${SOURCE_SIZE_MB}MB"
echo ""

# ============================================================================
# Step 2: Create deployment manifest
# ============================================================================
echo "Step 2/3: Creating deployment manifest..."

MANIFEST_FILE="/tmp/conformer-manifest-$$.json"

cat > "$MANIFEST_FILE" << EOF
{
  "artifact_id": "conformer-ctc-xl-streaming-${MODEL_VERSION}",
  "created_at": "${TIMESTAMP}",
  "model": {
    "name": "${RIVA_MODEL}",
    "version": "${MODEL_VERSION}",
    "language_code": "${RIVA_LANGUAGE_CODE}",
    "type": "speech_recognition",
    "architecture": "conformer-ctc",
    "streaming": true,
    "ms_per_timestep": 40
  },
  "source": {
    "s3_uri": "${S3_CONFORMER_SOURCE}",
    "filename": "$(basename "$S3_CONFORMER_SOURCE")",
    "size_bytes": ${SOURCE_SIZE},
    "size_mb": ${SOURCE_SIZE_MB}
  },
  "deployment": {
    "s3_bucket": "${S3_BUCKET}",
    "s3_base": "${S3_BASE}",
    "ready_for_build": true
  },
  "build_params": {
    "ms_per_timestep": 40,
    "streaming": true,
    "chunk_size": 0.16,
    "padding_size": 1.92,
    "decoder_type": "greedy"
  }
}
EOF

echo "✅ Manifest created: $MANIFEST_FILE"
echo ""

# ============================================================================
# Step 3: Upload manifest to S3
# ============================================================================
echo "Step 3/3: Uploading manifest to S3..."

aws s3 cp "$MANIFEST_FILE" "${S3_BASE}/manifest.json" \
    --content-type "application/json" \
    --region "$AWS_REGION"

echo "✅ Manifest uploaded: ${S3_BASE}/manifest.json"
echo ""

# Save state for next script
mkdir -p "$PROJECT_ROOT/artifacts"
echo "$S3_BASE" > "$PROJECT_ROOT/artifacts/s3_base_uri"
echo "$MODEL_VERSION" > "$PROJECT_ROOT/artifacts/model_version"
echo "$MANIFEST_FILE" > "$PROJECT_ROOT/artifacts/manifest_file"

# Cleanup
rm -f "$MANIFEST_FILE"

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ CONFORMER ARTIFACTS PREPARED"
echo "========================================="
echo ""
echo "S3 Location: $S3_BASE"
echo "Model: $RIVA_MODEL ($RIVA_LANGUAGE_CODE)"
echo "Source Size: ${SOURCE_SIZE_MB}MB"
echo ""
echo "Next Steps:"
echo "  1. Build Triton models: ./scripts/101-build-conformer-triton-models.sh"
echo "  2. Upload to S3: ./scripts/102-upload-triton-models-to-s3.sh"
echo "  3. Deploy from cache: ./scripts/125-deploy-conformer-from-s3-cache.sh"
echo ""
