#!/bin/bash
set -e
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# NVIDIA Riva Conformer-CTC ASR Security Group Configuration
# Configures AWS security groups for GPU instance and buildbox
# This script provides IP management with add/delete capabilities

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

echo -e "${BLUE}🔒 Enhanced Security Group Configuration${NC}"
echo "================================================================"
echo ""
echo -e "${CYAN}Architecture Overview:${NC}"
echo "  • GPU Worker: Runs NVIDIA Riva (ports 22, 50051, 8000)"
echo "  • Build Box: Runs WebSocket bridge & demo (ports 22, 8443, 8444)"
echo ""
echo -e "${GREEN}Smart Auto-Detection:${NC}"
echo "  This script will automatically detect and configure BOTH security"
echo "  groups if they exist in your .env file. You only need to run it once!"
echo ""
echo -e "${YELLOW}Optional Flags:${NC}"
echo "  --gpu       Configure GPU instance only"
echo "  --buildbox  Configure build box only"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-005-setup-project-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Check if this is AWS deployment
if [ "$DEPLOYMENT_STRATEGY" != "1" ]; then
    echo -e "${YELLOW}⏭️  Skipping security configuration (Strategy: $DEPLOYMENT_STRATEGY)${NC}"
    echo "This step is only for AWS EC2 deployment (Strategy 1)"
    exit 0
fi

# Parse command line arguments
TARGET_MODE="auto"
while [[ $# -gt 0 ]]; do
    case $1 in
        --buildbox)
            TARGET_MODE="buildbox"
            shift
            ;;
        --gpu)
            TARGET_MODE="gpu"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Configure AWS security group firewall rules for RIVA deployment"
            echo ""
            echo "Options:"
            echo "  (none)      Configure both GPU and buildbox security groups (default)"
            echo "  --gpu       Configure GPU instance security group only"
            echo "  --buildbox  Configure buildbox/control plane security group only"
            echo "  --help      Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0              # Configure both (recommended)"
            echo "  $0 --gpu        # Configure GPU only"
            echo "  $0 --buildbox   # Configure buildbox only"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Detect available security groups
declare -a SG_TARGETS=()

