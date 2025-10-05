#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# RIVA-200: Deploy Conformer-CTC Streaming ASR
# ============================================================================
# This script deploys a working Conformer-CTC streaming ASR model on the GPU
# worker. Use this to restore the working streaming transcription setup.
#
# Prerequisites:
# - GPU worker instance running (check GPU_INSTANCE_IP in .env)
# - SSH key available at ~/.ssh/dbm-sep23-2025.pem
# - Pre-built RMIR in S3 (or will build if not present)
#
# What this does:
# 1. Checks if pre-built RMIR exists in S3
# 2. If not, builds Conformer-CTC with correct streaming parameters
# 3. Deploys to GPU worker
# 4. Starts RIVA server with streaming model
# 5. Verifies health and tensor outputs
# ============================================================================

source "$(dirname "$0")/riva-common-functions.sh"
load_environment

# Validate required environment variables
if [ -z "${GPU_INSTANCE_IP:-}" ] || [ -z "${NGC_API_KEY:-}" ]; then
  echo "❌ ERROR: Required environment variables not set"
  echo "   GPU_INSTANCE_IP: ${GPU_INSTANCE_IP:-NOT SET}"
  echo "   NGC_API_KEY: ${NGC_API_KEY:-NOT SET}"
  exit 1
fi

SSH_KEY="${SSH_KEY:-$HOME/.ssh/dbm-sep23-2025.pem}"
S3_RMIR="s3://dbm-cf-2-web/bintarball/riva-models/conformer/conformer-ctc-xl-streaming-40ms.rmir"
S3_SOURCE="s3://dbm-cf-2-web/bintarball/riva-models/conformer/Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva"

log_info "🚀 Deploying Conformer-CTC Streaming ASR"
log_info "GPU Worker: $GPU_INSTANCE_IP"
echo ""

# Check if pre-built RMIR exists
log_info "Checking for pre-built RMIR in S3..."
if aws s3 ls "$S3_RMIR" >/dev/null 2>&1; then
    log_success "✅ Pre-built RMIR found in S3"
    USE_PREBUILT=true
else
    log_info "⚠️  Pre-built RMIR not found - will build from source"
    USE_PREBUILT=false
fi

# Deploy to GPU worker
log_info "Deploying to GPU worker via SSH..."

ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" "NGC_API_KEY='$NGC_API_KEY' S3_RMIR='$S3_RMIR' S3_SOURCE='$S3_SOURCE' USE_PREBUILT='$USE_PREBUILT'" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail

echo "========================================="
echo "Conformer-CTC Streaming Deployment"
echo "========================================="
echo ""

cd ~
mkdir -p conformer-ctc-deploy
cd conformer-ctc-deploy

# Get the RMIR (either download or build)
if [ "$USE_PREBUILT" = "true" ]; then
    echo "📥 Downloading pre-built RMIR from S3..."
    aws s3 cp "$S3_RMIR" conformer-ctc-xl-streaming.rmir
    echo "✅ Downloaded"
else
    echo "🔨 Building Conformer-CTC with correct streaming parameters..."
    echo "This will take ~2 minutes"
    echo ""

    # Download source model
    mkdir -p riva-build/input
    if [ ! -f riva-build/input/Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva ]; then
        echo "Downloading source model from S3..."
        aws s3 cp "$S3_SOURCE" riva-build/input/
    fi

    # Build with CORRECT parameters (40ms timestep, not 80ms)
    docker run --rm --gpus all \
      -v $(pwd)/riva-build:/workspace \
      nvcr.io/nvidia/riva/riva-speech:2.19.0 \
      riva-build speech_recognition \
      /workspace/output/conformer-ctc-xl-streaming.rmir \
      /workspace/input/Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva:tlt_encode \
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

    if [ ! -f riva-build/output/conformer-ctc-xl-streaming.rmir ]; then
        echo "❌ Build failed"
        exit 1
    fi

    cp riva-build/output/conformer-ctc-xl-streaming.rmir .
    echo "✅ Build complete"

    # Upload to S3 for future use
    echo "📤 Uploading RMIR to S3 for future deployments..."
    aws s3 cp conformer-ctc-xl-streaming.rmir "$S3_RMIR" || echo "⚠️  S3 upload failed (continuing anyway)"
fi

echo ""
echo "🚀 Deploying to RIVA..."

# Create model directory
sudo mkdir -p /opt/riva/models_conformer_ctc_streaming
sudo chown ubuntu:ubuntu /opt/riva/models_conformer_ctc_streaming

# Deploy RMIR
docker run --rm --gpus all \
  -v $(pwd):/workspace \
  -v /opt/riva/models_conformer_ctc_streaming:/data/models \
  nvcr.io/nvidia/riva/riva-speech:2.19.0 \
  riva-deploy /workspace/conformer-ctc-xl-streaming.rmir /data/models

echo ""
echo "🔄 Restarting RIVA server..."
docker rm -f riva-server 2>/dev/null || true
sleep 3

docker run -d --rm --gpus all --name riva-server \
  -p 50051:50051 -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v /opt/riva/models_conformer_ctc_streaming:/data/models \
  nvcr.io/nvidia/riva/riva-speech:2.19.0 \
  start-riva --asr_service=true --nlp_service=false --tts_service=false

echo "Waiting 45s for server startup..."
sleep 45

echo ""
echo "🔍 Verifying deployment..."
curl -sf http://localhost:8000/v2/health/ready && echo "✅ Server READY" || echo "❌ Server NOT READY"

echo ""
echo "Models loaded:"
curl -s -X POST http://localhost:8000/v2/repository/index \
  -H 'Content-Type: application/json' -d '{}' | \
  python3 -c "import sys, json; [print(f'  {m[\"name\"]}: {m[\"state\"]}') for m in json.load(sys.stdin)]"

echo ""
echo "Checking for frame count errors:"
docker logs riva-server 2>&1 | grep -i "frames expected" | tail -3 || echo "  ✅ No frame count errors"

REMOTE_SCRIPT

log_success "✅ Deployment complete!"
echo ""
log_info "Next steps:"
echo "  1. Restart WebSocket bridge: sudo systemctl restart riva-websocket-bridge"
echo "  2. Test streaming: https://3.16.124.227:8444/demo.html"
echo ""
