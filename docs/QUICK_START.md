# Quick Start: Conformer-CTC Streaming Transcription

## 🚀 Restore Working State (5-10 minutes)

```bash
# 1. Start GPU (if stopped)
aws ec2 start-instances --instance-ids i-06a36632f4d99f97b --region us-east-2
aws ec2 wait instance-running --instance-ids i-06a36632f4d99f97b --region us-east-2

# 2. Deploy Conformer-CTC
cd /home/ubuntu/event-b/nvidia-parakeet-ver-6
./scripts/riva-200-deploy-conformer-ctc-streaming.sh

# 3. Restart WebSocket bridge
sudo systemctl restart riva-websocket-bridge

# 4. Test
open https://3.16.124.227:8444/demo.html
```

## ✅ Verification

```bash
# Check GPU status
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'curl -sf http://localhost:8000/v2/health/ready && echo READY'

# Check WebSocket bridge
sudo systemctl status riva-websocket-bridge

# Check for errors
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.191.228.243 \
  'docker logs riva-server 2>&1 | grep -i "frames expected" | tail -5'
# Should be EMPTY (no errors)
```

## 📍 Key Locations

**GPU Worker:** `18.191.228.243`
**Build Box:** `3.16.124.227`
**Browser Demo:** `https://3.16.124.227:8444/demo.html`

**S3 RMIR:** `s3://dbm-cf-2-web/bintarball/riva-models/conformer/conformer-ctc-xl-streaming-40ms.rmir`

## 🔧 Common Issues

| Problem | Solution |
|---------|----------|
| "Frames expected 51 got 101" | Redeploy: `./scripts/riva-200-deploy-conformer-ctc-streaming.sh` |
| No transcriptions | Restart bridge: `sudo systemctl restart riva-websocket-bridge` |
| GPU stopped | Start GPU (commands above) then redeploy |

## 📖 Full Documentation

See [`docs/CONFORMER_CTC_STREAMING_GUIDE.md`](./CONFORMER_CTC_STREAMING_GUIDE.md) for complete details.
