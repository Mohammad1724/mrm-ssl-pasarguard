#!/bin/bash

# ==========================================
# MRM BACKUP & RESTORE PRO v7.2
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"
export LANG="en_US.UTF-8"

# Configuration
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"
SCRIPT_PATH="$(readlink -f "$0")"
BACKUP_LOG="/var/log/mrm-backup.log"

# Find binaries with full path
CURL_BIN=$(which curl 2>/dev/null || echo "/usr/bin/curl")
DOCKER_BIN=$(which docker 2>/dev/null || echo "/usr/bin/docker")
TAR_BIN=$(which tar 2>/dev/null || echo "/bin/tar")

# Colors (only for interactive mode)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ==========================================
# CHECK IF RUNNING IN AUTO MODE
# ==========================================
AUTO_MODE=false
[ "$1" == "auto" ] && AUTO_MODE=true

# ==========================================
# LOAD MODULES (only in interactive mode)
# ==========================================
if [ "$AUTO_MODE" = false ]; then
    if [ -f "/opt/mrm-manager/utils.sh" ]; then
        source /opt/mrm-manager/utils.sh
    fi
    if [ -f "/opt/mrm-manager/ui.sh" ]; then
        source /opt/mrm-manager/ui.sh
    fi
fi

# ==========================================
# FALLBACK FUNCTIONS (for auto mode)
# ==========================================
if ! declare -f ui_header >/dev/null 2>&1; then
    ui_header() { echo "=== $1 ==="; }
fi
if ! declare -f ui_success >/dev/null 2>&1; then
    ui_success() { echo "[OK] $1"; }
fi
if ! declare -f ui_error >/dev/null 2>&1; then
    ui_error() { echo "[ERROR] $1"; }
fi
if ! declare -f ui_warning >/dev/null 2>&1; then
    ui_warning() { echo "[WARN] $1"; }
fi
if ! declare -f ui_spinner_start >/dev/null 2>&1; then
    ui_spinner_start() { echo "$1"; }
fi
if ! declare -f ui_spinner_stop >/dev/null 2>&1; then
    ui_spinner_stop() { :; }
fi
if ! declare -f pause >/dev/null 2>&1; then
    pause() { read -p "Press Enter to continue..."; }
fi

# ==========================================
# LOGGING
# ==========================================
init_backup_logging() {
    mkdir -p "$(dirname "$BACKUP_LOG")" 2>/dev/null
    touch "$BACKUP_LOG" 2>/dev/null
    chmod 644 "$BACKUP_LOG" 2>/dev/null
}

log_backup() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MESSAGE" >> "$BACKUP_LOG" 2>/dev/null
}

# ==========================================
# PANEL DETECTION (standalone)
# ==========================================
detect_panel_standalone() {
    # Default paths
    PANEL_DIR=""
    DATA_DIR=""
    NODE_DIR=""
    PANEL_ENV=""
    NODE_ENV=""
    NODE_DEF_CERTS=""

    # Check Marzban
    if [ -d "/opt/marzban" ]; then
        PANEL_DIR="/opt/marzban"
        DATA_DIR="/var/lib/marzban"
        NODE_DIR="/opt/marzban-node"
        PANEL_ENV="/opt/marzban/.env"
        NODE_ENV="/opt/marzban-node/.env"
        NODE_DEF_CERTS="/var/lib/marzban-node/certs"
    # Check Marzneshin
    elif [ -d "/opt/marzneshin" ]; then
        PANEL_DIR="/opt/marzneshin"
        DATA_DIR="/var/lib/marzneshin"
        NODE_DIR="/opt/marzneshin-node"
        PANEL_ENV="/opt/marzneshin/.env"
        NODE_ENV="/opt/marzneshin-node/.env"
        NODE_DEF_CERTS="/var/lib/marzneshin-node/certs"
    # Check other locations
    elif [ -d "/root/marzban" ]; then
        PANEL_DIR="/root/marzban"
        DATA_DIR="/var/lib/marzban"
        PANEL_ENV="/root/marzban/.env"
    fi

    log_backup "INFO" "Panel detected: $PANEL_DIR"
}

