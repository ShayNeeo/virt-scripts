#!/bin/bash

# ==============================================================================
# Script Name: deploy-instance.sh
# Description: Automates the creation of a Debian Trixie Incus container,
#              configures SSH proxying, and enables root password login.
# Target Arch: Oracle A1.Flex (ARM64) / x86_64
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Deploy Debian Incus Container ===${NC}"

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
read -p "Enter Debian version (trixie/bookworm/bullseye) [default: trixie]: " DEBIAN_VERSION

# Set default Debian version
DEBIAN_VERSION=${DEBIAN_VERSION:-trixie}

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
echo -e "${GREEN}Debian Version: ${DEBIAN_VERSION}${NC}"
echo -e "${GREEN}--------------------------------------------------------${NC}"

# --- 2. Container Creation ---
# Using the 'images' remote which contains the community Debian images.
echo -e "\n${GREEN}[1/5] Launching Debian ${DEBIAN_VERSION} container...${NC}"
if ! incus launch images:debian/${DEBIAN_VERSION}/cloud "$CONTAINER_NAME"; then
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
echo "  > Updating package lists..."
incus exec "$CONTAINER_NAME" -- sh -c "apt update >/dev/null 2>&1" || true

echo "  > Installing openssh-server..."
if ! incus exec "$CONTAINER_NAME" -- sh -c "apt install -y openssh-server >/dev/null 2>&1"; then
    echo -e "${YELLOW}  > Warning: SSH installation had issues, but continuing...${NC}"
fi

echo -e "${GREEN}[4/5] Configuring SSH Daemon...${NC}"
# Enable Root Login and Password Auth
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config" || true
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config" || true
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config" || true
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config" || true

echo -e "  ${GREEN}✓ SSH configured${NC}"

# --- 5. User Interaction ---
echo ""
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo -e "${YELLOW}[Action Required] Please set the root password for the container.${NC}"
echo -e "${GREEN}--------------------------------------------------------${NC}"
incus exec "$CONTAINER_NAME" -- passwd root

echo ""
echo "Restarting SSH service..."
incus exec "$CONTAINER_NAME" -- systemctl restart ssh || incus exec "$CONTAINER_NAME" -- service ssh restart || true

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
echo "  IPv4:        ${CONTAINER_IPV4}"
echo "  IPv6:        ${CONTAINER_IPV6}"
echo "  SSH Port:    ${HOST_PORT}"
echo ""
echo "Access your container via:"
echo "  ssh root@<YOUR_ORACLE_PUBLIC_IP> -p ${HOST_PORT}"
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
