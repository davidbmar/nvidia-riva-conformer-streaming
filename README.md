# NVIDIA Riva Conformer-CTC Streaming ASR

**Production-ready real-time speech transcription using NVIDIA Riva 2.19 with Conformer-CTC streaming model.**

## What This Delivers

- ✅ **Real-time browser streaming** - Speak into your microphone, see instant transcriptions
- ✅ **Conformer-CTC-XL model** - State-of-the-art accuracy with 40ms timestep streaming
- ✅ **GPU-accelerated** - NVIDIA Riva on AWS g4dn.xlarge (Tesla T4)
- ✅ **WebSocket bridge** - Secure WSS connection from browser to Riva gRPC
- ✅ **HTTPS demo UI** - Professional browser interface with SSL
- ✅ **Production ready** - Systemd services, health checks, auto-restart
- ✅ **Cost optimized** - Start/stop GPU scripts for overnight shutdown

## Architecture

```
┌──────────────┐    WSS/HTTPS     ┌──────────────┐    gRPC      ┌──────────────┐
│   Browser    │◄────────────────►│  Build Box   │◄────────────►│  GPU Worker  │
│  Microphone  │  Audio Chunks    │  WebSocket   │  Streaming   │  RIVA 2.19   │
│              │                  │  Bridge      │              │  Conformer   │
└──────────────┘                  │  :8443       │              │  CTC-XL      │
                                  │  :8444 Demo  │              │  :50051      │
                                  └──────────────┘              └──────────────┘
```

## Quick Start (From Scratch)

### Prerequisites

- **Ubuntu 20.04/22.04** build box (where you run these scripts)
- **AWS Account** with EC2 permissions
- **NGC API Key** - Free from https://ngc.nvidia.com
- **10-15 minutes** for complete deployment

### Step 1: Clone and Configure

```bash
git clone https://github.com/YOUR_USERNAME/nvidia-riva-conformer-streaming.git
cd nvidia-riva-conformer-streaming

# Copy example config
cp .env.example .env

# Edit .env and fill in:
# - NGC_API_KEY (from https://ngc.nvidia.com)
# - AWS_REGION (default: us-east-2)
# - AWS_ACCOUNT_ID (your 12-digit AWS account ID)
nano .env
```

### Step 2: Setup Build Box

```bash
# Install all prerequisites (Python, AWS CLI, venv, SSL certs)
./scripts/010-setup-build-box.sh

# Configure AWS CLI if not done
aws configure
```

### Step 3: Deploy GPU Instance

```bash
# Creates AWS g4dn.xlarge instance with NVIDIA drivers
./scripts/020-create-gpu-instance.sh

# This will:
# - Launch EC2 instance
# - Install NVIDIA drivers
# - Setup Docker + NVIDIA runtime
# - Configure security groups
# - Save GPU IP to .env
```

### Step 4: Deploy Conformer-CTC Model

```bash
# Downloads pre-built RMIR from S3 and deploys to RIVA
./scripts/100-deploy-conformer-streaming.sh

# This takes 5-10 minutes:
# - Downloads conformer-ctc-xl-streaming-40ms.rmir from S3
# - Deploys to RIVA server
# - Starts RIVA with correct model
# - Verifies health
```

### Step 5: Setup WebSocket Bridge

```bash
# Installs WebSocket bridge as systemd service
./scripts/110-setup-websocket-bridge.sh

# This will:
# - Install bridge code
# - Create systemd service
# - Enable auto-start on boot
# - Start the service
```

### Step 6: Setup HTTPS Demo

```bash
# Installs browser demo interface
./scripts/120-setup-https-demo.sh

# This will:
# - Install demo HTML/JS
# - Create systemd service for HTTPS server
# - Start demo on port 8444
```

### Step 7: Test It!

```bash
# Get the build box IP
echo "Open: https://$(curl -s ifconfig.me):8444"
```

1. Open the URL in your browser
2. Accept SSL warning (self-signed cert)
3. Allow microphone access
4. Click "Start Transcription"
5. Speak - see real-time results!

## Daily Operations

### Shutdown GPU (Save Costs)

```bash
# Stop GPU instance overnight
./scripts/200-shutdown-gpu.sh

# Saves ~$0.526/hour
# All data preserved
```

### Startup and Restore

```bash
# One command to restore everything
./scripts/210-startup-restore.sh

# This will:
# - Start GPU instance
# - Detect IP changes
# - Update .env automatically
# - Verify RIVA is running
# - Restart WebSocket bridge
# - Run health checks
#
# Takes 5-10 minutes
```

## File Structure