if [ "$TARGET_MODE" == "auto" ]; then
    # Auto mode: detect and configure both if available
    if [ -n "$SECURITY_GROUP_ID" ]; then
        SG_TARGETS+=("gpu")
    fi
    if [ -n "$BUILDBOX_SECURITY_GROUP" ]; then
        SG_TARGETS+=("buildbox")
    fi

    if [ ${#SG_TARGETS[@]} -eq 0 ]; then
        echo -e "${RED}❌ No security groups found in configuration${NC}"
        echo "Set SECURITY_GROUP_ID and/or BUILDBOX_SECURITY_GROUP in .env"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}🎯 Auto-detected ${#SG_TARGETS[@]} security group(s) to configure:${NC}"
    for target in "${SG_TARGETS[@]}"; do
        if [ "$target" == "gpu" ]; then
            echo "  ✓ GPU Instance ($SECURITY_GROUP_ID) - ports 22, 50051, 8000"
        else
            echo "  ✓ Build Box ($BUILDBOX_SECURITY_GROUP) - ports 22, 8443, 8444"
        fi
    done
    echo ""
elif [ "$TARGET_MODE" == "gpu" ]; then
    if [ -z "$SECURITY_GROUP_ID" ]; then
        echo -e "${RED}❌ GPU security group ID not found in configuration${NC}"
        echo "SECURITY_GROUP_ID is not set in .env"
        exit 1
    fi
    SG_TARGETS=("gpu")
elif [ "$TARGET_MODE" == "buildbox" ]; then
    if [ -z "$BUILDBOX_SECURITY_GROUP" ]; then
        echo -e "${RED}❌ Buildbox security group ID not found in configuration${NC}"
        echo "BUILDBOX_SECURITY_GROUP is not set in .env"
        exit 1
    fi
    SG_TARGETS=("buildbox")
fi

# Function to get port configuration for a target
get_port_config() {
    local target=$1

    if [ "$target" == "buildbox" ]; then
        TARGET_SG="$BUILDBOX_SECURITY_GROUP"
        SG_NAME="Buildbox"

        if [[ -n "${BUILDBOX_SG_PORTS:-}" ]]; then
            IFS=',' read -ra PORTS <<< "$BUILDBOX_SG_PORTS"
            IFS=',' read -ra PORT_DESCRIPTIONS <<< "$BUILDBOX_SG_PORT_DESCRIPTIONS"
            IFS=',' read -ra PUBLIC_PORTS <<< "${BUILDBOX_SG_PUBLIC_PORTS:-}"
        else
            PORTS=(22 8443 8444)
            PORT_DESCRIPTIONS=("SSH" "WebSocket Bridge (WSS)" "HTTPS Demo Server")
            PUBLIC_PORTS=(8443 8444)
        fi
    else
        # GPU mode
        TARGET_SG="$SECURITY_GROUP_ID"
        SG_NAME="GPU Instance"

        if [[ -n "${GPU_SG_PORTS:-}" ]]; then
            IFS=',' read -ra PORTS <<< "$GPU_SG_PORTS"
            IFS=',' read -ra PORT_DESCRIPTIONS <<< "$GPU_SG_PORT_DESCRIPTIONS"
        else
            PORTS=(22 50051 8000)
            PORT_DESCRIPTIONS=("SSH" "Riva gRPC" "Riva HTTP/Health")
        fi
        PUBLIC_PORTS=()
    fi
}

# Function to display port explanations in user-friendly format
display_port_info() {
    echo -e "\n${CYAN}📚 Understanding the Ports (Think of them as doors to your server)${NC}"
    echo "================================================================"
    echo ""
    echo -e "${YELLOW}What are these ports?${NC}"
    echo "Ports are like numbered doors on your server. Each service uses a specific"
    echo "door number so clients know where to connect. Here's what each port does:"
    echo ""

    for i in "${!PORTS[@]}"; do
        local port="${PORTS[$i]}"
        local desc="${PORT_DESCRIPTIONS[$i]}"

        # Add helpful explanations for each port
        case "$port" in
            22)
                echo -e "${GREEN}Port $port - $desc${NC}"
                echo "  └─ For remote terminal access (like using SSH to log in)"
                ;;
            50051)
                echo -e "${GREEN}Port $port - $desc${NC}"
                echo "  └─ RIVA's main communication channel for speech recognition"
                ;;
            8000)
                echo -e "${GREEN}Port $port - $desc${NC}"
                echo "  └─ RIVA's web API for checking health and status"
                ;;
            8443)
                echo -e "${GREEN}Port $port - $desc${NC}"
                echo "  └─ Secure WebSocket connection for real-time audio streaming"
                ;;
            8444)
                echo -e "${GREEN}Port $port - $desc${NC}"
                echo "  └─ Secure HTTPS demo page that lets your browser use the microphone"
                ;;
            *)
                echo -e "${GREEN}Port $port - $desc${NC}"
                ;;
        esac
    done

    echo ""
    echo -e "${YELLOW}Why do I need to add my IP address?${NC}"
    echo "AWS security groups act like a bouncer at a club - they only let in people"
    echo "on the guest list. You need to add your computer's IP address to this list"
    echo "so you can access these services through your web browser or terminal."
    echo ""
}

# Function to get current machine's public IP
get_current_ip() {
    local ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
    if [ -z "$ip" ]; then
        echo "unknown"
    else
        echo "$ip"
    fi
}

