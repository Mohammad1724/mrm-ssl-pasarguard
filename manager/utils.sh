#!/bin/bash

# --- Configuration & Paths ---
export PANEL_DIR="/opt/pasarguard"
export PANEL_ENV="$PANEL_DIR/.env"
export PANEL_DEF_CERTS="/var/lib/pasarguard/certs"

export NODE_DIR="/opt/pg-node"
export NODE_ENV="$NODE_DIR/.env"
export NODE_DEF_CERTS="/var/lib/pg-node/certs"

export THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/templates/subscription/index.html"

# --- Colors ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export PURPLE='\033[0;35m'
export ORANGE='\033[0;33m'
export NC='\033[0m'

# --- Common Functions ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    if ! command -v certbot &> /dev/null || ! command -v nginx &> /dev/null || ! command -v python3 &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 -qq > /dev/null
    fi
}

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

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

# NEW FUNCTION: Check if panel is installed
check_installation() {
    if [ ! -d "$PANEL_DIR" ] && [ ! -d "$NODE_DIR" ]; then
        echo -e "${YELLOW}It seems Pasarguard is not installed yet.${NC}"
        echo "Would you like to install the Main Panel now?"
        read -p "Install Panel? (y/n): " INS
        if [ "$INS" == "y" ]; then
            install_panel_wizard
        fi
    fi
}

install_panel_wizard() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      INSTALL PASARGUARD PANEL               ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    mkdir -p "$PANEL_DIR"
    mkdir -p "/var/lib/pasarguard/certs"
    mkdir -p "/var/lib/pasarguard/templates"
    
    echo -e "${BLUE}Downloading docker-compose.yml...${NC}"
    
    # Download standard docker-compose
    curl -s -o "$PANEL_DIR/docker-compose.yml" "https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/docker-compose.yml"
    
    # Generate default config.json
    echo -e "${BLUE}Generating config.json...${NC}"
    cat > "/var/lib/pasarguard/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "DIRECT" },
    { "protocol": "blackhole", "tag": "BLOCK" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
    
    echo -e "${BLUE}Generating .env...${NC}"
    touch "$PANEL_ENV"
    
    echo -e "${GREEN}✔ Installation files ready.${NC}"
    echo "Starting Docker..."
    
    cd "$PANEL_DIR"
    docker compose up -d
    
    echo -e "${GREEN}✔ Panel Installed!${NC}"
    pause
}