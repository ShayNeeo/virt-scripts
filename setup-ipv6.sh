#!/bin/bash

# ==============================================================================
# Script Name: setup-ipv6.sh
# Description: Enables Routed IPv6 (Stateful DHCP) for Incus on Oracle Cloud
#              Configures host networking, firewall, and Incus bridge for IPv6
# OS Support:  Debian 13 (Testing) / Debian 12
# ==============================================================================

set -e

# --- Configuration ---
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
INCUS_BRIDGE="incusbr0"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Incus IPv6 Routed Setup (Oracle A1.Flex) ===${NC}"

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo).${NC}"
  exit 1
fi

# Check if Incus is installed
if ! command -v incus >/dev/null 2>&1; then
    echo -e "${RED}Incus is not installed. Please run install-incus-debian13.sh or install-incus-debian12.sh first.${NC}"
    exit 1
fi

# Input Prompt
echo ""
echo "Please enter your IPv6 Prefix with CIDR notation."
echo "Examples:"
echo "  - 2603:c024:4518:1400:1::/80  (Oracle /80)"
echo "  - 2001:db8::/64               (Standard /64)"
echo "  - 2001:db8:1234::/48          (Larger /48)"
read -p "Prefix (with CIDR): " USER_PREFIX

# Validate input contains colon (IPv6 format)
if [[ ! "$USER_PREFIX" =~ : ]]; then
    echo -e "${RED}Invalid IPv6 format.${NC}"
    exit 1
fi

# Extract prefix and CIDR
if [[ "$USER_PREFIX" =~ /([0-9]+)$ ]]; then
    PREFIX_CIDR="${BASH_REMATCH[1]}"
    PREFIX_ADDR="${USER_PREFIX%/*}"
else
    echo -e "${RED}Invalid format. Please include CIDR notation (e.g., /80, /64).${NC}"
    exit 1
fi

# Validate CIDR is between 48 and 128
if ! [[ "$PREFIX_CIDR" =~ ^[0-9]+$ ]] || [ "$PREFIX_CIDR" -lt 48 ] || [ "$PREFIX_CIDR" -gt 128 ]; then
    echo -e "${RED}Invalid CIDR. Please use a value between 48 and 128.${NC}"
    exit 1
fi

# Clean prefix address (remove trailing ::)
CLEAN_PREFIX=$(echo "$PREFIX_ADDR" | sed 's|::$||g' | sed 's|:$||g')

# Calculate bridge subnet CIDR (add 16 bits for bridge subnet)
# This gives us a /96 for /80, /80 for /64, /64 for /48, etc.
BRIDGE_CIDR=$((PREFIX_CIDR + 16))

# Validate bridge CIDR doesn't exceed 128
if [ "$BRIDGE_CIDR" -gt 128 ]; then
    BRIDGE_CIDR=128
fi

# Define Subnets
HOST_IP="${CLEAN_PREFIX}::1"
BRIDGE_SUBNET="${CLEAN_PREFIX}:1::1/${BRIDGE_CIDR}"
HOST_SUBNET="${CLEAN_PREFIX}::/${PREFIX_CIDR}"

echo -e "\n${YELLOW}Configuration Target:${NC}"
echo -e "  Interface:      ${DEFAULT_IFACE}"
echo -e "  Prefix CIDR:    /${PREFIX_CIDR}"
echo -e "  Host IP:        ${HOST_IP} (/128)"
echo -e "  Host Subnet:    ${HOST_SUBNET}"
echo -e "  Incus Subnet:   ${BRIDGE_SUBNET} (/${BRIDGE_CIDR})"
echo -e "----------------------------------------"
read -p "Press Enter to apply configuration..."

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
echo -e "  ${GREEN}✓ Kernel parameters configured${NC}"

# ---------------------------------------------------------
# Step 2: Host Network Configuration
# ---------------------------------------------------------
echo -e "${GREEN}[2/5] Configuring Host Network...${NC}"

# Flush old IPs to ensure clean slate
ip -6 addr flush dev "$DEFAULT_IFACE" scope global 2>/dev/null || true

# Add Host IP as /128 (Prevents "Whole Subnet" ownership)
ip -6 addr add "${HOST_IP}/128" dev "$DEFAULT_IFACE" 2>/dev/null || true

# Add Default Gateway (Standard OCI Link-Local Gateway)
ip -6 route add default via fe80::1 dev "$DEFAULT_IFACE" 2>/dev/null || true

# Route the rest of the prefix upstream to prevent loops
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
    # Route rest of prefix (/${PREFIX_CIDR}) to gateway
    up ip -6 route add ${HOST_SUBNET} via fe80::1 dev $DEFAULT_IFACE
EOF
    fi
fi
echo -e "  ${GREEN}✓ Host network configured${NC}"

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
echo -e "  ${GREEN}✓ Firewall rules configured${NC}"

# ---------------------------------------------------------
# Step 4: Incus Bridge Configuration
# ---------------------------------------------------------
echo -e "${GREEN}[4/5] Configuring Incus Bridge (${INCUS_BRIDGE})...${NC}"

# Create if missing
if ! incus network show "$INCUS_BRIDGE" >/dev/null 2>&1; then
    echo "  > Creating network bridge..."
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
echo -e "  ${GREEN}✓ Incus bridge configured${NC}"

# ---------------------------------------------------------
# Step 5: Verification
# ---------------------------------------------------------
echo -e "${GREEN}[5/5] Testing Connectivity...${NC}"
echo "  > Pinging Google (IPv6)..."
if ping -6 -c 2 google.com >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ SUCCESS: Host is online!${NC}"
else
    echo -e "  ${RED}✗ FAILURE: Host cannot reach Internet.${NC}"
    echo -e "    ${YELLOW}Check your Oracle Security List (Ingress/Egress ::/0).${NC}"
fi

echo -e "\n${GREEN}=== SETUP COMPLETE ===${NC}"
echo ""
echo "Configuration Summary:"
echo "  Prefix:         ${CLEAN_PREFIX}::/${PREFIX_CIDR}"
echo "  Host IP:        ${HOST_IP}/128"
echo "  Bridge Subnet:  ${BRIDGE_SUBNET}"
echo ""
echo "You can now assign static IPs to containers:"
echo "  1. incus launch images:debian/trixie/cloud my-app"
echo "  2. incus config device override my-app eth0 ipv6.address=${CLEAN_PREFIX}:1:1::100"
echo "  3. incus restart my-app"
echo ""
echo "Or use the deploy-lxc.sh script to create containers with SSH access."
