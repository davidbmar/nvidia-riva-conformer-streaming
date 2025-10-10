#!/bin/bash
set -e

# NVIDIA Riva Conformer Streaming - Step 999: Destroy All Resources
# This script safely removes all AWS resources created by the deployment
# IMPORTANT: Run 998-prepare-destroy.sh first!
# IMPORTANT: S3 buckets are NOT destroyed to protect your data

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${RED}🗑️  Riva Conformer Streaming - Resource Cleanup${NC}"
echo "================================================================"
echo -e "${YELLOW}⚠️  WARNING: This will destroy AWS resources created by this deployment${NC}"
echo -e "${GREEN}✅ SAFE: S3 buckets will NOT be deleted${NC}"
echo ""
echo -e "${CYAN}Prerequisites: Run 998-prepare-destroy.sh first!${NC}"
echo ""

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Nothing to clean up."
    exit 0
fi

# Load configuration
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-2}"

# Function to check if resource exists in AWS
check_resource_exists() {
    local resource_type="$1"
    local resource_id="$2"

    if [ -z "$resource_id" ] || [ "$resource_id" = "" ]; then
        return 1
    fi

    case "$resource_type" in
        "instance")
            STATE=$(aws ec2 describe-instances \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" \
                --query 'Reservations[0].Instances[0].State.Name' \
                --output text 2>/dev/null || echo "not-found")
            [ "$STATE" != "not-found" ] && [ "$STATE" != "terminated" ]
            ;;
        "security-group")
            aws ec2 describe-security-groups \
                --group-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "key-pair")
            aws ec2 describe-key-pairs \
                --key-names "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "iam-role")
            aws iam get-role --role-name "$resource_id" &>/dev/null
            ;;
        "iam-instance-profile")
            aws iam get-instance-profile --instance-profile-name "$resource_id" &>/dev/null
            ;;
        "iam-policy")
            aws iam get-policy --policy-arn "$resource_id" &>/dev/null
            ;;
        "s3")
            aws s3api head-bucket --bucket "$resource_id" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac

    return $?
}

# Arrays to track resources
declare -a ENV_RESOURCES
declare -a AWS_RESOURCES
declare -a NOT_FOUND_RESOURCES
declare -a DESTROY_PLAN

echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 1: DISCOVERING RESOURCES FROM .ENV FILE${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Reading configuration from: $ENV_FILE${NC}"
echo ""

# Phase 1: Discover what's configured in .env
echo -e "${YELLOW}Resources found in .env file:${NC}"
echo ""

ENV_FOUND=false

# EC2 Instance
if [ -n "$GPU_INSTANCE_ID" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    echo -e "  ${BLUE}📦 EC2 GPU Instance:${NC}"
    echo "     • Instance ID: $GPU_INSTANCE_ID"
    echo "     • Instance Type: ${GPU_INSTANCE_TYPE:-'Not specified'}"
    echo "     • Public IP: ${GPU_INSTANCE_IP:-'Not specified'}"
    ENV_RESOURCES+=("instance:$GPU_INSTANCE_ID:EC2 GPU Instance")
    ENV_FOUND=true
fi

# Security Groups
if [ -n "$SECURITY_GROUP_ID" ] && [ "$SECURITY_GROUP_ID" != "" ]; then
    echo -e "  ${BLUE}🔒 GPU Security Group:${NC}"
    echo "     • Group ID: $SECURITY_GROUP_ID"
    ENV_RESOURCES+=("security-group:$SECURITY_GROUP_ID:GPU Security Group")
    ENV_FOUND=true
fi

if [ -n "$BUILDBOX_SECURITY_GROUP" ] && [ "$BUILDBOX_SECURITY_GROUP" != "" ]; then
    # Remove quotes if present
    BUILDBOX_SG=$(echo "$BUILDBOX_SECURITY_GROUP" | tr -d '"')
    echo -e "  ${BLUE}🔒 Build Box Security Group:${NC}"
    echo "     • Group ID: $BUILDBOX_SG"
    ENV_RESOURCES+=("security-group:$BUILDBOX_SG:Build Box Security Group")
    ENV_FOUND=true
fi

# IAM Resources
if [ -n "$IAM_ROLE_NAME" ] && [ "$IAM_ROLE_NAME" != "" ]; then
    echo -e "  ${BLUE}👤 IAM Role:${NC}"
    echo "     • Role Name: $IAM_ROLE_NAME"
    ENV_RESOURCES+=("iam-role:$IAM_ROLE_NAME:IAM Role")
    ENV_FOUND=true
fi

if [ -n "$IAM_INSTANCE_PROFILE_NAME" ] && [ "$IAM_INSTANCE_PROFILE_NAME" != "" ]; then
    echo -e "  ${BLUE}👤 IAM Instance Profile:${NC}"
    echo "     • Profile Name: $IAM_INSTANCE_PROFILE_NAME"
    ENV_RESOURCES+=("iam-instance-profile:$IAM_INSTANCE_PROFILE_NAME:IAM Instance Profile")
    ENV_FOUND=true
fi

if [ -n "$IAM_POLICY_ARN" ] && [ "$IAM_POLICY_ARN" != "" ]; then
    POLICY_NAME=$(echo "$IAM_POLICY_ARN" | rev | cut -d'/' -f1 | rev)
    echo -e "  ${BLUE}👤 IAM Policy:${NC}"
    echo "     • Policy ARN: $IAM_POLICY_ARN"
    echo "     • Policy Name: $POLICY_NAME"
    ENV_RESOURCES+=("iam-policy:$IAM_POLICY_ARN:IAM Policy ($POLICY_NAME)")
    ENV_FOUND=true
fi

# Key Pair
if [ -n "$SSH_KEY_NAME" ] && [ "$SSH_KEY_NAME" != "" ]; then
    echo -e "  ${BLUE}🔑 SSH Key Pair:${NC}"
    echo "     • Key Name: $SSH_KEY_NAME"
    ENV_RESOURCES+=("key-pair:$SSH_KEY_NAME:SSH Key Pair")
    ENV_FOUND=true
fi

# S3 Buckets (informational only)
if [ -n "$S3_MODEL_BUCKET" ] && [ "$S3_MODEL_BUCKET" != "" ]; then
    echo -e "  ${GREEN}💾 S3 Model Bucket (PROTECTED):${NC}"
    echo "     • Bucket Name: $S3_MODEL_BUCKET"
    echo "     • Status: Will NOT be deleted"
    ENV_RESOURCES+=("s3:$S3_MODEL_BUCKET:S3 Model Bucket:protected")
fi

if [ "$ENV_FOUND" = false ]; then
    echo -e "  ${GREEN}No resources configured in .env file${NC}"
fi

echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 2: VERIFYING ACTUAL AWS RESOURCES${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Checking which .env resources actually exist in AWS...${NC}"
echo ""

AWS_FOUND=false

for resource in "${ENV_RESOURCES[@]}"; do
    IFS=':' read -r type id name protection <<< "$resource"

    if [ "$protection" = "protected" ]; then
        if check_resource_exists "$type" "$id"; then
            echo -e "  ${GREEN}✅ Found (Protected):${NC} $name - $id"
        else
            echo -e "  ${YELLOW}⚠️  Not Found (Protected):${NC} $name - $id"
        fi
    else
        if check_resource_exists "$type" "$id"; then
            echo -e "  ${GREEN}✅ Found:${NC} $name - $id"
            AWS_RESOURCES+=("$resource")
            AWS_FOUND=true

            # Get additional status for EC2 instances
            if [ "$type" = "instance" ]; then
                INSTANCE_STATE=$(aws ec2 describe-instances \
                    --instance-ids "$id" \
                    --region "$AWS_REGION" \
                    --query 'Reservations[0].Instances[0].State.Name' \
                    --output text 2>/dev/null)
                echo "     • Current State: $INSTANCE_STATE"

                if [ "$INSTANCE_STATE" != "terminated" ]; then
                    echo -e "     ${RED}⚠️  WARNING: Instance should be terminated first!${NC}"
                    echo "     Run: ./scripts/998-prepare-destroy.sh"
                fi
            fi
        else
            echo -e "  ${YELLOW}⚠️  Not Found:${NC} $name - $id (already deleted or doesn't exist)"
            NOT_FOUND_RESOURCES+=("$resource")
        fi
    fi
done

if [ "$AWS_FOUND" = false ]; then
    echo ""
    echo -e "${GREEN}✅ No active AWS resources found to clean up.${NC}"
    echo -e "${CYAN}All resources in .env have already been deleted or don't exist.${NC}"
    exit 0
fi

echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 3: DESTRUCTION PLAN${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Show not-found resources first
if [ ${#NOT_FOUND_RESOURCES[@]} -gt 0 ]; then
    echo -e "${CYAN}Resources in .env but NOT FOUND in AWS (no action needed):${NC}"
    echo ""
    for resource in "${NOT_FOUND_RESOURCES[@]}"; do
        IFS=':' read -r type id name <<< "$resource"
        echo -e "  ${CYAN}ℹ️  NOT FOUND:${NC} $name"
        echo "     • Resource ID: $id"
        echo "     • Status: Already deleted or never created"
    done
    echo ""
fi

# Show resources that will be destroyed
if [ ${#AWS_RESOURCES[@]} -gt 0 ]; then
    echo -e "${YELLOW}The following resources WILL BE DESTROYED:${NC}"
    echo ""

    # Build destruction plan in correct order
    # Order matters: instance -> iam-instance-profile -> iam-role -> iam-policy -> security-group -> key-pair
    DESTROY_ORDER=("instance" "iam-instance-profile" "iam-role" "iam-policy" "security-group" "key-pair")
    PLAN_NUMBER=1

    for order_type in "${DESTROY_ORDER[@]}"; do
        for resource in "${AWS_RESOURCES[@]}"; do
            IFS=':' read -r type id name <<< "$resource"
            if [ "$type" = "$order_type" ]; then
                echo -e "  ${RED}$PLAN_NUMBER. DESTROY:${NC} $name"
                echo "     • Resource ID: $id"
                echo "     • Type: $type"
                DESTROY_PLAN+=("$resource")
                ((PLAN_NUMBER++))
            fi
        done
    done
    echo ""
fi

# Show protected resources
if [ -n "$S3_MODEL_BUCKET" ] && [ "$S3_MODEL_BUCKET" != "" ]; then
    echo -e "${GREEN}The following resources WILL BE PRESERVED:${NC}"
    echo ""
    if check_resource_exists "s3" "$S3_MODEL_BUCKET"; then
        echo -e "  ${GREEN}✅ KEEP:${NC} S3 Model Bucket"
        echo "     • Bucket: $S3_MODEL_BUCKET"
        echo "     • Reason: Data protection"
    fi
    echo ""
fi

echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}⚠️  DESTRUCTIVE ACTION CONFIRMATION ⚠️${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}This action cannot be undone!${NC}"
echo ""
read -p "Type 'DESTROY' to confirm deletion of the above resources: " confirmation

if [ "$confirmation" != "DESTROY" ]; then
    echo -e "${BLUE}❌ Cleanup cancelled by user.${NC}"
    exit 0
fi

echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 4: EXECUTING DESTRUCTION PLAN${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Function to safely delete resource
delete_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"

    echo -n "   Deleting $resource_name..."

    case "$resource_type" in
        "instance")
            # Terminate the instance
            aws ec2 terminate-instances \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null

            # Wait for termination (with timeout)
            timeout 180 aws ec2 wait instance-terminated \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" 2>/dev/null || true
            ;;
        "security-group")
            # Small delay to ensure instances are fully terminated
            sleep 5
            aws ec2 delete-security-group \
                --group-id "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "key-pair")
            aws ec2 delete-key-pair \
                --key-name "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "iam-instance-profile")
            aws iam delete-instance-profile \
                --instance-profile-name "$resource_id" &>/dev/null
            ;;
        "iam-role")
            aws iam delete-role \
                --role-name "$resource_id" &>/dev/null
            ;;
        "iam-policy")
            aws iam delete-policy \
                --policy-arn "$resource_id" &>/dev/null
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo -e " ${GREEN}✅ Deleted${NC}"
        return 0
    else
        echo -e " ${RED}❌ Failed${NC}"
        return 1
    fi
}

# Execute destruction plan
STEP=1
FAILED=false

for resource in "${DESTROY_PLAN[@]}"; do
    IFS=':' read -r type id name <<< "$resource"
    echo -e "${YELLOW}Step $STEP: Destroying $name${NC}"

    if delete_resource "$type" "$id" "$name"; then
        echo "   Successfully destroyed $name"
    else
        echo -e "   ${RED}Failed to destroy $name - manual cleanup may be required${NC}"
        FAILED=true
    fi

    ((STEP++))
    echo ""
done

echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 5: VALIDATION${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Verifying resources were destroyed...${NC}"
echo ""

VALIDATION_FAILED=false

for resource in "${DESTROY_PLAN[@]}"; do
    IFS=':' read -r type id name <<< "$resource"

    if check_resource_exists "$type" "$id"; then
        echo -e "  ${RED}❌ STILL EXISTS:${NC} $name - $id"
        VALIDATION_FAILED=true
    else
        echo -e "  ${GREEN}✅ CONFIRMED DESTROYED:${NC} $name"
    fi
done

echo ""

# Clear .env file entries
echo -e "${YELLOW}Clearing .env configuration...${NC}"
echo -n "   Resetting destroyed resource IDs in .env..."

sed -i 's/^GPU_INSTANCE_ID=.*/GPU_INSTANCE_ID=/' "$ENV_FILE"
sed -i 's/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=/' "$ENV_FILE"
sed -i 's/^SECURITY_GROUP_ID=.*/SECURITY_GROUP_ID=/' "$ENV_FILE"
sed -i 's/^BUILDBOX_SECURITY_GROUP=.*/BUILDBOX_SECURITY_GROUP=/' "$ENV_FILE"
sed -i 's/^IAM_ROLE_NAME=.*/IAM_ROLE_NAME=/' "$ENV_FILE"
sed -i 's/^IAM_INSTANCE_PROFILE_NAME=.*/IAM_INSTANCE_PROFILE_NAME=/' "$ENV_FILE"
sed -i 's/^IAM_POLICY_ARN=.*/IAM_POLICY_ARN=/' "$ENV_FILE"
sed -i 's/^RIVA_DEPLOYMENT_STATUS=.*/RIVA_DEPLOYMENT_STATUS=pending/' "$ENV_FILE"

echo -e " ${GREEN}✅ Reset${NC}"
echo ""

# Final Summary
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
if [ "$FAILED" = true ] || [ "$VALIDATION_FAILED" = true ]; then
    echo -e "${YELLOW}⚠️  Cleanup Completed with Warnings${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Some resources may require manual cleanup.${NC}"
    echo "Check the AWS console for any remaining resources."
else
    echo -e "${GREEN}✅ Cleanup Successfully Completed!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "All discovered AWS resources have been destroyed."
fi

echo ""
echo "Summary:"
echo "  • Resources destroyed: ${#DESTROY_PLAN[@]}"
echo "  • S3 bucket preserved: ${S3_MODEL_BUCKET:-None}"
echo "  • Configuration reset: .env file cleared"
echo ""
echo -e "${BLUE}To deploy again, run:${NC}"
echo "   ./scripts/020-deploy-gpu-instance.sh"
echo ""
