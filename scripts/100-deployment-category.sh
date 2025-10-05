#!/bin/bash
set -euo pipefail

cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║                      🚀 DEPLOYMENT SCRIPTS (1xx)                          ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

This category contains scripts for deploying the Conformer-CTC streaming
ASR model to the GPU worker instance.

═══════════════════════════════════════════════════════════════════════════

SCRIPTS IN THIS CATEGORY:

  110-deploy-conformer-streaming.sh
    • Deploy Conformer-CTC-XL streaming model to GPU worker
    • Uses pre-built RMIR from S3 (or builds if not available)
    • Configures streaming parameters (40ms timestep - CRITICAL)
    • Starts RIVA server with correct model loaded
    • Takes 5-10 minutes (or 30+ if building from scratch)

═══════════════════════════════════════════════════════════════════════════

CRITICAL PARAMETERS:

  The Conformer-CTC model MUST be built with:
    --ms_per_timestep=40   (NOT 80!)
    --chunk_size=0.16
    --padding_size=1.92
    --streaming=true

  Using wrong parameters causes "Frames expected 51 got 101" errors.

═══════════════════════════════════════════════════════════════════════════

TYPICAL USAGE:

  ./scripts/110-deploy-conformer-streaming.sh

  This will:
    1. Check for pre-built RMIR in S3
    2. Download or build the model
    3. Deploy to GPU worker at /opt/riva/models_conformer_ctc_streaming/
    4. Start RIVA server on ports 50051 (gRPC) and 8000 (HTTP)
    5. Verify model health

═══════════════════════════════════════════════════════════════════════════

After deployment, proceed to OPERATIONS scripts (2xx) for daily
shutdown/startup workflows.

EOF
