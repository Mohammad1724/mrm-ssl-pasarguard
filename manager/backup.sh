#!/bin/bash

# ====================================================
# MRM BACKUP & RESTORE PRO - v6.5 (Final Debugged)
# Fixed Menu Logic & Full DB Import Integration
# ====================================================

BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"
SCRIPT_PATH="$(readlink -f "$0")"

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
    [ -f "$ENV_FILE" ] && grep "^$1=" "$ENV_FILE" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*$//' | sed 's/^"//;s/"$//' | xargs
}

# --- Logic: Telegram ---
send_to_telegram() {
    local FILE="$1"
    if [ -f "$TG_CONFIG" ]; then
        local TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
        local CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
        [ -z "$TK" ] || [ -z "$CH" ] && return 1
        local CAPTION="✅ MRM Backup - $(hostname) - $(date '+%Y-%m-%d %H:%M')"
        curl -s -F chat_id="$CH" -F caption="$CAPTION" -F document=@"$FILE" "https://api.telegram.org/bot$TK/sendDocument" > /dev/null
        return $?
    fi
    return 1
}

setup_scheduler() {
    clear
    echo -e "${CYAN}=== BACKUP SCHEDULER ===${NC}"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every 24 hours"
    echo "4) Disable Auto-Backup"
    read -p "Select: " CRON_OPT
    case $CRON_OPT in
        1) TIME="0 */6 * * *" ;;
        2) TIME="0 */12 * * *" ;;
        3) TIME="0 0 * * *" ;;
        4) (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH") | crontab -; echo "Disabled."; sleep 1; return ;;
        *) return ;;
    esac
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" ; echo "$TIME $SCRIPT_PATH auto > /dev/null 2>&1") | crontab -
    echo -e "${GREEN}Scheduled!${NC}"; sleep 1
}

# --- Logic: Fixes ---
apply_smart_fix() {
    echo -e "${CYAN}Applying Auto-Fixes...${NC}"
    local SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    mkdir -p /var/lib/pg-node/certs
    [ ! -f /var/lib/pg-node/certs/ssl_key.pem ] && openssl genrsa -out /var/lib/pg-node/certs/ssl_key.pem 2048 >/dev/null 2>&1
    if [ -f "$ENV_FILE" ]; then
        sed -i 's|\(postgresql+asyncpg://[^"?]*\)\(["\s]*\)$|\1?ssl=disable\2|' "$ENV_FILE"
        sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$ENV_FILE"
        sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$ENV_FILE"
    fi
    systemctl restart nginx >/dev/null 2>&1
}

