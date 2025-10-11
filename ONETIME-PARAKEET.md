  I recommend Option A: Create clean 120-series for Parakeet.

  ---
  Implementation Plan

  Phase 1: One-Time S3 Population (Run Once)

  Script: 120-prepare-parakeet-s3-artifacts.sh
  # Validates that source model exists in S3
  # Input: RIVA_MODEL_PATH from .env
  # Output: Confirms s3://dbm-cf-2-web/.../parakeet-rnnt-*.tar.gz exists

  Script: 121-build-parakeet-triton-models.sh
  # Downloads source from S3
  # Runs riva-build to convert .riva -> Triton format
  # Builds on GPU instance
  # Output: /opt/riva/models/parakeet-rnnt-1-1b-*/ directories

  Script: 122-upload-parakeet-triton-to-s3.sh
  # Uploads built Triton models to S3
  # aws s3 sync /opt/riva/models/ \
  #   s3://dbm-cf-2-web/bintarball/riva-repository/parakeet-rnnt-1.1b/v8.1/
  # Creates manifest.json with metadata

  Phase 2: Fast Deployment (Run Every Time)

  Script: 135-deploy-parakeet-from-s3-cache.sh
  #!/bin/bash
  # Fast deployment from S3 cache (7-10 minutes)

  # Step 1: Load RIVA container (shared with Conformer)
  if ! docker images | grep -q "riva-speech:2.19.0"; then
      aws s3 cp s3://.../riva-speech-2.19.0.tar.gz - | docker load
  fi

  # Step 2: Download Parakeet Triton models from S3
  aws s3 sync \
    s3://dbm-cf-2-web/bintarball/riva-repository/parakeet-rnnt-1.1b/v8.1/ \
    /tmp/parakeet-models/

  # Step 3: SCP to GPU instance
  scp -r /tmp/parakeet-models/* $GPU_INSTANCE_IP:/opt/riva/models/

  # Step 4: Start RIVA server
  ssh $GPU_INSTANCE_IP "docker run riva-speech:2.19.0 ..."

  # Step 5: Verify health
  curl http://$GPU_INSTANCE_IP:8000/v1/health

  echo "✅ Parakeet deployed in 7 minutes!"

  ---
  Updated S3 Structure After Implementation

  s3://dbm-cf-2-web/bintarball/
  │
  ├── riva-containers/                          (SHARED)
  │   └── riva-speech-2.19.0.tar.gz            19.8 GB ✅
  │
  ├── riva-models/
  │   ├── conformer/
  │   │   ├── conformer-ctc-xl-streaming-40ms.rmir     ✅
  │   │   └── Conformer-CTC-XL_spe-128_en-US...riva   ✅
  │   └── parakeet/
  │       └── parakeet-rnnt-riva-1-1b...tar.gz         ✅ 3.7 GB
  │
  └── riva-repository/                          (TRITON CACHES)
      ├── conformer-ctc-xl/v1.0/               ✅ 2-4 GB
      │   ├── conformer_encoder_large/
      │   ├── decoder/
      │   └── feature_extractor/
      └── parakeet-rnnt-1.1b/v8.1/             🆕 2-4 GB
          ├── parakeet-rnnt-...-asr-bls-ensemble/
          ├── parakeet-rnnt-...-asr-decoder/
          ├── parakeet-rnnt-...-asr-encoder/
          └── parakeet-rnnt-...-asr-feature-extractor/

  ---
  User Experience After Implementation

  Administrator (One Time):

  # Populate S3 for Conformer (already done)
  ./scripts/100-prepare-conformer-s3-artifacts.sh
  ./scripts/101-build-conformer-triton-models.sh
  ./scripts/102-upload-triton-models-to-s3.sh

  # Populate S3 for Parakeet (NEW - run once)
  ./scripts/120-prepare-parakeet-s3-artifacts.sh
  ./scripts/121-build-parakeet-triton-models.sh
  ./scripts/122-upload-parakeet-triton-to-s3.sh

  Regular User (Every Time):

  # Deploy Conformer (7 minutes)
  ./scripts/125-deploy-conformer-from-s3-cache.sh

  # OR Deploy Parakeet (7 minutes) 🆕
  ./scripts/135-deploy-parakeet-from-s3-cache.sh

  ---
  My Thoughts / Recommendations

  ✅ This Architecture is Excellent Because:

  1. Clear Separation: Build-once vs deploy-often
  2. Fast Onboarding: New users skip 30-minute builds
  3. Consistent Pattern: 100s/120s populate, 125/135 deploy
  4. Bandwidth Efficient: Share RIVA container (19.8 GB)
  5. Maintainable: Easy to add new models (140s, 150s, etc.)