# Function to list current security group rules
list_current_rules() {
    echo -e "\n${CYAN}📋 Current Security Group Rules (${SG_NAME}: ${TARGET_SG})${NC}"
    echo "================================================================"

    # Get all rules and parse them
    local rules=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$TARGET_SG" \
        --query "SecurityGroups[0].IpPermissions[]" \
        --output json 2>/dev/null)

    if [ -z "$rules" ] || [ "$rules" = "[]" ]; then
        echo -e "${YELLOW}No rules configured yet${NC}"
        return
    fi

    # Parse and display rules in a nice format
    echo -e "\n${CYAN}Configured IP Addresses:${NC}"
    echo "----------------------------------------"

    # Get unique IPs across all ports
    local unique_ips=$(echo "$rules" | jq -r '.[].IpRanges[].CidrIp' 2>/dev/null | sed 's|/32||g' | sort -u)

    if [ -z "$unique_ips" ]; then
        echo "No IP addresses configured"
        return
    fi

    local index=1
    declare -gA IP_INDEX_MAP
    declare -ga IP_ARRAY

    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        IP_ARRAY[$index]="$ip"
        IP_INDEX_MAP["$ip"]=$index

        # Check which ports this IP can access
        local accessible_ports=""
        for port in "${PORTS[@]}"; do
            if echo "$rules" | jq -e ".[] | select(.FromPort == $port) | .IpRanges[] | select(.CidrIp == \"${ip}/32\")" > /dev/null 2>&1; then
                accessible_ports="${accessible_ports}${port} "
            fi
        done

        # Get description if available from .env
        local description=""
        if grep -q "$ip" "$ENV_FILE" 2>/dev/null; then
            description=$(grep -A1 "AUTHORIZED_IPS_LIST" "$ENV_FILE" | grep "DESCRIPTIONS" | sed "s/.*=\"//" | sed "s/\"$//" | awk -v ip="$ip" '{
                split($0, descs, " ");
                split("'"$(grep "AUTHORIZED_IPS_LIST" "$ENV_FILE" | sed "s/.*=\"//" | sed "s/\"$//")"'", ips, " ");
                for(i in ips) if(ips[i] == ip) print descs[i];
            }')
        fi

        printf "  ${YELLOW}%2d.${NC} %-18s ${CYAN}Ports:${NC} %-30s %s\n" \
            "$index" "$ip" "$accessible_ports" "${description:+(${description})}"

        ((index++))
    done <<< "$unique_ips"

    echo ""
}

