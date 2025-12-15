#!/bin/bash

# --- Configuration & Paths ---
export PANEL_DIR="/opt/pasarguard"  # Default, auto-detected later
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
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 -qq > /dev/null

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
    if [ -d "/opt/rebecca" ]; then
        echo "rebecca"
        export PANEL_DIR="/opt/rebecca"
        export PANEL_ENV="/opt/rebecca/.env"
        export PANEL_DEF_CERTS="/var/lib/rebecca/certs"
    elif [ -d "/opt/pasarguard" ]; then
        echo "pasarguard"
        export PANEL_DIR="/opt/pasarguard"
        export PANEL_ENV="/opt/pasarguard/.env"
        export PANEL_DEF_CERTS="/var/lib/pasarguard/certs"
    else
        echo "marzban"
        export PANEL_DIR="/opt/marzban"
        export PANEL_ENV="/opt/marzban/.env"
        export PANEL_DEF_CERTS="/var/lib/marzban/certs"
    fi
}

get_panel_cli() {
    local panel=$(detect_active_panel)
    if [ "$panel" == "rebecca" ]; then echo "rebecca-cli"; else echo "pasarguard-cli"; fi
}

restart_service() {
    local SERVICE=$1
    detect_active_panel > /dev/null

    if [ "$SERVICE" == "panel" ]; then
        echo -e "${BLUE}Restarting Panel ($PANEL_DIR)...${NC}"
        if [ -d "$PANEL_DIR" ]; then
            cd "$PANEL_DIR" && docker compose restart
            echo -e "${GREEN}Done.${NC}"
        else
            echo -e "${RED}Panel not found.${NC}"
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
    local panel=$(detect_active_panel)
    local cli="marzban-cli"
    [ "$panel" == "rebecca" ] && cli="rebecca-cli"
    [ "$panel" == "pasarguard" ] && cli="pasarguard-cli"

    # Try finding CLI in container
    local cid=$(docker compose -f "$PANEL_DIR/docker-compose.yml" ps -q | head -1)

    if [ -z "$cid" ]; then
        echo -e "${RED}Panel is not running!${NC}"
        return
    fi

    echo -e "${CYAN}Creating Admin for $panel${NC}"
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
    local panel=$(detect_active_panel)
    local cli="marzban-cli"
    [ "$panel" == "rebecca" ] && cli="rebecca-cli"
    [ "$panel" == "pasarguard" ] && cli="pasarguard-cli"

    local cid=$(docker compose -f "$PANEL_DIR/docker-compose.yml" ps -q | head -1)

    if [ -z "$cid" ]; then echo -e "${RED}Panel not running${NC}"; return; fi

    read -p "Username to reset password: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin update --username "$user" --password
    fi
}

admin_delete() {
    local panel=$(detect_active_panel)
    local cli="marzban-cli"
    [ "$panel" == "rebecca" ] && cli="rebecca-cli"
    [ "$panel" == "pasarguard" ] && cli="pasarguard-cli"

    local cid=$(docker compose -f "$PANEL_DIR/docker-compose.yml" ps -q | head -1)

    if [ -z "$cid" ]; then echo -e "${RED}Panel not running${NC}"; return; fi

    read -p "Username to delete: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin delete --username "$user"
    fi
}