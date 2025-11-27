#!/bin/bash

# --- Configuration & Paths ---
export PANEL_DIR="/opt/pasarguard"
export PANEL_ENV="$PANEL_DIR/.env"
export PANEL_DEF_CERTS="/var/lib/pasarguard/certs"

export NODE_DIR="/opt/pg-node"
export NODE_ENV="$NODE_DIR/.env"
export NODE_DEF_CERTS="/var/lib/pg-node/certs"

export THEME_SCRIPT_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/theme.sh"

# --- Colors ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export PURPLE='\033[0;35m'
export ORANGE='\033[0;33m'
export NC='\033[0m' # No Color

# --- Common Functions ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    # Check if essential tools exist
    if ! command -v certbot &> /dev/null || ! command -v nano &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing dependencies (certbot, curl, nano, etc)...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl nano socat tar -qq > /dev/null
    fi
}

pause() {
    read -p "Press Enter to continue..."
}

# Helper to restart services safely
restart_service() {
    local SERVICE=$1
    if [ "$SERVICE" == "panel" ]; then
        echo -e "${BLUE}Restarting Panel...${NC}"
        if command -v pasarguard &> /dev/null; then
            pasarguard restart
        else
            if [ -d "$PANEL_DIR" ]; then
                cd "$PANEL_DIR" && docker compose restart
            else
                echo -e "${RED}Panel directory not found!${NC}"
            fi
        fi
    elif [ "$SERVICE" == "node" ]; then
        echo -e "${BLUE}Restarting Node...${NC}"
        if [ -d "$NODE_DIR" ]; then
            cd "$NODE_DIR" && docker compose restart
        else
            echo -e "${RED}Node directory not found!${NC}"
        fi
    fi
}