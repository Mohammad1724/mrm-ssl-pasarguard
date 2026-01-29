#!/bin/bash

# ==========================================
# MRM BACKUP & RESTORE PRO v7.4
# Fixed: Database Export (Empty Folder Fix)
# ==========================================

# ==========================================
# FIX FOR CRON / NON-INTERACTIVE ENV
# ==========================================
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"

# Load modules
if [ -f "/opt/mrm-manager/utils.sh" ]; then source /opt/mrm-manager/utils.sh; fi
if [ -f "/opt/mrm-manager/ui.sh" ]; then source /opt/mrm-manager/ui.sh; fi

# Fallback UI functions if modules missing
if ! declare -f ui_header >/dev/null; then
    ui_header() { echo "=== $1 ==="; }
    ui_success() { echo "OK: $1"; }
    ui_error() { echo "ERROR: $1"; }
    ui_warning() { echo "WARN: $1"; }
    ui_spinner_start() { echo "Processing: $1"; }
    ui_spinner_stop() { :; }
    pause() { read -p "Press Enter..."; }
fi

# Configuration
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BACKUP_LOG="/var/log/mrm-backup.log"

# ==========================================
# LOGGING
# ==========================================
init_backup_logging() {
    mkdir -p "$(dirname "$BACKUP_LOG")"
    touch "$BACKUP_LOG"
}

log_backup() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MESSAGE" >> "$BACKUP_LOG"
}

# ==========================================
# ENVIRONMENT DETECTION
# ==========================================
setup_env() {
    # Try internal detection first
    if declare -f detect_active_panel >/dev/null; then
        detect_active_panel > /dev/null 2>&1
    fi

    # Fallback detection if variables are empty
    if [ -z "$PANEL_DIR" ]; then
        if [ -d "/opt/marzban" ]; then
            PANEL_DIR="/opt/marzban"
            DATA_DIR="/var/lib/marzban"
            PANEL_ENV="/opt/marzban/.env"
        elif [ -d "/opt/marzneshin" ]; then
            PANEL_DIR="/opt/marzneshin"
            DATA_DIR="/var/lib/marzneshin"
            PANEL_ENV="/opt/marzneshin/.env"
        fi
    fi

    DOCKER_CMD="docker compose"
    ! docker compose version >/dev/null 2>&1 && DOCKER_CMD="docker-compose"

    log_backup "INFO" "Environment: PANEL_DIR=$PANEL_DIR, DATA_DIR=$DATA_DIR"
}

get_server_ip() {
    local IP=$(curl -s --connect-timeout 3 ifconfig.me)
    [ -z "$IP" ] && IP=$(curl -s --connect-timeout 3 icanhazip.com)
    [ -z "$IP" ] && IP=$(ip route get 8.8.8.8 | grep -oP 'src \K[^ ]+')
    echo "$IP"
}

