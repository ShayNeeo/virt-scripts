#!/bin/bash

# ==============================================================================
# Script Name: install-dokploy.sh
# Description: Configures an Incus container for Dokploy and installs Dokploy
#              Sets up Docker with btrfs storage driver and required security settings
# OS Support:  Debian 12+ (Bookworm/Trixie)
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Dokploy Installation Script for Incus Container ===${NC}"

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
read -p "Enter the Container Name (must exist): " CONTAINER_NAME

# Validate container exists
if ! incus list -c n | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${RED}Error: Container '${CONTAINER_NAME}' does not exist.${NC}"
    echo -e "${YELLOW}Please create the container first using deploy-lxc.sh${NC}"
    exit 1
fi

# Check if container is running
if ! incus list -c ns | grep -q "${CONTAINER_NAME}.*RUNNING"; then
    echo -e "${YELLOW}Container is not running. Starting container...${NC}"
    incus start "$CONTAINER_NAME"
    sleep 3
fi

echo ""
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo -e "${GREEN}Configuring container '${CONTAINER_NAME}' for Dokploy...${NC}"
echo -e "${GREEN}--------------------------------------------------------${NC}"

# ---------------------------------------------------------
# Step 1: Configure Incus Container Security Settings
# ---------------------------------------------------------
echo -e "\n${GREEN}[1/6] Configuring Incus container security settings...${NC}"
incus config set "$CONTAINER_NAME" security.nesting=true
incus config set "$CONTAINER_NAME" security.syscalls.intercept.mknod=true
incus config set "$CONTAINER_NAME" security.syscalls.intercept.setxattr=true

# Also enable raw.idmap for better Docker compatibility
incus config set "$CONTAINER_NAME" raw.idmap="both 1000 1000" 2>/dev/null || true

echo -e "  ${GREEN}✓ Security settings configured${NC}"

# Restart container to apply security settings
echo -e "${YELLOW}  > Restarting container to apply security settings...${NC}"
incus restart "$CONTAINER_NAME"
sleep 5

# ---------------------------------------------------------
# Step 2: Update Container and Install Prerequisites
# ---------------------------------------------------------
echo -e "${GREEN}[2/6] Updating container and installing prerequisites...${NC}"
echo "  > Updating package lists..."
incus exec "$CONTAINER_NAME" -- sh -c "apt update >/dev/null 2>&1" || true

echo "  > Installing required packages..."
incus exec "$CONTAINER_NAME" -- sh -c "apt install -y curl ca-certificates gnupg lsb-release >/dev/null 2>&1" || true

echo -e "  ${GREEN}✓ Prerequisites installed${NC}"

# ---------------------------------------------------------
# Step 3: Install Docker
# ---------------------------------------------------------
echo -e "${GREEN}[3/6] Installing Docker...${NC}"

# Check if Docker is already installed
if incus exec "$CONTAINER_NAME" -- sh -c "command -v docker >/dev/null 2>&1"; then
    echo -e "${YELLOW}  > Docker is already installed, skipping installation...${NC}"
else
    echo "  > Installing Docker..."
    incus exec "$CONTAINER_NAME" -- sh -c "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh >/dev/null 2>&1" || {
        echo -e "${RED}  ✗ Failed to install Docker${NC}"
        exit 1
    }
fi

echo -e "  ${GREEN}✓ Docker installed${NC}"

# ---------------------------------------------------------
# Step 4: Configure Docker for btrfs Storage Driver
# ---------------------------------------------------------
echo -e "${GREEN}[4/6] Configuring Docker storage driver (btrfs)...${NC}"

# Create docker config directory
incus exec "$CONTAINER_NAME" -- sh -c "mkdir -p /etc/docker"

# Configure Docker daemon.json for btrfs
incus exec "$CONTAINER_NAME" -- sh -c 'cat <<EOF > /etc/docker/daemon.json
{
  "storage-driver": "btrfs"
}
EOF'

echo -e "  ${GREEN}✓ Docker daemon.json configured${NC}"

# ---------------------------------------------------------
# Step 5: Configure Docker for LXC/Incus Environment
# ---------------------------------------------------------
echo -e "${GREEN}[5/6] Configuring Docker for LXC/Incus environment...${NC}"

