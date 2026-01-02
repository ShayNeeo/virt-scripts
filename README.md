# Virt Scripts

Automation scripts for setting up and managing Incus (LXC) containers on Debian systems, with special focus on Oracle Cloud Infrastructure (OCI) deployments.

## 📋 Overview

This collection provides automated scripts to:
- Install and configure Incus on Debian 12+ systems
- Set up IPv6 networking for containers (supports any prefix with CIDR notation)
- Deploy and configure Debian containers
- Install and configure Dokploy in containers

## 🚀 Quick Start

### Prerequisites

- Debian 12 (Bookworm) or Debian 13+ (Trixie)
- Root or sudo access
- Internet connectivity

### Installation

1. Clone this repository:
```bash
git clone https://github.com/ShayNeeo/virt-scripts.git
cd virt-scripts
```

2. Make scripts executable:
```bash
chmod +x *.sh
```

## 📦 Scripts

### Installation Scripts

#### `install-incus-debian13.sh`
Installs Incus on Debian 13+ using official Debian packages.

```bash
sudo ./install-incus-debian13.sh
```

**Features:**
- Installs from official Debian repositories
- Configures btrfs storage backend
- Sets up network bridge
- Initializes Incus with recommended settings

#### `install-incus-debian12.sh`
Installs Incus on Debian 12 and below using Zabbly repository.

```bash
sudo ./install-incus-debian12.sh
```

**Features:**
- Adds Zabbly repository for Incus packages
- Same configuration as Debian 13+ script
- Compatible with Debian 12 (Bookworm)

### Network Configuration

#### `setup-ipv6.sh`
Configures IPv6 routing for Incus containers on Oracle Cloud Infrastructure.

```bash
sudo ./setup-ipv6.sh
```

**Features:**
- Supports any IPv6 prefix with CIDR notation (e.g., `/80`, `/64`, `/48`)
- Configures kernel parameters for IPv6 forwarding
- Sets up host networking with proper routing
- Configures nftables firewall rules
- Configures Incus bridge for routed IPv6 with stateful DHCP

**Example Usage:**
```bash
# Oracle Cloud /80 prefix
Prefix: 2603:c024:4518:1400:1::/80

# Standard /64 prefix
Prefix: 2001:db8::/64

# Larger /48 prefix
Prefix: 2001:db8:1234::/48
```

### Container Management

#### `deploy-lxc.sh`
Automates the creation of Debian Incus containers with SSH access.

```bash
./deploy-lxc.sh
```

**Features:**
- Creates Debian containers (trixie/bookworm/bullseye)
- Configures SSH proxy device for external access
- Installs and configures SSH server
- Enables root password login
- Validates inputs and checks for conflicts

**Interactive Prompts:**
- Container name
- Host port for SSH proxy (e.g., 2222)
- Debian version (default: trixie)

### Application Deployment

#### `install-dokploy.sh`
Configures an Incus container for Dokploy and installs it.

```bash
./install-dokploy.sh
```

**Features:**
- Configures Incus container security settings
- Installs Docker with btrfs storage driver
- Configures Docker for LXC/Incus compatibility
- Installs Dokploy using official installer
- Sets up all required configurations automatically

**Requirements:**
- Container must already exist (use `deploy-lxc.sh` first)

## 📖 Usage Examples

### Complete Setup Workflow

1. **Install Incus:**
```bash
# For Debian 13+
sudo ./install-incus-debian13.sh

# For Debian 12
sudo ./install-incus-debian12.sh
```

2. **Configure IPv6 (if needed):**
```bash
sudo ./setup-ipv6.sh
# Enter your IPv6 prefix when prompted (e.g., 2603:c024:4518:1400:1::/80)
```

3. **Deploy a Container:**
```bash
./deploy-lxc.sh
# Follow the interactive prompts
```

4. **Install Dokploy (optional):**
```bash
./install-dokploy.sh
# Enter the container name when prompted
```

### Manual Container Management

```bash
# List containers
incus list

# Launch a container
incus launch images:debian/trixie/cloud my-container

# Access container shell
incus exec my-container -- bash

# Stop/Start container
incus stop my-container
incus start my-container

# Delete container
incus delete my-container
```

## 🔧 Configuration Details

### Incus Initialization

When running the installation scripts, you'll be prompted with recommended settings:

- **Clustering:** `no`
- **Storage pool:** `default` (btrfs backend)
- **Loop device size:** `30GiB` (adjustable)
- **Network bridge:** `incusbr0`
- **IPv4:** `auto` (NAT enabled)
- **IPv6:** Configure as needed

### IPv6 Configuration

The `setup-ipv6.sh` script automatically:
- Calculates appropriate subnet sizes based on your prefix
- Configures host networking with `/128` address
- Sets up bridge subnet (prefix CIDR + 16 bits)
- Enables IPv6 forwarding and RA acceptance
- Configures firewall rules for bridge traffic

### Docker in Containers

For containers running Docker (like Dokploy):
- Uses btrfs storage driver
- Configured for LXC/Incus compatibility
- Security settings enabled (nesting, syscalls)

## 🛠️ Troubleshooting

### Incus Not Found
```bash
# Check if Incus is installed
which incus

# If not, run the appropriate installation script
sudo ./install-incus-debian13.sh  # or install-incus-debian12.sh
```

### Container Network Issues
```bash
# Check network configuration
incus network list
incus network show incusbr0

# Restart network
incus network reload incusbr0
```

### IPv6 Connectivity Problems
```bash
# Verify IPv6 forwarding
sysctl net.ipv6.conf.all.forwarding

# Check routes
ip -6 route show

# Test connectivity
ping6 -c 2 google.com
```

### Docker Issues in Container
```bash
# Check Docker status
incus exec container-name -- systemctl status docker

# View Docker logs
incus exec container-name -- journalctl -u docker

# Verify storage driver
incus exec container-name -- docker info | grep "Storage Driver"
```

## 📝 Documentation

For detailed configuration notes and manual setup instructions, see [scripts.md](scripts.md).

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

These scripts are provided as-is for automation purposes. Always review scripts before running them, especially with root privileges. Test in a non-production environment first.

## 🔗 Related Resources

- [Incus Documentation](https://linuxcontainers.org/incus/)
- [Dokploy Documentation](https://docs.dokploy.com/)
- [Oracle Cloud Infrastructure](https://www.oracle.com/cloud/)

## 📧 Support

For issues, questions, or contributions, please open an issue on the GitHub repository.

---

**Note:** These scripts are optimized for Oracle Cloud Infrastructure (OCI) A1.Flex instances but should work on any Debian 12+ system.
