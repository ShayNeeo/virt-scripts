#!/bin/bash

# ==============================================================================
# Script Name: install-incus-debian13.sh
# Description: Installs and configures Incus on Debian 13+ (Bookworm/Trixie)
#              Uses official Debian packages from apt
# OS Support:  Debian 13+ (Trixie and later)
# ==============================================================================

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Incus Installation Script for Debian 13+ ===${NC}"

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo).${NC}"
  exit 1
fi

# Check Debian version
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
if [ "$DEBIAN_VERSION" -lt 13 ]; then
    echo -e "${RED}This script is for Debian 13+ only.${NC}"
    echo -e "${YELLOW}For Debian 12 and below, use install-incus-debian12.sh${NC}"
    exit 1
fi

# ---------------------------------------------------------
# Step 1: Update System and Install Dependencies
# ---------------------------------------------------------
echo -e "\n${GREEN}[1/6] Updating system and installing dependencies...${NC}"
apt update && apt upgrade -y
apt install -y curl gpg btrfs-progs dnsmasq-base iptables nftables

# ---------------------------------------------------------
# Step 2: Enable vhost_vsock Module
# ---------------------------------------------------------
echo -e "${GREEN}[2/6] Enabling vhost_vsock kernel module...${NC}"
modprobe vhost_vsock
if ! grep -q "vhost_vsock" /etc/modules; then
    echo "vhost_vsock" >> /etc/modules
fi

# ---------------------------------------------------------
# Step 3: Install Incus from Official Debian Repositories
# ---------------------------------------------------------
echo -e "${GREEN}[3/6] Installing Incus from Debian repositories...${NC}"
apt update
apt install -y incus incus-ui-canonical

# ---------------------------------------------------------
# Step 4: Add Current User to incus-admin Group
# ---------------------------------------------------------
echo -e "${GREEN}[4/6] Configuring user permissions...${NC}"
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "root" ]; then
    adduser "$CURRENT_USER" incus-admin
    echo -e "${YELLOW}Note: You may need to log out and back in for group changes to take effect.${NC}"
    echo -e "${YELLOW}Or run: newgrp incus-admin${NC}"
else
    echo -e "${YELLOW}Running as root. Skipping user group configuration.${NC}"
fi

# ---------------------------------------------------------
# Step 5: Initialize Incus
# ---------------------------------------------------------
echo -e "${GREEN}[5/6] Initializing Incus...${NC}"
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
# Step 6: Verification
# ---------------------------------------------------------
echo -e "\n${GREEN}[6/6] Verifying installation...${NC}"
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