# Create systemd override directory
incus exec "$CONTAINER_NAME" -- sh -c "mkdir -p /etc/systemd/system/docker.service.d"

# Create LXC compatibility configuration
incus exec "$CONTAINER_NAME" -- sh -c 'cat <<EOF > /etc/systemd/system/docker.service.d/lxc.conf
[Service]
Environment="DOCKER_IGNORE_BR_NETFILTER_ERROR=1"
EOF'

echo -e "  ${GREEN}✓ Docker LXC compatibility configured${NC}"

# Restart Docker to apply configurations
echo "  > Restarting Docker service..."
incus exec "$CONTAINER_NAME" -- sh -c "systemctl daemon-reload >/dev/null 2>&1" || true
incus exec "$CONTAINER_NAME" -- sh -c "systemctl restart docker >/dev/null 2>&1" || incus exec "$CONTAINER_NAME" -- sh -c "service docker restart >/dev/null 2>&1" || true

# Wait for Docker to be ready
echo "  > Waiting for Docker to be ready..."
sleep 5

# Verify Docker is running
if incus exec "$CONTAINER_NAME" -- sh -c "docker info >/dev/null 2>&1"; then
    echo -e "  ${GREEN}✓ Docker is running${NC}"
else
    echo -e "${RED}  ✗ Docker failed to start. Please check the container logs.${NC}"
    echo -e "${YELLOW}  > You can check logs with: incus exec ${CONTAINER_NAME} -- journalctl -u docker${NC}"
    exit 1
fi

# ---------------------------------------------------------
# Step 6: Install Dokploy
# ---------------------------------------------------------
echo -e "${GREEN}[6/6] Installing Dokploy...${NC}"
echo -e "${YELLOW}  > This may take a few minutes...${NC}"

# Install Dokploy using official script
if incus exec "$CONTAINER_NAME" -- sh -c "curl -sSL https://dokploy.com/install.sh | sh"; then
    echo -e "  ${GREEN}✓ Dokploy installed successfully${NC}"
else
    echo -e "${RED}  ✗ Failed to install Dokploy${NC}"
    echo -e "${YELLOW}  > You can try installing manually inside the container${NC}"
    exit 1
fi

# ---------------------------------------------------------
# Verification and Information
# ---------------------------------------------------------
echo ""
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}--------------------------------------------------------${NC}"
echo ""

# Get container information
CONTAINER_IPV4=$(incus list "$CONTAINER_NAME" -c 4 --format csv | head -n1 | awk '{print $1}' || echo "N/A")
CONTAINER_IPV6=$(incus list "$CONTAINER_NAME" -c 6 --format csv | head -n1 | awk '{print $1}' || echo "N/A")

# Check if Dokploy is accessible
echo "Container Information:"
echo "  Name:        ${CONTAINER_NAME}"
echo "  IPv4:        ${CONTAINER_IPV4}"
echo "  IPv6:        ${CONTAINER_IPV6}"
echo ""

echo "Dokploy Access:"
echo "  Web UI:      http://${CONTAINER_IPV4}:3000"
if [ "$CONTAINER_IPV6" != "N/A" ]; then
    echo "  Web UI (v6): http://[${CONTAINER_IPV6}]:3000"
fi
echo ""

echo "Configuration Applied:"
echo "  ✓ Security nesting enabled"
echo "  ✓ Security syscalls configured"
echo "  ✓ Docker installed with btrfs storage driver"
echo "  ✓ Docker LXC compatibility enabled"
echo "  ✓ Dokploy installed"
echo ""

echo "Useful Commands:"
echo "  incus exec ${CONTAINER_NAME} -- bash          - Enter container shell"
echo "  incus exec ${CONTAINER_NAME} -- docker ps     - List Docker containers"
echo "  incus exec ${CONTAINER_NAME} -- docker logs   - View Dokploy logs"
echo "  incus restart ${CONTAINER_NAME}               - Restart container"
echo ""

echo -e "${YELLOW}Note: If you need to access Dokploy from outside, configure port forwarding:${NC}"
echo "  incus config device add ${CONTAINER_NAME} dokploy-proxy proxy \\"
echo "    listen=tcp:0.0.0.0:3000 connect=tcp:127.0.0.1:3000 bind=host"
echo ""

echo -e "${GREEN}--------------------------------------------------------${NC}"
