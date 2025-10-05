# Conformer-CTC Streaming ASR - Operations Guide

## 🎯 Quick Start (Restore Working State)

If the GPU is shutdown or you need to redeploy from scratch:

```bash
# 1. Start GPU instance (if stopped)
./scripts/riva-018-status-gpu-instance.sh

# 2. Deploy Conformer-CTC streaming model
./scripts/riva-200-deploy-conformer-ctc-streaming.sh

# 3. Restart WebSocket bridge
sudo systemctl restart riva-websocket-bridge

# 4. Test in browser
open https://3.16.124.227:8444/demo.html
```

**Total time:** ~10 minutes (5 min if RMIR already in S3)

---

## 📋 What's Deployed

### Architecture

```
Browser Microphone
    ↓ (WebSocket WSS)
Build Box (3.16.124.227)
    ├── WebSocket Bridge :8443
    ├── HTTPS Demo :8444
    ↓ (gRPC)
GPU Worker (18.191.228.243)
    ├── RIVA Server :50051
    └── Triton :8000-8002
        └── Conformer-CTC-XL (streaming mode)
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **RIVA Server** | GPU Worker (18.191.228.243:50051) | Hosts Conformer-CTC streaming model |
| **WebSocket Bridge** | Build Box (systemd service) | Converts browser audio → gRPC |
| **HTTPS Demo** | Build Box (https://3.16.124.227:8444) | Browser microphone interface |
| **Model RMIR** | S3 + GPU `/opt/riva/models_conformer_ctc_streaming` | Deployed streaming model |

---

## 🔑 Critical Configuration

### Why Conformer-CTC Works (and Parakeet RNNT Doesn't)

| Model | Classic RIVA Streaming | Issue |
|-------|----------------------|-------|
| **Parakeet RNNT** | ❌ Not supported | Only works in NIM, not classic RIVA 2.19 |
| **Conformer-CTC** | ✅ Supported | Official streaming support in RIVA 2.19 |

### Critical Build Parameters

**MUST use these exact parameters** (learned through debugging):

```bash
--ms_per_timestep=40          # NOT 80! (Conformer outputs at 40ms)
--chunk_size=0.16             # 160ms chunks
--padding_size=1.92           # 1920ms padding (both sides)
--streaming=true              # Enable streaming mode
```

**Why 40ms not 80ms?**
- Conformer-CTC-XL outputs frames every **40ms**
- Using 80ms causes "Frames expected 51 got 101" error
- The frame count doubles when timestep is wrong (101 ≈ 2×51)

**Frame Calculation:**
```
total_window = chunk_size + 2*padding_size
             = 0.16 + 2*1.92 = 4.0 seconds

frames = total_window / (ms_per_timestep / 1000)
       = 4.0 / 0.04 = 100-101 frames ✅
```

---

## 📁 File Locations

### On GPU Worker (18.191.228.243)

```
/opt/riva/models_conformer_ctc_streaming/   # Deployed model (active)
~/conformer-ctc-deploy/                     # Deployment workspace
    └── conformer-ctc-xl-streaming.rmir     # Built RMIR file
```

### On Build Box (3.16.124.227)

```
/opt/riva/nvidia-parakeet-ver-6/.env                    # Configuration
/opt/riva/nvidia-parakeet-ver-6/src/asr/                # WebSocket bridge code
/etc/systemd/system/riva-websocket-bridge.service      # Systemd service
scripts/riva-200-deploy-conformer-ctc-streaming.sh     # Deployment script
```

### In S3

```
s3://dbm-cf-2-web/bintarball/riva-models/conformer/
├── Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva   # Source model (1.5GB)
└── conformer-ctc-xl-streaming-40ms.rmir                    # Pre-built streaming (1.5GB)
```

---

## 🔧 Common Operations

### Check Status

```bash
# GPU worker health
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'curl -sf http://localhost:8000/v2/health/ready && echo READY || echo NOT_READY'

# WebSocket bridge status
sudo systemctl status riva-websocket-bridge

# Check for errors
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'docker logs riva-server 2>&1 | grep -i error | tail -10'
```

### Restart Services

```bash
# Restart RIVA on GPU worker
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'docker restart riva-server'

# Restart WebSocket bridge
sudo systemctl restart riva-websocket-bridge
```

### View Logs

```bash
# WebSocket bridge logs
sudo journalctl -u riva-websocket-bridge -f

# RIVA server logs (on GPU)
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'docker logs -f riva-server'
```

### Update .env Configuration

```bash
# Key settings in .env
RIVA_HOST=18.191.228.243
RIVA_PORT=50051
RIVA_MODEL=conformer-ctc-xl-en-us-streaming-asr-bls-ensemble
GPU_INSTANCE_IP=18.191.228.243
NGC_API_KEY=nvapi-...
```

---

## 🚨 Troubleshooting

### Problem: "Frames expected 51 got 101"

**Cause:** Built with wrong `--ms_per_timestep` (80 instead of 40)

**Fix:**
```bash
# Rebuild with correct parameters
./scripts/riva-200-deploy-conformer-ctc-streaming.sh
```

### Problem: "Unavailable model type=offline"

**Cause:** Model built with `--streaming=true` doesn't support batch mode

**Fix:** This is expected - streaming models only work with streaming API. Use NIM for offline transcription.

### Problem: No transcriptions returned

**Checks:**
```bash
# 1. Verify correct models loaded
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'docker inspect riva-server | grep -A1 Mounts'
# Should show: /opt/riva/models_conformer_ctc_streaming