# ==========================================
# DATABASE EXPORT LOGIC (FIXED)
# ==========================================
export_database() {
    local DEST_DIR="$1"
    local EXPORT_SUCCESS=false

    # Method 1: PostgreSQL via Docker
    if grep -q "postgresql" "$PANEL_ENV" 2>/dev/null || grep -q "postgres" "$PANEL_ENV" 2>/dev/null; then
        log_backup "INFO" "Detected PostgreSQL configuration"
        
        # Find Container
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres|mysql|mariadb" | head -1)
        
        if [ -z "$DB_CONT" ]; then
            log_backup "ERROR" "Database container not found running!"
            echo "Error: Database container not running."
            return 1
        fi

        log_backup "INFO" "Found DB Container: $DB_CONT"

        # Detect Credentials from .env
        local DB_USER=$(grep "^POSTGRES_USER" "$PANEL_ENV" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
        local DB_NAME=$(grep "^POSTGRES_DB" "$PANEL_ENV" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
        
        # Defaults if empty
        [ -z "$DB_USER" ] && DB_USER="marzban"
        [ -z "$DB_NAME" ] && DB_NAME="marzban"

        # Try Export - Attempt 1 (Detected/Default User)
        log_backup "INFO" "Attempting export with User: $DB_USER, DB: $DB_NAME"
        docker exec "$DB_CONT" pg_dump -U "$DB_USER" -d "$DB_NAME" -f /tmp/db.sql >/dev/null 2>&1
        
        # Check if successful
        if docker exec "$DB_CONT" ls /tmp/db.sql >/dev/null 2>&1; then
            EXPORT_SUCCESS=true
        else
            # Try Export - Attempt 2 (Legacy User: pasarguard)
            log_backup "WARN" "Export failed with user $DB_USER. Retrying with 'pasarguard'..."
            docker exec "$DB_CONT" pg_dump -U pasarguard -d pasarguard -f /tmp/db.sql >/dev/null 2>&1
            if docker exec "$DB_CONT" ls /tmp/db.sql >/dev/null 2>&1; then
                EXPORT_SUCCESS=true
            else
                # Try Export - Attempt 3 (User: postgres)
                log_backup "WARN" "Retrying with 'postgres'..."
                docker exec "$DB_CONT" pg_dump -U postgres -d postgres -f /tmp/db.sql >/dev/null 2>&1
                if docker exec "$DB_CONT" ls /tmp/db.sql >/dev/null 2>&1; then
                    EXPORT_SUCCESS=true
                fi
            fi
        fi

        if [ "$EXPORT_SUCCESS" = true ]; then
            docker cp "$DB_CONT:/tmp/db.sql" "$DEST_DIR/db.sql"
            docker exec "$DB_CONT" rm /tmp/db.sql
            
            # Verify file size
            if [ -s "$DEST_DIR/db.sql" ]; then
                log_backup "SUCCESS" "PostgreSQL exported successfully."
                return 0
            else
                log_backup "ERROR" "Exported SQL file is empty!"
                return 1
            fi
        else
            log_backup "ERROR" "All PostgreSQL export attempts failed."
            return 1
        fi

    # Method 2: SQLite
    elif [ -f "$DATA_DIR/db.sqlite3" ]; then
        cp "$DATA_DIR/db.sqlite3" "$DEST_DIR/"
        log_backup "INFO" "SQLite database exported from DATA_DIR"
        return 0
    elif [ -f "$PANEL_DIR/db.sqlite3" ]; then
        cp "$PANEL_DIR/db.sqlite3" "$DEST_DIR/"
        log_backup "INFO" "SQLite database exported from PANEL_DIR"
        return 0
    else
        log_backup "ERROR" "No recognizable database found."
        return 1
    fi
}

# ==========================================
# FIX ENV & COMPOSE
# ==========================================
fix_env_file() {
    local ENV_FILE=$1
    [ ! -f "$ENV_FILE" ] && return

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

    sed -i 's/UVICORN_ SSL/UVICORN_SSL/g' "$TEMP_FILE"
    sed -i 's/[[:space:]]*=[[:space:]]*/=/g' "$TEMP_FILE"
    cat -s "$TEMP_FILE" > "$ENV_FILE"
    rm -f "$TEMP_FILE"
}

fix_docker_compose() {
    local COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
    [ ! -f "$COMPOSE_FILE" ] && return
    local NEW_IP=$(get_server_ip)
    
    if grep -q "PGADMIN_LISTEN_ADDRESS" "$COMPOSE_FILE"; then
        sed -i "s/PGADMIN_LISTEN_ADDRESS:.*/PGADMIN_LISTEN_ADDRESS: $NEW_IP/g" "$COMPOSE_FILE"
    fi
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8010/${NEW_IP}:8010/g" "$COMPOSE_FILE"
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:7431/${NEW_IP}:7431/g" "$COMPOSE_FILE"
}

# ==========================================
# BACKUP & RESTORE MAIN
# ==========================================
do_backup() {
    local MODE="${1:-manual}"
    setup_env
    init_backup_logging

    [ "$MODE" != "auto" ] && clear
    [ "$MODE" != "auto" ] && ui_header "FULL SYSTEM BACKUP"

    local TS=$(date +%Y%m%d_%H%M%S)
    local B_NAME="MRM_Full_${TS}"
    local B_PATH="$TEMP_BASE/$B_NAME"
    local ERROR_FLAG=false

    mkdir -p "$B_PATH/database" "$B_PATH/panel" "$B_PATH/data" "$BACKUP_DIR"

    # 1. Database
    [ "$MODE" != "auto" ] && ui_spinner_start "Exporting database..."
    if ! export_database "$B_PATH/database"; then
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Database export failed! Check logs."
        ERROR_FLAG=true
    else
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported"
    fi

    if [ "$ERROR_FLAG" = true ] && [ "$MODE" == "manual" ]; then
        read -p "Database backup failed. Continue anyway? (y/N): " CONT
        if [[ ! "$CONT" =~ ^[Yy]$ ]]; then return; fi
    fi

    # 2. Files
    [ "$MODE" != "auto" ] && ui_spinner_start "Backing up files..."
    cp -a "$PANEL_DIR/." "$B_PATH/panel/" 2>/dev/null
    cp -a "$DATA_DIR/." "$B_PATH/data/" 2>/dev/null
    
    if [ -d "$NODE_DIR" ]; then
        mkdir -p "$B_PATH/node" "$B_PATH/node-data"
        cp -a "$NODE_DIR/." "$B_PATH/node/" 2>/dev/null
        if [ -d "$NODE_DEF_CERTS" ]; then
             cp -a "$(dirname "$NODE_DEF_CERTS")/." "$B_PATH/node-data/" 2>/dev/null
        fi
    fi
    
    [ -d "/etc/letsencrypt" ] && mkdir -p "$B_PATH/ssl" && cp -a /etc/letsencrypt/. "$B_PATH/ssl/" 2>/dev/null
    [ -d "/etc/nginx" ] && mkdir -p "$B_PATH/nginx" && cp -a /etc/nginx/. "$B_PATH/nginx/" 2>/dev/null
    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Files backed up"

    # 3. Metadata
    cat > "$B_PATH/backup_info.txt" << EOF
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Server IP: $(get_server_ip)
Panel Dir: $PANEL_DIR
EOF

    # 4. Archive
    [ "$MODE" != "auto" ] && ui_spinner_start "Creating archive..."
    tar -czf "$BACKUP_DIR/$B_NAME.tar.gz" -C "$TEMP_BASE" "$B_NAME"
    rm -rf "$TEMP_BASE"
    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Archive created"

    # 5. Telegram
    if [ -f "$TG_CONFIG" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Sending to Telegram..."
        if send_to_telegram "$BACKUP_DIR/$B_NAME.tar.gz"; then
             [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Sent to Telegram"
        else
             [ "$MODE" != "auto" ] && ui_spinner_stop && ui_warning "Telegram send failed"
        fi
    fi

    # Cleanup
    ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
    
    if [ "$MODE" != "auto" ]; then
        pause
    fi
}

do_restore() {
    setup_env
    clear
    ui_header "FULL SYSTEM RESTORE"

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then ui_error "No backups found"; pause; return; fi

    for i in "${!FILES[@]}"; do
        echo "$((i+1))) $(basename "${FILES[$i]}")"
    done
    echo ""
    read -p "Select backup: " CH
    local SELECTED="${FILES[$((CH-1))]}"
    [ -z "$SELECTED" ] && return

    read -p "This will OVERWRITE data. Confirm? (y/n): " C
    [[ ! "$C" =~ ^[Yy]$ ]] && return

    local WORK_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$WORK_DIR"
    tar -xzf "$SELECTED" -C "$WORK_DIR"
    local ROOT=$(ls -d "$WORK_DIR"/* | head -1)

    # Check Database file
    if [ ! -s "$ROOT/database/db.sql" ] && [ ! -f "$ROOT/database/db.sqlite3" ]; then
        ui_error "CRITICAL: Backup does not contain a valid database file!"
        rm -rf "$WORK_DIR"
        pause
        return
    fi

    # Stop Services
    ui_spinner_start "Stopping services..."
    $DOCKER_CMD -f "$PANEL_DIR/docker-compose.yml" down >/dev/null 2>&1
    ui_spinner_stop

    # Wipe & Restore Files
    rm -rf "$PANEL_DIR" "$DATA_DIR"
    mkdir -p "$PANEL_DIR" "$DATA_DIR"
    
    cp -a "$ROOT/panel/." "$PANEL_DIR/" 2>/dev/null
    cp -a "$ROOT/data/." "$DATA_DIR/" 2>/dev/null
    
    # Fix Permissions
    chmod -R 755 "$DATA_DIR"
    chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

    if [ -d "$ROOT/node" ]; then
        rm -rf "$NODE_DIR"
        mkdir -p "$NODE_DIR"
        cp -a "$ROOT/node/." "$NODE_DIR/" 2>/dev/null
    fi

    # Restore Nginx/SSL
    [ -d "$ROOT/ssl" ] && rm -rf /etc/letsencrypt && cp -a "$ROOT/ssl" /etc/letsencrypt
    [ -d "$ROOT/nginx" ] && cp -a "$ROOT/nginx/." /etc/nginx/

    # Fix Env
    fix_env_file "$PANEL_ENV"
    fix_docker_compose

    # Start Services
    ui_spinner_start "Starting services..."
    cd "$PANEL_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    ui_spinner_stop

    # Import Database
    if grep -q "postgresql" "$PANEL_ENV" 2>/dev/null && [ -f "$ROOT/database/db.sql" ]; then
        ui_spinner_start "Waiting for DB (30s)..."
        sleep 30
        ui_spinner_stop

        ui_spinner_start "Importing Database..."
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        if [ -n "$DB_CONT" ]; then
            # Detect User again for import
            local DB_USER=$(grep "^POSTGRES_USER" "$PANEL_ENV" | cut -d'=' -f2 | tr -d '"')
            [ -z "$DB_USER" ] && DB_USER="marzban"
            
            # Try Import
            docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_USER" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
            docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_USER" < "$ROOT/database/db.sql" >/dev/null 2>&1
        fi
        ui_spinner_stop
    fi

    rm -rf "$WORK_DIR"
    ui_success "Restore Completed."
    pause
}

# ==========================================
# TELEGRAM HELPERS
# ==========================================
send_to_telegram() {
    local FILE="$1"
    if [ ! -f "$TG_CONFIG" ]; then return 1; fi
    local TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    
    local RES=$(curl -s -m 600 -F chat_id="$CH" -F document=@"$FILE" "https://api.telegram.org/bot$TK/sendDocument")
    echo "$RES" | grep -q '"ok":true'
}

setup_telegram() {
    clear
    ui_header "TELEGRAM SETUP"
    read -p "Bot Token: " TK
    read -p "Chat ID: " CI
    echo "TG_TOKEN=$TK" > "$TG_CONFIG"
    echo "TG_CHAT=$CI" >> "$TG_CONFIG"
    ui_success "Saved."
    pause
}

test_telegram() {
    clear
    if [ ! -f "$TG_CONFIG" ]; then ui_error "Not configured"; pause; return; fi
    local TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    curl -s -X POST "https://api.telegram.org/bot$TK/sendMessage" -d chat_id="$CH" -d text="Test OK"
    pause
}

# ==========================================
# CRON
# ==========================================
setup_cron() {
    clear
    ui_header "CRON SETUP"
    echo "1) Every 6 Hours"
    echo "2) Every 12 Hours"
    echo "3) Daily"
    echo "5) Disable"
    read -p "Select: " C
    
    local TM=""
    case $C in
        1) TM="0 */6 * * *" ;;
        2) TM="0 */12 * * *" ;;
        3) TM="0 0 * * *" ;;
        5) TM="" ;;
        *) return ;;
    esac

    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | grep -v "backup.sh auto"; [ -n "$TM" ] && echo "$TM /bin/bash $SCRIPT_PATH auto >> $BACKUP_LOG 2>&1") | crontab -
    ui_success "Cron Updated"
    pause
}

list_backups() {
    clear
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null
    pause
}

delete_backup() {
    clear
    ls -t "$BACKUP_DIR"/*.tar.gz | nl
    read -p "Delete #: " N
    [ -n "$N" ] && rm "$(ls -t "$BACKUP_DIR"/*.tar.gz | sed -n "${N}p")" && ui_success "Deleted"
    pause
}

view_logs() {
    clear
    tail -n 30 "$BACKUP_LOG"
    pause
}

# ==========================================
# MENU
# ==========================================
backup_menu() {
    while true; do
        clear
        ui_header "BACKUP v7.4 (Fix: Empty DB)"
        echo "1) Backup"
        echo "2) Restore"
        echo "3) List"
        echo "4) Delete"
        echo "5) Telegram Setup"
        echo "6) Test Telegram"
        echo "7) Cron Setup"
        echo "9) Logs"
        echo "0) Exit"
        read -p "Select: " O
        case $O in
            1) do_backup ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) setup_telegram ;;
            6) test_telegram ;;
            7) setup_cron ;;
            9) view_logs ;;
            0) break ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" == "auto" ]; then do_backup "auto"; else backup_menu; fi
fi