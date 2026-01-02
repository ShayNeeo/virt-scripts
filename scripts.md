Install
---
```
apt update && apt upgrade -y
apt install -y curl gpg btrfs-progs dnsmasq-base iptables nftables

modprobe vhost_vsock
echo "vhost_vsock" >> /etc/modules

mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc

sh -c 'cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc

EOF'
apt update
apt install -y incus incus-ui-canonical
adduser $(whoami) incus-admin
newgrp incus-admin # Apply changes immediately
incus admin init
```
- **Clustering:** `no`
    
- **New local storage pool:** `yes`
    
- **Name of storage pool:** `default`
    
- **Storage backend:** `btrfs`
    
- **Create a new loop device:** `yes`
    
- **Size of the new loop device:** `30GiB` (Or whatever space you can spare; OCI Free Tier boot volumes are usually ~47GB).
    
- **Configure a new network bridge:** `yes`
    
- **Network bridge name:** `incusbr0`
    
- **IPv4 address:** `auto` (This enables NAT).
    
- **IPv6 address:** `2603:c024:4518:1400:1:1::1/96`
    
    - _Note:_ We are explicitly defining the gateway IP and the CIDR.
        
- **IPv6 NAT:** `true`
    
    - _Why NAT?_ Even with a public block, OCI networking infrastructure handles routing strictly. Enabling NAT on IPv6 ensures container egress works immediately. If you wish to make them publicly routable without NAT later, we can modify the profile, but we would need to add NDP Proxy rules.
        
- **Make the bridge available to other computers:** `no` (Unless you have a specific VLAN setup).
    
- **Update-profile default:** `yes`
Prompt
---
```
help me install incus in Oracle A1.Flex shape instance from scratch.
Using IPv4 NAT and IPv6 (for later assigning to Containers). Help me
install from scratch (BTRFS install packages guide too). It is running
Debian 13. These are IPs assigned to my Instance: Ipv4: 138.2.102.216; IPv6: 2603:c024:4518:1400:1::/80
```
Create SSH
---
```
# Update and install SSH
apt update && apt install openssh-server -y

# Set a root password so you can log in
passwd root

# Allow root login via password
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Restart SSH to apply changes
systemctl restart ssh
exit
```

Dokploy
---

Automated installation script: `install-dokploy.sh`

This script automatically:
- Configures Incus container security settings (nesting, syscalls)
- Installs Docker with btrfs storage driver
- Configures Docker for LXC/Incus compatibility
- Installs Dokploy using the official installer

**Usage:**
```bash
./install-dokploy.sh
```

**Manual Configuration (if needed):**

1. Configure Incus container security:
```bash
incus config set <container-name> security.nesting=true
incus config set <container-name> security.syscalls.intercept.mknod=true
incus config set <container-name> security.syscalls.intercept.setxattr=true
```

2. Configure Docker daemon.json (inside container):
```bash
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "storage-driver": "btrfs"
}
EOF
```

3. Configure Docker for LXC/Incus (inside container):
```bash
mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF > /etc/systemd/system/docker.service.d/lxc.conf
[Service]
Environment="DOCKER_IGNORE_BR_NETFILTER_ERROR=1"
EOF
systemctl daemon-reload
systemctl restart docker
```

4. Install Dokploy (inside container):
```bash
curl -sSL https://dokploy.com/install.sh | sh
```

**Access Dokploy:**
- Web UI: `http://<container-ip>:3000`
- Configure port forwarding for external access:
```bash
incus config device add <container-name> dokploy-proxy proxy \
  listen=tcp:0.0.0.0:3000 connect=tcp:127.0.0.1:3000 bind=host
```

