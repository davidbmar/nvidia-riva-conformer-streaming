# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NVIDIA Riva Conformer-CTC Streaming ASR** - Production-ready real-time speech transcription system using NVIDIA Riva 2.19 with Conformer-CTC-XL streaming model.

### Architecture

The system consists of three components:
1. **GPU Worker** (AWS g4dn.xlarge) - Runs NVIDIA Riva 2.19 with Conformer-CTC model via Docker
2. **Build Box** - Runs WebSocket bridge and HTTPS demo server
3. **Browser Client** - WebSocket client for real-time streaming audio

```
Browser (mic) --WSS/HTTPS--> Build Box (WebSocket bridge) --gRPC--> GPU Worker (RIVA)
              :8443/:8444                                          :50051
```

## Key Commands

### Deployment Scripts (Run from Build Box)
```bash
# Initial setup
./scripts/010-setup-build-box.sh        # Install Python, AWS CLI, SSL certs, venv

# Deploy Conformer-CTC model to GPU
./scripts/100-deploy-conformer-streaming.sh

# Daily operations
./scripts/200-shutdown-gpu.sh           # Stop GPU to save costs (~$0.526/hour)
./scripts/210-startup-restore.sh        # Start GPU and restore everything (5-10min)
```

### Service Management
```bash
# WebSocket bridge (runs on build box as systemd service)
sudo systemctl status riva-websocket-bridge
sudo systemctl restart riva-websocket-bridge
sudo journalctl -u riva-websocket-bridge -f

# Check RIVA health (on GPU worker)
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@$GPU_INSTANCE_IP 'curl http://localhost:8000/v2/health/ready'
```

### Development
```bash
# Run WebSocket bridge manually (for development)
cd src/asr
python3 -m riva_websocket_bridge

# Test transcription
# Open: https://<BUILD_BOX_IP>:8444/demo.html
```

## Critical Configuration

### Conformer-CTC vs Parakeet RNNT
- ✅ **Use Conformer-CTC-XL** - Officially supported for streaming in RIVA 2.19
- ❌ **DO NOT use Parakeet RNNT** - Only works in NIM, not classic RIVA 2.19

### Required Streaming Parameters
When deploying Conformer-CTC, these parameters are **REQUIRED**:
```bash
--ms_per_timestep=40      # NOT 80! Conformer outputs at 40ms
--chunk_size=0.16         # 160ms chunks
--padding_size=1.92       # 1920ms padding
--streaming=true
```

**Why 40ms not 80ms?** Using 80ms causes "Frames expected 51 got 101" error because frame count doubles when timestep is wrong.

## Architecture Details

### Python Code Structure
- `src/asr/riva_client.py` - Riva gRPC client wrapper with config from .env
- `src/asr/riva_websocket_bridge.py` - WebSocket server that bridges browser to Riva gRPC
- `scripts/riva-common-functions.sh` - Shared bash utilities (logging, env validation, SSH helpers)

### WebSocket Bridge
- Loads config from `.env` file
- Uses existing SSL certs at `/opt/riva/certs/`
- Manages async connection between WebSocket (browser) and gRPC (Riva)
- Runs as systemd service `riva-websocket-bridge`

### Environment Variables
All configuration is in `.env` file (copied from `.env.example`):
- `GPU_INSTANCE_IP`, `GPU_INSTANCE_ID` - Auto-updated by scripts
- `NGC_API_KEY` - Required for model downloads from NVIDIA
- `RIVA_HOST`, `RIVA_PORT` - GPU worker endpoint
- `APP_PORT=8443` - WebSocket bridge port
- `DEMO_PORT=8444` - HTTPS demo UI port

### Deployment Flow
1. `100-deploy-conformer-streaming.sh`:
   - Downloads pre-built RMIR from S3 (or builds if missing)
   - Deploys to `/opt/riva/models_conformer_ctc_streaming` on GPU
   - Starts Riva Docker container with correct model
   - Verifies health and checks for frame errors

2. `210-startup-restore.sh`:
   - Starts stopped GPU instance
   - Detects IP changes and updates `.env`
   - Verifies Riva is running
   - Restarts WebSocket bridge with updated config

### Cost Optimization Pattern
The shutdown/startup scripts enable overnight cost savings:
- `200-shutdown-gpu.sh` - Stop GPU instance (preserves EBS)
- `210-startup-restore.sh` - Restore full working state in one command

## Common Patterns

### SSH to GPU Worker
All scripts use:
```bash
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dbm-sep23-2025.pem}"
ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" '<commands>'
```

### Script Structure
Deployment scripts follow this pattern:
1. Source `riva-common-functions.sh`
2. Load environment with `load_environment`
3. Use logging functions: `log_info`, `log_success`, `log_error`
4. Execute remote commands via SSH heredoc

### Environment Updates
Scripts auto-update `.env` using:
```bash
update_env_var "GPU_INSTANCE_IP" "$NEW_IP"
```

## Troubleshooting

### Frame Count Errors
If you see "frames expected X got Y" errors:
- Check `ms_per_timestep` is set to **40** (not 80)
- Verify model is Conformer-CTC (not Parakeet)
- Check with: `docker logs riva-server 2>&1 | grep "frames expected"`

### IP Changes After GPU Restart
`210-startup-restore.sh` automatically:
1. Detects IP changes
2. Updates `.env` files in multiple locations
3. Restarts WebSocket bridge with new config

### WebSocket Bridge Not Connecting
1. Check service: `sudo systemctl status riva-websocket-bridge`
2. Verify GPU IP in `.env` matches actual GPU instance
3. Check logs: `sudo journalctl -u riva-websocket-bridge -f`
4. Verify Riva health on GPU worker

## Important Notes

- All scripts expect to run from repository root
- GPU instance must have NVIDIA drivers and Docker with GPU support
- Pre-built RMIR in S3 saves ~2 minutes vs building from source
- WebSocket bridge and HTTPS demo both use self-signed certs at `/opt/riva/certs/`
- Systemd services auto-start on build box reboot