# ==========================================
# ENVIRONMENT DETECTION
# ==========================================
setup_env() {
    # Try to use detect_active_panel if available
    if declare -f detect_active_panel >/dev/null 2>&1; then
        detect_active_panel > /dev/null 2>&1
    else
        detect_panel_standalone
    fi

    # Docker command detection
    DOCKER_CMD="docker compose"
    if ! $DOCKER_BIN compose version >/dev/null 2>&1; then
        DOCKER_CMD="docker-compose"
    fi

    log_backup "INFO" "Environment: PANEL_DIR=$PANEL_DIR, DATA_DIR=$DATA_DIR"
}

get_env_val() {
    [ -f "$PANEL_ENV" ] && grep "^$1=" "$PANEL_ENV" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*$//' | sed 's/^"//;s/"$//' | xargs
}

# ==========================================
# GET CURRENT SERVER IP
# ==========================================
get_server_ip() {
    local IP=""

    IP=$($CURL_BIN -s --connect-timeout 5 ifconfig.me 2>/dev/null)
    [ -z "$IP" ] && IP=$($CURL_BIN -s --connect-timeout 5 icanhazip.com 2>/dev/null)
    [ -z "$IP" ] && IP=$($CURL_BIN -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null)
    [ -z "$IP" ] && IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+')

    echo "$IP"
}

# ==========================================
# FIX ENV FILE (Broken Lines)
# ==========================================
fix_env_file() {
    local ENV_FILE=$1

    [ ! -f "$ENV_FILE" ] && return

    log_backup "INFO" "Fixing .env file: $ENV_FILE"

    local TEMP_FILE=$(mktemp)
    local prev_line=""

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$prev_line" =~ ^UVICORN_$ ]] || [[ "$prev_line" =~ ^SSL_$ ]]; then
            echo "${prev_line}${line}" >> "$TEMP_FILE"
            prev_line=""
        elif [[ "$line" =~ ^UVICORN_$ ]] || [[ "$line" =~ ^SSL_$ ]]; then
            prev_line="$line"
        else
            [ -n "$prev_line" ] && echo "$prev_line" >> "$TEMP_FILE"
            echo "$line" >> "$TEMP_FILE"
            prev_line=""
        fi
    done < "$ENV_FILE"

    [ -n "$prev_line" ] && echo "$prev_line" >> "$TEMP_FILE"

    sed -i ':a;N;$!ba;s/UVICORN_\nSSL_CERTFILE/UVICORN_SSL_CERTFILE/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/UVICORN_\nSSL_KEYFILE/UVICORN_SSL_KEYFILE/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/UVICORN_\n/UVICORN_/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/SSL_\n/SSL_/g' "$TEMP_FILE"
    sed -i 's/[[:space:]]*=[[:space:]]*/=/g' "$TEMP_FILE"
    sed -i 's/UVICORN_ SSL_CERTFILE/UVICORN_SSL_CERTFILE/g' "$TEMP_FILE"
    sed -i 's/UVICORN_ SSL_KEYFILE/UVICORN_SSL_KEYFILE/g' "$TEMP_FILE"

    cat -s "$TEMP_FILE" > "$ENV_FILE"
    rm -f "$TEMP_FILE"

    log_backup "SUCCESS" "Fixed .env file: $ENV_FILE"
}

# ==========================================
# FIX DOCKER COMPOSE (Update IPs)
# ==========================================
fix_docker_compose() {
    local COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"

    [ ! -f "$COMPOSE_FILE" ] && return

    local NEW_IP=$(get_server_ip)
    [ -z "$NEW_IP" ] && return

    log_backup "INFO" "Updating docker-compose with new IP: $NEW_IP"

    if grep -q "PGADMIN_LISTEN_ADDRESS" "$COMPOSE_FILE"; then
        sed -i "s/PGADMIN_LISTEN_ADDRESS:.*/PGADMIN_LISTEN_ADDRESS: $NEW_IP/g" "$COMPOSE_FILE"
    fi

    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8010/${NEW_IP}:8010/g" "$COMPOSE_FILE"
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:7431/${NEW_IP}:7431/g" "$COMPOSE_FILE"
    sed -i -E "s/--bind [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/--bind ${NEW_IP}:/g" "$COMPOSE_FILE"

    log_backup "SUCCESS" "Updated docker-compose.yml with IP: $NEW_IP"
}

