#!/bin/bash
set -e
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# NVIDIA Riva ASR Deployment - Step 0: Configuration Setup
# This script creates comprehensive .env configuration for Riva deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 NVIDIA Riva ASR Deployment - Configuration Setup${NC}"
echo "================================================================"
echo "This script will set up your .env configuration for Riva ASR deployment."
echo ""
echo "You'll need:"
echo "  • AWS Account ID and region (for GPU worker deployment)"  
echo "  • Desired GPU instance type for Riva server"
echo "  • NVIDIA NGC API key (optional, for model downloads)"
echo "  • SSL certificate preferences"
echo ""

# Function to prompt for input with default
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local secret="${4:-false}"
    
    if [ "$secret" = "true" ]; then
        echo -n -e "${YELLOW}$prompt${NC}"
        [ -n "$default" ] && echo -n " [$default]"
        echo -n ": "
        read -s value
        echo ""  # New line after hidden input
    else
        echo -n -e "${YELLOW}$prompt${NC}"
        [ -n "$default" ] && echo -n " [$default]"
        echo -n ": "
        read value
    fi
    
    if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
    fi
    
    eval "$var_name='$value'"
}

# Function to validate AWS account ID
validate_aws_account_id() {
    if [[ ! $1 =~ ^[0-9]{12}$ ]]; then
        echo -e "${RED}❌ Invalid AWS Account ID. Must be 12 digits.${NC}"
        return 1
    fi
    return 0
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Check if .env already exists
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}⚠️  Configuration file already exists: $ENV_FILE${NC}"
    echo -n "Do you want to overwrite it? [y/N]: "
    read overwrite
    if [[ ! $overwrite =~ ^[Yy]$ ]]; then
        echo "Configuration setup cancelled."
        exit 0
    fi
    echo ""
fi

echo -e "${BLUE}📋 Please provide the following information:${NC}"
echo ""

# Deployment Strategy
echo -e "${GREEN}=== Deployment Strategy ===${NC}"
echo "1. AWS EC2 GPU Worker (deploy new GPU instance for Riva)"
echo "2. Existing GPU Server (use existing server with GPU)"
echo "3. Local Development (Riva on localhost)"
echo ""
prompt_with_default "Choose deployment strategy [1/2/3]" "1" DEPLOYMENT_STRATEGY

case $DEPLOYMENT_STRATEGY in
    1)
        # AWS Configuration for new EC2 instance
        echo ""
        echo -e "${GREEN}=== AWS Configuration ===${NC}"
        echo "The GPU worker will be deployed as an EC2 instance in your AWS account."
        echo ""
        prompt_with_default "AWS Region (where to deploy GPU instance)" "us-east-2" AWS_REGION
        prompt_with_default "AWS Account ID (12 digits, from AWS console)" "821850226835" AWS_ACCOUNT_ID

        # Validate AWS Account ID
        while ! validate_aws_account_id "$AWS_ACCOUNT_ID"; do
            prompt_with_default "AWS Account ID (12 digits, from AWS console)" "821850226835" AWS_ACCOUNT_ID
        done

        echo ""
        echo "GPU instance type determines cost and performance:"
        echo "  • g4dn.xlarge  - Tesla T4, 4 vCPU, 16GB RAM (~\$0.526/hr) [RECOMMENDED]"
        echo "  • g4dn.2xlarge - Tesla T4, 8 vCPU, 32GB RAM (~\$0.752/hr)"
        echo "  • g5.xlarge    - A10G GPU, 4 vCPU, 16GB RAM (~\$1.006/hr)"
        echo "  • p3.2xlarge   - Tesla V100, 8 vCPU, 61GB RAM (~\$3.06/hr)"
        echo ""
        prompt_with_default "GPU Instance Type (affects hourly cost)" "g4dn.xlarge" GPU_INSTANCE_TYPE

        echo ""
        echo "SSH key pair is needed to connect to the GPU instance for debugging."
        echo "Use an existing key name from your AWS EC2 console (without .pem extension)."
        prompt_with_default "SSH Key Pair Name (e.g., dbm-oct5-2025)" "dbm-oct5-2025" SSH_KEY_NAME
        
        RIVA_HOST_TYPE="aws_ec2"
        RIVA_HOST="auto_detected"  # Will be set after instance creation
        ;;
    2)
        # Existing GPU Server
        echo ""
        echo -e "${GREEN}=== Existing GPU Server ===${NC}"
        prompt_with_default "Riva Server Hostname or IP" "" RIVA_HOST
        
        while [ -z "$RIVA_HOST" ]; do
            echo -e "${RED}❌ Riva server hostname/IP is required${NC}"
            prompt_with_default "Riva Server Hostname or IP" "" RIVA_HOST
        done
        
        RIVA_HOST_TYPE="existing"
        AWS_REGION=""
        AWS_ACCOUNT_ID=""
        GPU_INSTANCE_TYPE=""
        SSH_KEY_NAME=""
        ;;
    3)
        # Local Development
        RIVA_HOST="localhost"
        RIVA_HOST_TYPE="local"
        AWS_REGION=""
        AWS_ACCOUNT_ID=""
        GPU_INSTANCE_TYPE=""
        SSH_KEY_NAME=""
        ;;
    *)
        echo -e "${RED}❌ Invalid deployment strategy${NC}"
        exit 1
        ;;