# --- Logic: Backup ---
do_backup() {
    local MODE="$1"
    detect_env
    [ "$MODE" != "auto" ] && clear && echo -e "${BLUE}Creating Backup...${NC}"
    local TS=$(date +%Y%m%d_%H%M%S); local B_NAME="MRM_Full_${TS}"
    local B_PATH="$TEMP_BASE/$B_NAME"; mkdir -p "$B_PATH/database"

    if grep -q "postgresql" "$ENV_FILE" 2>/dev/null; then
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        if [ -n "$DB_CONT" ]; then
            docker exec "$DB_CONT" pg_dump -U pasarguard -d pasarguard -f /tmp/db.sql 2>/dev/null
            docker cp "$DB_CONT:/tmp/db.sql" "$B_PATH/database/db.sql" 2>/dev/null
        fi
    else
        [ -f "$DATA_DIR/db.sqlite3" ] && cp "$DATA_DIR/db.sqlite3" "$B_PATH/database/"
    fi
    cp -a "$PANEL_DIR/." "$B_PATH/panel/" 2>/dev/null
    cp -a "$DATA_DIR/." "$B_PATH/data/" 2>/dev/null
    [ -d "/opt/pg-node" ] && cp -a /opt/pg-node/. "$B_PATH/node/" 2>/dev/null
    [ -d "/var/lib/pg-node" ] && cp -a /var/lib/pg-node/. "$B_PATH/node-data/" 2>/dev/null
    [ -d "/etc/letsencrypt" ] && cp -a /etc/letsencrypt/. "$B_PATH/ssl/" 2>/dev/null
    [ -d "/etc/nginx" ] && cp -a /etc/nginx/. "$B_PATH/nginx/" 2>/dev/null

    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_DIR/$B_NAME.tar.gz" -C "$TEMP_BASE" "$B_NAME"
    rm -rf "$TEMP_BASE"
    send_to_telegram "$BACKUP_DIR/$B_NAME.tar.gz"
    ls -t "$BACKUP_DIR"/*.tar.gz | tail -n +6 | xargs rm -f 2>/dev/null
    [ "$MODE" != "auto" ] && echo -e "${GREEN}Backup Done.${NC}" && sleep 2
}

# --- Logic: Restore ---
do_restore() {
    detect_env
    clear
    local FILES=($(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    [ ${#FILES[@]} -eq 0 ] && { echo "No backups!"; sleep 2; return; }
    for i in "${!FILES[@]}"; do echo "$((i+1))) $(basename "${FILES[$i]}")"; done
    read -p "Choice: " CH; local SELECTED="${FILES[$((CH-1))]}"
    [ -z "$SELECTED" ] && return
    read -p "Type 'CONFIRM': " CONF; [ "$CONF" != "CONFIRM" ] && return

    local WORK_DIR="/tmp/mrm_res_$(date +%s)"; mkdir -p "$WORK_DIR"
    tar -xzf "$SELECTED" -C "$WORK_DIR"; local ROOT=$(ls -d "$WORK_DIR"/* | head -1)

    $DOCKER_CMD -f "$PANEL_DIR/docker-compose.yml" down >/dev/null 2>&1
    $DOCKER_CMD -f /opt/pg-node/docker-compose.yml down >/dev/null 2>&1
    rm -rf "$PANEL_DIR" "$DATA_DIR" /opt/pg-node /var/lib/pg-node
    mkdir -p "$PANEL_DIR" "$DATA_DIR" /opt/pg-node /var/lib/pg-node
    cp -a "$ROOT/panel/." "$PANEL_DIR/"
    cp -a "$ROOT/data/." "$DATA_DIR/"
    cp -a "$ROOT/node/." /opt/pg-node/ 2>/dev/null
    cp -a "$ROOT/node-data/." /var/lib/pg-node/ 2>/dev/null
    cp -a "$ROOT/ssl/." /etc/letsencrypt/ 2>/dev/null
    cp -a "$ROOT/nginx/." /etc/nginx/ 2>/dev/null
    
    apply_smart_fix
    cd /opt/pg-node && $DOCKER_CMD up -d >/dev/null 2>&1
    cd "$PANEL_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    
    if grep -q "postgresql" "$ENV_FILE" 2>/dev/null && [ -f "$ROOT/database/db.sql" ]; then
        echo "Importing DB..."; sleep 12
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        docker exec "$DB_CONT" psql -U pasarguard -d pasarguard -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
        docker exec -i "$DB_CONT" psql -U pasarguard -d pasarguard < "$ROOT/database/db.sql" >/dev/null 2>&1
    fi
    rm -rf "$WORK_DIR"
    echo -e "${GREEN}Restore Done.${NC}"; sleep 2
}

# --- Main ---
if [ "$1" == "auto" ]; then
    do_backup "auto"
else
    while true; do
        clear
        echo -e "${BLUE}MRM BACKUP MANAGER v6.5${NC}"
        echo "1) Backup & Telegram"
        echo "2) Restore & Fix"
        echo "3) Setup Bot"
        echo "4) Setup Scheduler"
        echo "0) Exit"
        read -p "Select: " opt
        case $opt in
            1) do_backup "manual" ;;
            2) do_restore ;;
            3) read -p "Token: " TK; read -p "Chat ID: " CI; echo "TG_TOKEN=$TK" > "$TG_CONFIG"; echo "TG_CHAT=$CI" >> "$TG_CONFIG"; echo "Saved."; sleep 1 ;;
            4) setup_scheduler ;;
            0) exit 0 ;;
            *) echo "Invalid"; sleep 1 ;;
        esac
    done
fi