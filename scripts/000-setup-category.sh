#!/bin/bash
set -euo pipefail

cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║                         📦 SETUP SCRIPTS (0xx)                            ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

This category contains scripts for initial setup and configuration of the
build box environment for NVIDIA Riva Conformer-CTC streaming deployment.

═══════════════════════════════════════════════════════════════════════════

SCRIPTS IN THIS CATEGORY:

  010-setup-build-box.sh
    • First-time setup of build box (Python, AWS CLI, venv, SSL certs)
    • Creates necessary directories and installs dependencies
    • Generates SSL certificates for HTTPS/WSS connections
    • Run once on fresh Ubuntu system

  020-deploy-gpu-instance.sh
    • Deploy new GPU EC2 instance (g4dn.xlarge)
    • Installs NVIDIA drivers, Docker, and CUDA
    • Configures security groups and SSH access
    • Only needed for initial deployment

  030-configure-security-groups.sh
    • Configure AWS security groups for GPU and build box
    • Opens required ports (SSH, gRPC, HTTP, metrics)
    • Updates authorized IP addresses
    • Run when IP addresses change

═══════════════════════════════════════════════════════════════════════════

TYPICAL USAGE ORDER:

  1. ./scripts/010-setup-build-box.sh        # First time setup
  2. Configure .env with your AWS credentials
  3. ./scripts/020-deploy-gpu-instance.sh    # Deploy GPU worker
  4. ./scripts/030-configure-security-groups.sh --gpu  # Configure networking

═══════════════════════════════════════════════════════════════════════════

After completing setup, proceed to DEPLOYMENT scripts (1xx) to install
and configure the Conformer-CTC streaming model.

EOF