esac

# Riva Configuration
echo ""
echo -e "${GREEN}=== Riva ASR Configuration ===${NC}"
echo "These ports are where the RIVA server will listen on the GPU instance."
echo ""
prompt_with_default "Riva gRPC Port (for streaming audio)" "50051" RIVA_PORT
prompt_with_default "Riva HTTP Port (for REST API and health checks)" "8000" RIVA_HTTP_PORT

echo ""
echo "Riva model determines the ASR accuracy and language support."
echo "Conformer-CTC provides excellent accuracy for English streaming transcription."
echo ""
prompt_with_default "Riva Model Name" "conformer-ctc-xl-en-us-streaming" RIVA_MODEL
prompt_with_default "Language Code (en-US, es-US, etc.)" "en-US" RIVA_LANGUAGE_CODE

# SSL Configuration
echo ""
echo -e "${GREEN}=== SSL/Security Configuration ===${NC}"
echo "SSL between build box and GPU is usually not needed (private network)."
prompt_with_default "Enable SSL for Riva connection [y/N]" "N" ENABLE_RIVA_SSL
if [[ "$ENABLE_RIVA_SSL" =~ ^[Yy]$ ]]; then
    RIVA_SSL="true"
    prompt_with_default "Riva SSL Certificate Path" "/opt/riva/certs/riva.crt" RIVA_SSL_CERT
    prompt_with_default "Riva SSL Key Path" "/opt/riva/certs/riva.key" RIVA_SSL_KEY
else
    RIVA_SSL="false"
    RIVA_SSL_CERT=""
    RIVA_SSL_KEY=""
fi

# NVIDIA NGC Configuration
echo ""
echo -e "${GREEN}=== NVIDIA NGC Configuration ===${NC}"
echo "NGC API key is used to pull NVIDIA containers and download models."
echo "Get your key from: https://catalog.ngc.nvidia.com/ → Generate API Key"
echo "Press Enter to skip if you don't have one yet (can add later to .env)"
echo ""
prompt_with_default "NGC API Key (optional, hidden input)" "" NGC_API_KEY true

# Application Server Configuration
echo ""
echo -e "${GREEN}=== WebSocket Server Configuration ===${NC}"
echo "The WebSocket bridge runs on the build box and connects browsers to RIVA."
echo ""
prompt_with_default "WebSocket Server Port (for browser connections)" "8443" APP_PORT
prompt_with_default "Enable HTTPS for WebSocket server [y/N]" "y" ENABLE_APP_SSL
if [[ "$ENABLE_APP_SSL" =~ ^[Yy]$ ]]; then
    APP_SSL_CERT="/opt/riva/certs/server.crt"
    APP_SSL_KEY="/opt/riva/certs/server.key"
