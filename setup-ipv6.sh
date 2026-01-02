#!/bin/bash

# ==============================================================================
# Script Name: setup-ipv6.sh
# Description: Enables Routed IPv6 for Incus containers
#              Supports both Routed Networks (Oracle Cloud) and Non-Routed VPS (Greencloud/Hetzner)
# OS Support:  Debian 12 / 13 (Ubuntu compatible)
# ==============================================================================

set -e

# --- Configuration ---
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip -6 route show default 2>/dev/null | grep default | awk '{print $5}' | head -n1)
fi
if [ -z "$DEFAULT_IFACE" ]; then DEFAULT_IFACE="eth0"; fi
INCUS_BRIDGE="incusbr0"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Incus IPv6 Setup ===${NC}"

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

# --- Network Type Selection ---
echo ""
echo -e "${YELLOW}Select your network type:${NC}"
echo "  1) Routed Network (Oracle Cloud, AWS, etc.) - Uses gateway routing"
echo "  2) Non-Routed VPS (Greencloud, Hetzner, etc.) - Uses NDP proxy (ndppd)"
echo ""
read -p "Enter choice [1 or 2]: " NETWORK_TYPE

if [[ ! "$NETWORK_TYPE" =~ ^[12]$ ]]; then
    echo -e "${RED}Invalid choice. Please enter 1 or 2.${NC}"
    exit 1
fi

# --- Input Prompt ---
echo ""
if [ "$NETWORK_TYPE" -eq 1 ]; then
    echo "Please enter your IPv6 Prefix with CIDR notation."
    echo "Examples:"
    echo "  - 2603:c024:4518:1400:1::/80  (Oracle /80)"
    echo "  - 2001:db8::/64               (Standard /64)"
    echo "  - 2001:db8:1234::/48          (Larger /48)"
else
    echo "Please enter your IPv6 /64 Prefix."
    echo "Example: 2a03:d9c2:100:1083::/64"
fi
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

# Validate CIDR
if ! [[ "$PREFIX_CIDR" =~ ^[0-9]+$ ]] || [ "$PREFIX_CIDR" -lt 48 ] || [ "$PREFIX_CIDR" -gt 128 ]; then
    echo -e "${RED}Invalid CIDR. Please use a value between 48 and 128.${NC}"
    exit 1
fi

# Clean prefix address (remove trailing ::)
CLEAN_PREFIX=$(echo "$PREFIX_ADDR" | sed 's|::$||g' | sed 's|:$||g')

# --- Network Type Specific Configuration ---
if [ "$NETWORK_TYPE" -eq 1 ]; then
    # ========================================================================
    # ROUTED NETWORK MODE (Oracle Cloud, AWS, etc.)
    # ========================================================================
    
    echo -e "\n${BLUE}=== Routed Network Mode ===${NC}"
    
    # Calculate bridge subnet CIDR (add 16 bits for bridge subnet)
    BRIDGE_CIDR=$((PREFIX_CIDR + 16))
    if [ "$BRIDGE_CIDR" -gt 128 ]; then
        BRIDGE_CIDR=128
    fi
    
    # Define Subnets
    HOST_IP="${CLEAN_PREFIX}::1"
    BRIDGE_SUBNET="${CLEAN_PREFIX}:1::1/${BRIDGE_CIDR}"
    HOST_SUBNET="${CLEAN_PREFIX}::/${PREFIX_CIDR}"
    
    # Gateway Configuration
    echo ""
    echo "IPv6 Gateway Configuration:"
    echo "  Default: fe80::1 (Standard OCI Link-Local Gateway)"
    echo "  Custom:   Enter your specific IPv6 gateway address"
    read -p "Gateway [default: fe80::1] or press Enter for default: " USER_GATEWAY
    
    # Set default gateway if empty
    if [[ -z "$USER_GATEWAY" ]]; then
        IPV6_GATEWAY="fe80::1"
        echo -e "${YELLOW}Using default gateway: fe80::1${NC}"
    else
        # Validate gateway format
        if [[ ! "$USER_GATEWAY" =~ : ]]; then
            echo -e "${RED}Invalid IPv6 gateway format.${NC}"
            exit 1
        fi
        IPV6_GATEWAY="$USER_GATEWAY"
        echo -e "${GREEN}Using custom gateway: ${IPV6_GATEWAY}${NC}"
    fi
    
    echo -e "\n${YELLOW}Configuration Target:${NC}"
    echo -e "  Interface:      ${DEFAULT_IFACE}"
    echo -e "  Prefix CIDR:    /${PREFIX_CIDR}"
    echo -e "  Host IP:        ${HOST_IP} (/128)"
    echo -e "  Host Subnet:    ${HOST_SUBNET}"
    echo -e "  Gateway:        ${IPV6_GATEWAY}"
    echo -e "  Incus Subnet:   ${BRIDGE_SUBNET} (/${BRIDGE_CIDR})"
    
