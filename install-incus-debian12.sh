#!/bin/bash

# ==============================================================================
# Script Name: install-incus-debian12.sh
# Description: Installs and configures Incus on Debian 12 and below
#              Uses Zabbly repository for Incus packages
# OS Support:  Debian 12 (Bookworm) and earlier
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Incus Installation Script for Debian 12- ===${NC}"

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo).${NC}"
  exit 1
fi

# Check Debian version
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
if [ "$DEBIAN_VERSION" -ge 13 ]; then
    echo -e "${YELLOW}You are running Debian 13+.${NC}"
    echo -e "${YELLOW}For Debian 13+, use install-incus-debian13.sh (uses official apt packages)${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ---------------------------------------------------------
# Step 1: Update System and Install Dependencies
# ---------------------------------------------------------
echo -e "\n${GREEN}[1/7] Updating system and installing dependencies...${NC}"
apt update && apt upgrade -y
apt install -y curl gpg btrfs-progs dnsmasq-base iptables nftables

# ---------------------------------------------------------
# Step 2: Enable vhost_vsock Module
# ---------------------------------------------------------
echo -e "${GREEN}[2/7] Enabling vhost_vsock kernel module...${NC}"
modprobe vhost_vsock
if ! grep -q "vhost_vsock" /etc/modules; then
    echo "vhost_vsock" >> /etc/modules
fi

# ---------------------------------------------------------
# Step 3: Add Zabbly GPG Key
# ---------------------------------------------------------
echo -e "${GREEN}[3/7] Adding Zabbly GPG key...${NC}"
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc

# ---------------------------------------------------------
# Step 4: Add Zabbly Repository
# ---------------------------------------------------------
echo -e "${GREEN}[4/7] Adding Zabbly Incus repository...${NC}"
sh -c 'cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc

EOF'

# ---------------------------------------------------------
# Step 5: Install Incus from Zabbly Repository
# ---------------------------------------------------------
echo -e "${GREEN}[5/7] Installing Incus from Zabbly repository...${NC}"
apt update
apt install -y incus incus-ui-canonical

# ---------------------------------------------------------
# Step 6: Add Current User to incus-admin Group
# ---------------------------------------------------------
echo -e "${GREEN}[6/7] Configuring user permissions...${NC}"
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "root" ]; then
    adduser "$CURRENT_USER" incus-admin
    echo -e "${YELLOW}Note: You may need to log out and back in for group changes to take effect.${NC}"
    echo -e "${YELLOW}Or run: newgrp incus-admin${NC}"
else
    echo -e "${YELLOW}Running as root. Skipping user group configuration.${NC}"
fi

# ---------------------------------------------------------
# Step 7: Initialize Incus
# ---------------------------------------------------------
echo -e "${GREEN}[7/7] Initializing Incus...${NC}"
echo -e "${YELLOW}You will be prompted to configure Incus. Recommended settings:${NC}"
echo "  - Clustering: no"
echo "  - New local storage pool: yes"
echo "  - Name of storage pool: default"
echo "  - Storage backend: btrfs"
echo "  - Create a new loop device: yes"
echo "  - Size of the new loop device: 30GiB (or as needed)"
echo "  - Configure a new network bridge: yes"
echo "  - Network bridge name: incusbr0"
echo "  - IPv4 address: auto (enables NAT)"
echo "  - IPv6 address: (configure as needed)"
echo "  - IPv6 NAT: true (recommended for OCI)"
echo "  - Make the bridge available to other computers: no"
echo "  - Update-profile default: yes"
echo ""
read -p "Press Enter to start initialization..."

incus admin init

# ---------------------------------------------------------
# Step 8: Verification
# ---------------------------------------------------------
echo -e "\n${GREEN}[8/8] Verifying installation...${NC}"
if incus list >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Incus is installed and configured successfully!${NC}"
    echo ""
    echo "Useful commands:"
    echo "  incus list              - List all containers"
    echo "  incus launch images:debian/trixie/cloud <name>  - Launch a container"
    echo "  incus network list      - List networks"
    echo "  incus storage list     - List storage pools"
else
    echo -e "${RED}✗ Incus initialization may have failed. Please check the output above.${NC}"
    exit 1
fi

echo -e "\n${GREEN}=== Installation Complete ===${NC}"