```
nvidia-riva-conformer-streaming/
├── README.md                       # This file
├── .env.example                    # Configuration template
├── .gitignore                      # Git ignore rules
│
├── scripts/                        # Deployment automation
│   ├── riva-common-functions.sh    # Shared utilities
│   ├── 010-setup-build-box.sh      # Build box prerequisites
│   ├── 020-create-gpu-instance.sh  # AWS GPU deployment
│   ├── 030-configure-security.sh   # Security groups + SSH
│   ├── 100-deploy-conformer-streaming.sh  # Model deployment
│   ├── 110-setup-websocket-bridge.sh      # WebSocket service
│   ├── 120-setup-https-demo.sh            # Demo UI
│   ├── 200-shutdown-gpu.sh                # GPU shutdown
│   └── 210-startup-restore.sh             # Startup + restore
│
├── src/asr/                        # Python source code
│   ├── riva_client.py              # RIVA gRPC client wrapper
│   └── riva_websocket_bridge.py    # WebSocket ↔ gRPC bridge
│
├── static/                         # Browser demo files
│   ├── demo.html                   # Main UI
│   ├── websocket-client.js         # Client JavaScript
│   └── styles.css                  # UI styles
│
└── docs/                           # Documentation
    ├── QUICK_START.md              # Quick reference
    ├── CONFORMER_CTC_STREAMING_GUIDE.md  # Ops guide
    └── TROUBLESHOOTING.md          # Common issues
```

## What Makes This Different

### Why Conformer-CTC (Not Parakeet RNNT)?

| Model | Classic RIVA 2.19 Streaming | Notes |
|-------|----------------------------|-------|
| **Conformer-CTC-XL** | ✅ **Fully supported** | Official streaming support, 40ms timestep |
| Parakeet RNNT | ❌ **NOT supported** | Only works in NIM, not classic RIVA |

**Key Learning:** Parakeet RNNT streaming only works in NVIDIA NIM containers, not in classic RIVA 2.19. We use Conformer-CTC which has official streaming support.

### Critical Configuration

**Must use these exact parameters:**
```bash
--ms_per_timestep=40          # NOT 80! (Conformer outputs at 40ms)
--chunk_size=0.16             # 160ms chunks
--padding_size=1.92           # 1920ms padding
--streaming=true              # Enable streaming mode
```

**Why 40ms not 80ms?**
- Conformer-CTC-XL outputs frames every **40ms**
- Using 80ms causes "Frames expected 51 got 101" error
- Frame count doubles when timestep is wrong

## Performance

| Metric | Value |
|--------|-------|
| **First partial** | ~160ms |
| **Final result** | After pause detection |
| **GPU memory** | ~4GB VRAM |
| **Throughput** | Real-time+ |
| **Model** | Conformer-CTC-XL |
| **Accuracy** | State-of-the-art |

## Cost Breakdown

| Component | Cost (us-east-2) |
|-----------|------------------|
| **g4dn.xlarge** (running) | ~$0.526/hour |
| **g4dn.xlarge** (stopped) | ~$0.01/hour (EBS only) |
| **Data transfer** | Minimal (browser ↔ bridge) |

**Cost optimization:** Use `200-shutdown-gpu.sh` overnight, `210-startup-restore.sh` in morning.

## Troubleshooting

### GPU Won't Start
```bash
# Check GPU status
./scripts/018-status-gpu-instance.sh

# If stopped, start it
./scripts/210-startup-restore.sh
```

### No Transcriptions
```bash
# Check RIVA health
ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@GPU_IP \
  'curl http://localhost:8000/v2/health/ready'

# Should return: "READY"

# Check for frame errors
ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@GPU_IP \
  'docker logs riva-server 2>&1 | grep "frames expected"'

# Should be empty (no errors)
```

### WebSocket Bridge Down
```bash
# Check status
sudo systemctl status riva-websocket-bridge

# View logs
sudo journalctl -u riva-websocket-bridge -f

# Restart
sudo systemctl restart riva-websocket-bridge
```

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for more.

## Documentation

- **[QUICK_START.md](docs/QUICK_START.md)** - Single-page quick reference
- **[CONFORMER_CTC_STREAMING_GUIDE.md](docs/CONFORMER_CTC_STREAMING_GUIDE.md)** - Complete operations guide
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** - Common issues and solutions

## Support

- **GitHub Issues:** https://github.com/YOUR_USERNAME/nvidia-riva-conformer-streaming/issues
- **NVIDIA Riva Docs:** https://docs.nvidia.com/deeplearning/riva/user-guide/
- **NGC Catalog:** https://catalog.ngc.nvidia.com/orgs/nvidia/teams/riva/models

## License

MIT License - See LICENSE file

## Credits

Built with NVIDIA Riva 2.19.0 and Conformer-CTC-XL streaming model.

---

**Ready to transcribe in real-time? Start with Step 1 above! 🎤**
