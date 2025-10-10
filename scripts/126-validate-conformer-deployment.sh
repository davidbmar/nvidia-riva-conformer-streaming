#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 126: Validate Conformer Deployment
# ============================================================================
# Validates that RIVA server is running correctly with Conformer-CTC model.
#
# Category: FAST DEPLOYMENT FROM S3 CACHE
# This script: ~30 seconds
#
# What this does:
# 1. Verify Triton server health endpoints
# 2. List loaded models and their status
# 3. Check RIVA server logs for errors
# 4. Verify no frame count errors (40ms timestep validation)
# 5. Test basic gRPC connectivity
# ============================================================================

echo "============================================"
echo "126: Validate Conformer Deployment"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Configuration file not found: $ENV_FILE"
    exit 1
fi

# Load configuration
source "$ENV_FILE"

# Required variables
REQUIRED_VARS=(
    "GPU_INSTANCE_IP"
    "SSH_KEY_NAME"
    "RIVA_PORT"
    "RIVA_HTTP_PORT"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required variable not set: $var"
        exit 1
    fi
done

# Configuration
SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
SSH_OPTS="-i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
REMOTE_USER="ubuntu"

echo "Configuration:"
echo "  • GPU Instance: $GPU_INSTANCE_IP"
echo "  • gRPC Port: $RIVA_PORT"
echo "  • HTTP Port: $RIVA_HTTP_PORT"
echo ""

VALIDATION_ERRORS=0

# ============================================================================
# Check 1: HTTP Health Endpoints
# ============================================================================
echo "Check 1/5: HTTP Health Endpoints"
echo "─────────────────────────────────────────"

# Health ready
if curl -sf "http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}/v2/health/ready" >/dev/null 2>&1; then
    echo "✅ /v2/health/ready - Server is READY"
else
    echo "❌ /v2/health/ready - Server NOT READY"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

# Health live
if curl -sf "http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}/v2/health/live" >/dev/null 2>&1; then
    echo "✅ /v2/health/live - Server is LIVE"
else
    echo "❌ /v2/health/live - Server NOT LIVE"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

echo ""

# ============================================================================
# Check 2: Model List and Status
# ============================================================================
echo "Check 2/5: Model List and Status"
echo "─────────────────────────────────────────"

# Get model list (using repository/index endpoint - requires POST)
MODEL_LIST=$(curl -sf -X POST "http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}/v2/repository/index" 2>/dev/null || echo "[]")

if [ "$MODEL_LIST" != "[]" ]; then
    echo "Loaded models:"
    echo "$MODEL_LIST" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for model in data:
            if isinstance(model, dict):
                name = model.get('name', 'unknown')
                state = model.get('state', 'unknown')
                print(f'  • {name}: {state}')
            else:
                print(f'  • {model}')
    else:
        print('  (unexpected format)')
except:
    print('  (parse error)')
" || echo "  (unable to parse model list)"

    # Check for conformer models
    if echo "$MODEL_LIST" | grep -qi "conformer"; then
        echo "✅ Conformer models found"
    else
        echo "⚠️  No conformer models found in list"
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    fi
else
    echo "❌ No models loaded"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

echo ""

# ============================================================================
# Check 3: Container Status
# ============================================================================
echo "Check 3/5: Container Status"
echo "─────────────────────────────────────────"

CONTAINER_STATUS=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" << 'CONTAINER_SCRIPT'
set -euo pipefail

if docker ps --filter name=riva-server --format '{{.Status}}' | grep -q "Up"; then
    echo "RUNNING"
    docker ps --filter name=riva-server --format 'Status: {{.Status}}'
else
    echo "NOT_RUNNING"
    docker ps -a --filter name=riva-server --format 'Status: {{.Status}}'
fi
CONTAINER_SCRIPT
)

if echo "$CONTAINER_STATUS" | grep -q "RUNNING"; then
    echo "✅ RIVA container is running"
    echo "$CONTAINER_STATUS" | tail -1
else
    echo "❌ RIVA container is NOT running"
    echo "$CONTAINER_STATUS"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

echo ""