# 2. Check for frame errors
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'docker logs riva-server 2>&1 | grep "frames expected"'
# Should be empty (no errors)

# 3. Verify audio is flowing
sudo journalctl -u riva-websocket-bridge -f | grep "audio chunk"
# Should see chunks being sent
```

### Problem: GPU instance stopped

**Start GPU:**
```bash
# Check status
./scripts/riva-018-status-gpu-instance.sh

# Start if stopped
aws ec2 start-instances --instance-ids i-06a36632f4d99f97b --region us-east-2

# Wait for ready (2-3 minutes)
aws ec2 wait instance-running --instance-ids i-06a36632f4d99f97b --region us-east-2

# Redeploy
./scripts/riva-200-deploy-conformer-ctc-streaming.sh
```

---

## 🧪 Testing

### Quick Test (Browser)

1. Open https://3.16.124.227:8444/demo.html
2. Click "Start Transcription"
3. Speak into microphone
4. See partial results appear in real-time
5. See final results after pauses

### Diagnostic Test (Command Line)

```bash
# Test from build box
cd /opt/riva/nvidia-parakeet-ver-6
python3 << 'EOF'
import riva.client

auth = riva.client.Auth(uri="18.191.228.243:50051")
service = riva.client.ASRService(auth)

config = riva.client.StreamingRecognitionConfig(
    config=riva.client.RecognitionConfig(
        encoding=riva.client.AudioEncoding.LINEAR_PCM,
        sample_rate_hertz=16000,
        language_code="en-US",
        max_alternatives=1,
    ),
    interim_results=True,
)

def audio_generator():
    import wave
    with wave.open("/tmp/test.wav", "rb") as wf:
        while chunk := wf.readframes(1600):  # 100ms chunks
            yield chunk

responses = service.streaming_response_generator(
    audio_chunks=audio_generator(),
    streaming_config=config
)

for response in responses:
    for result in response.results:
        print(f"{'PARTIAL' if not result.is_final else 'FINAL'}: {result.alternatives[0].transcript}")
EOF
```

---

## 📊 Performance

| Metric | Value | Notes |
|--------|-------|-------|
| **Latency** | ~160ms | First partial result |
| **Throughput** | Real-time | Processes as fast as you speak |
| **Accuracy** | High | Conformer-CTC-XL is state-of-the-art |
| **GPU Memory** | ~4GB | On T4 GPU |
| **Build Time** | ~2 min | With GPU |
| **Deploy Time** | ~2 min | TensorRT engine compilation |
| **Startup Time** | ~45s | Server + model loading |

---

## 🔐 Security Notes

- **NGC API Key** stored in .env (never commit!)
- **SSH Key** required: `~/.ssh/dbm-sep23-2025.pem`
- **HTTPS** enabled for demo (self-signed cert)
- **Security Group** limits GPU access to build box IP

---

## 📝 Version Info

| Component | Version |
|-----------|---------|
| RIVA | 2.19.0 |
| Triton | 2.54.0 |
| CUDA | 12.6 |
| Driver | 570.133.07 |
| GPU | Tesla T4 (16GB) |
| Model | Conformer-CTC-XL |
| Tokenizer | SentencePiece (128 tokens) |

---

## 🎓 Lessons Learned

1. **Parakeet RNNT streaming NOT supported in classic RIVA 2.19**
   - Only works in NIM
   - Classic RIVA only supports RNNT for offline/batch mode

2. **Conformer-CTC requires 40ms timestep, not 80ms**
   - Frame count error ("expected 51 got 101") indicates wrong timestep
   - Always use `--ms_per_timestep=40` for Conformer-CTC

3. **Match servicemaker and runtime versions**
   - Don't mix 2.17 servicemaker with 2.19 runtime
   - Use 2.19.0 for both

4. **Tensor outputs must be FP32/FP16 rank=3**
   - TYPE_STRING indicates Python backend issue (RNNT problem)
   - Conformer-CTC outputs correct FP32 tensors

5. **Streaming-built models don't support offline API**
   - `--streaming=true` disables batch/offline mode
   - Need separate builds for streaming vs offline

---

## 📞 Support

- **Deployment Issues:** Run `./scripts/riva-200-deploy-conformer-ctc-streaming.sh`
- **NVIDIA RIVA Docs:** https://docs.nvidia.com/deeplearning/riva/user-guide/
- **NGC Catalog:** https://catalog.ngc.nvidia.com/orgs/nvidia/teams/riva/models

---

## ✅ Success Checklist

After deployment, verify:

- [ ] GPU instance running
- [ ] RIVA server READY (curl health check)
- [ ] Models loaded (conformer-ctc-xl-en-us-streaming-asr-bls-ensemble)
- [ ] WebSocket bridge running (systemctl status)
- [ ] Browser demo accessible (https://3.16.124.227:8444)
- [ ] Microphone streaming works (see transcriptions)
- [ ] No frame count errors in logs

**If all checked: You're ready to transcribe! 🎉**
