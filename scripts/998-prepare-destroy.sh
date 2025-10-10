#!/bin/bash
set -e

# NVIDIA Riva Conformer Streaming - Step 998: Prepare for Resource Destruction
# This script handles prerequisites before destroying resources
# MUST run this before 999-destroy-all.sh

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

echo -e "${YELLOW}🔧 Riva Conformer Streaming - Prepare for Destruction${NC}"
echo "================================================================"
echo "This script prepares resources for safe destruction by:"
echo "  1. Stopping/terminating EC2 instances"
echo "  2. Removing IAM instance profiles from instances"
echo "  3. Detaching IAM policies from roles"
echo ""

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Nothing to prepare."
    exit 0
fi

# Load configuration
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-2}"

echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 1: TERMINATE EC2 INSTANCES${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

INSTANCES_TERMINATED=0

# Terminate GPU instance
if [ -n "$GPU_INSTANCE_ID" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    echo -e "${CYAN}Checking GPU instance: $GPU_INSTANCE_ID${NC}"

    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")

    if [ "$INSTANCE_STATE" != "not-found" ] && [ "$INSTANCE_STATE" != "terminated" ]; then
        echo "   Current state: $INSTANCE_STATE"
        echo -n "   Terminating instance..."

        aws ec2 terminate-instances \
            --instance-ids "$GPU_INSTANCE_ID" \
            --region "$AWS_REGION" \
            --output text &>/dev/null

        if [ $? -eq 0 ]; then
            echo -e " ${GREEN}✅ Termination initiated${NC}"
            ((INSTANCES_TERMINATED++))

            echo "   Waiting for termination (this may take 1-2 minutes)..."
            aws ec2 wait instance-terminated \
                --instance-ids "$GPU_INSTANCE_ID" \
                --region "$AWS_REGION" 2>/dev/null

            echo -e "   ${GREEN}✅ Instance terminated${NC}"
        else
            echo -e " ${YELLOW}⚠️  Failed or already terminated${NC}"
        fi
    else
        echo -e "   ${GREEN}✅ Already terminated or not found${NC}"
    fi
    echo ""
fi

echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 2: DETACH IAM POLICIES FROM ROLES${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

POLICIES_DETACHED=0

# Detach managed policies from IAM role
if [ -n "$IAM_ROLE_NAME" ] && [ "$IAM_ROLE_NAME" != "" ]; then
    echo -e "${CYAN}Checking IAM role: $IAM_ROLE_NAME${NC}"

    # Check if role exists
    ROLE_EXISTS=$(aws iam get-role --role-name "$IAM_ROLE_NAME" 2>/dev/null && echo "yes" || echo "no")

    if [ "$ROLE_EXISTS" = "yes" ]; then
        echo "   Role found, checking attached policies..."

        # List and detach all managed policies
        ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
            --role-name "$IAM_ROLE_NAME" \
            --query 'AttachedPolicies[*].PolicyArn' \
            --output text 2>/dev/null)

        if [ -n "$ATTACHED_POLICIES" ]; then
            for policy_arn in $ATTACHED_POLICIES; do
                echo -n "   Detaching policy: $(basename $policy_arn)..."
                aws iam detach-role-policy \
                    --role-name "$IAM_ROLE_NAME" \
                    --policy-arn "$policy_arn" 2>/dev/null

                if [ $? -eq 0 ]; then
                    echo -e " ${GREEN}✅ Detached${NC}"
                    ((POLICIES_DETACHED++))
                else
                    echo -e " ${YELLOW}⚠️  Failed${NC}"
                fi
            done
        else
            echo "   No managed policies attached"
        fi

        # List and delete inline policies
        INLINE_POLICIES=$(aws iam list-role-policies \
            --role-name "$IAM_ROLE_NAME" \
            --query 'PolicyNames[*]' \
            --output text 2>/dev/null)

        if [ -n "$INLINE_POLICIES" ]; then
            for policy_name in $INLINE_POLICIES; do
                echo -n "   Deleting inline policy: $policy_name..."
                aws iam delete-role-policy \
                    --role-name "$IAM_ROLE_NAME" \
                    --policy-name "$policy_name" 2>/dev/null

                if [ $? -eq 0 ]; then
                    echo -e " ${GREEN}✅ Deleted${NC}"
                else
                    echo -e " ${YELLOW}⚠️  Failed${NC}"
                fi
            done
        fi

        echo -e "   ${GREEN}✅ IAM role prepared for deletion${NC}"
    else
        echo -e "   ${GREEN}✅ Role not found (already deleted)${NC}"
    fi
    echo ""
fi

echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}PHASE 3: REMOVE IAM INSTANCE PROFILES${NC}"
echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

PROFILES_PREPARED=0

if [ -n "$IAM_INSTANCE_PROFILE_NAME" ] && [ "$IAM_INSTANCE_PROFILE_NAME" != "" ]; then
    echo -e "${CYAN}Checking IAM instance profile: $IAM_INSTANCE_PROFILE_NAME${NC}"

    # Check if instance profile exists
    PROFILE_EXISTS=$(aws iam get-instance-profile \
        --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" 2>/dev/null && echo "yes" || echo "no")

    if [ "$PROFILE_EXISTS" = "yes" ]; then
        echo "   Instance profile found, checking associations..."

        # Remove role from instance profile
        if [ -n "$IAM_ROLE_NAME" ] && [ "$IAM_ROLE_NAME" != "" ]; then
            echo -n "   Removing role $IAM_ROLE_NAME from profile..."
            aws iam remove-role-from-instance-profile \
                --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
                --role-name "$IAM_ROLE_NAME" 2>/dev/null

            if [ $? -eq 0 ]; then
                echo -e " ${GREEN}✅ Removed${NC}"
                ((PROFILES_PREPARED++))
            else
                echo -e " ${YELLOW}⚠️  Failed or already removed${NC}"
            fi
        fi

        echo -e "   ${GREEN}✅ Instance profile prepared for deletion${NC}"
    else
        echo -e "   ${GREEN}✅ Instance profile not found (already deleted)${NC}"
    fi
    echo ""
fi

echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ PREPARATION COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Summary:"
echo "  • Instances terminated: $INSTANCES_TERMINATED"
echo "  • IAM policies detached: $POLICIES_DETACHED"
echo "  • Instance profiles prepared: $PROFILES_PREPARED"
echo ""
echo -e "${CYAN}Resources are now ready for final destruction.${NC}"
echo ""
echo -e "${YELLOW}Next step:${NC}"
echo "   ./scripts/999-destroy-all.sh"
echo ""