# ============================================================================
# Check 4: Log Analysis (Frame Count Errors)
# ============================================================================
echo "Check 4/5: Log Analysis"
echo "─────────────────────────────────────────"
echo "Checking for frame count errors (40ms timestep validation)..."

FRAME_ERRORS=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "docker logs riva-server 2>&1 | grep -i 'frames expected' | tail -5" || true)

if [ -z "$FRAME_ERRORS" ]; then
    echo "✅ No frame count errors (40ms timestep correct)"
else
    echo "⚠️  Frame count errors detected:"
    echo "$FRAME_ERRORS" | sed 's/^/     /'
    echo ""
    echo "This may indicate incorrect ms_per_timestep setting"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

# Check for other errors
ERROR_COUNT=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "docker logs riva-server 2>&1 | grep -i 'error' | wc -l" || echo "0")

if [ "$ERROR_COUNT" -eq 0 ]; then
    echo "✅ No errors in logs"
else
    echo "⚠️  Found $ERROR_COUNT error messages in logs"
    echo "Recent errors:"
    ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
        "docker logs riva-server 2>&1 | grep -i 'error' | tail -5" | sed 's/^/     /' || true
fi

echo ""

# ============================================================================
# Check 5: gRPC Connectivity
# ============================================================================
echo "Check 5/5: gRPC Connectivity"
echo "─────────────────────────────────────────"

# Test gRPC connectivity from build box (if grpcurl available)
if command -v grpcurl >/dev/null 2>&1; then
    echo "Testing gRPC connection from build box..."
    if timeout 5 grpcurl -plaintext "${GPU_INSTANCE_IP}:${RIVA_PORT}" list >/dev/null 2>&1; then
        echo "✅ gRPC connection successful from build box"
    else
        echo "⚠️  gRPC connection failed from build box"
        echo "   (This may be normal if grpcurl is not configured)"
    fi
else
    echo "⚠️  grpcurl not available - skipping gRPC test from build box"
fi

# Test from GPU instance
echo "Testing gRPC connection from GPU instance..."
GRPC_TEST=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "RIVA_PORT='${RIVA_PORT}'" << 'GRPC_SCRIPT'
set -euo pipefail

if command -v grpcurl >/dev/null 2>&1; then
    if timeout 5 grpcurl -plaintext "localhost:${RIVA_PORT}" list >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
    fi
else
    echo "SKIPPED"
fi
GRPC_SCRIPT
)

case "$GRPC_TEST" in
    OK)
        echo "✅ gRPC port responding on GPU instance"
        ;;
    FAILED)
        echo "❌ gRPC port not responding on GPU instance"
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
        ;;
    SKIPPED)
        echo "⚠️  grpcurl not available on GPU instance"
        ;;
esac

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
if [ $VALIDATION_ERRORS -eq 0 ]; then
    echo "✅ VALIDATION PASSED"
    echo "========================================="
    echo ""
    echo "RIVA server is healthy and ready for use!"
    echo ""
    echo "Endpoints:"
    echo "  • gRPC: ${GPU_INSTANCE_IP}:${RIVA_PORT}"
    echo "  • HTTP: http://${GPU_INSTANCE_IP}:${RIVA_HTTP_PORT}"
    echo ""
    echo "Next Steps:"
    echo "  • Update WebSocket bridge to point to this RIVA instance"
    echo "  • Test streaming: https://$(curl -s ifconfig.me 2>/dev/null || echo '<buildbox-ip>'):${DEMO_PORT:-8444}/demo.html"
    echo ""
    exit 0
else
    echo "⚠️  VALIDATION COMPLETED WITH $VALIDATION_ERRORS ISSUES"
    echo "========================================="
    echo ""
    echo "Review the issues above. The server may still be functional."
    echo ""
    echo "Troubleshooting:"
    echo "  • Check logs: ssh ${REMOTE_USER}@${GPU_INSTANCE_IP} 'docker logs riva-server'"
    echo "  • Restart server: ./scripts/125-deploy-conformer-from-s3-cache.sh"
    echo ""
    exit 1
fi
