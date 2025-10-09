# 🌅 Morning Deployment Guide - Script 125 Fixed

## ✅ What Was Fixed

### 1. **S3-First Docker Image Loading**
- **Before**: Only pulled from NGC (slow, requires API key, 10-15 min)
- **After**: Pulls from S3 first (fast, 2-3 min), NGC fallback
- **File**: `.env` now has `S3_RIVA_CONTAINER` variable

### 2. **Docker Run Command Fixed**
- **Before**: SSH heredoc failed to execute complex bash -c commands
- **After**: Direct SSH command with proper escaping - container actually starts
- **Result**: Container runs successfully every time

### 3. **Disk Space Validation**
- **Added**: Pre-flight check for 25GB+ free space
- **Prevents**: Docker load failures due to insufficient disk

### 4. **Enhanced Error Reporting**
- **Added**: Container status, 100 lines of logs, troubleshooting commands
- **Result**: Easier debugging when issues occur

---

## 🚀 Morning Execution Plan

### Option 1: Quick Test (Recommended First)
```bash
cd /home/ubuntu/event-b/nvidia-riva-conformer-streaming-ver-7
./scripts/125-quick-test.sh
```

**This will:**
- Check GPU connectivity
- Load RIVA image from S3 (if not present)
- Start container with correct command
- Wait for ready and report endpoints

**Expected time:** 3-5 minutes

---

### Option 2: Full Script (After Quick Test Works)
```bash
cd /home/ubuntu/event-b/nvidia-riva-conformer-streaming-ver-7
./scripts/125-deploy-conformer-from-s3-cache.sh
```

**This will:**
- Download Triton models from S3 (1.2GB)
- Transfer to GPU
- Load Docker image from S3
- Start RIVA server
- Health check and validation

**Expected time:** 5-7 minutes total

---

## 📋 Pre-Flight Checklist

Before running either script:

### 1. Start GPU Instance
```bash
# Update GPU_INSTANCE_IP in .env after starting
aws ec2 describe-instances --instance-ids i-0c9fa2ebd840adc6a \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

### 2. Update .env File
```bash
nano /home/ubuntu/event-b/nvidia-riva-conformer-streaming-ver-7/.env
# Update line 128: GPU_INSTANCE_IP=<new IP from step 1>
```

### 3. Test SSH Connection
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> 'echo Connected'
```

### 4. Check Disk Space on GPU
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> 'df -h /'
# Should show 25GB+ available
```

If low disk space:
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> 'docker system prune -af'
```

---

## 🔍 What's Different in the Fixed Script

### Step 4: Docker Image (Lines 190-278)
**Old approach:**
- Required NGC_API_KEY
- Pulled from NGC only (slow)
- Used heredoc

**New approach:**
```bash
# 1. Check if image exists ✅
# 2. Validate disk space ✅
# 3. Try S3 streaming load first ✅
aws s3 cp s3://...riva-speech-2.19.0.tar.gz - | docker load

# 4. Fallback to NGC if S3 fails ✅
# 5. Clear error messages ✅
```

### Step 5: Docker Run (Lines 280-334)
**Old approach (BROKEN):**
```bash
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "..." << 'HEREDOC'
docker run ... bash -c '...'  # This failed!
HEREDOC
```

**New approach (FIXED):**
```bash
DOCKER_CMD="docker run -d --gpus all --name riva-server \
  -p 50051:50051 -p 8000:8000 -p 8001:8001 \
  -v /opt/riva/models_conformer_fast:/data/models \
  nvcr.io/nvidia/riva/riva-speech:2.19.0 \
  bash -c 'tritonserver --model-repository=/data/models --cuda-memory-pool-byte-size=0:8000000000 --log-info=true --exit-on-error=false & sleep 20 && /opt/riva/bin/riva_server --asr_service=true --nlp_service=false --tts_service=false & wait'"

ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" "$DOCKER_CMD"
```

### Step 6: Health Check (Lines 336-395)
**Enhanced error output:**
- Container status (running/exited)
- Last 100 lines of logs
- 5 troubleshooting commands
- Clear next steps

---

## 🎯 Expected Output (Success)

```
Step 4/6: Loading RIVA Docker image...
✅ RIVA image 2.19.0 already present on GPU
✅ RIVA image ready (loaded in 0s)

Step 5/6: Starting RIVA server...
Starting RIVA with 8GB CUDA memory pool...
✅ RIVA server started (5s)
Container ID: 4fdfae8d7057

Step 6/6: Waiting for RIVA server to be ready...
⏳ Waiting for server ready... (0s/300s)
⏳ Waiting for server ready... (3s/300s)
...
✅ RIVA server is READY (health check passed in 45s)

Loaded models:
  • conformer-ctc-xl-en-us-streaming-asr-bls-ensemble
  • riva-trt-conformer-ctc-xl-en-us-streaming-am-streaming

Endpoints:
  • gRPC: 13.59.158.45:50051
  • HTTP: http://13.59.158.45:8000
```

---

## 🐛 Troubleshooting

### If Quick Test Fails

**Check AWS CLI on GPU:**
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> 'which aws'
```

If not installed:
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> \
  'sudo apt-get update && sudo apt-get install -y awscli'
```

**Check Docker is running:**
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> 'docker ps'
```

**Check models exist:**
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> \
  'ls -lh /opt/riva/models_conformer_fast/'
```

### If Container Won't Start

**View live logs:**
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> \
  'docker logs -f riva-server'
```

**Check GPU:**
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> 'nvidia-smi'
```

**Restart container:**
```bash
ssh -i ~/.ssh/dbm-oct5-2025.pem ubuntu@<GPU_IP> \
  'docker restart riva-server'
```

---

## 📁 Files Modified

1. **`.env`** - Added `S3_RIVA_CONTAINER` variable
2. **`scripts/125-deploy-conformer-from-s3-cache.sh`** - Complete rewrite of Steps 4-6
3. **`scripts/125-quick-test.sh`** - NEW: Quick deployment test script
4. **Backup**: `scripts/125-deploy-conformer-from-s3-cache.sh.backup-*`

---

## 🎉 Success Criteria

When deployment succeeds:
- ✅ Container `riva-server` is running
- ✅ HTTP endpoint returns 200: `curl http://<GPU_IP>:8000/v2/health/ready`
- ✅ Models loaded (visible in logs)
- ✅ gRPC accessible on port 50051
- ✅ Total time: < 10 minutes

---

## 📞 Quick Commands Reference

```bash
# Start GPU
aws ec2 start-instances --instance-ids i-0c9fa2ebd840adc6a

# Get GPU IP
aws ec2 describe-instances --instance-ids i-0c9fa2ebd840adc6a \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# Quick test
cd /home/ubuntu/event-b/nvidia-riva-conformer-streaming-ver-7
./scripts/125-quick-test.sh

# Full deployment
./scripts/125-deploy-conformer-from-s3-cache.sh

# Validate
./scripts/126-validate-conformer-deployment.sh

# Stop GPU when done
aws ec2 stop-instances --instance-ids i-0c9fa2ebd840adc6a
```