else
    # ========================================================================
    # NON-ROUTED VPS MODE (Greencloud, Hetzner, etc.)
    # ========================================================================
    
    echo -e "\n${BLUE}=== Non-Routed VPS Mode (NDP Proxy) ===${NC}"
    
    # For non-routed, we expect /64 and carve out a /80 for containers
    if [ "$PREFIX_CIDR" -ne 64 ]; then
        echo -e "${YELLOW}Warning: Non-routed mode typically uses /64. Continuing anyway...${NC}"
    fi
    
    # Define topology: carve /80 from /64
    CONTAINER_SUBNET="${CLEAN_PREFIX}:1::/80"
    BRIDGE_IP="${CLEAN_PREFIX}:1::1"
    HOST_SUBNET="${CLEAN_PREFIX}::/${PREFIX_CIDR}"
    
    echo -e "\n${YELLOW}Configuration Target:${NC}"
    echo -e "  Interface:      ${DEFAULT_IFACE}"
    echo -e "  Proxy Range:    ${CONTAINER_SUBNET} (Managed by ndppd)"
    echo -e "  Incus Gateway:  ${BRIDGE_IP} (Containers will use this)"
    
    # Install ndppd if needed
    if ! command -v ndppd >/dev/null 2>&1; then
        echo -e "\n${YELLOW}Installing ndppd (Required for NDP proxying)...${NC}"
        apt-get update -qq && apt-get install -y ndppd
    else
        echo -e "  ${GREEN}✓ ndppd is already installed${NC}"
    fi
fi

echo -e "----------------------------------------"
read -p "Press Enter to apply configuration..."

# ========================================================================
# COMMON CONFIGURATION STEPS
# ========================================================================

# ---------------------------------------------------------
# Step 1: Kernel Configuration (Sysctl)
# ---------------------------------------------------------
echo -e "\n${GREEN}[1/5] Configuring Kernel Parameters...${NC}"
cat <<EOF > /etc/sysctl.d/99-incus-ipv6.conf
# Enable Forwarding (Router Mode)
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.${DEFAULT_IFACE}.forwarding=1
EOF

# For routed networks, also enable RA acceptance
if [ "$NETWORK_TYPE" -eq 1 ]; then
    cat <<EOF >> /etc/sysctl.d/99-incus-ipv6.conf

# Accept RA (Client Mode) - REQUIRED for OCI
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv6.conf.${DEFAULT_IFACE}.accept_ra=2
EOF
fi

sysctl --system > /dev/null
echo -e "  ${GREEN}✓ Kernel parameters configured${NC}"

# ---------------------------------------------------------
# Step 2: Host Network Configuration
# ---------------------------------------------------------
echo -e "${GREEN}[2/5] Configuring Host Network...${NC}"