else
    APP_SSL_CERT=""
    APP_SSL_KEY=""
fi

# Performance and Monitoring
echo ""
echo -e "${GREEN}=== Performance & Monitoring ===${NC}"
echo "These settings control logging detail and system monitoring."
echo ""
prompt_with_default "Log Level (DEBUG for troubleshooting, INFO for normal)" "INFO" LOG_LEVEL
prompt_with_default "Enable Prometheus Metrics (for monitoring) [y/N]" "y" ENABLE_METRICS
prompt_with_default "Max WebSocket Connections (concurrent browsers)" "100" WS_MAX_CONNECTIONS

# Generate timestamp
DEPLOYMENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DEPLOYMENT_ID="riva-$(date +%Y%m%d-%H%M%S)"

# Create .env file
echo ""
echo -e "${BLUE}📝 Creating configuration file...${NC}"

cat > "$ENV_FILE" << EOF
# NVIDIA Riva ASR Deployment Configuration
# Generated on: $DEPLOYMENT_TIMESTAMP
# Deployment ID: $DEPLOYMENT_ID

# ============================================================================
# Deployment Strategy
# ============================================================================
DEPLOYMENT_STRATEGY=$DEPLOYMENT_STRATEGY
DEPLOYMENT_ID=$DEPLOYMENT_ID
DEPLOYMENT_TIMESTAMP=$DEPLOYMENT_TIMESTAMP
RIVA_HOST_TYPE=$RIVA_HOST_TYPE

# ============================================================================
# AWS Configuration (for EC2 deployment)
# ============================================================================
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
GPU_INSTANCE_TYPE=$GPU_INSTANCE_TYPE
SSH_KEY_NAME=$SSH_KEY_NAME

# ============================================================================
# Riva Server Connection
# ============================================================================
RIVA_HOST=$RIVA_HOST
RIVA_PORT=$RIVA_PORT
RIVA_HTTP_PORT=$RIVA_HTTP_PORT
RIVA_SSL=$RIVA_SSL
RIVA_SSL_CERT=$RIVA_SSL_CERT
RIVA_SSL_KEY=$RIVA_SSL_KEY

# ============================================================================
# Riva Model Configuration
# ============================================================================
RIVA_MODEL=$RIVA_MODEL
RIVA_LANGUAGE_CODE=$RIVA_LANGUAGE_CODE
RIVA_ENABLE_AUTOMATIC_PUNCTUATION=true
RIVA_ENABLE_WORD_TIME_OFFSETS=true

# ============================================================================
# S3 Model Paths (for Conformer-CTC Streaming)
# ============================================================================
S3_CONFORMER_RMIR=s3://dbm-cf-2-web/bintarball/riva-models/conformer/conformer-ctc-xl-streaming-40ms.rmir
S3_CONFORMER_SOURCE=s3://dbm-cf-2-web/bintarball/riva-models/conformer/Conformer-CTC-XL_spe-128_en-US_Riva-ASR-SET-4.0.riva

# ============================================================================
# NVIDIA NGC
# ============================================================================
NGC_API_KEY=$NGC_API_KEY

# ============================================================================
# Connection Settings
# ============================================================================
RIVA_TIMEOUT_MS=5000
RIVA_MAX_RETRIES=3
RIVA_RETRY_DELAY_MS=1000

# ============================================================================
# Performance Tuning
# ============================================================================
RIVA_MAX_BATCH_SIZE=8
RIVA_CHUNK_SIZE_BYTES=8192
RIVA_ENABLE_PARTIAL_RESULTS=true
RIVA_PARTIAL_RESULT_INTERVAL_MS=300

# ============================================================================
# Application Server Settings
# ============================================================================
APP_HOST=0.0.0.0
APP_PORT=$APP_PORT
APP_SSL_CERT=$APP_SSL_CERT
APP_SSL_KEY=$APP_SSL_KEY

# ============================================================================
# WebSocket Settings
# ============================================================================
WS_MAX_CONNECTIONS=$WS_MAX_CONNECTIONS
WS_PING_INTERVAL_S=30
WS_MAX_MESSAGE_SIZE_MB=10

