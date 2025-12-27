#!/bin/bash

# ====================================================
# MRM BACKUP & RESTORE - v5.3 (Env Parser Fix)
# Fix: Safe parsing of .env variables (No more export errors)
# ====================================================

# --- CONFIGURATION ---
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
BACKUP_VERSION="5.3"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# --- INTERNAL FUNCTIONS ---

detect_active_panel() {
    if [ -d "/opt/rebecca" ]; then
        export PANEL_DIR="/opt/rebecca"
        export DATA_DIR="/var/lib/rebecca"
    elif [ -d "/opt/pasarguard" ]; then
        export PANEL_DIR="/opt/pasarguard"
        export DATA_DIR="/var/lib/pasarguard"
    else
        export PANEL_DIR="/opt/marzban"
        export DATA_DIR="/var/lib/marzban"
    fi
}

force_pause() {
    echo ""
    echo -e "${YELLOW}--- Press ENTER to continue ---${NC}"
    read -p ""
}

# --- SAFE ENV PARSER ---
get_env_var() {
    local VAR_NAME="$1"
    local FILE="$2"
    # Grep the line, remove comments, get value after =, remove quotes and spaces
    grep "^${VAR_NAME}" "$FILE" | head -1 | cut -d'=' -f2- | sed 's/^ *//;s/ *$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//'
}

detect_db_type() {
    detect_active_panel
    local ENV_FILE="$PANEL_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        if grep -q "postgresql" "$ENV_FILE" 2>/dev/null; then
            echo "postgresql"
        elif grep -q "mysql" "$ENV_FILE" 2>/dev/null; then
            echo "mysql"
        else
            echo "sqlite"
        fi
    else
        echo "sqlite"
    fi
}

# --- TELEGRAM SETUP ---
setup_telegram() {
    clear
    echo -e "${CYAN}=== TELEGRAM CONFIG ===${NC}"

    if [ -f "$TG_CONFIG" ]; then
        CUR_TOKEN=$(get_env_var "TG_TOKEN" "$TG_CONFIG")
        CUR_CHAT=$(get_env_var "TG_CHAT" "$TG_CONFIG")
        echo -e "Current Chat ID: ${GREEN}$CUR_CHAT${NC}"
    else
        echo "Not configured."
    fi
    echo ""

    read -p "Bot Token: " TOKEN
    read -p "Chat ID: " CHATID

    if [ -n "$TOKEN" ] && [ -n "$CHATID" ]; then
        echo "TG_TOKEN=\"$TOKEN\"" > "$TG_CONFIG"
        echo "TG_CHAT=\"$CHATID\"" >> "$TG_CONFIG"
        echo -e "${GREEN}Saved.${NC}"

        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d chat_id="$CHATID" \
            -d text="✅ MRM Backup v$BACKUP_VERSION - Connection OK" > /tmp/tg_test.log

        if grep -q '"ok":true' /tmp/tg_test.log; then
             echo -e "${GREEN}✔ Connection Successful!${NC}"
        else
             echo -e "${RED}✘ Connection Failed!${NC}"
             cat /tmp/tg_test.log
        fi
    fi
    force_pause
}

# --- SEND TO TELEGRAM ---
send_to_telegram() {
    local FILE="$1"

    if [ ! -f "$TG_CONFIG" ]; then
        echo -e "${YELLOW}Telegram not configured. Skipping upload.${NC}"
        return 1
    fi

    local TG_TOKEN=$(get_env_var "TG_TOKEN" "$TG_CONFIG")
    local TG_CHAT=$(get_env_var "TG_CHAT" "$TG_CONFIG")

    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
        echo -e "${YELLOW}Telegram config incomplete. Skipping.${NC}"
        return 1
    fi

    local FSIZE=$(du -m "$FILE" | cut -f1)
    echo -e "${BLUE}Uploading to Telegram (${FSIZE} MB)...${NC}"

    local CAPTION="#FullBackup $(hostname) $(date +%F_%R)"

    curl -s --connect-timeout 120 --max-time 600 \
         -F chat_id="$TG_CHAT" \
         -F caption="$CAPTION" \
         -F document=@"$FILE" \
         "https://api.telegram.org/bot$TG_TOKEN/sendDocument" > /tmp/tg_debug.log 2>&1

    if grep -q '"ok":true' /tmp/tg_debug.log; then
        echo -e "${GREEN}✔ Uploaded to Telegram${NC}"
        return 0
    else
        echo -e "${RED}✘ Telegram upload failed${NC}"
        cat /tmp/tg_debug.log
        return 1
    fi
}

