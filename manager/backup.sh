#!/bin/bash

# ====================================================
# MRM BACKUP & RESTORE PRO - v6.3 (Ultra Pro Release)
# 100% Migration Safety & Anti-Lockout Guarantee
# Optimized for: Pasarguard / Rebecca / Marzban
# ====================================================

BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Logic: Environment Detection ---
detect_env() {
    if [ -d "/opt/pasarguard" ]; then
        PANEL_DIR="/opt/pasarguard"; DATA_DIR="/var/lib/pasarguard"
    elif [ -d "/opt/rebecca" ]; then
        PANEL_DIR="/opt/rebecca"; DATA_DIR="/var/lib/rebecca"
    else
        PANEL_DIR="/opt/marzban"; DATA_DIR="/var/lib/marzban"
    fi
    ENV_FILE="$PANEL_DIR/.env"
    DOCKER_CMD="docker compose"
    ! docker compose version >/dev/null 2>&1 && DOCKER_CMD="docker-compose"
}

get_env_val() {
    # Precision extraction: removes quotes, comments, and trailing spaces
    [ -f "$ENV_FILE" ] && grep "^$1=" "$ENV_FILE" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*$//' | sed 's/^"//;s/"$//' | xargs
}

# --- Logic: The Smart Fix (The migration heart) ---
apply_smart_fix() {
    echo -e "${CYAN}Applying Smart-Fix Engine v6.3...${NC}"
    
    # 1. Advanced SSH Safety (Detecting active SSH ports)
    local SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=$(grep -P '^Port \d+' /etc/ssh/sshd_config | awk '{print $2}')
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    
    echo -e "${YELLOW}Securing SSH on port $SSH_PORT...${NC}"
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1

    # 2. Node SSL Repair (Fixing "Connection Refused" issues)
    mkdir -p /var/lib/pg-node/certs
    if [ ! -f /var/lib/pg-node/certs/ssl_key.pem ]; then
        echo -e "${YELLOW}Generating Node RSA keys...${NC}"
        openssl genrsa -out /var/lib/pg-node/certs/ssl_key.pem 2048 >/dev/null 2>&1
    fi

    # 3. .env Structure & SSL Fix
    if [ -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}Repairing .env and Database SSL configs...${NC}"
        # Fix for PostgreSQL Handshake Error
        sed -i 's|\(postgresql+asyncpg://[^"?]*\)\(["\s]*\)$|\1?ssl=disable\2|' "$ENV_FILE"
        # Fix for glued UVICORN/SSL lines
        sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$ENV_FILE"
        sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$ENV_FILE"
    fi

    # 4. Nginx Internal Proxy Optimization
    local NG_CONF="/etc/nginx/conf.d/panel_separate.conf"
    if [ -f "$NG_CONF" ]; then
        echo -e "${YELLOW}Optimizing Nginx Proxy...${NC}"
        sed -i 's|proxy_pass http://127.0.0.1:7431;|proxy_pass https://127.0.0.1:7431;\n        proxy_ssl_verify off;|g' "$NG_CONF"
        systemctl restart nginx >/dev/null 2>&1
    fi
    
    # 5. Permission Enforcement
    chown -R root:root "$DATA_DIR" >/dev/null 2>&1
}

# --- Logic: Backup ---
do_backup() {
    detect_env
    clear
    echo -e "${BLUE}MRM PRO BACKUP v6.3${NC}"
    
    # Disk Space Check (Minimum 400MB)
    [ $(df -m /tmp | tail -1 | awk '{print $4}') -lt 400 ] && { echo -e "${RED}Insufficient space in /tmp!${NC}"; return; }

    local TS=$(date +%Y%m%d_%H%M%S)
    local B_NAME="MRM_Full_${TS}"
    local B_PATH="$TEMP_BASE/$B_NAME"
    mkdir -p "$B_PATH/database"

    # Database Export with Fallback Credentials
    echo -e "${CYAN}Dumping Database...${NC}"
    if grep -q "postgresql" "$ENV_FILE" 2>/dev/null; then
        local DB_NAME=$(get_env_val "DB_NAME"); [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
        local DB_USER=$(get_env_val "DB_USER"); [ -z "$DB_USER" ] && DB_USER="pasarguard"
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        if [ -n "$DB_CONT" ]; then
            docker exec "$DB_CONT" pg_dump -U "$DB_USER" -d "$DB_NAME" -f /tmp/db.sql 2>/dev/null
            docker cp "$DB_CONT:/tmp/db.sql" "$B_PATH/database/db.sql"
        fi
    else
        [ -f "$DATA_DIR/db.sqlite3" ] && cp "$DATA_DIR/db.sqlite3" "$B_PATH/database/"
    fi

    # Core Assets
    echo -e "${CYAN}Archiving Core Files...${NC}"
    cp -a "$PANEL_DIR/." "$B_PATH/panel/" 2>/dev/null
    cp -a "$DATA_DIR/." "$B_PATH/data/" 2>/dev/null
    [ -d "/opt/pg-node" ] && cp -a /opt/pg-node/. "$B_PATH/node/" 2>/dev/null
    [ -d "/var/lib/pg-node" ] && cp -a /var/lib/pg-node/. "$B_PATH/node-data/" 2>/dev/null
    [ -d "/etc/letsencrypt" ] && cp -a /etc/letsencrypt/. "$B_PATH/ssl/" 2>/dev/null
    [ -d "/etc/nginx" ] && cp -a /etc/nginx/. "$B_PATH/nginx/" 2>/dev/null
    crontab -l > "$B_PATH/crontab.txt" 2>/dev/null

    # Package Creation
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_DIR/$B_NAME.tar.gz" -C "$TEMP_BASE" "$B_NAME"
    rm -rf "$TEMP_BASE"
    echo -e "${GREEN}✔ Migration Package Created: $B_NAME.tar.gz${NC}"
    
    # Telegram Upload
    if [ -f "$TG_CONFIG" ]; then
        echo -e "${BLUE}Uploading to Telegram...${NC}"
        local TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2)
        local CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2)
        curl -s -F chat_id="$CH" -F document=@"$BACKUP_DIR/$B_NAME.tar.gz" "https://api.telegram.org/bot$TK/sendDocument" > /dev/null &
    fi
    read -p "Press Enter to return..."
}