if [ "$NETWORK_TYPE" -eq 1 ]; then
    # ROUTED MODE: Configure host IP and gateway
    # Flush old IPs to ensure clean slate
    ip -6 addr flush dev "$DEFAULT_IFACE" scope global 2>/dev/null || true
    
    # Add Host IP as /128 (Prevents "Whole Subnet" ownership)
    ip -6 addr add "${HOST_IP}/128" dev "$DEFAULT_IFACE" 2>/dev/null || true
    
    # Remove existing default route if it exists
    ip -6 route del default dev "$DEFAULT_IFACE" 2>/dev/null || true
    
    # Add Default Gateway
    ip -6 route add default via "${IPV6_GATEWAY}" dev "$DEFAULT_IFACE" 2>/dev/null || true
    
    # Route the rest of the prefix upstream to prevent loops
    ip -6 route del "${HOST_SUBNET}" dev "$DEFAULT_IFACE" 2>/dev/null || true
    ip -6 route add "${HOST_SUBNET}" via "${IPV6_GATEWAY}" dev "$DEFAULT_IFACE" 2>/dev/null || true
    
    # Persistence for /etc/network/interfaces (Debian)
    if [ -f /etc/network/interfaces ]; then
        if ! grep -q "iface $DEFAULT_IFACE inet6 static" /etc/network/interfaces; then
            echo "  > Persisting to /etc/network/interfaces..."
            cat <<EOF >> /etc/network/interfaces

# IPv6 Static Setup for Incus (Routed Mode)
iface $DEFAULT_IFACE inet6 static
    address ${HOST_IP}
    netmask 128
    gateway ${IPV6_GATEWAY}
    accept_ra 2
    # Route rest of prefix (/${PREFIX_CIDR}) to gateway
    up ip -6 route add ${HOST_SUBNET} via ${IPV6_GATEWAY} dev $DEFAULT_IFACE
EOF
        fi
    fi
    echo -e "  ${GREEN}✓ Host network configured (routed mode)${NC}"
else
    # NON-ROUTED MODE: Just ensure forwarding is enabled, host keeps existing config
    echo -e "  ${GREEN}✓ Host network ready (non-routed mode)${NC}"
fi

# ---------------------------------------------------------
# Step 3: NDP Proxy Configuration (Non-Routed Only)
# ---------------------------------------------------------
if [ "$NETWORK_TYPE" -eq 2 ]; then
    echo -e "${GREEN}[3/5] Configuring Neighbor Discovery Proxy (ndppd)...${NC}"
    
    # Configure ndppd to proxy NDP requests for the container subnet
    cat <<EOF > /etc/ndppd.conf
proxy ${DEFAULT_IFACE} {
    rule ${CONTAINER_SUBNET} {
        auto
    }
}
EOF
    
    systemctl restart ndppd
    systemctl enable ndppd >/dev/null 2>&1
    echo -e "  ${GREEN}✓ ndppd configured and restarted${NC}"
else
    echo -e "${GREEN}[3/5] Skipping NDP proxy (not needed for routed networks)...${NC}"
fi

# ---------------------------------------------------------
# Step 4: Firewall Configuration (NFTables)
# ---------------------------------------------------------
echo -e "${GREEN}[4/5] Configuring Firewall (nftables)...${NC}"

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
# Step 5: Incus Bridge Configuration
# ---------------------------------------------------------
echo -e "${GREEN}[5/5] Configuring Incus Bridge (${INCUS_BRIDGE})...${NC}"

# Create if missing
if ! incus network show "$INCUS_BRIDGE" >/dev/null 2>&1; then
    echo "  > Creating network bridge..."
    incus network create "$INCUS_BRIDGE"
fi

