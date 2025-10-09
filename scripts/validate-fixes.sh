#!/bin/bash
# Validation script - checks that all fixes are in place

echo "🔍 Validating Script 125 Fixes"
echo "==============================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check 1: .env has S3_RIVA_CONTAINER
echo "✓ Checking .env configuration..."
if grep -q "S3_RIVA_CONTAINER=s3://" "$PROJECT_ROOT/.env"; then
    echo "  ✅ S3_RIVA_CONTAINER configured"
else
    echo "  ❌ S3_RIVA_CONTAINER missing in .env"
    exit 1
fi

# Check 2: Script has S3-first logic
echo "✓ Checking Step 4 (S3-first Docker loading)..."
if grep -q "Loading from S3 (streaming" "$SCRIPT_DIR/125-deploy-conformer-from-s3-cache.sh"; then
    echo "  ✅ S3-first logic present"
else
    echo "  ❌ S3-first logic missing"
    exit 1
fi

# Check 3: Script has direct SSH (no heredoc)
echo "✓ Checking Step 5 (Fixed Docker run)..."
if grep -q "DOCKER_CMD=" "$SCRIPT_DIR/125-deploy-conformer-from-s3-cache.sh"; then
    echo "  ✅ Direct SSH command present (heredoc fixed)"
else
    echo "  ❌ Still using heredoc (not fixed)"
    exit 1
fi

# Check 4: Enhanced error reporting
echo "✓ Checking Step 6 (Enhanced errors)..."
if grep -q "Troubleshooting Commands:" "$SCRIPT_DIR/125-deploy-conformer-from-s3-cache.sh"; then
    echo "  ✅ Enhanced error reporting present"
else
    echo "  ❌ Enhanced error reporting missing"
    exit 1
fi

# Check 5: Backup exists
echo "✓ Checking backup..."
if ls "$SCRIPT_DIR"/125-deploy-conformer-from-s3-cache.sh.backup-* 1> /dev/null 2>&1; then
    BACKUP=$(ls -t "$SCRIPT_DIR"/125-deploy-conformer-from-s3-cache.sh.backup-* | head -1)
    echo "  ✅ Backup exists: $(basename "$BACKUP")"
else
    echo "  ⚠️  No backup found (not critical)"
fi

# Check 6: Quick test script
echo "✓ Checking quick test script..."
if [ -x "$SCRIPT_DIR/125-quick-test.sh" ]; then
    echo "  ✅ Quick test script exists and is executable"
else
    echo "  ❌ Quick test script missing or not executable"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ ALL VALIDATIONS PASSED"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Read: cat MORNING_DEPLOY_GUIDE.md"
echo "  2. Start GPU and update GPU_INSTANCE_IP in .env"
echo "  3. Run: ./scripts/125-quick-test.sh"
echo "  4. Then: ./scripts/125-deploy-conformer-from-s3-cache.sh"
echo ""
