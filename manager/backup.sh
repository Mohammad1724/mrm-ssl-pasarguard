#!/bin/bash

# ====================================================
# MRM BACKUP & RESTORE - v5.2 (Standalone & Safe)
# Fix: Embedded detection logic to prevent "command not found"
# Fix: Ensures DB type is detected correctly during restore
# ====================================================

# --- CONFIGURATION ---
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
BACKUP_VERSION="5.2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# --- INTERNAL FUNCTIONS (NO EXTERNAL DEPENDENCY) ---

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

detect_db_type() {
    # Ensure variables are set
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
        # If env missing (fresh install?), assume sqlite temporarily
        echo "sqlite"
    fi
}

# --- TELEGRAM SETUP ---
setup_telegram() {
    clear
    echo -e "${CYAN}=== TELEGRAM CONFIG ===${NC}"

    if [ -f "$TG_CONFIG" ]; then
        CUR_TOKEN=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'"' -f2)
        CUR_CHAT=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'"' -f2)
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

        echo "Testing connection..."
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

    local TG_TOKEN=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'"' -f2)
    local TG_CHAT=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'"' -f2)

    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
        echo -e "${YELLOW}Telegram config incomplete. Skipping.${NC}"
        return 1
    fi

    local FSIZE=$(du -m "$FILE" | cut -f1)
    echo -e "${BLUE}Uploading to Telegram (${FSIZE} MB)...${NC}"

    if [ "$FSIZE" -gt 49 ]; then
        echo -e "${YELLOW}Warning: File > 50MB. Splitting might be needed.${NC}"
    fi

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
    
    # Get DB credentials
    local DB_NAME=$(grep "^DB_NAME=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    local DB_USER=$(grep "^DB_USER=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
    [ -z "$DB_USER" ] && DB_USER="pasarguard"
    
    # Find Container
    local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres|pasarguard-timescaledb" | head -1)
    
    if [ -n "$DB_CONTAINER" ]; then
        # Method 1: pg_dump (SQL format)
        echo -ne "    SQL Dump... "
        docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -f /tmp/database.sql 2>/dev/null
        if [ $? -eq 0 ]; then
            docker cp "$DB_CONTAINER:/tmp/database.sql" "$BACKUP_PATH/" 2>/dev/null
            docker exec "$DB_CONTAINER" rm -f /tmp/database.sql 2>/dev/null
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
        
        # Method 2: pg_dump (Binary format)
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
        echo -e "    ${RED}Container not found (is panel running?)${NC}"
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
        echo -e "  Hostname: ${GREEN}$(hostname)${NC}"
        echo -e "  Time:     ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo ""
    fi

    mkdir -p "$BACKUP_DIR"
    local TS=$(date +%Y%m%d_%H%M%S)
    local NAME="fullbackup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"
    
    # Create Info File
    cat > "$TMP/backup_info.txt" << EOF
MRM Full Backup
Version: $BACKUP_VERSION
Date: $(date)
Hostname: $(hostname)
Panel: $PANEL_NAME
Database: $DB_TYPE
EOF

    # === 1. DATABASE ===
    echo -e "${BLUE}[1/12] Database${NC}"
    mkdir -p "$TMP/database"
    if [ "$DB_TYPE" == "postgresql" ]; then
        backup_postgresql_full "$TMP/database"
    else
        echo -ne "  SQLite... "
        if [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp -a "$DATA_DIR/db.sqlite3" "$TMP/database/"
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Not found${NC}"
        fi
    fi

    # === 2. PANEL CONFIG ===
    echo -e "${BLUE}[2/12] Panel Configuration${NC}"
    echo -ne "  $PANEL_DIR... "
    if [ -d "$PANEL_DIR" ]; then
        mkdir -p "$TMP/panel"
        # FIX: Include hidden files
        cp -a "$PANEL_DIR"/.* "$TMP/panel/" 2>/dev/null
        cp -a "$PANEL_DIR"/* "$TMP/panel/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}Not found${NC}"
    fi

    # === 3. PANEL DATA ===
    echo -e "${BLUE}[3/12] Panel Data${NC}"
    echo -ne "  $DATA_DIR... "
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$TMP/data"
        cp -a "$DATA_DIR"/. "$TMP/data/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}Not found${NC}"
    fi

    # === 4. NODE CONFIG ===
    echo -e "${BLUE}[4/12] Node Configuration${NC}"
    echo -ne "  /opt/pg-node... "
    if [ -d "/opt/pg-node" ]; then
        mkdir -p "$TMP/node"
        cp -a /opt/pg-node/. "$TMP/node/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    # === 5. NODE DATA ===
    echo -e "${BLUE}[5/12] Node Data${NC}"
    echo -ne "  /var/lib/pg-node... "
    if [ -d "/var/lib/pg-node" ]; then
        mkdir -p "$TMP/node-data"
        cp -a /var/lib/pg-node/. "$TMP/node-data/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    # === 6. SSL CERTIFICATES ===
    echo -e "${BLUE}[6/12] SSL Certificates${NC}"
    echo -ne "  Let's Encrypt... "
    if [ -d "/etc/letsencrypt" ]; then
        mkdir -p "$TMP/ssl"
        cp -a /etc/letsencrypt/. "$TMP/ssl/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    # === 7. PANEL CERTS ===
    echo -e "${BLUE}[7/12] Panel Certificates${NC}"
    echo -ne "  $DATA_DIR/certs... "
    if [ -d "$DATA_DIR/certs" ]; then
        mkdir -p "$TMP/panel-certs"
        cp -a "$DATA_DIR/certs"/* "$TMP/panel-certs/" 2>/dev/null
        local CERT_COUNT=$(ls -d "$DATA_DIR/certs"/*/ 2>/dev/null | wc -l)
        echo -e "${GREEN}OK ($CERT_COUNT domains)${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    # === 8. NGINX ===
    echo -e "${BLUE}[8/12] Nginx Configuration${NC}"
    mkdir -p "$TMP/nginx"
    if [ -d "/etc/nginx/sites-available" ]; then
        mkdir -p "$TMP/nginx/sites-available"
        cp -a /etc/nginx/sites-available/. "$TMP/nginx/sites-available/" 2>/dev/null
    fi
    if [ -d "/etc/nginx/sites-enabled" ]; then
        mkdir -p "$TMP/nginx/sites-enabled"
        cp -a /etc/nginx/sites-enabled/. "$TMP/nginx/sites-enabled/" 2>/dev/null
    fi
    if [ -d "/etc/nginx/conf.d" ]; then
        mkdir -p "$TMP/nginx/conf.d"
        cp -a /etc/nginx/conf.d/. "$TMP/nginx/conf.d/" 2>/dev/null
    fi
    [ -f "/etc/nginx/nginx.conf" ] && cp -a /etc/nginx/nginx.conf "$TMP/nginx/"
    echo -e "  Saved Nginx config... ${GREEN}OK${NC}"

    # === 9. POSTGRESQL RAW DATA ===
    # Skipping direct copy to avoid corruption, relying on Step 1.
    echo -e "${BLUE}[9/12] Database Verification${NC}"
    if [ -f "$TMP/database/database.sql" ] || [ -f "$TMP/database/database.dump" ]; then
        echo -e "  Dumps verified... ${GREEN}OK${NC}"
    else
        echo -e "  ${RED}WARNING: No DB Dump found!${NC}"
    fi

    # === 10. SYSTEM FILES ===
    echo -e "${BLUE}[10/12] System Configuration${NC}"
    mkdir -p "$TMP/system"
    crontab -l > "$TMP/system/crontab.txt" 2>/dev/null
    cp -a /etc/hosts "$TMP/system/" 2>/dev/null
    [ -f "/root/.mrm_telegram" ] && cp /root/.mrm_telegram "$TMP/system/"
    mkdir -p "$TMP/system/systemd"
    cp -a /etc/systemd/system/pg-node*.service "$TMP/system/systemd/" 2>/dev/null
    cp -a /etc/systemd/system/pasarguard*.service "$TMP/system/systemd/" 2>/dev/null
    echo -e "  System files... ${GREEN}OK${NC}"

    # === 11. MRM MANAGER ===
    echo -e "${BLUE}[11/12] MRM Manager${NC}"
    if [ -d "/opt/mrm-manager" ]; then
        mkdir -p "$TMP/mrm-manager"
        cp -a /opt/mrm-manager/. "$TMP/mrm-manager/" 2>/dev/null
        echo -e "  Manager files... ${GREEN}OK${NC}"
    fi

    # === 12. COMPRESS ===
    echo -e "${BLUE}[12/12] Compressing${NC}"
    echo -ne "  Creating archive... "
    cd "$BACKUP_DIR"
    tar -czpf "${NAME}.tar.gz" -C "/tmp" "$NAME" 2>/dev/null
    rm -rf "$TMP"
    
    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"
    local FINAL_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
    echo -e "${GREEN}OK ($FINAL_SIZE)${NC}"
    
    send_to_telegram "$FINAL_FILE"

    if [ "$MODE" != "auto" ]; then
        force_pause
    fi
}