# Apply configuration using atomic 'set' commands to prevent hangs
if [ "$NETWORK_TYPE" -eq 1 ]; then
    # ROUTED MODE
    incus network set "$INCUS_BRIDGE" ipv4.address="10.58.144.1/24"
    incus network set "$INCUS_BRIDGE" ipv4.nat="true"
    incus network set "$INCUS_BRIDGE" ipv6.address="${BRIDGE_SUBNET}"
    incus network set "$INCUS_BRIDGE" ipv6.nat="false"
    incus network set "$INCUS_BRIDGE" ipv6.dhcp="true"
    incus network set "$INCUS_BRIDGE" ipv6.dhcp.stateful="true"
    echo -e "  ${GREEN}✓ Incus bridge configured (routed mode)${NC}"
else
    # NON-ROUTED MODE
    incus network set "$INCUS_BRIDGE" ipv4.address="10.10.10.1/24"
    incus network set "$INCUS_BRIDGE" ipv4.nat="true"
    incus network set "$INCUS_BRIDGE" ipv6.address="${BRIDGE_IP}/80"
    incus network set "$INCUS_BRIDGE" ipv6.nat="false"
    incus network set "$INCUS_BRIDGE" ipv6.dhcp="true"
    incus network set "$INCUS_BRIDGE" ipv6.dhcp.stateful="true"
    incus network set "$INCUS_BRIDGE" ipv6.routing="true"
    echo -e "  ${GREEN}✓ Incus bridge configured with Gateway: ${BRIDGE_IP}${NC}"
fi

# Reloading usually isn't necessary with 'set' commands, but if you do it:
# Only reload if the bridge was previously down or significantly changed.
# incus network reload "$INCUS_BRIDGE" >/dev/null 2>&1

# ---------------------------------------------------------
# Step 6: Verification
# ---------------------------------------------------------
echo -e "${GREEN}[6/6] Testing Connectivity...${NC}"
echo "  > Pinging Google (IPv6)..."
if ping -6 -c 2 google.com >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ SUCCESS: Host is online!${NC}"
else
    echo -e "  ${RED}✗ FAILURE: Host cannot reach Internet.${NC}"
    if [ "$NETWORK_TYPE" -eq 1 ]; then
        echo -e "    ${YELLOW}Check your Security List/Firewall rules (Ingress/Egress ::/0).${NC}"
    else
        echo -e "    ${YELLOW}Check your VPS provider's firewall and IPv6 configuration.${NC}"
    fi
fi

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
echo -e "\n${GREEN}=== SETUP COMPLETE ===${NC}"
echo ""
echo "Configuration Summary:"
if [ "$NETWORK_TYPE" -eq 1 ]; then
    echo "  Mode:           Routed Network"
    echo "  Prefix:         ${CLEAN_PREFIX}::/${PREFIX_CIDR}"
    echo "  Host IP:        ${HOST_IP}/128"
    echo "  Gateway:        ${IPV6_GATEWAY}"
    echo "  Bridge Subnet:  ${BRIDGE_SUBNET}"
    echo ""
    echo "To assign static IPs to containers:"
    echo "  1. incus launch images:debian/trixie/cloud my-app"
    echo "  2. incus config device override my-app eth0 ipv6.address=${CLEAN_PREFIX}:1:1::100"
    echo "  3. incus restart my-app"
else
    echo "  Mode:           Non-Routed VPS (NDP Proxy)"
    echo "  Prefix:         ${CLEAN_PREFIX}::/${PREFIX_CIDR}"
    echo "  Container Subnet: ${CONTAINER_SUBNET}"
    echo "  Bridge Gateway:   ${BRIDGE_IP}"
    echo ""
    echo "To assign static IPs to containers:"
    echo "  1. incus launch images:debian/trixie/cloud my-app"
    echo "  2. incus config device override my-app eth0 ipv6.address=${CLEAN_PREFIX}:1::100"
    echo "     (Gateway will be auto-configured to ${BRIDGE_IP})"
    echo "  3. incus restart my-app"
    echo "  4. incus exec my-app -- ping6 google.com"
fi
echo ""
echo "Or use the deploy-lxc.sh script to create containers with SSH access."