# Function to delete selected IPs
delete_selected_ips() {
    if [ ${#IP_ARRAY[@]} -eq 0 ]; then
        echo -e "${YELLOW}No IPs to delete${NC}"
        return
    fi

    echo -e "\n${YELLOW}⚠️  Delete Existing IP Addresses${NC}"
    echo "----------------------------------------"
    read -p "Do you want to remove any existing IPs? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Keeping all existing IPs${NC}"
        return
    fi

    echo -e "\nEnter the ${YELLOW}NUMBERS${NC} of IPs to delete (not the IP addresses themselves)"
    echo "Example: To delete IPs #1 and #3, enter: 1,3"
    echo "Or type 'all' to remove all IPs:"
    read -p "Enter number(s) or 'all': " delete_selection

    local ips_to_delete=()

    if [ "$delete_selection" = "all" ]; then
        ips_to_delete=("${IP_ARRAY[@]}")
    else
        # Parse comma-separated numbers
        IFS=',' read -ra SELECTIONS <<< "$delete_selection"
        for sel in "${SELECTIONS[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${IP_ARRAY[$sel]}" ]; then
                ips_to_delete+=("${IP_ARRAY[$sel]}")
            fi
        done
    fi

    if [ ${#ips_to_delete[@]} -eq 0 ]; then
        echo -e "${YELLOW}No valid selections made${NC}"
        return
    fi

    # Confirm deletion
    echo -e "\n${RED}Will delete the following IPs:${NC}"
    for ip in "${ips_to_delete[@]}"; do
        echo "  • $ip"
    done

    read -p "Confirm deletion? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Deletion cancelled${NC}"
        return
    fi

    # Delete the IPs from all ports
    echo -e "\n${CYAN}Removing selected IPs...${NC}"
    for ip in "${ips_to_delete[@]}"; do
        echo -n "  Removing $ip from all ports..."
        for port in "${PORTS[@]}"; do
            # SPECIAL CASE: Handle 0.0.0.0/0 (anywhere) vs regular IPs
            # The sed command earlier (line 89) only strips /32, but leaves /0 intact
            # So 0.0.0.0/0 stays as "0.0.0.0/0" while 3.16.124.227/32 becomes "3.16.124.227"
            # We need to handle both cases correctly for AWS deletion
            if [ "$ip" = "0.0.0.0/0" ]; then
                cidr="0.0.0.0/0"  # Keep "anywhere" CIDR as-is
            else
                cidr="${ip}/32"   # Regular single-host CIDR notation
            fi

            # Show the actual AWS command output so we can see if it succeeds or fails
            aws ec2 revoke-security-group-ingress \
                --region "$AWS_REGION" \
                --group-id "$TARGET_SG" \
                --protocol tcp \
                --port "$port" \
                --cidr "$cidr" || echo "  (rule may not exist for port $port)"
        done
        echo -e " ${GREEN}✓${NC}"
    done
}

# Function to add an IP to all required ports
add_ip_to_ports() {
    local ip=$1
    local description=$2

    echo -n "  Adding $ip ${description:+(${description})}..."

    local success=true
    for port in "${PORTS[@]}"; do
        if ! aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$TARGET_SG" \
            --protocol tcp \
            --port "$port" \
            --cidr "${ip}/32" 2>&1 | grep -q "already exists\|Success"; then
            success=false
        fi
    done

    if $success; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}(some rules already existed)${NC}"
    fi
}

# Function to configure public access for specific ports (buildbox only)
configure_public_ports() {
    if [ ${#PUBLIC_PORTS[@]} -eq 0 ]; then
        return
    fi

    echo -e "\n${CYAN}🌍 Public Access Configuration${NC}"
    echo "----------------------------------------"
    echo "The following ports need to be accessible from anywhere (0.0.0.0/0)"
    echo "for browser clients to connect:"
    for port in "${PUBLIC_PORTS[@]}"; do
        local port_name=""
        for i in "${!PORTS[@]}"; do
            if [ "${PORTS[$i]}" = "$port" ]; then
                port_name="${PORT_DESCRIPTIONS[$i]}"
                break
            fi
        done
        echo "  • Port $port - $port_name"
    done
    echo ""
    read -p "Configure public access for these ports? (Y/n): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Skipping public access configuration${NC}"
        return
    fi

    echo -e "\n${CYAN}Opening ports to public access...${NC}"
    for port in "${PUBLIC_PORTS[@]}"; do
        echo -n "  Opening port $port to 0.0.0.0/0..."
        if aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$TARGET_SG" \
            --protocol tcp \
            --port "$port" \
            --cidr "0.0.0.0/0" 2>&1 | grep -q "already exists\|Success"; then
            echo -e " ${GREEN}✓${NC}"
        else
            echo -e " ${YELLOW}(already open)${NC}"
        fi
    done
}

# Function to save configuration to .env
save_configuration() {
    local ips="$1"
    local descriptions="$2"

    # Update or add the configuration
    if grep -q "^AUTHORIZED_IPS_LIST=" "$ENV_FILE"; then
        sed -i "s|^AUTHORIZED_IPS_LIST=.*|AUTHORIZED_IPS_LIST=\"$ips\"|" "$ENV_FILE"
        sed -i "s|^AUTHORIZED_IPS_DESCRIPTIONS=.*|AUTHORIZED_IPS_DESCRIPTIONS=\"$descriptions\"|" "$ENV_FILE"
    else
        echo "" >> "$ENV_FILE"
        echo "# Security Configuration (added by enhanced security script)" >> "$ENV_FILE"
        echo "AUTHORIZED_IPS_LIST=\"$ips\"" >> "$ENV_FILE"
        echo "AUTHORIZED_IPS_DESCRIPTIONS=\"$descriptions\"" >> "$ENV_FILE"
        echo "SECURITY_CONFIGURED=true" >> "$ENV_FILE"
    fi
}

# Function to configure a single security group
configure_security_group() {
    local target=$1
    local collected_ips="$2"
    local collected_descriptions="$3"

    # Load port configuration for this target
    get_port_config "$target"

    echo ""
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Configuring: ${SG_NAME}${NC}"
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo "  • Security Group: ${TARGET_SG}"
    echo "  • AWS Region: $AWS_REGION"
    echo "  • Ports: ${PORTS[*]}"
    if [ ${#PUBLIC_PORTS[@]} -gt 0 ]; then
        echo "  • Public Ports: ${PUBLIC_PORTS[*]} (0.0.0.0/0)"
    fi

    # Display user-friendly port information
    display_port_info

    # Step 1: List current rules
    list_current_rules

    # Step 2: Optional - Delete existing IPs
    delete_selected_ips

    # Step 3: Apply collected IPs to this security group
    if [ -n "$collected_ips" ]; then
        echo -e "\n${CYAN}Adding authorized IPs to ${SG_NAME}...${NC}"
        # Parse the IPs and descriptions
        IFS=' ' read -ra ip_array <<< "$collected_ips"
        IFS=' ' read -ra desc_array <<< "$collected_descriptions"

        for i in "${!ip_array[@]}"; do
            add_ip_to_ports "${ip_array[$i]}" "${desc_array[$i]:-}"
        done
    fi

    # Step 4: Configure public access for buildbox ports
    configure_public_ports

    # Step 5: Final verification
    echo -e "\n${BLUE}🔍 ${SG_NAME} Final Configuration${NC}"
    echo "================================================================"

    # Get all rules and display them properly
    echo "Configured Security Rules:"
    echo "-------------------------"
    aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$TARGET_SG" \
        --output json 2>/dev/null | jq -r '
        .SecurityGroups[0].IpPermissions[] |
        "Port \(.FromPort): \([.IpRanges[].CidrIp] | join(", "))"
        ' | sort -n | while read rule; do
        echo "  $rule"
    done

    echo ""
    echo "Summary by IP Address:"
    echo "---------------------"
    # Get unique IPs and show what ports they can access
    aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$TARGET_SG" \
        --output json 2>/dev/null | jq -r '
        .SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp
        ' | sort -u | while read ip; do
        clean_ip=$(echo "$ip" | sed 's|/32||')
        ports=$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --group-ids "$TARGET_SG" \
            --output json 2>/dev/null | jq -r --arg ip "$ip" '
            .SecurityGroups[0].IpPermissions[] |
            select(.IpRanges[].CidrIp == $ip) | .FromPort
            ' | sort -n | tr '\n' ' ')
        echo "  ${clean_ip}: ports ${ports}"
    done

    echo -e "\n${GREEN}✅ ${SG_NAME} Configuration Complete!${NC}"
    echo "================================================================"
}

# Main execution - Collect IPs once
echo ""
echo -e "${CYAN}📋 IP Address Collection (applies to all security groups)${NC}"
echo "================================================================"

# Note for users about public access
if [ "${#SG_TARGETS[@]}" -gt 1 ] || [[ " ${SG_TARGETS[@]} " =~ " buildbox " ]]; then
    echo ""
    echo -e "${YELLOW}💡 Note about browser access:${NC}"
    echo "Ports 8443 and 8444 will be opened to everyone (0.0.0.0/0) on the build box."
    echo "You only need to add IPs here for SSH/admin access, NOT for browser clients."
    echo ""
fi

# Step 1: Auto-detect and collect current IP
CURRENT_IP=$(get_current_ip)
echo -e "\n${CYAN}🌐 Current Machine IP Detection${NC}"
echo "----------------------------------------"
echo -e "Your current public IP: ${GREEN}$CURRENT_IP${NC}"

if [ "$CURRENT_IP" != "unknown" ]; then
    read -p "Add this IP to security groups? (Y/n): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        read -p "Enter a description for this IP (e.g., 'LLM-EC2', 'Home-MacBook'): " current_ip_desc
        current_ip_desc=${current_ip_desc:-"Current-Machine"}

        ALL_IPS="$CURRENT_IP"
        ALL_DESCRIPTIONS="$current_ip_desc"
    fi
fi

# Step 2: Check if we should add GPU instance's own IP (best practice)
if [ -n "$GPU_INSTANCE_IP" ] && [ "$GPU_INSTANCE_IP" != "$CURRENT_IP" ]; then
    echo -e "\n${CYAN}🖥️ GPU Instance IP${NC}"
    echo "----------------------------------------"
    echo -e "GPU Instance IP: ${GREEN}$GPU_INSTANCE_IP${NC}"
    echo -e "${YELLOW}Note: Adding the GPU instance's own IP is a best practice${NC}"
    echo "This ensures internal services can communicate properly."

    read -p "Add GPU instance IP to security groups? (Y/n): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        ALL_IPS="${ALL_IPS:+$ALL_IPS }$GPU_INSTANCE_IP"
        ALL_DESCRIPTIONS="${ALL_DESCRIPTIONS:+$ALL_DESCRIPTIONS }GPU-Instance"
    fi
fi

# Step 3: Collect additional IPs
echo -e "\n${CYAN}📝 Additional IP Addresses${NC}"
echo "----------------------------------------"
read -p "Do you want to add more IPs? (y/N): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "\nEnter IP addresses one at a time (press Enter with empty input when done):"

    while true; do
        read -p "IP Address (or press Enter to finish): " new_ip

        [ -z "$new_ip" ] && break

        # Validate IP format
        if [[ ! "$new_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}Invalid IP format. Please use XXX.XXX.XXX.XXX${NC}"
            continue
        fi

        read -p "Description for $new_ip: " new_ip_desc
        new_ip_desc=${new_ip_desc:-"Custom"}

        ALL_IPS="${ALL_IPS:+$ALL_IPS }$new_ip"
        ALL_DESCRIPTIONS="${ALL_DESCRIPTIONS:+$ALL_DESCRIPTIONS }$new_ip_desc"
    done
fi

# Step 4: Configure each security group
for target in "${SG_TARGETS[@]}"; do
    configure_security_group "$target" "$ALL_IPS" "$ALL_DESCRIPTIONS"
done

# Step 5: Save configuration
if [ -n "$ALL_IPS" ]; then
    echo -e "\n${CYAN}💾 Saving configuration...${NC}"
    save_configuration "$ALL_IPS" "$ALL_DESCRIPTIONS"
    echo -e "${GREEN}✓ Configuration saved${NC}"
fi

# Final Summary
echo ""
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ ALL SECURITY GROUPS CONFIGURED SUCCESSFULLY!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Summary:${NC}"
echo "  • Configured ${#SG_TARGETS[@]} security group(s)"
if [ -n "$ALL_IPS" ]; then
    echo "  • Added $(echo "$ALL_IPS" | wc -w) authorized IP(s) for SSH/admin access"
fi
for target in "${SG_TARGETS[@]}"; do
    if [ "$target" == "buildbox" ]; then
        echo "  • Build Box: Ports 8443, 8444 open to public (0.0.0.0/0)"
    fi
done
echo ""
echo -e "${YELLOW}⚠️  Important Notes:${NC}"
echo "  • Security group changes may take 30-60 seconds to propagate"
echo "  • To modify configuration later, run this script again"
if [[ " ${SG_TARGETS[@]} " =~ " buildbox " ]]; then
    echo "  • Browser clients (phone, laptop) can access ports 8443/8444 without IP whitelisting"
fi
echo ""
echo -e "${CYAN}🎯 Next Steps:${NC}"
if [[ " ${SG_TARGETS[@]} " =~ " buildbox " ]]; then
    echo "  • Access demo: https://${BUILDBOX_PUBLIC_IP:-<buildbox-ip>}:8444/demo.html"
fi
if [[ " ${SG_TARGETS[@]} " =~ " gpu " ]]; then
    echo "  • Deploy model: ./scripts/110-deploy-conformer-streaming.sh"
    echo "  • Check status: ./scripts/750-status-gpu-instance.sh"
fi
echo "================================================================"