# ==========================================
# TELEGRAM INTEGRATION
# ==========================================
send_to_telegram() {
    local FILE="$1"
    local MESSAGE="${2:-}"

    log_backup "INFO" "send_to_telegram called - File: $FILE"

    if [ ! -f "$TG_CONFIG" ]; then
        log_backup "ERROR" "Telegram config not found: $TG_CONFIG"
        return 1
    fi

    # Read config
    local TK=$(grep "^TG_TOKEN" "$TG_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
    local CH=$(grep "^TG_CHAT" "$TG_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')

    log_backup "DEBUG" "Token length: ${#TK}, Chat ID: $CH"

    if [ -z "$TK" ] || [ -z "$CH" ]; then
        log_backup "ERROR" "Invalid Telegram config - Token or Chat ID empty"
        return 1
    fi

    if [ -n "$FILE" ] && [ -f "$FILE" ]; then
        local FILE_SIZE=$(du -h "$FILE" | cut -f1)
        log_backup "INFO" "Sending file to Telegram: $(basename "$FILE") ($FILE_SIZE)"

        local CAPTION="✅ MRM Auto Backup
🖥 Host: $(hostname)
🌐 IP: $(get_server_ip)
📅 $(date '+%Y-%m-%d %H:%M:%S')
📦 $(basename "$FILE")
💾 Size: $FILE_SIZE"

        # Send with timeout
        local RESULT=$($CURL_BIN -s -m 600 \
            --connect-timeout 30 \
            -F chat_id="$CH" \
            -F caption="$CAPTION" \
            -F document=@"$FILE" \
            "https://api.telegram.org/bot${TK}/sendDocument" 2>&1)

        log_backup "DEBUG" "Telegram API response: $RESULT"

        if echo "$RESULT" | grep -q '"ok":true'; then
            log_backup "SUCCESS" "File sent to Telegram successfully!"
            return 0
        else
            local ERROR_DESC=$(echo "$RESULT" | grep -oP '"description":"[^"]*"' | cut -d'"' -f4)
            log_backup "ERROR" "Telegram send failed: $ERROR_DESC"
            return 1
        fi
    elif [ -n "$MESSAGE" ]; then
        $CURL_BIN -s -m 30 -X POST "https://api.telegram.org/bot${TK}/sendMessage" \
            -d chat_id="$CH" \
            -d text="$MESSAGE" > /dev/null 2>&1
        return $?
    fi

    return 1
}

test_telegram() {
    if [ ! -f "$TG_CONFIG" ]; then
        ui_error "Telegram not configured!"
        return 1
    fi

    ui_spinner_start "Testing Telegram connection..."

    local TK=$(grep "^TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
    local CH=$(grep "^TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')

    local RESULT=$($CURL_BIN -s -m 30 -X POST "https://api.telegram.org/bot${TK}/sendMessage" \
        -d chat_id="$CH" \
        -d text="🧪 MRM Backup Test - $(date '+%Y-%m-%d %H:%M')" 2>&1)

    ui_spinner_stop

    if echo "$RESULT" | grep -q '"ok":true'; then
        ui_success "Telegram connection successful!"
        return 0
    else
        ui_error "Telegram connection failed!"
        echo -e "${YELLOW}Error: $RESULT${NC}"
        return 1
    fi
}

setup_telegram() {
    ui_header "SETUP TELEGRAM BOT"

    echo -e "${CYAN}To get Bot Token:${NC}"
    echo "  1. Message @BotFather on Telegram"
    echo "  2. Send /newbot and follow instructions"
    echo "  3. Copy the token"
    echo ""
    echo -e "${CYAN}To get Chat ID:${NC}"
    echo "  1. Message @userinfobot on Telegram"
    echo "  2. It will show your Chat ID"
    echo ""

    read -p "Enter Bot Token: " TK
    if [ -z "$TK" ]; then
        ui_error "Token is required!"
        pause
        return
    fi

    read -p "Enter Chat ID: " CI
    if [ -z "$CI" ]; then
        ui_error "Chat ID is required!"
        pause
        return
    fi

    # Save without extra quotes
    echo "TG_TOKEN=$TK" > "$TG_CONFIG"
    echo "TG_CHAT=$CI" >> "$TG_CONFIG"
    chmod 600 "$TG_CONFIG"

    ui_success "Telegram configured!"
    log_backup "INFO" "Telegram bot configured"

    echo ""
    read -p "Test connection now? (Y/n): " TEST
    if [[ ! "$TEST" =~ ^[Nn]$ ]]; then
        test_telegram
    fi

    pause
}

# ==========================================
# SMART FIX ENGINE
# ==========================================
apply_smart_fix() {
    echo -e "${CYAN}Applying Intelligent System Repairs...${NC}"
    log_backup "INFO" "Starting smart fix"

    local SERVER_IP=$(get_server_ip)
    echo -e "${BLUE}Detected Server IP: ${CYAN}$SERVER_IP${NC}"

    ui_spinner_start "Configuring Firewall..."
    local SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Firewall configured (SSH: $SSH_PORT)"

    ui_spinner_start "Fixing .env files..."
    fix_env_file "$PANEL_ENV"
    fix_env_file "$NODE_ENV"
    ui_spinner_stop
    ui_success ".env files repaired"

    ui_spinner_start "Updating docker-compose IPs..."
    fix_docker_compose
    ui_spinner_stop
    ui_success "Docker compose updated with IP: $SERVER_IP"

    if [ -f "$NODE_ENV" ]; then
        ui_spinner_start "Fixing Node configuration..."
        sed -i 's/=[[:space:]]*/=/g' "$NODE_ENV"
        sed -i 's/[[:space:]]*=/=/g' "$NODE_ENV"
        ui_spinner_stop
        ui_success "Node .env fixed"
    fi

    if [ -d "$NODE_DIR" ]; then
        mkdir -p "$NODE_DEF_CERTS"
        if [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then
            ui_spinner_start "Generating Node SSL key..."
            openssl genrsa -out "$NODE_DEF_CERTS/ssl_key.pem" 2048 >/dev/null 2>&1
            ui_spinner_stop
            ui_success "Node SSL key generated"
        fi
    fi

    local NG_CONF="/etc/nginx/conf.d/panel_separate.conf"
    if [ -f "$NG_CONF" ]; then
        ui_spinner_start "Fixing Nginx config..."
        sed -i 's|proxy_pass http://127.0.0.1:7431;|proxy_pass https://127.0.0.1:7431;\n        proxy_ssl_verify off;|g' "$NG_CONF"
        systemctl restart nginx >/dev/null 2>&1
        ui_spinner_stop
        ui_success "Nginx configuration repaired"
    fi

    log_backup "SUCCESS" "Smart fix completed"
}

# ==========================================
# BACKUP FUNCTIONS
# ==========================================
do_backup() {
    local MODE="${1:-manual}"

    # Initialize
    init_backup_logging
    log_backup "INFO" "########## BACKUP STARTED (mode: $MODE) ##########"

    # Setup environment
    setup_env

    [ "$MODE" != "auto" ] && ui_header "FULL SYSTEM BACKUP"

    local TS=$(date +%Y%m%d_%H%M%S)
    local B_NAME="MRM_Full_${TS}"
    local B_PATH="$TEMP_BASE/$B_NAME"

    mkdir -p "$B_PATH/database" "$B_PATH/panel" "$B_PATH/data"
    mkdir -p "$BACKUP_DIR"

    # 1. Export Database
    [ "$MODE" != "auto" ] && ui_spinner_start "Exporting database..."

    if grep -q "postgresql" "$PANEL_ENV" 2>/dev/null; then
        local DB_CONT=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -iE "timescale|postgres" | head -1)
        if [ -n "$DB_CONT" ]; then
            $DOCKER_BIN exec "$DB_CONT" pg_dump -U pasarguard -d pasarguard -f /tmp/db.sql 2>/dev/null
            $DOCKER_BIN cp "$DB_CONT:/tmp/db.sql" "$B_PATH/database/db.sql" 2>/dev/null
            log_backup "INFO" "PostgreSQL exported"
        fi
    else
        [ -f "$DATA_DIR/db.sqlite3" ] && cp "$DATA_DIR/db.sqlite3" "$B_PATH/database/"
        log_backup "INFO" "SQLite exported"
    fi

    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported"

    # 2. Collect Panel Files
    [ "$MODE" != "auto" ] && ui_spinner_start "Backing up panel files..."
    cp -a "$PANEL_DIR/." "$B_PATH/panel/" 2>/dev/null
    cp -a "$DATA_DIR/." "$B_PATH/data/" 2>/dev/null
    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Panel files backed up"

    # 3. Collect Node Files
    if [ -d "$NODE_DIR" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up node files..."
        mkdir -p "$B_PATH/node" "$B_PATH/node-data"
        cp -a "$NODE_DIR/." "$B_PATH/node/" 2>/dev/null
        [ -d "$(dirname "$NODE_DEF_CERTS")" ] && cp -a "$(dirname "$NODE_DEF_CERTS")/." "$B_PATH/node-data/" 2>/dev/null
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Node files backed up"
    fi

    # 4. Collect SSL Certificates
    if [ -d "/etc/letsencrypt" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up SSL certificates..."
        mkdir -p "$B_PATH/ssl"
        cp -a /etc/letsencrypt/. "$B_PATH/ssl/" 2>/dev/null
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "SSL certificates backed up"
    fi

    # 5. Collect Nginx Config
    if [ -d "/etc/nginx" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up Nginx config..."
        mkdir -p "$B_PATH/nginx"
        cp -a /etc/nginx/. "$B_PATH/nginx/" 2>/dev/null
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Nginx config backed up"
    fi

    # 6. Save metadata
    local SERVER_IP=$(get_server_ip)
    cat > "$B_PATH/backup_info.txt" << EOF
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Server IP: $SERVER_IP
Panel: $(basename "$PANEL_DIR")
Panel Dir: $PANEL_DIR
Data Dir: $DATA_DIR
Node Dir: $NODE_DIR
MRM Version: 3.0
EOF

    # 7. Create archive
    [ "$MODE" != "auto" ] && ui_spinner_start "Creating backup archive..."
    $TAR_BIN -czf "$BACKUP_DIR/$B_NAME.tar.gz" -C "$TEMP_BASE" "$B_NAME" 2>/dev/null
    local BACKUP_SIZE=$(du -h "$BACKUP_DIR/$B_NAME.tar.gz" 2>/dev/null | cut -f1)
    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Archive created ($BACKUP_SIZE)"

    log_backup "INFO" "Archive created: $B_NAME.tar.gz ($BACKUP_SIZE)"

    # 8. Cleanup temp
    rm -rf "$TEMP_BASE"

    # 9. Send to Telegram
    log_backup "INFO" "Checking Telegram config..."
    if [ -f "$TG_CONFIG" ]; then
        log_backup "INFO" "Telegram config exists, sending backup..."

        [ "$MODE" != "auto" ] && ui_spinner_start "Sending to Telegram..."

        if send_to_telegram "$BACKUP_DIR/$B_NAME.tar.gz"; then
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Backup sent to Telegram!"
        else
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_warning "Failed to send to Telegram"
        fi
    else
        log_backup "WARNING" "Telegram not configured - skipping send"
    fi

    # 10. Cleanup old backups (keep last 5)
    ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null

    log_backup "SUCCESS" "Backup completed: $B_NAME.tar.gz ($BACKUP_SIZE)"
    log_backup "INFO" "########## BACKUP FINISHED ##########"

    if [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ✔ BACKUP COMPLETED!                         ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} File: ${CYAN}$BACKUP_DIR/$B_NAME.tar.gz${NC}"
        echo -e "${GREEN}║${NC} Size: ${CYAN}$BACKUP_SIZE${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
        pause
    fi
}

# ==========================================
# RESTORE FUNCTIONS
# ==========================================
do_restore() {
    setup_env
    ui_header "FULL SYSTEM RESTORE"

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#FILES[@]} -eq 0 ]; then
        ui_error "No backups found in $BACKUP_DIR"
        echo ""
        echo "Options:"
        echo "1) Upload backup file manually to $BACKUP_DIR"
        echo "2) Download from Telegram and place in $BACKUP_DIR"
        pause
        return
    fi

    echo -e "${YELLOW}Available Backups:${NC}"
    echo ""
    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        echo "$((i+1))) $(basename "${FILES[$i]}") [$SIZE] - $DATE"
    done

    echo ""
    read -p "Select backup to restore (0 to cancel): " CH

    [ "$CH" == "0" ] && return

    local SELECTED="${FILES[$((CH-1))]}"
    if [ -z "$SELECTED" ] || [ ! -f "$SELECTED" ]; then
        ui_error "Invalid selection!"
        pause
        return
    fi

    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              ⚠️  WARNING  ⚠️                              ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║  This will OVERWRITE all current data!                   ║${NC}"
    echo -e "${RED}║  Make sure you have a backup of current state.           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Type 'CONFIRM' to proceed: " CONF

    if [ "$CONF" != "CONFIRM" ]; then
        echo "Cancelled."
        pause
        return
    fi

    log_backup "INFO" "Starting restore from: $(basename "$SELECTED")"

    local NEW_SERVER_IP=$(get_server_ip)
    echo -e "${BLUE}Current Server IP: ${CYAN}$NEW_SERVER_IP${NC}"

    local WORK_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$WORK_DIR"

    ui_spinner_start "Extracting backup..."
    $TAR_BIN -xzf "$SELECTED" -C "$WORK_DIR"
    ui_spinner_stop

    local ROOT=$(ls -d "$WORK_DIR"/* | head -1)

    if [ ! -d "$ROOT" ]; then
        ui_error "Invalid backup archive!"
        rm -rf "$WORK_DIR"
        pause
        return
    fi

    if [ -f "$ROOT/backup_info.txt" ]; then
        echo ""
        echo -e "${CYAN}Backup Info:${NC}"
        cat "$ROOT/backup_info.txt"
        echo ""

        local OLD_IP=$(grep "Server IP:" "$ROOT/backup_info.txt" | awk '{print $3}')
        if [ -n "$OLD_IP" ] && [ "$OLD_IP" != "$NEW_SERVER_IP" ]; then
            echo -e "${YELLOW}⚠ IP Changed: $OLD_IP → $NEW_SERVER_IP${NC}"
            echo -e "${GREEN}Will auto-update configurations...${NC}"
            echo ""
        fi
    fi

    ui_spinner_start "Stopping services..."
    $DOCKER_CMD -f "$PANEL_DIR/docker-compose.yml" down >/dev/null 2>&1
    $DOCKER_CMD -f "$NODE_DIR/docker-compose.yml" down >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Services stopped"

    ui_spinner_start "Creating safety backup..."
    local SAFETY_BACKUP="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    $TAR_BIN -czf "$SAFETY_BACKUP" "$PANEL_DIR" "$DATA_DIR" 2>/dev/null
    ui_spinner_stop
    ui_success "Safety backup created"

    ui_spinner_start "Cleaning old files..."
    rm -rf "$PANEL_DIR" "$DATA_DIR" "$NODE_DIR" "$(dirname "$NODE_DEF_CERTS")"
    ui_spinner_stop

    ui_spinner_start "Restoring panel files..."
    mkdir -p "$PANEL_DIR" "$DATA_DIR"
    cp -a "$ROOT/panel/." "$PANEL_DIR/" 2>/dev/null
    cp -a "$ROOT/data/." "$DATA_DIR/" 2>/dev/null
    ui_spinner_stop
    ui_success "Panel files restored"

    if [ -d "$ROOT/node" ]; then
        ui_spinner_start "Restoring node files..."
        mkdir -p "$NODE_DIR" "$(dirname "$NODE_DEF_CERTS")"
        cp -a "$ROOT/node/." "$NODE_DIR/" 2>/dev/null
        cp -a "$ROOT/node-data/." "$(dirname "$NODE_DEF_CERTS")/" 2>/dev/null
        ui_spinner_stop
        ui_success "Node files restored"
    fi

    if [ -d "$ROOT/ssl" ]; then
        ui_spinner_start "Restoring SSL certificates..."
        rm -rf /etc/letsencrypt
        mkdir -p /etc/letsencrypt
        cp -a "$ROOT/ssl/." /etc/letsencrypt/ 2>/dev/null
        ui_spinner_stop
        ui_success "SSL certificates restored"
    fi

    if [ -d "$ROOT/nginx" ]; then
        ui_spinner_start "Restoring Nginx config..."
        cp -a "$ROOT/nginx/." /etc/nginx/ 2>/dev/null
        ui_spinner_stop
        ui_success "Nginx config restored"
    fi

    echo ""
    echo -e "${CYAN}Fixing configurations for new server...${NC}"

    ui_spinner_start "Fixing .env files..."
    fix_env_file "$PANEL_ENV"
    fix_env_file "$NODE_ENV"
    ui_spinner_stop
    ui_success ".env files fixed"

    ui_spinner_start "Updating IPs in docker-compose..."
    fix_docker_compose
    ui_spinner_stop
    ui_success "Docker compose IPs updated"

    apply_smart_fix

    ui_spinner_start "Starting services..."
    if [ -d "$NODE_DIR" ] && [ -f "$NODE_DIR/docker-compose.yml" ]; then
        cd "$NODE_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    fi
    cd "$PANEL_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Services started"

    if grep -q "postgresql" "$PANEL_ENV" 2>/dev/null && [ -f "$ROOT/database/db.sql" ]; then
        echo -e "${YELLOW}Waiting for database to initialize...${NC}"
        sleep 15

        ui_spinner_start "Importing database..."
        local DB_CONT=$($DOCKER_BIN ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        if [ -n "$DB_CONT" ]; then
            $DOCKER_BIN exec "$DB_CONT" psql -U pasarguard -d pasarguard -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
            $DOCKER_BIN exec -i "$DB_CONT" psql -U pasarguard -d pasarguard < "$ROOT/database/db.sql" >/dev/null 2>&1
        fi
        ui_spinner_stop
        ui_success "Database imported"
    fi

    rm -rf "$WORK_DIR"

    log_backup "SUCCESS" "Restore completed from: $(basename "$SELECTED")"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✔ RESTORE COMPLETED!                        ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Server IP: ${CYAN}$NEW_SERVER_IP${NC}"
    echo -e "${GREEN}║${NC} Configurations auto-fixed for new server"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Safety backup: $SAFETY_BACKUP${NC}"

    pause
}

# ==========================================
# CRON SCHEDULER
# ==========================================
setup_cron() {
    ui_header "BACKUP SCHEDULER"

    echo "Current cron status:"
    if crontab -l 2>/dev/null | grep -q "backup.sh"; then
        local CURRENT=$(crontab -l 2>/dev/null | grep "backup.sh")
        echo -e "${GREEN}Active:${NC} $CURRENT"
    else
        echo -e "${YELLOW}No scheduled backup${NC}"
    fi

    echo ""
    echo "Select backup interval:"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every 24 hours (Daily)"
    echo "4) Every week (Sunday)"
    echo "5) Disable scheduled backup"
    echo "0) Cancel"
    echo ""
    read -p "Select: " c

    local CRON_TIME=""
    case $c in
        1) CRON_TIME="0 */6 * * *" ;;
        2) CRON_TIME="0 */12 * * *" ;;
        3) CRON_TIME="0 0 * * *" ;;
        4) CRON_TIME="0 0 * * 0" ;;
        5) CRON_TIME="" ;;
        0) return ;;
        *) ui_error "Invalid selection"; pause; return ;;
    esac

    # Remove old entries and add new one
    (crontab -l 2>/dev/null | grep -v "backup.sh"
     [ -n "$CRON_TIME" ] && echo "$CRON_TIME /bin/bash $SCRIPT_PATH auto >> $BACKUP_LOG 2>&1"
    ) | crontab -

    if [ -n "$CRON_TIME" ]; then
        ui_success "Scheduled backup enabled: $CRON_TIME"
        log_backup "INFO" "Cron scheduled: $CRON_TIME"
        
        echo ""
        echo -e "${CYAN}Cron job set. To verify:${NC}"
        echo "  crontab -l"
    else
        ui_success "Scheduled backup disabled"
        log_backup "INFO" "Cron disabled"
    fi

    pause
}

# ==========================================
# VIEW LOGS
# ==========================================
view_backup_logs() {
    ui_header "BACKUP LOGS"

    if [ -f "$BACKUP_LOG" ]; then
        echo -e "${YELLOW}Last 50 entries:${NC}"
        echo ""
        tail -n 50 "$BACKUP_LOG"
    else
        ui_warning "No logs found"
    fi

    pause
}

# ==========================================
# LIST BACKUPS
# ==========================================
list_backups() {
    ui_header "AVAILABLE BACKUPS"

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#FILES[@]} -eq 0 ]; then
        ui_warning "No backups found"
        pause
        return
    fi

    echo -e "${GREEN}ID │ Filename                              │ Size   │ Date${NC}"
    echo "───┼─────────────────────────────────────────┼────────┼───────────"

    for i in "${!FILES[@]}"; do
        local NAME=$(basename "${FILES[$i]}")
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        printf "%-2s │ %-39s │ %-6s │ %s\n" "$((i+1))" "$NAME" "$SIZE" "$DATE"
    done

    echo ""
    echo -e "Total: ${CYAN}${#FILES[@]}${NC} backups"
    echo -e "Location: ${CYAN}$BACKUP_DIR${NC}"

    pause
}

# ==========================================
# DELETE BACKUP
# ==========================================
delete_backup() {
    ui_header "DELETE BACKUP"

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#FILES[@]} -eq 0 ]; then
        ui_warning "No backups found"
        pause
        return
    fi

    echo -e "${YELLOW}Select backup to delete:${NC}"
    echo ""

    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        echo "$((i+1))) $(basename "${FILES[$i]}") [$SIZE]"
    done

    echo ""
    read -p "Select (0 to cancel): " SEL

    [ "$SEL" == "0" ] && return

    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ]; then
        ui_error "Invalid selection"
        pause
        return
    fi

    echo ""
    read -p "Delete $(basename "$SELECTED")? (y/N): " CONFIRM

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -f "$SELECTED"
        ui_success "Backup deleted"
        log_backup "INFO" "Deleted backup: $(basename "$SELECTED")"
    else
        echo "Cancelled"
    fi

    pause
}

# ==========================================
# MAIN MENU
# ==========================================
backup_menu() {
    init_backup_logging

    while true; do
        clear
        ui_header "BACKUP & RESTORE v7.2"
        setup_env

        local BACKUP_COUNT=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        local TG_STATUS="${RED}Not Configured${NC}"
        [ -f "$TG_CONFIG" ] && TG_STATUS="${GREEN}Configured${NC}"
        local CRON_STATUS="${RED}Disabled${NC}"
        crontab -l 2>/dev/null | grep -q "backup.sh" && CRON_STATUS="${GREEN}Active${NC}"
        local SERVER_IP=$(get_server_ip)

        echo -e "Panel: ${CYAN}$(basename "$PANEL_DIR")${NC} | IP: ${CYAN}$SERVER_IP${NC}"
        echo -e "Backups: ${CYAN}$BACKUP_COUNT${NC} | Telegram: $TG_STATUS | Cron: $CRON_STATUS"
        echo ""

        echo "1)  📦 Create Full Backup"
        echo "2)  📥 Restore from Backup"
        echo "3)  📋 List All Backups"
        echo "4)  🗑️  Delete Backup"
        echo "5)  🤖 Setup Telegram Bot"
        echo "6)  🧪 Test Telegram"
        echo "7)  ⏰ Setup Cron Scheduler"
        echo "8)  🔧 Run Smart Fix Only"
        echo "9)  📋 View Logs"
        echo ""
        echo "0)  ↩️  Back"
        echo ""
        read -p "Select: " opt

        case $opt in
            1) do_backup "manual" ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) setup_telegram ;;
            6) test_telegram; pause ;;
            7) setup_cron ;;
            8) apply_smart_fix; pause ;;
            9) view_backup_logs ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ==========================================
# ENTRY POINT
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" == "auto" ]; then
        do_backup "auto"
    else
        backup_menu
    fi
fi