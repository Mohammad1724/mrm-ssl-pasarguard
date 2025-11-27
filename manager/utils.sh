#!/bin/bash

# Paths
PANEL_DIR="/opt/pasarguard"
PANEL_ENV="$PANEL_DIR/.env"
PANEL_DEF_CERTS="/var/lib/pasarguard/certs"

NODE_DIR="/opt/pg-node"
NODE_ENV="$NODE_DIR/.env"
NODE_DEF_CERTS="/var/lib/pg-node/certs"

THEME_SCRIPT_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/theme.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run as root.${NC}"
        exit 1
    fi
}

install_deps() {
    if ! command -v certbot &> /dev/null || ! command -v nano &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl nano socat -qq > /dev/null
    fi
}

pause() {
    read -p "Press Enter to continue..."
}