IPv6-Incus
---
```
#!/bin/bash

# ==============================================================================
# Script Name: ipv6-setup.sh
# Description: Enables Routed IPv6 (Stateful DHCP) for Incus on Oracle Cloud
# OS Support:  Debian 13 (Testing) / Debian 12
# Author:      Incus Expert System
# ==============================================================================

set -e

# --- Configuration ---
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
INCUS_BRIDGE="incusbr0"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Incus IPv6 Routed Setup (Oracle A1.Flex) ===${NC}"

# 1. Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root.${NC}"
  exit 1
fi

# 2. Input Prompt
echo "Please enter your Oracle IPv6 /80 Prefix."
echo "Example: 2603:c024:4518:1400:1::"
read -p "Prefix: " USER_PREFIX

if [[ ! "$USER_PREFIX" =~ : ]]; then
    echo -e "${RED}Invalid IPv6 format.${NC}"
    exit 1
fi

# Clean input
CLEAN_PREFIX=$(echo "$USER_PREFIX" | sed 's|/80||g' | sed 's|::$||g')

# Define Subnets
HOST_IP="${CLEAN_PREFIX}::1"
BRIDGE_SUBNET="${CLEAN_PREFIX}:1::1/96"
HOST_SUBNET="${CLEAN_PREFIX}::/80"

echo -e "\nConfiguration Target:"
echo -e "  Interface:      ${DEFAULT_IFACE}"
echo -e "  Host IP:        ${HOST_IP} (/128)"
echo -e "  Incus Subnet:   ${BRIDGE_SUBNET}"
echo -e "----------------------------------------"
read -p "Press Enter to apply..."

# ---------------------------------------------------------
# Step 1: Kernel Configuration (Sysctl)
# ---------------------------------------------------------
echo -e "\n${GREEN}[1/5] Configuring Kernel Parameters...${NC}"
cat <<EOF > /etc/sysctl.d/99-oci-incus-ipv6.conf
# Enable Forwarding (Router Mode)
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.${DEFAULT_IFACE}.forwarding=1

# Accept RA (Client Mode) - REQUIRED for OCI
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv6.conf.${DEFAULT_IFACE}.accept_ra=2
EOF

sysctl --system > /dev/null

# ---------------------------------------------------------
# Step 2: Host Network Configuration
# ---------------------------------------------------------
echo -e "${GREEN}[2/5] Configuring Host Network...${NC}"

# Flush old IPs to ensure clean slate
ip -6 addr flush dev "$DEFAULT_IFACE" scope global

# Add Host IP as /128 (Prevents "Whole Subnet" ownership)
ip -6 addr add "${HOST_IP}/128" dev "$DEFAULT_IFACE"

# Add Default Gateway (Standard OCI Link-Local Gateway)
ip -6 route add default via fe80::1 dev "$DEFAULT_IFACE" 2>/dev/null || true

# Route the rest of the /80 upstream to prevent loops
ip -6 route add "${HOST_SUBNET}" via fe80::1 dev "$DEFAULT_IFACE" 2>/dev/null || true

# Persistence for /etc/network/interfaces (Debian)
if [ -f /etc/network/interfaces ]; then
    if ! grep -q "iface $DEFAULT_IFACE inet6 static" /etc/network/interfaces; then
        echo "  > Persisting to /etc/network/interfaces..."
        cat <<EOF >> /etc/network/interfaces

# IPv6 Static Setup for Incus
iface $DEFAULT_IFACE inet6 static
    address ${HOST_IP}
    netmask 128
    gateway fe80::1
    accept_ra 2
    # Route rest of /80 to gateway
    up ip -6 route add ${HOST_SUBNET} via fe80::1 dev $DEFAULT_IFACE
EOF
    fi
fi

# ---------------------------------------------------------
# Step 3: Firewall Configuration (NFTables)
# ---------------------------------------------------------
echo -e "${GREEN}[3/5] Configuring Firewall (nftables)...${NC}"

# Create a dedicated table to allow Bridge traffic
cat <<EOF > /etc/nftables.conf.incus
#!/usr/sbin/nft -f

table inet incus_ipv6_fix {
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "${INCUS_BRIDGE}" meta l4proto ipv6-icmp accept
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "${INCUS_BRIDGE}" accept
        oifname "${INCUS_BRIDGE}" accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
        oifname "${INCUS_BRIDGE}" meta l4proto ipv6-icmp accept
    }
}
EOF

nft -f /etc/nftables.conf.incus

# Try to save rules if persistence is installed
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null
fi

# ---------------------------------------------------------
# Step 4: Incus Bridge Configuration
# ---------------------------------------------------------
echo -e "${GREEN}[4/5] Configuring Incus Bridge (${INCUS_BRIDGE})...${NC}"

# Create if missing
if ! incus network show "$INCUS_BRIDGE" >/dev/null 2>&1; then
    incus network create "$INCUS_BRIDGE"
fi

# Apply Routed Configuration (Stateful=true allows Static IPs)
cat <<EOF | incus network edit "$INCUS_BRIDGE"
config:
  ipv4.address: 10.58.144.1/24
  ipv4.nat: "true"
  ipv6.address: ${BRIDGE_SUBNET}
  ipv6.dhcp: "true"
  ipv6.dhcp.stateful: "true"
  ipv6.nat: "false"
description: "Routed IPv6 for OCI (Scripted)"
name: ${INCUS_BRIDGE}
type: bridge
EOF

incus network reload "$INCUS_BRIDGE" >/dev/null 2>&1

# ---------------------------------------------------------
# Step 5: Verification
# ---------------------------------------------------------
echo -e "${GREEN}[5/5] Testing Connectivity...${NC}"
echo "  > Pinging Google (IPv6)..."
if ping -6 -c 2 google.com >/dev/null 2>&1; then
    echo -e "  > ${GREEN}SUCCESS: Host is online!${NC}"
else
    echo -e "  > ${RED}FAILURE: Host cannot reach Internet.${NC}"
    echo "    Check your Oracle Security List (Ingress/Egress ::/0)."
fi

echo -e "\n${GREEN}=== SETUP COMPLETE ===${NC}"
echo "You can now assign static IPs to containers:"
echo "  1. incus launch images:debian/12 my-app"
echo "  2. incus config device override my-app eth0 ipv6.address=${CLEAN_PREFIX}:1:1::100"
echo "  3. incus restart my-app"
```
Create LXCs script:
---
```
#!/bin/bash

# ==============================================================================
# Script Name: deploy-debian-lxc.sh
# Description: Automates the creation of a Debian Trixie Incus container, 
#              configures SSH proxying, and enables root password login.
# Target Arch: Oracle A1.Flex (ARM64)
# ==============================================================================

set -e

# --- 1. User Input ---
read -p "Enter the new Container Name: " CONTAINER_NAME
read -p "Enter the Host Port for SSH Proxy (e.g., 2222): " HOST_PORT

# Basic Input Validation
if [[ -z "$CONTAINER_NAME" || -z "$HOST_PORT" ]]; then
    echo "Error: Container Name and Host Port are required."
    exit 1
fi

# Check if port is in use on the host
if ss -tuln | grep -q ":$HOST_PORT "; then
    echo "Error: Port $HOST_PORT is already in use on the host."
    exit 1
fi

echo "--------------------------------------------------------"
echo "Initializing deployment for '$CONTAINER_NAME' on Port $HOST_PORT..."
echo "--------------------------------------------------------"

# --- 2. Container Creation ---
# Using the 'images' remote which contains the community Debian images.
# On Oracle A1, this automatically pulls the aarch64 architecture.
echo "[1/5] Launching Debian Trixie container..."
incus launch images:debian/trixie/cloud "$CONTAINER_NAME"

# Wait for container to be fully running and have network
echo "[2/5] Waiting for networking initialization..."
sleep 5

# --- 3. Network Configuration (Proxy Device) ---
# We use a proxy device to avoid NAT complexity. 
# Traffic hitting Host:HOST_PORT is forwarded to Container:22.
echo "[3/5] Configuring SSH Proxy Device..."
incus config device add "$CONTAINER_NAME" ssh-proxy proxy \
    listen=tcp:0.0.0.0:"$HOST_PORT" \
    connect=tcp:127.0.0.1:22 \
    bind=host

# --- 4. System Provisioning ---
echo "[4/5] Updating system and installing SSH..."
incus exec "$CONTAINER_NAME" -- sh -c "apt update && apt install openssh-server -y"

echo "[4/5] Configuring SSH Daemon..."
# Enable Root Login and Password Auth as requested
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config"
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config"

# --- 5. User Interaction ---
echo "--------------------------------------------------------"
echo "[Action Required] Please set the root password for the container."
incus exec "$CONTAINER_NAME" -- passwd root

echo "Restarting SSH service..."
incus exec "$CONTAINER_NAME" -- systemctl restart ssh

echo "--------------------------------------------------------"
echo "Deployment Complete."
echo "Access your container via:"
echo "ssh root@<YOUR_ORACLE_PUBLIC_IP> -p $HOST_PORT"
echo "--------------------------------------------------------"
```
Tasks:
Many nodes.