# --- BACKUP POSTGRESQL ---
backup_postgresql_full() {
    local BACKUP_PATH="$1"
    echo -e "  ${CYAN}PostgreSQL Database:${NC}"
    
    local DB_NAME=$(get_env_var "DB_NAME" "$PANEL_DIR/.env")
    local DB_USER=$(get_env_var "DB_USER" "$PANEL_DIR/.env")
    [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
    [ -z "$DB_USER" ] && DB_USER="pasarguard"
    
    local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres|pasarguard-timescaledb" | head -1)
    
    if [ -n "$DB_CONTAINER" ]; then
        echo -ne "    SQL Dump... "
        docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -f /tmp/database.sql 2>/dev/null
        if [ $? -eq 0 ]; then
            docker cp "$DB_CONTAINER:/tmp/database.sql" "$BACKUP_PATH/" 2>/dev/null
            docker exec "$DB_CONTAINER" rm -f /tmp/database.sql 2>/dev/null
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
        
        echo -ne "    Binary Dump... "
        docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -F c -f /tmp/database.dump 2>/dev/null
        if [ $? -eq 0 ]; then
            docker cp "$DB_CONTAINER:/tmp/database.dump" "$BACKUP_PATH/" 2>/dev/null
            docker exec "$DB_CONTAINER" rm -f /tmp/database.dump 2>/dev/null
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
    else
        echo -e "    ${RED}Container not found${NC}"
    fi
}

# --- CREATE FULL BACKUP ---
create_backup() {
    local MODE="$1"
    
    detect_active_panel
    local PANEL_NAME=$(basename "$PANEL_DIR")
    local DB_TYPE=$(detect_db_type)
    
    if [ "$MODE" != "auto" ]; then
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     FULL SYSTEM BACKUP v$BACKUP_VERSION              ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  Panel:    ${GREEN}$PANEL_NAME${NC}"
        echo -e "  Database: ${GREEN}$DB_TYPE${NC}"
    fi

    mkdir -p "$BACKUP_DIR"
    local TS=$(date +%Y%m%d_%H%M%S)
    local NAME="fullbackup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"
    
    # Info File
    cat > "$TMP/backup_info.txt" << EOF
MRM Full Backup
Version: $BACKUP_VERSION
Date: $(date)
Hostname: $(hostname)
Panel: $PANEL_NAME
Database: $DB_TYPE
EOF

    # 1. DB
    echo -e "${BLUE}[1/12] Database${NC}"
    mkdir -p "$TMP/database"
    if [ "$DB_TYPE" == "postgresql" ]; then
        backup_postgresql_full "$TMP/database"
    else
        echo -ne "  SQLite... "
        if [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp -a "$DATA_DIR/db.sqlite3" "$TMP/database/" && echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Not found${NC}"
        fi
    fi

    # 2. Panel
    echo -e "${BLUE}[2/12] Panel Configuration${NC}"
    if [ -d "$PANEL_DIR" ]; then
        mkdir -p "$TMP/panel"
        cp -a "$PANEL_DIR"/.* "$TMP/panel/" 2>/dev/null
        cp -a "$PANEL_DIR"/* "$TMP/panel/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 3. Data
    echo -e "${BLUE}[3/12] Panel Data${NC}"
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$TMP/data"
        cp -a "$DATA_DIR"/. "$TMP/data/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 4. Node Config
    echo -e "${BLUE}[4/12] Node Configuration${NC}"
    if [ -d "/opt/pg-node" ]; then
        mkdir -p "$TMP/node"
        cp -a /opt/pg-node/. "$TMP/node/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 5. Node Data
    echo -e "${BLUE}[5/12] Node Data${NC}"
    if [ -d "/var/lib/pg-node" ]; then
        mkdir -p "$TMP/node-data"
        cp -a /var/lib/pg-node/. "$TMP/node-data/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 6. SSL
    echo -e "${BLUE}[6/12] SSL Certificates${NC}"
    if [ -d "/etc/letsencrypt" ]; then
        mkdir -p "$TMP/ssl"
        cp -a /etc/letsencrypt/. "$TMP/ssl/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 7. Panel Certs
    echo -e "${BLUE}[7/12] Panel Certificates${NC}"
    if [ -d "$DATA_DIR/certs" ]; then
        mkdir -p "$TMP/panel-certs"
        cp -a "$DATA_DIR/certs"/* "$TMP/panel-certs/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 8. Nginx
    echo -e "${BLUE}[8/12] Nginx Configuration${NC}"
    mkdir -p "$TMP/nginx"
    [ -d "/etc/nginx/sites-available" ] && mkdir -p "$TMP/nginx/sites-available" && cp -a /etc/nginx/sites-available/. "$TMP/nginx/sites-available/"
    [ -d "/etc/nginx/sites-enabled" ] && mkdir -p "$TMP/nginx/sites-enabled" && cp -a /etc/nginx/sites-enabled/. "$TMP/nginx/sites-enabled/"
    [ -d "/etc/nginx/conf.d" ] && mkdir -p "$TMP/nginx/conf.d" && cp -a /etc/nginx/conf.d/. "$TMP/nginx/conf.d/"
    [ -f "/etc/nginx/nginx.conf" ] && cp -a /etc/nginx/nginx.conf "$TMP/nginx/"
    echo -e "  Copied... ${GREEN}OK${NC}"

    # 9. DB Verification
    echo -e "${BLUE}[9/12] Database Verification${NC}"
    if [ -f "$TMP/database/database.sql" ] || [ -f "$TMP/database/database.dump" ]; then
        echo -e "  Verified... ${GREEN}OK${NC}"
    else
        echo -e "  ${RED}WARNING: No DB Dump!${NC}"
    fi

    # 10. System
    echo -e "${BLUE}[10/12] System Configuration${NC}"
    mkdir -p "$TMP/system"
    crontab -l > "$TMP/system/crontab.txt" 2>/dev/null
    cp -a /etc/hosts "$TMP/system/" 2>/dev/null
    mkdir -p "$TMP/system/systemd"
    cp -a /etc/systemd/system/pg-node*.service "$TMP/system/systemd/" 2>/dev/null
    cp -a /etc/systemd/system/pasarguard*.service "$TMP/system/systemd/" 2>/dev/null
    echo -e "  Copied... ${GREEN}OK${NC}"

    # 11. Manager
    echo -e "${BLUE}[11/12] MRM Manager${NC}"
    if [ -d "/opt/mrm-manager" ]; then
        mkdir -p "$TMP/mrm-manager"
        cp -a /opt/mrm-manager/. "$TMP/mrm-manager/" 2>/dev/null
        echo -e "  Copied... ${GREEN}OK${NC}"
    fi

    # 12. Compress
    echo -e "${BLUE}[12/12] Compressing${NC}"
    cd "$BACKUP_DIR"
    tar -czpf "${NAME}.tar.gz" -C "/tmp" "$NAME" 2>/dev/null
    rm -rf "$TMP"
    
    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"
    local FINAL_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
    echo -e "${GREEN}OK ($FINAL_SIZE)${NC}"
    
    send_to_telegram "$FINAL_FILE"

    if [ "$MODE" != "auto" ]; then force_pause; fi
}

# --- LIST BACKUPS ---
list_backups() {
    clear
    echo -e "${CYAN}=== AVAILABLE BACKUPS ===${NC}"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${RED}No backups found.${NC}"; force_pause; return 1
    fi
    local i=1; declare -g BACKUP_FILES=()
    for f in $(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        echo -e "${GREEN}$i)${NC} $(basename "$f") [$(du -h "$f" | cut -f1)]"
        BACKUP_FILES+=("$f")
        ((i++))
    done
    return 0
}

# --- RESTORE FULL ---
restore_full() {
    local BACKUP_FILE="$1"
    
    clear
    echo -e "${RED}WARNING: ALL DATA WILL BE REPLACED!${NC}"
    read -p "Type 'RESTORE' to confirm: " CONFIRM
    [ "$CONFIRM" != "RESTORE" ] && return
    
    detect_active_panel
    local DB_TYPE=$(detect_db_type)
    
    echo ""
    echo -e "${CYAN}Starting Restore...${NC}"
    
    # 1. Extract
    echo -ne " [1/9] Extracting... "
    local EXT="/tmp/mrm_res_$(date +%s)"
    mkdir -p "$EXT"
    tar -xzpf "$BACKUP_FILE" -C "$EXT" 2>/dev/null
    local ROOT=$(ls -d "$EXT"/* | head -1)
    if [ -z "$ROOT" ]; then echo -e "${RED}Error${NC}"; return; fi
    echo -e "${GREEN}OK${NC}"
    
    # 2. Stop Services
    echo -ne " [2/9] Stopping Services... "
    cd "$PANEL_DIR" 2>/dev/null && docker compose down >/dev/null 2>&1
    cd /opt/pg-node 2>/dev/null && docker compose down >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    # 3. Restore Files
    echo -ne " [3/9] Restoring Panel Files... "
    if [ -d "$ROOT/panel" ]; then
        rm -rf "$PANEL_DIR"
        mkdir -p "$PANEL_DIR"
        cp -a "$ROOT/panel"/. "$PANEL_DIR/"
    fi
    if [ -d "$ROOT/data" ]; then
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
        cp -a "$ROOT/data"/. "$DATA_DIR/"
    fi
    echo -e "${GREEN}OK${NC}"
    
    echo -ne " [4/9] Restoring Node... "
    if [ -d "$ROOT/node" ]; then
        rm -rf /opt/pg-node
        mkdir -p /opt/pg-node
        cp -a "$ROOT/node"/. /opt/pg-node/
    fi
    if [ -d "$ROOT/node-data" ]; then
        rm -rf /var/lib/pg-node
        mkdir -p /var/lib/pg-node
        cp -a "$ROOT/node-data"/. /var/lib/pg-node/
    fi
    echo -e "${GREEN}OK${NC}"
    
    echo -ne " [5/9] Restoring System Configs... "
    [ -d "$ROOT/ssl" ] && rm -rf /etc/letsencrypt && cp -a "$ROOT/ssl" /etc/letsencrypt
    [ -d "$ROOT/nginx" ] && cp -a "$ROOT/nginx"/. /etc/nginx/
    [ -f "$ROOT/system/hosts" ] && cp -a "$ROOT/system/hosts" /etc/hosts
    [ -f "$ROOT/system/crontab.txt" ] && crontab "$ROOT/system/crontab.txt"
    echo -e "${GREEN}OK${NC}"
    
    # 4. Start Services
    echo -ne " [6/9] Starting Services... "
    systemctl start nginx
    [ -d "/opt/pg-node" ] && cd /opt/pg-node && docker compose up -d >/dev/null 2>&1
    cd "$PANEL_DIR" && docker compose up -d >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    # 5. Restore DB
    echo -ne " [7/9] Waiting for DB ($DB_TYPE)... "
    if [ "$DB_TYPE" == "postgresql" ]; then
        local RETRY=0
        local DB_CONT=""
        local DB_READY=false
        
        while [ $RETRY -lt 60 ]; do
            DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres|pasarguard-timescaledb" | head -1)
            if [ -n "$DB_CONT" ] && docker exec "$DB_CONT" pg_isready -U pasarguard >/dev/null 2>&1; then
                DB_READY=true
                break
            fi
            sleep 2
            ((RETRY++))
        done
        
        if [ "$DB_READY" = true ]; then
            echo -e "${GREEN}Ready${NC}"
            echo -ne " [8/9] Importing Dump... "
            
            # Safe read of credentials
            local DB_NAME=$(get_env_var "DB_NAME" "$PANEL_DIR/.env")
            local DB_USER=$(get_env_var "DB_USER" "$PANEL_DIR/.env")
            [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            
            # Reset Schema
            docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
            
            if [ -f "$ROOT/database/database.dump" ]; then
                docker cp "$ROOT/database/database.dump" "$DB_CONT:/tmp/restore.dump"
                docker exec "$DB_CONT" pg_restore -U "$DB_USER" -d "$DB_NAME" -c --if-exists /tmp/restore.dump >/dev/null 2>&1
            elif [ -f "$ROOT/database/database.sql" ]; then
                docker cp "$ROOT/database/database.sql" "$DB_CONT:/tmp/restore.sql"
                docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -f /tmp/restore.sql >/dev/null 2>&1
            fi
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}Timeout${NC}"
        fi
    else
        echo -e "${GREEN}Done (SQLite restored)${NC}"
    fi
    
    rm -rf "$EXT"
    echo ""
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    force_pause
}

# --- RESTORE BACKUP SELECTOR ---
restore_backup() {
    if ! list_backups; then return; fi
    echo ""; read -p "Select Backup: " C
    [ "$C" == "0" ] || [ -z "$C" ] && return
    local I=$((C-1)); [ $I -lt 0 ] && return
    restore_full "${BACKUP_FILES[$I]}"
}

# --- MENU ---
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== BACKUP & RESTORE v$BACKUP_VERSION ===${NC}"
        echo "1) Create Backup"; echo "2) Restore"; echo "3) Upload to TG"; echo "4) Delete"; echo "5) Schedule"; echo "6) Telegram"; echo "0) Exit"
        read -p "Opt: " O
        case $O in
            1) create_backup "manual" ;;
            2) restore_backup ;;
            3) if list_backups; then echo ""; read -p "Upload #: " C; I=$((C-1)); [ $I -ge 0 ] && send_to_telegram "${BACKUP_FILES[$I]}"; force_pause; fi ;;
            4) if list_backups; then echo ""; read -p "Delete #: " C; I=$((C-1)); [ $I -ge 0 ] && rm -f "${BACKUP_FILES[$I]}"; force_pause; fi ;;
            5) setup_cron ;;
            6) setup_telegram ;;
            0) exit 0 ;;
        esac
    done
}

[ "$1" == "auto" ] && create_backup "auto" || main_menu