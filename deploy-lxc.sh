#!/bin/bash

# ==============================================================================
# Script Name: deploy-lxc.sh
# Description: Automates the creation of Linux Incus containers (Debian/Ubuntu/Alpine),
#              configures SSH proxying with flexible authentication (password/SSH key/both)
# Target Arch: Oracle A1.Flex (ARM64) / x86_64
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Deploy Linux Incus Container ===${NC}"

# Check if Incus is installed
if ! command -v incus >/dev/null 2>&1; then
    echo -e "${RED}Incus is not installed. Please run install-incus-debian13.sh or install-incus-debian12.sh first.${NC}"
    exit 1
fi

# Check if Incus is initialized
if ! incus list >/dev/null 2>&1; then
    echo -e "${RED}Incus is not initialized. Please run 'incus admin init' first.${NC}"
    exit 1
fi

# --- 1. User Input ---
echo ""
read -p "Enter the new Container Name: " CONTAINER_NAME
read -p "Enter the Host Port for SSH Proxy (e.g., 2222): " HOST_PORT

# OS Selection
echo ""
echo -e "${YELLOW}Select container OS:${NC}"
echo "  1) Debian"
echo "  2) Ubuntu"
echo "  3) Alpine"
read -p "Enter choice [1, 2, or 3]: " OS_CHOICE

if [[ ! "$OS_CHOICE" =~ ^[123]$ ]]; then
    echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${NC}"
    exit 1
fi

# Version selection based on OS
case "$OS_CHOICE" in
    1)
        OS_TYPE="debian"
        echo ""
        read -p "Enter Debian version (trixie/bookworm/bullseye) [default: trixie]: " OS_VERSION
        OS_VERSION=${OS_VERSION:-trixie}
        IMAGE_NAME="images:debian/${OS_VERSION}/cloud"
        ;;
    2)
        OS_TYPE="ubuntu"
        echo ""
        read -p "Enter Ubuntu version (24.04/22.04/20.04) [default: 24.04]: " OS_VERSION
        OS_VERSION=${OS_VERSION:-24.04}
        IMAGE_NAME="images:ubuntu/${OS_VERSION}/cloud"
        ;;
    3)
        OS_TYPE="alpine"
        echo ""
        read -p "Enter Alpine version (3.19/3.18/edge) [default: 3.19]: " OS_VERSION
        OS_VERSION=${OS_VERSION:-3.19}
        IMAGE_NAME="images:alpine/${OS_VERSION}"
        ;;
esac

# Authentication method selection
echo ""
echo -e "${YELLOW}Select authentication method:${NC}"
echo "  1) Password only"
echo "  2) SSH key only"
echo "  3) Both password and SSH key"
read -p "Enter choice [1, 2, or 3]: " AUTH_METHOD

if [[ ! "$AUTH_METHOD" =~ ^[123]$ ]]; then
    echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${NC}"
    exit 1
fi