# --- LIST BACKUPS ---
list_backups() {
    clear
    echo -e "${CYAN}=== AVAILABLE BACKUPS ===${NC}"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${RED}No backups found in $BACKUP_DIR${NC}"
        force_pause
        return 1
    fi
    
    local i=1
    declare -g BACKUP_FILES=()
    
    for f in $(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$f")
        local fsize=$(du -h "$f" | cut -f1)
        BACKUP_FILES+=("$f")
        echo -e "${GREEN}$i)${NC} $fname  [$fsize]"
        ((i++))
    done
    
    return 0
}

# --- RESTORE BACKUP ---
restore_backup() {
    if ! list_backups; then return; fi
    
    echo ""
    echo -e "${YELLOW}0) Cancel${NC}"
    read -p "Select backup to restore: " CHOICE
    
    if [ "$CHOICE" == "0" ] || [ -z "$CHOICE" ]; then return; fi
    
    local INDEX=$((CHOICE - 1))
    if [ $INDEX -lt 0 ] || [ $INDEX -ge ${#BACKUP_FILES[@]} ]; then
        echo -e "${RED}Invalid selection.${NC}"
        force_pause
        return
    fi
    
    local SELECTED_FILE="${BACKUP_FILES[$INDEX]}"
    
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           RESTORE OPTIONS                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo "1) 🔄 Full Restore (Recommended)"
    echo "2) 💾 Database Only"
    echo "3) ⚙️  Panel Config Only"
    echo "0) Cancel"
    echo ""
    read -p "Select: " OPT
    
    case $OPT in
        1) restore_full "$SELECTED_FILE" ;;
        2) restore_component "$SELECTED_FILE" "database" ;;
        3) restore_component "$SELECTED_FILE" "panel" ;;
        0) return ;;
        *) echo "Invalid"; force_pause ;;
    esac
}

