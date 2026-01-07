#!/bin/bash

# --- Colors ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export PURPLE='\033[0;35m'
export ORANGE='\033[0;33m'
export NC='\033[0m'

# --- Config File (ذخیره انتخاب کاربر) ---
CONFIG_FILE="/opt/mrm-manager/panel.conf"

# --- Panel Selection ---
select_panel() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo -e "${CYAN}       SELECT YOUR PANEL TYPE         ${NC}"
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo ""
    echo "1) Pasarguard"
    echo "2) Marzban"
    echo "3) Rebecca"
    echo ""
    read -p "Select [1-3]: " PANEL_CHOICE

    case $PANEL_CHOICE in
        1)
            echo "pasarguard" > "$CONFIG_FILE"
            ;;
        2)
            echo "marzban" > "$CONFIG_FILE"
            ;;
        3)
            echo "rebecca" > "$CONFIG_FILE"
            ;;
        *)
            echo -e "${RED}Invalid selection. Defaulting to Pasarguard.${NC}"
            echo "pasarguard" > "$CONFIG_FILE"
            ;;
    esac

    load_panel_config
    echo -e "${GREEN}✔ Panel set to: $(cat $CONFIG_FILE)${NC}"
    echo ""
}

# --- Load Panel Config ---
load_panel_config() {
    # اگر فایل کانفیگ وجود نداشت، از کاربر بپرس
    if [ ! -f "$CONFIG_FILE" ]; then
        select_panel
        return
    fi

    local PANEL_TYPE=$(cat "$CONFIG_FILE" 2>/dev/null)

    case $PANEL_TYPE in
        pasarguard)
            export PANEL_DIR="/opt/pasarguard"
            export PANEL_ENV="/opt/pasarguard/.env"
            export PANEL_DEF_CERTS="/var/lib/pasarguard/certs"
            export DATA_DIR="/var/lib/pasarguard"
            export NODE_DIR="/opt/pg-node"
            export NODE_ENV="/opt/pg-node/.env"
            export NODE_DEF_CERTS="/var/lib/pg-node/certs"
            ;;
        marzban)
            export PANEL_DIR="/opt/marzban"
            export PANEL_ENV="/opt/marzban/.env"
            export PANEL_DEF_CERTS="/var/lib/marzban/certs"
            export DATA_DIR="/var/lib/marzban"
            export NODE_DIR="/opt/marzban-node"
            export NODE_ENV="/opt/marzban-node/.env"
            export NODE_DEF_CERTS="/var/lib/marzban-node/certs"
            ;;
        rebecca)
            export PANEL_DIR="/opt/rebecca"
            export PANEL_ENV="/opt/rebecca/.env"
            export PANEL_DEF_CERTS="/var/lib/rebecca/certs"
            export DATA_DIR="/var/lib/rebecca"
            export NODE_DIR="/opt/rebecca-node"
            export NODE_ENV="/opt/rebecca-node/.env"
            export NODE_DEF_CERTS="/var/lib/rebecca-node/certs"
            ;;
        *)
            select_panel
            return
            ;;
    esac
}

# --- Detect Active Panel (برای سازگاری با کدهای قبلی) ---
detect_active_panel() {
    load_panel_config
    cat "$CONFIG_FILE" 2>/dev/null || echo "unknown"
}

# --- Change Panel (برای منوی تنظیمات) ---
change_panel() {
    echo -e "${YELLOW}Current Panel: $(cat $CONFIG_FILE 2>/dev/null)${NC}"
    select_panel
}

# --- Initialize on load ---
load_panel_config

# --- GitHub URL ---
export THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/templates/subscription/index.html"

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

get_panel_cli() {
    local panel=$(cat "$CONFIG_FILE" 2>/dev/null)
    case "$panel" in
        rebecca) echo "rebecca-cli" ;;
        pasarguard) echo "pasarguard-cli" ;;
        marzban) echo "marzban-cli" ;;
        *) echo "marzban-cli" ;;
    esac
}

restart_service() {
    local SERVICE=$1
    load_panel_config

    if [ "$SERVICE" == "panel" ]; then
        echo -e "${BLUE}Restarting Panel ($PANEL_DIR)...${NC}"
        if [ -d "$PANEL_DIR" ]; then
            cd "$PANEL_DIR" && docker compose down && docker compose up -d
            echo -e "${GREEN}Done.${NC}"
        else
            echo -e "${RED}Panel not found at $PANEL_DIR${NC}"
        fi
    elif [ "$SERVICE" == "node" ]; then
        echo -e "${BLUE}Restarting Node ($NODE_DIR)...${NC}"
        if [ -d "$NODE_DIR" ]; then
            cd "$NODE_DIR" && docker compose restart
            echo -e "${GREEN}Done.${NC}"
        else
            echo -e "${RED}Node directory not found at $NODE_DIR${NC}"
        fi
    fi
}

# --- Admin Management ---

admin_create() {
    local cli=$(get_panel_cli)
    local cid=$(docker compose -f "$PANEL_DIR/docker-compose.yml" ps -q 2>/dev/null | head -1)

    if [ -z "$cid" ]; then
        echo -e "${RED}Panel is not running!${NC}"
        return
    fi

    echo -e "${CYAN}Creating Admin for $(cat $CONFIG_FILE)${NC}"
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
    local cid=$(docker compose -f "$PANEL_DIR/docker-compose.yml" ps -q 2>/dev/null | head -1)

    if [ -z "$cid" ]; then echo -e "${RED}Panel not running${NC}"; return; fi

    read -p "Username to reset password: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin update --username "$user" --password
    fi
}

admin_delete() {
    local cli=$(get_panel_cli)
    local cid=$(docker compose -f "$PANEL_DIR/docker-compose.yml" ps -q 2>/dev/null | head -1)

    if [ -z "$cid" ]; then echo -e "${RED}Panel not running${NC}"; return; fi

    read -p "Username to delete: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin delete --username "$user"
    fi
}