# Get SSH public key if needed
SSH_PUBLIC_KEY=""
if [ "$AUTH_METHOD" -eq 2 ] || [ "$AUTH_METHOD" -eq 3 ]; then
    echo ""
    echo -e "${YELLOW}Please paste your SSH public key:${NC}"
    echo "  (Example: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@host)"
    read -p "SSH Public Key: " SSH_PUBLIC_KEY
    
    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        echo -e "${RED}Error: SSH public key is required for this authentication method.${NC}"
        exit 1
    fi
    
    # Basic validation - check if it starts with ssh-rsa, ssh-ed25519, ecdsa, etc.
    if [[ ! "$SSH_PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-dss) ]]; then
        echo -e "${YELLOW}Warning: The key format may be invalid. Continuing anyway...${NC}"
    fi
fi

# Basic Input Validation
if [[ -z "$CONTAINER_NAME" || -z "$HOST_PORT" ]]; then
    echo -e "${RED}Error: Container Name and Host Port are required.${NC}"
    exit 1
fi

# Validate port is a number
if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: Host Port must be a number.${NC}"
    exit 1
fi

# Check if container name already exists
if incus list -c n | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${RED}Error: Container '${CONTAINER_NAME}' already exists.${NC}"
    exit 1
fi

# Check if port is in use on the host
if ss -tuln | grep -q ":$HOST_PORT "; then
    echo -e "${RED}Error: Port $HOST_PORT is already in use on the host.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo -e "${GREEN}Initializing deployment for '${CONTAINER_NAME}' on Port ${HOST_PORT}...${NC}"
echo -e "${GREEN}OS: ${OS_TYPE^} ${OS_VERSION}${NC}"
echo -e "${GREEN}--------------------------------------------------------${NC}"

# --- 2. Container Creation ---
# Using the 'images' remote which contains community Linux images.
echo -e "\n${GREEN}[1/5] Launching ${OS_TYPE^} ${OS_VERSION} container...${NC}"
if ! incus launch "$IMAGE_NAME" "$CONTAINER_NAME"; then
    echo -e "${RED}Error: Failed to launch container. Check if the image exists.${NC}"
    exit 1
fi

# Wait for container to be fully running and have network
echo -e "${GREEN}[2/5] Waiting for networking initialization...${NC}"
sleep 5

# Verify container is running
if ! incus list -c ns | grep -q "${CONTAINER_NAME}.*RUNNING"; then
    echo -e "${YELLOW}Warning: Container may not be fully started. Continuing anyway...${NC}"
fi

# --- 3. Network Configuration (Proxy Device) ---
# We use a proxy device to avoid NAT complexity.
# Traffic hitting Host:HOST_PORT is forwarded to Container:22.
echo -e "${GREEN}[3/5] Configuring SSH Proxy Device...${NC}"
if incus config device show "$CONTAINER_NAME" | grep -q "ssh-proxy"; then
    echo -e "${YELLOW}  > SSH proxy device already exists, removing old one...${NC}"
    incus config device remove "$CONTAINER_NAME" ssh-proxy 2>/dev/null || true
fi

incus config device add "$CONTAINER_NAME" ssh-proxy proxy \
    listen=tcp:0.0.0.0:"$HOST_PORT" \
    connect=tcp:127.0.0.1:22 \
    bind=host

echo -e "  ${GREEN}✓ SSH proxy configured on port ${HOST_PORT}${NC}"

# --- 4. System Provisioning ---
echo -e "${GREEN}[4/5] Updating system and installing SSH...${NC}"

# Install SSH based on OS type
if [ "$OS_TYPE" = "alpine" ]; then
    # Alpine uses apk
    echo "  > Updating package index..."
    incus exec "$CONTAINER_NAME" -- sh -c "apk update >/dev/null 2>&1" || true
    
    echo "  > Installing openssh..."
    if ! incus exec "$CONTAINER_NAME" -- sh -c "apk add -q openssh >/dev/null 2>&1"; then
        echo -e "${YELLOW}  > Warning: SSH installation had issues, but continuing...${NC}"
    fi
    
    # Alpine needs sshd service enabled
    incus exec "$CONTAINER_NAME" -- sh -c "rc-update add sshd 2>/dev/null || true" || true
else
    # Debian/Ubuntu use apt
    echo "  > Updating package lists..."
    incus exec "$CONTAINER_NAME" -- sh -c "apt update >/dev/null 2>&1" || true
    
    echo "  > Installing openssh-server..."
    if ! incus exec "$CONTAINER_NAME" -- sh -c "apt install -y openssh-server >/dev/null 2>&1"; then
        echo -e "${YELLOW}  > Warning: SSH installation had issues, but continuing...${NC}"
    fi
fi

echo -e "${GREEN}[4/5] Configuring SSH Daemon...${NC}"

# Configure SSH based on authentication method
if [ "$AUTH_METHOD" -eq 1 ]; then
    # Password only
    echo "  > Configuring for password authentication only..."
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication no/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PubkeyAuthentication yes/PubkeyAuthentication no/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "echo 'PubkeyAuthentication no' >> /etc/ssh/sshd_config" || true
    
elif [ "$AUTH_METHOD" -eq 2 ]; then
    # SSH key only
    echo "  > Configuring for SSH key authentication only..."
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config" || true
    
    # Setup SSH directory and authorized_keys
    echo "  > Setting up SSH key..."
    incus exec "$CONTAINER_NAME" -- sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    incus exec "$CONTAINER_NAME" -- sh -c "echo '${SSH_PUBLIC_KEY}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    
else
    # Both password and SSH key
    echo "  > Configuring for both password and SSH key authentication..."
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config" || true
    incus exec "$CONTAINER_NAME" -- sh -c "echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config" || true
    
    # Setup SSH directory and authorized_keys
    echo "  > Setting up SSH key..."
    incus exec "$CONTAINER_NAME" -- sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    incus exec "$CONTAINER_NAME" -- sh -c "echo '${SSH_PUBLIC_KEY}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
fi

echo -e "  ${GREEN}✓ SSH configured${NC}"

# --- 5. User Interaction (Password Setup) ---
if [ "$AUTH_METHOD" -eq 1 ] || [ "$AUTH_METHOD" -eq 3 ]; then
    echo ""
    echo -e "${GREEN}--------------------------------------------------------${NC}"
    echo -e "${YELLOW}[Action Required] Please set the root password for the container.${NC}"
    echo -e "${GREEN}--------------------------------------------------------${NC}"
    incus exec "$CONTAINER_NAME" -- passwd root
fi

echo ""
echo "Restarting SSH service..."
# Restart SSH service based on OS type
if [ "$OS_TYPE" = "alpine" ]; then
    incus exec "$CONTAINER_NAME" -- sh -c "rc-service sshd restart 2>/dev/null || service sshd restart 2>/dev/null || true" || true
else
    incus exec "$CONTAINER_NAME" -- sh -c "systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true" || true
fi

# Get container IP addresses
CONTAINER_IPV4=$(incus list "$CONTAINER_NAME" -c 4 --format csv | head -n1 | awk '{print $1}' || echo "N/A")
CONTAINER_IPV6=$(incus list "$CONTAINER_NAME" -c 6 --format csv | head -n1 | awk '{print $1}' || echo "N/A")

echo ""
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo ""
echo "Container Information:"
echo "  Name:        ${CONTAINER_NAME}"
echo "  OS:          ${OS_TYPE^} ${OS_VERSION}"
echo "  IPv4:        ${CONTAINER_IPV4}"
echo "  IPv6:        ${CONTAINER_IPV6}"
echo "  SSH Port:    ${HOST_PORT}"
echo ""
echo "Access your container via:"
if [ "$AUTH_METHOD" -eq 1 ]; then
    echo "  ssh root@<YOUR_PUBLIC_IP> -p ${HOST_PORT}"
    echo "  (Use password authentication)"
elif [ "$AUTH_METHOD" -eq 2 ]; then
    echo "  ssh root@<YOUR_PUBLIC_IP> -p ${HOST_PORT}"
    echo "  (Use SSH key authentication)"
else
    echo "  ssh root@<YOUR_PUBLIC_IP> -p ${HOST_PORT}"
    echo "  (Use password or SSH key authentication)"
fi
echo ""
echo "Or from within the host:"
echo "  incus exec ${CONTAINER_NAME} -- bash"
echo ""
echo "Useful commands:"
echo "  incus list                    - List all containers"
echo "  incus stop ${CONTAINER_NAME}  - Stop the container"
echo "  incus start ${CONTAINER_NAME} - Start the container"
echo "  incus delete ${CONTAINER_NAME} - Delete the container"
echo -e "${GREEN}--------------------------------------------------------${NC}"