# --- RESTORE FULL ---
restore_full() {
    local BACKUP_FILE="$1"
    
    clear
    echo -e "${RED}WARNING: THIS WILL REPLACE ALL DATA AND RESTART SERVICES!${NC}"
    read -p "Type 'RESTORE' to confirm: " CONFIRM
    if [ "$CONFIRM" != "RESTORE" ]; then echo "Cancelled."; force_pause; return; fi
    
    echo ""
    echo -e "${CYAN}Starting Restore...${NC}"
    
    # 1. EXTRACT
    echo -ne " [1/9] Extracting... "
    local EXT="/tmp/mrm_res_$(date +%s)"
    mkdir -p "$EXT"
    tar -xzpf "$BACKUP_FILE" -C "$EXT" 2>/dev/null
    
    local ROOT=$(ls -d "$EXT"/* | head -1)
    if [ -z "$ROOT" ]; then echo -e "${RED}Empty Backup${NC}"; return; fi
    echo -e "${GREEN}OK${NC}"
    
    # Force set paths based on what we find in backup to be safe
    # But rely on internal function for now
    detect_active_panel
    
    # 2. STOP SERVICES
    echo -ne " [2/9] Stopping Services... "
    cd "$PANEL_DIR" 2>/dev/null && docker compose down >/dev/null 2>&1
    cd /opt/pg-node 2>/dev/null && docker compose down >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    # 3. RESTORE FILES
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
    
    # 4. START SERVICES
    echo -ne " [6/9] Starting Services... "
    systemctl start nginx
    [ -d "/opt/pg-node" ] && cd /opt/pg-node && docker compose up -d >/dev/null 2>&1
    cd "$PANEL_DIR" && docker compose up -d >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    # 5. RESTORE DB
    # Now that panel is starting, we can check DB type from restored .env
    local DB_TYPE=$(detect_db_type)
    
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
            
            # Re-read env vars from RESTORED file
            export $(grep -v '^#' "$PANEL_DIR/.env" | xargs)
            
            # Clean & Import
            docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
            
            if [ -f "$ROOT/database/database.dump" ]; then
                docker cp "$ROOT/database/database.dump" "$DB_CONT:/tmp/r.dump"
                docker exec "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" -c --if-exists /tmp/r.dump >/dev/null 2>&1
            elif [ -f "$ROOT/database/database.sql" ]; then
                docker cp "$ROOT/database/database.sql" "$DB_CONT:/tmp/r.sql"
                docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -f /tmp/r.sql >/dev/null 2>&1
            fi
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}Timeout${NC}"
        fi
    else
        echo -e "${GREEN}Done (SQLite restored via file copy)${NC}"
    fi
    
    rm -rf "$EXT"
    echo ""
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    force_pause
}

# --- RESTORE COMPONENT ---
restore_component() {
    local BACKUP_FILE="$1"
    local COMPONENT="$2"
    
    echo ""
    read -p "Type 'YES' to restore $COMPONENT: " CONFIRM
    [ "$CONFIRM" != "YES" ] && return
    
    local EXT="/tmp/mrm_res_$(date +%s)"
    mkdir -p "$EXT"
    tar -xzpf "$BACKUP_FILE" -C "$EXT"
    local ROOT=$(ls -d "$EXT"/* | head -1)
    
    detect_active_panel
    
    case $COMPONENT in
        "database")
            local DB_TYPE=$(detect_db_type)
            if [ "$DB_TYPE" == "postgresql" ]; then
                local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
                export $(grep -v '^#' "$PANEL_DIR/.env" | xargs)
                if [ -n "$DB_CONT" ] && [ -f "$ROOT/database/database.sql" ]; then
                    docker cp "$ROOT/database/database.sql" "$DB_CONT:/tmp/r.sql"
                    docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -f /tmp/r.sql
                    echo -e "${GREEN}DB Restored${NC}"
                fi
            fi
            ;;
        "panel")
            cd "$PANEL_DIR" && docker compose down
            [ -d "$ROOT/panel" ] && cp -a "$ROOT/panel"/. "$PANEL_DIR/"
            [ -d "$ROOT/data" ] && cp -a "$ROOT/data"/. "$DATA_DIR/"
            cd "$PANEL_DIR" && docker compose up -d
            echo -e "${GREEN}Panel Restored${NC}"
            ;;
    esac
    
    rm -rf "$EXT"
    force_pause
}

# --- DELETE BACKUP ---
delete_backup() {
    if ! list_backups; then return; fi
    echo ""; read -p "Delete # (or 'a'): " C
    [ "$C" == "a" ] && rm -f "$BACKUP_DIR"/*.tar.gz && return
    local I=$((C-1)); [ $I -ge 0 ] && rm -f "${BACKUP_FILES[$I]}"
}

# --- UPLOAD ---
upload_backup() {
    if ! list_backups; then return; fi
    echo ""; read -p "Upload #: " C
    local I=$((C-1)); [ $I -ge 0 ] && send_to_telegram "${BACKUP_FILES[$I]}"
}

# --- CRON ---
setup_cron() {
    clear; echo "Auto Backup"; echo "1) 6H"; echo "2) Daily"; echo "3) Disable"
    read -p "Select: " O
    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    (crontab -l | grep -v "mrm-manager/backup.sh") | crontab -
    case $O in
        1) (crontab -l; echo "0 */6 * * * $CMD") | crontab - ;;
        2) (crontab -l; echo "0 0 * * * $CMD") | crontab - ;;
    esac
}

# --- MAIN ---
backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== MRM BACKUP v$BACKUP_VERSION ===${NC}"
        echo "1) Create Backup"; echo "2) Upload to Telegram"; echo "3) Restore"; echo "4) Delete"; echo "5) Schedule"; echo "6) Setup Telegram"; echo "0) Exit"
        read -p "Opt: " O
        case $O in
            1) create_backup "manual" ;;
            2) upload_backup ;;
            3) restore_backup ;;
            4) delete_backup ;;
            5) setup_cron ;;
            6) setup_telegram ;;
            0) exit 0 ;;
        esac
    done
}

[ "$1" == "auto" ] && create_backup "auto" || backup_menu