# ============================================================================
# Audio Processing
# ============================================================================
AUDIO_SAMPLE_RATE=16000
AUDIO_CHANNELS=1
AUDIO_ENCODING=pcm16
AUDIO_MAX_SEGMENT_DURATION_S=30
AUDIO_VAD_ENABLED=true
AUDIO_VAD_THRESHOLD=0.5

# ============================================================================
# Observability
# ============================================================================
LOG_LEVEL=$LOG_LEVEL
LOG_DIR=/opt/riva/logs
METRICS_ENABLED=${ENABLE_METRICS:-true}
METRICS_PORT=9090
TRACING_ENABLED=false
TRACING_ENDPOINT=http://localhost:4317

# ============================================================================
# Development/Testing
# ============================================================================
DEBUG_MODE=false
TEST_AUDIO_PATH=/opt/riva/test_audio

# ============================================================================
# Status Flags (used by deployment scripts)
# ============================================================================
CONFIG_VALIDATION_PASSED=true
RIVA_DEPLOYMENT_STATUS=pending
APP_DEPLOYMENT_STATUS=pending
TESTING_STATUS=pending
EOF

# Set proper permissions
chmod 600 "$ENV_FILE"

echo -e "${GREEN}✅ Configuration file created: $ENV_FILE${NC}"
echo ""

# Show configuration summary
echo -e "${BLUE}📋 Configuration Summary:${NC}"
echo "  • Deployment Strategy: $DEPLOYMENT_STRATEGY"
case $DEPLOYMENT_STRATEGY in
    1)
        echo "  • AWS Region: $AWS_REGION"
        echo "  • AWS Account: $AWS_ACCOUNT_ID"
        echo "  • Instance Type: $GPU_INSTANCE_TYPE"
        echo "  • SSH Key: $SSH_KEY_NAME"
        ;;
    2)
        echo "  • Riva Server: $RIVA_HOST:$RIVA_PORT"
        ;;
    3)
        echo "  • Local Riva: localhost:$RIVA_PORT"
        ;;
esac
echo "  • Riva Model: $RIVA_MODEL"
echo "  • App Port: $APP_PORT"
echo "  • SSL Enabled: Riva=$RIVA_SSL, App=${ENABLE_APP_SSL:-N}"
echo "  • Log Level: $LOG_LEVEL"
echo ""

# Show next steps based on deployment strategy
echo -e "${GREEN}🎯 Next Steps:${NC}"
case $DEPLOYMENT_STRATEGY in
    1)
        echo "1. Install build box dependencies: ./scripts/010-setup-build-box.sh"
        echo "2. Deploy GPU instance: ./scripts/020-deploy-gpu-instance.sh"
        echo "3. Configure security groups: ./scripts/030-configure-security-groups.sh"
        echo "4. Deploy Conformer-CTC model: ./scripts/110-deploy-conformer-streaming.sh"
        echo "5. Test: https://<BUILDBOX-IP>:8444/demo.html"
        ;;
    2)
        echo "1. Setup Riva on existing server: ./scripts/riva-020-setup-riva-server.sh"
        echo "2. Deploy WebSocket app: ./scripts/riva-030-deploy-websocket-app.sh"
        echo "3. Test system: ./scripts/riva-040-test-system.sh"
        ;;
    3)
        echo "1. Setup Riva locally: ./scripts/riva-020-setup-riva-server.sh"
        echo "2. Run WebSocket app: ./scripts/riva-030-deploy-websocket-app.sh"
        echo "3. Test system: ./scripts/riva-040-test-system.sh"
        ;;
esac
echo ""
echo "Or run the complete deployment: ./scripts/riva-000-run-complete-deployment.sh"
echo ""

echo -e "${BLUE}⚠️  Security Note:${NC}"
echo "• The .env file contains sensitive configuration"
echo "• It's excluded from git (check .gitignore)"
echo "• Keep this file secure and don't share it"
echo ""

echo -e "${CYAN}✨ Configuration setup complete!${NC}"