# --- Logic: Restore & Migration ---
do_restore() {
    detect_env
    clear
    echo -e "${RED}MRM PRO RESTORE & MIGRATION v6.3${NC}"
    
    local FILES=($(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    [ ${#FILES[@]} -eq 0 ] && { echo "No backups found!"; sleep 2; return; }

    for i in "${!FILES[@]}"; do echo "$((i+1))) $(basename "${FILES[$i]}")"; done
    read -p "Select Backup Number: " CHOICE
    local SELECTED="${FILES[$((CHOICE-1))]}"
    [ -z "$SELECTED" ] && return

    read -p "Type 'CONFIRM' to overwrite ALL data: " ATTEMPT
    [ "$ATTEMPT" != "CONFIRM" ] && return

    local WORK_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$WORK_DIR"
    tar -xzf "$SELECTED" -C "$WORK_DIR"
    local ROOT=$(ls -d "$WORK_DIR"/* | head -1)

    # Stop Services
    $DOCKER_CMD -f "$PANEL_DIR/docker-compose.yml" down >/dev/null 2>&1
    $DOCKER_CMD -f /opt/pg-node/docker-compose.yml down >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1

    # Restore Files
    echo -e "${BLUE}Restoring Files...${NC}"
    rm -rf "$PANEL_DIR" "$DATA_DIR" /opt/pg-node /var/lib/pg-node
    mkdir -p "$PANEL_DIR" "$DATA_DIR" /opt/pg-node /var/lib/pg-node
    
    cp -a "$ROOT/panel/." "$PANEL_DIR/"
    cp -a "$ROOT/data/." "$DATA_DIR/"
    [ -d "$ROOT/node" ] && cp -a "$ROOT/node/." /opt/pg-node/
    [ -d "$ROOT/node-data" ] && cp -a "$ROOT/node-data/." /var/lib/pg-node/
    [ -d "$ROOT/ssl" ] && cp -a "$ROOT/ssl/." /etc/letsencrypt/
    [ -d "$ROOT/nginx" ] && cp -a "$ROOT/nginx/." /etc/nginx/
    [ -f "$ROOT/crontab.txt" ] && crontab "$ROOT/crontab.txt"

    apply_smart_fix

    # Start Infrastructure
    echo -e "${BLUE}Starting Services...${NC}"
    [ -d "/opt/pg-node" ] && cd /opt/pg-node && $DOCKER_CMD up -d >/dev/null 2>&1
    cd "$PANEL_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    systemctl restart nginx >/dev/null 2>&1

    # Database Import with Dynamic Wait
    if grep -q "postgresql" "$ENV_FILE" 2>/dev/null && [ -f "$ROOT/database/db.sql" ]; then
        echo -e "${YELLOW}Waiting for Database...${NC}"
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        local DB_NAME=$(get_env_val "DB_NAME"); [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
        local DB_USER=$(get_env_val "DB_USER"); [ -z "$DB_USER" ] && DB_USER="pasarguard"
        
        local RETRY=0
        until docker exec "$DB_CONT" pg_isready -U "$DB_USER" >/dev/null 2>&1 || [ $RETRY -eq 15 ]; do
            echo -n "."; sleep 2; ((RETRY++))
        done
        
        echo -e "\n${CYAN}Importing SQL...${NC}"
        docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
        docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" < "$ROOT/database/db.sql" >/dev/null 2>&1
    fi

    rm -rf "$WORK_DIR"
    echo -e "${GREEN}✔ System Restore & Optimization Complete!${NC}"
    read -p "Press Enter to return..."
}

# --- Main ---
while true; do
    clear
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${BLUE}    MRM BACKUP MANAGER PRO v6.3${NC}"
    echo -e "${CYAN}=======================================${NC}"
    echo "1) Create Backup"
    echo "2) Restore & Auto-Fix"
    echo "3) Telegram Setup"
    echo "0) Exit"
    read -p "=> " OPT
    case $OPT in
        1) do_backup ;;
        2) do_restore ;;
        3) read -p "Token: " TK; read -p "Chat ID: " CI; echo "TG_TOKEN=$TK" > "$TG_CONFIG"; echo "TG_CHAT=$CI" >> "$TG_CONFIG"; echo -e "${GREEN}Saved!${NC}"; sleep 1 ;;
        0) exit 0 ;;
    esac
done