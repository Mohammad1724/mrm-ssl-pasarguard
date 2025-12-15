#!/bin/bash

# --- Auto Detect Panel & Paths (FIXED) ---
if [ -d "/opt/rebecca" ]; then
    export PANEL_NAME="rebecca"
    export PANEL_DIR="/opt/rebecca"
    export DATA_DIR="/var/lib/rebecca"
    export PANEL_CLI="rebecca-cli"
elif [ -d "/opt/marzban" ]; then
    export PANEL_NAME="marzban"
    export PANEL_DIR="/opt/marzban"
    export DATA_DIR="/var/lib/marzban"
    export PANEL_CLI="marzban-cli"
else
    # Default fallback
    export PANEL_NAME="pasarguard"
    export PANEL_DIR="/opt/pasarguard"
    export DATA_DIR="/var/lib/pasarguard"
    export PANEL_CLI="pasarguard-cli"
fi

export PANEL_ENV="$PANEL_DIR/.env"
export PANEL_DEF_CERTS="$DATA_DIR/certs"

# Node Paths
export NODE_DIR="/opt/pg-node"
# Check if standard marzban-node exists
if [ -d "/opt/marzban-node" ]; then
    export NODE_DIR="/opt/marzban-node"
    export NODE_DEF_CERTS="/var/lib/marzban-node/certs"
else
    export NODE_DEF_CERTS="/var/lib/pg-node/certs"
fi
export NODE_ENV="$NODE_DIR/.env"

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

install_package() {
    local PKG_DEB=$1
    local PKG_RPM=$2
    [ -z "$PKG_RPM" ] && PKG_RPM=$PKG_DEB

    if command -v apt-get &> /dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y "$PKG_DEB" -qq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum install -y "$PKG_RPM" >/dev/null 2>&1
    elif command -v dnf &> /dev/null; then
        dnf install -y "$PKG_RPM" >/dev/null 2>&1
    else
        echo -e "${RED}Package manager not found. Please install $PKG_DEB manually.${NC}"
    fi
}

install_deps() {
    local NEED_INSTALL=false

    command -v certbot &> /dev/null || NEED_INSTALL=true
    command -v nginx &> /dev/null || NEED_INSTALL=true
    command -v python3 &> /dev/null || NEED_INSTALL=true
    command -v sqlite3 &> /dev/null || NEED_INSTALL=true
    command -v docker &> /dev/null || NEED_INSTALL=true
    command -v jq &> /dev/null || NEED_INSTALL=true
    command -v lsof &> /dev/null || NEED_INSTALL=true

    if [ "$NEED_INSTALL" = true ]; then
        echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
        
        # Package manager detection
        if command -v apt-get &> /dev/null; then
            apt-get update -qq > /dev/null
            apt-get install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 -qq > /dev/null
        elif command -v yum &> /dev/null; then
            yum install -y epel-release >/dev/null 2>&1
            yum install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 >/dev/null 2>&1
        fi

        if ! command -v docker &> /dev/null; then
            echo -e "${BLUE}[INFO] Installing Docker...${NC}"
            curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        fi
    fi
}

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

# --- Service Control Functions ---

detect_active_panel() {
    # Logic moved to top of file for global export, this echoes for UI compatibility
    echo "$PANEL_NAME"
}

get_panel_cli() {
    echo "$PANEL_CLI"
}

restart_service() {
    local SERVICE=$1
    
    if [ "$SERVICE" == "panel" ]; then
        echo -e "${BLUE}Restarting Panel ($PANEL_DIR)...${NC}"
        if [ -d "$PANEL_DIR" ]; then
            cd "$PANEL_DIR" && docker compose restart
            echo -e "${GREEN}Done.${NC}"
        else
            echo -e "${RED}Panel directory not found.${NC}"
        fi
    elif [ "$SERVICE" == "node" ]; then
        echo -e "${BLUE}Restarting Node...${NC}"
        if [ -d "$NODE_DIR" ]; then
            cd "$NODE_DIR" && docker compose restart
            echo -e "${GREEN}Done.${NC}"
        else
            echo -e "${RED}Node directory not found!${NC}"
        fi
    fi
}

# --- Admin Management ---

admin_create() {
    local cli=$(get_panel_cli)

    # Robust container detection
    local cid=$(docker ps --format '{{.ID}} {{.Names}}' | grep -iE "$PANEL_NAME|marzban|pasarguard|rebecca" | grep -v "mysql" | grep -v "node" | head -1 | awk '{print $1}')

    if [ -z "$cid" ]; then
        echo -e "${RED}Panel container is not running!${NC}"
        return
    fi

    echo -e "${CYAN}Creating Admin for $PANEL_NAME${NC}"
    echo "1) Super Admin (Sudo)"
    echo "2) Regular Admin"
    read -p "Select: " type

    if [ "$type" == "1" ]; then
        docker exec -it "$cid" $cli admin create --sudo
    else
        docker exec -it "$cid" $cli admin create
    fi
}

admin_reset() {
    local cli=$(get_panel_cli)
    local cid=$(docker ps --format '{{.ID}} {{.Names}}' | grep -iE "$PANEL_NAME|marzban|pasarguard|rebecca" | grep -v "mysql" | grep -v "node" | head -1 | awk '{print $1}')

    if [ -z "$cid" ]; then echo -e "${RED}Panel not running${NC}"; return; fi

    read -p "Username to reset password: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin update --username "$user" --password
    fi
}

admin_delete() {
    local cli=$(get_panel_cli)
    local cid=$(docker ps --format '{{.ID}} {{.Names}}' | grep -iE "$PANEL_NAME|marzban|pasarguard|rebecca" | grep -v "mysql" | grep -v "node" | head -1 | awk '{print $1}')

    if [ -z "$cid" ]; then echo -e "${RED}Panel not running${NC}"; return; fi

    read -p "Username to delete: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin delete --username "$user"
    fi
}