#!/bin/bash
set -euo pipefail

cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║                   🔧 MANAGEMENT & OPERATIONS (7xx)                        ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

This category contains advanced GPU instance management scripts copied from
the legacy repository. These provide fine-grained control over GPU instance
lifecycle for users who need more than the simplified operations scripts.

═══════════════════════════════════════════════════════════════════════════

SCRIPTS IN THIS CATEGORY:

  710-gpu-instance-manager.sh  🌟 ORCHESTRATOR
    • Interactive menu for all GPU operations
    • Auto-mode for smart action selection
    • Supports: deploy, start, stop, restart, status, destroy
    • Cost tracking and reminders
    • Command-line flags: --auto, --deploy, --start, --stop, etc.

  720-deploy-gpu-instance.sh
    • Low-level GPU instance deployment
    • Creates EC2 instance with Deep Learning AMI
    • Configures user data, security groups, SSH keys
    • More control than simplified deployment

  730-start-gpu-instance.sh
    • Start stopped GPU instance
    • Comprehensive health checks (SSH, Docker, GPU, RIVA)
    • Updates configuration files
    • Exponential backoff for reliability

  740-stop-gpu-instance.sh
    • Stop running GPU instance
    • Graceful service shutdown
    • Container log backup
    • Cost summary reporting

  750-status-gpu-instance.sh
    • Comprehensive instance status
    • Multiple output formats (--json, --brief, --verbose)
    • Live health checks
    • Cost analysis

═══════════════════════════════════════════════════════════════════════════

WHEN TO USE THESE:

  Use Operations (2xx) scripts for:
    ✓ Daily shutdown/startup workflow
    ✓ Simple, one-command operations
    ✓ Recommended for most users

  Use Management (7xx) scripts for:
    ✓ Advanced control and options
    ✓ Troubleshooting and diagnostics
    ✓ Multiple instances
    ✓ CI/CD automation
    ✓ Custom workflows

═══════════════════════════════════════════════════════════════════════════

EXAMPLE USAGE:

  # Interactive menu
  ./scripts/710-gpu-instance-manager.sh

  # Auto mode (smart action selection)
  ./scripts/710-gpu-instance-manager.sh --auto

  # Direct commands
  ./scripts/710-gpu-instance-manager.sh --stop --yes
  ./scripts/710-gpu-instance-manager.sh --start

  # Status checks
  ./scripts/750-status-gpu-instance.sh --verbose
  ./scripts/750-status-gpu-instance.sh --json

  # Individual operations
  ./scripts/730-start-gpu-instance.sh --instance-id i-xxx
  ./scripts/740-stop-gpu-instance.sh --no-save-logs

═══════════════════════════════════════════════════════════════════════════

NOTE: These scripts source riva-099-common.sh which provides shared
functions. They have more dependencies than the simplified operations scripts.

EOF
