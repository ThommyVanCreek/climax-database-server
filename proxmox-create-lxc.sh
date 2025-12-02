#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ClimaX - Proxmox LXC Creation Script
# Run this on your PROXMOX HOST (not inside a container)
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# Configuration - ClimaX Database Server
# ─────────────────────────────────────────────────────────────────────────────
CTID="22220"                          # Container ID
HOSTNAME="climaxdb.vancreek.de"      # Container hostname
STORAGE="b-storage10"                 # Storage for container (check: pvesm status)
TEMPLATE_STORAGE="local"              # Resource pool for templates
DISK_SIZE="10"                        # Disk size in GiB
MEMORY="2048"                         # Memory in MB
CORES="2"                             # CPU cores
BRIDGE="vmbr0"                        # Network bridge
IP_ADDRESS="172.22.0.220/24"         # Static IPv4 with CIDR
GATEWAY="172.22.0.1"                 # Gateway IP
PASSWORD=""                           # Root password for container (will be prompted if empty)
USE_DOCKER=0                          # Set to 1 if you need Docker inside container

# Template - Alpine 3.16 (lightweight, production-ready)
TEMPLATE="alpine-3.16-default_20220622_amd64.tar.xz"

# ─────────────────────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "   Creating LXC Container for ClimaX Database"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo -e "${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Prompt for root password if not provided
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$PASSWORD" ]; then
    while [ -z "$PASSWORD" ]; do
        read -s -p "Enter root password for container: " PASSWORD
        echo
        if [ ${#PASSWORD} -lt 8 ]; then
            echo -e "${RED}Password must be at least 8 characters${NC}"
            PASSWORD=""
        fi
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check template exists
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/4] Checking template...${NC}"

if ! pveam list ${TEMPLATE_STORAGE} 2>/dev/null | grep -q "${TEMPLATE}"; then
    echo -e "${YELLOW}Template not found. Updating template list...${NC}"
    pveam update > /dev/null 2>&1 || true
    
    if ! pveam list ${TEMPLATE_STORAGE} 2>/dev/null | grep -q "${TEMPLATE}"; then
        echo -e "${RED}Error: Template ${TEMPLATE} not found${NC}"
        echo "Available Alpine 3.16 templates:"
        pveam list ${TEMPLATE_STORAGE} 2>/dev/null | grep "alpine-3.16" || echo "None found"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Template found${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Build network configuration
# ─────────────────────────────────────────────────────────────────────────────
if [ "$IP_ADDRESS" = "dhcp" ]; then
    NETWORK_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
    NETWORK_CONFIG="name=eth0,bridge=${BRIDGE},ip=${IP_ADDRESS},gw=${GATEWAY}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Determine privileged mode based on Docker requirement
# ─────────────────────────────────────────────────────────────────────────────
if [ "$USE_DOCKER" = "1" ]; then
    UNPRIVILEGED=0
    FEATURES="nesting=1,keyctl=1"
    echo -e "${YELLOW}Using privileged container (Docker support enabled)${NC}"
else
    UNPRIVILEGED=1
    FEATURES="nesting=1"
    echo -e "${YELLOW}Using unprivileged container (more secure)${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Create container
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[2/4] Creating container...${NC}"

pct create $CTID ${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE} \
    --hostname $HOSTNAME \
    --storage $STORAGE \
    --rootfs ${STORAGE}:${DISK_SIZE} \
    --memory $MEMORY \
    --cores $CORES \
    --net0 $NETWORK_CONFIG \
    --password "$PASSWORD" \
    --unprivileged $UNPRIVILEGED \
    --features $FEATURES \
    --onboot 1 \
    --start 0 || {
        echo -e "${RED}Error: Failed to create container${NC}"
        exit 1
    }

echo -e "${GREEN}✓ Container $CTID created${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Start container
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[3/4] Starting container...${NC}"

pct start $CTID || {
    echo -e "${RED}Error: Failed to start container${NC}"
    exit 1
}

# Wait for container to be ready
echo "Waiting for container to start..."
for i in {1..20}; do
    if pct exec $CTID -- true 2>/dev/null; then
        echo "Container is ready"
        break
    fi
    sleep 0.5
done

echo -e "${GREEN}✓ Container started${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Get container IP
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[4/4] Getting container IP...${NC}"

# Wait for network to be configured
sleep 3

CONTAINER_IP=$(pct exec $CTID -- hostname -I 2>/dev/null | awk '{print $1}')

if [ -z "$CONTAINER_IP" ]; then
    echo -e "${YELLOW}Warning: Could not determine IP yet. Check manually with: pct exec $CTID -- hostname -I${NC}"
    CONTAINER_IP="<pending>"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Print summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Container Created Successfully!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Container Details:"
echo "  ID:          $CTID"
echo "  Hostname:    $HOSTNAME"
echo "  IP Address:  $CONTAINER_IP"
echo "  Memory:      ${MEMORY}MB"
echo "  Cores:       $CORES"
echo "  Disk:        ${DISK_SIZE}GB"
echo ""
echo "─────────────────────────────────────────────────────────────────────────────"
echo ""
echo "Next steps:"
echo ""
echo "1. Copy setup files to container:"
echo "   scp lxc-setup.sh database_schema.sql requirements.txt root@${CONTAINER_IP}:/root/"
echo ""
echo "2. SSH into container:"
echo "   ssh root@${CONTAINER_IP}"
echo ""
echo "3. Run setup script:"
echo "   chmod +x lxc-setup.sh"
echo "   ./lxc-setup.sh"
echo ""
echo "─────────────────────────────────────────────────────────────────────────────"
echo ""
echo "Useful commands:"
echo "  pct enter $CTID          # Enter container shell"
echo "  pct exec $CTID -- CMD    # Run command in container"
echo "  pct stop $CTID           # Stop container"
echo "  pct start $CTID          # Start container"
echo "  pct destroy $CTID        # Delete container"
echo ""
