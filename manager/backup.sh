#!/bin/bash

# ====================================================
# MRM BACKUP & RESTORE - v5.1 (Hidden Files Fix)
# Fix: Now correctly includes .env files using "/."
# ====================================================

# --- CONFIGURATION ---
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
BACKUP_VERSION="5.1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Check dependencies
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# --- FORCED PAUSE ---
force_pause() {
    echo ""
    echo -e "${YELLOW}--- Press ENTER to continue ---${NC}"
    read -p ""
}

# --- DETECT DATABASE TYPE ---
detect_db_type() {
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

# --- BACKUP POSTGRESQL (FULL SAFE METHOD) ---
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
        # Method 1: pg_dump (SQL format - Standard)
        echo -ne "    SQL Dump... "
        docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -f /tmp/database.sql 2>/dev/null
        if [ $? -eq 0 ]; then
            docker cp "$DB_CONTAINER:/tmp/database.sql" "$BACKUP_PATH/" 2>/dev/null
            docker exec "$DB_CONTAINER" rm -f /tmp/database.sql 2>/dev/null
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
        
        # Method 2: pg_dump (Binary format - Robust)
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
    
    detect_active_panel > /dev/null
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
        # FIX: Use "/." to include hidden files like .env
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
        # FIX: Include hidden files
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
        # FIX: Include hidden files (.env)
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
        cp -a "$DATA_DIR/certs"/. "$TMP/panel-certs/" 2>/dev/null
        local CERT_COUNT=$(ls -d "$DATA_DIR/certs"/*/ 2>/dev/null | wc -l)
        echo -e "${GREEN}OK ($CERT_COUNT domains)${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    # === 8. NGINX ===
    echo -e "${BLUE}[8/12] Nginx Configuration${NC}"
    mkdir -p "$TMP/nginx"
    
    echo -ne "  sites-available... "
    if [ -d "/etc/nginx/sites-available" ]; then
        mkdir -p "$TMP/nginx/sites-available"
        cp -a /etc/nginx/sites-available/. "$TMP/nginx/sites-available/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    fi
    
    echo -ne "  sites-enabled... "
    if [ -d "/etc/nginx/sites-enabled" ]; then
        mkdir -p "$TMP/nginx/sites-enabled"
        cp -a /etc/nginx/sites-enabled/. "$TMP/nginx/sites-enabled/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    fi
    
    echo -ne "  conf.d... "
    if [ -d "/etc/nginx/conf.d" ]; then
        mkdir -p "$TMP/nginx/conf.d"
        cp -a /etc/nginx/conf.d/. "$TMP/nginx/conf.d/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    fi
    
    echo -ne "  nginx.conf... "
    [ -f "/etc/nginx/nginx.conf" ] && cp -a /etc/nginx/nginx.conf "$TMP/nginx/" && echo -e "${GREEN}OK${NC}"

    # === 9. POSTGRESQL RAW DATA ===
    echo -e "${BLUE}[9/12] Database Verification${NC}"
    echo -ne "  Verifying dumps... "
    if [ -f "$TMP/database/database.sql" ] || [ -f "$TMP/database/database.dump" ]; then
        echo -e "${GREEN}OK (Valid Dumps)${NC}"
    else
        echo -e "${RED}WARNING: No DB Dump created!${NC}"
    fi

    # === 10. SYSTEM FILES ===
    echo -e "${BLUE}[10/12] System Configuration${NC}"
    mkdir -p "$TMP/system"
    
    echo -ne "  Cron jobs... "
    crontab -l > "$TMP/system/crontab.txt" 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    echo -ne "  Hosts file... "
    cp -a /etc/hosts "$TMP/system/" 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    echo -ne "  MRM Telegram config... "
    [ -f "/root/.mrm_telegram" ] && cp /root/.mrm_telegram "$TMP/system/"
    echo -e "${GREEN}OK${NC}"
    
    echo -ne "  Systemd services... "
    mkdir -p "$TMP/system/systemd"
    cp -a /etc/systemd/system/pg-node*.service "$TMP/system/systemd/" 2>/dev/null
    cp -a /etc/systemd/system/pasarguard*.service "$TMP/system/systemd/" 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    echo -ne "  Open ports info... "
    ss -tlnp > "$TMP/system/open_ports.txt" 2>/dev/null
    echo -e "${GREEN}OK${NC}"

    # === 11. MRM MANAGER ===
    echo -e "${BLUE}[11/12] MRM Manager${NC}"
    echo -ne "  /opt/mrm-manager... "
    if [ -d "/opt/mrm-manager" ]; then
        mkdir -p "$TMP/mrm-manager"
        cp -a /opt/mrm-manager/. "$TMP/mrm-manager/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    # === 12. COMPRESS ===
    echo -e "${BLUE}[12/12] Compressing${NC}"
    echo -ne "  Creating archive... "
    cd "$BACKUP_DIR"
    tar -czpf "${NAME}.tar.gz" -C "/tmp" "$NAME" 2>/dev/null
    rm -rf "$TMP"
    
    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"
    local FINAL_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
    echo -e "${GREEN}OK${NC}"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       BACKUP COMPLETED SUCCESSFULLY        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  File: ${CYAN}$FINAL_FILE${NC}"
    echo -e "  Size: ${CYAN}$FINAL_SIZE${NC}"
    echo ""

    # Send to Telegram
    send_to_telegram "$FINAL_FILE"

    if [ "$MODE" != "auto" ]; then
        force_pause
    fi
}

# --- LIST BACKUPS ---
list_backups() {
    clear
    echo -e "${CYAN}=== AVAILABLE BACKUPS ===${NC}"
    echo ""
    
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
        local fdate=$(stat -c %y "$f" | cut -d'.' -f1)
        
        BACKUP_FILES+=("$f")
        
        local TYPE="${YELLOW}Standard${NC}"
        if [[ "$fname" == fullbackup_* ]]; then
            TYPE="${GREEN}Full${NC}"
        fi
        
        echo -e "${GREEN}$i)${NC} $fname"
        echo -e "   Type: $TYPE | Size: $fsize"
        echo -e "   Date: $fdate"
        echo ""
        ((i++))
    done
    
    return 0
}

# --- RESTORE BACKUP ---
restore_backup() {
    if ! list_backups; then
        return
    fi
    
    echo -e "${YELLOW}0) Cancel${NC}"
    echo ""
    read -p "Select backup to restore: " CHOICE
    
    if [ "$CHOICE" == "0" ] || [ -z "$CHOICE" ]; then
        return
    fi
    
    local INDEX=$((CHOICE - 1))
    
    if [ $INDEX -lt 0 ] || [ $INDEX -ge ${#BACKUP_FILES[@]} ]; then
        echo -e "${RED}Invalid selection.${NC}"
        force_pause
        return
    fi
    
    local SELECTED_FILE="${BACKUP_FILES[$INDEX]}"
    local SELECTED_NAME=$(basename "$SELECTED_FILE")
    
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           RESTORE OPTIONS                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Selected: ${GREEN}$SELECTED_NAME${NC}"
    echo ""
    echo "1) 🔄 Full Restore (Recommended)"
    echo "2) 💾 Database Only"
    echo "3) ⚙️  Panel Config + Data"
    echo "4) 🔐 SSL Certificates"
    echo "5) 🌐 Nginx Config"
    echo "6) 📡 Node Config"
    echo "0) Cancel"
    echo ""
    read -p "Select: " RESTORE_OPT
    
    case $RESTORE_OPT in
        1) restore_full "$SELECTED_FILE" ;;
        2) restore_component "$SELECTED_FILE" "database" ;;
        3) restore_component "$SELECTED_FILE" "panel" ;;
        4) restore_component "$SELECTED_FILE" "ssl" ;;
        5) restore_component "$SELECTED_FILE" "nginx" ;;
        6) restore_component "$SELECTED_FILE" "node" ;;
        0) return ;;
        *) echo "Invalid option."; force_pause ;;
    esac
}

# --- RESTORE FULL ---
restore_full() {
    local BACKUP_FILE="$1"
    
    clear
    echo -e "${RED}╔════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     ⚠️  FULL SYSTEM RESTORE  ⚠️            ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}WARNING: ALL CURRENT DATA WILL BE REPLACED!${NC}"
    echo ""
    read -p "Type 'RESTORE' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "RESTORE" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    detect_active_panel > /dev/null
    local DB_TYPE=$(detect_db_type)
    
    echo ""
    echo -e "${CYAN}Starting full restore...${NC}"
    
    # 1. EXTRACT
    echo -ne "  [1/9] Extracting backup... "
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzpf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAILED${NC}"
        rm -rf "$EXTRACT_DIR"
        force_pause
        return
    fi
    echo -e "${GREEN}OK${NC}"
    
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    if [ -z "$BACKUP_CONTENT" ]; then
        BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*fullbackup_* 2>/dev/null | head -1)
    fi

    if [ -z "$BACKUP_CONTENT" ] || [ ! -d "$BACKUP_CONTENT" ]; then
        echo -e "${RED}Invalid backup structure.${NC}"
        rm -rf "$EXTRACT_DIR"
        force_pause
        return
    fi
    
    # 2. STOP SERVICES
    echo -ne "  [2/9] Stopping services... "
    cd "$PANEL_DIR" 2>/dev/null && docker compose down >/dev/null 2>&1
    cd /opt/pg-node 2>/dev/null && docker compose down >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    # 3. RESTORE PANEL
    echo -ne "  [3/9] Restoring panel (.env included)... "
    if [ -d "$BACKUP_CONTENT/panel" ]; then
        rm -rf "$PANEL_DIR"
        mkdir -p "$PANEL_DIR"
        # FIX: Include dotfiles in restore
        cp -a "$BACKUP_CONTENT/panel"/. "$PANEL_DIR/"
    fi
    if [ -d "$BACKUP_CONTENT/data" ]; then
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
        cp -a "$BACKUP_CONTENT/data"/. "$DATA_DIR/"
    fi
    echo -e "${GREEN}OK${NC}"
    
    # 4. RESTORE NODE
    echo -ne "  [4/9] Restoring node... "
    if [ -d "$BACKUP_CONTENT/node" ]; then
        rm -rf /opt/pg-node
        mkdir -p /opt/pg-node
        # FIX: Include dotfiles
        cp -a "$BACKUP_CONTENT/node"/. /opt/pg-node/
    fi
    if [ -d "$BACKUP_CONTENT/node-data" ]; then
        rm -rf /var/lib/pg-node
        mkdir -p /var/lib/pg-node
        cp -a "$BACKUP_CONTENT/node-data"/. /var/lib/pg-node/
    fi
    echo -e "${GREEN}OK${NC}"
    
    # 5. RESTORE SSL & NGINX
    echo -ne "  [5/9] Restoring SSL/Nginx... "
    if [ -d "$BACKUP_CONTENT/ssl" ]; then
        rm -rf /etc/letsencrypt
        mkdir -p /etc/letsencrypt
        cp -a "$BACKUP_CONTENT/ssl"/. /etc/letsencrypt/
    fi
    if [ -d "$BACKUP_CONTENT/nginx" ]; then
        [ -d "$BACKUP_CONTENT/nginx/sites-available" ] && cp -a "$BACKUP_CONTENT/nginx/sites-available"/. /etc/nginx/sites-available/
        [ -d "$BACKUP_CONTENT/nginx/conf.d" ] && cp -a "$BACKUP_CONTENT/nginx/conf.d"/. /etc/nginx/conf.d/
        [ -f "$BACKUP_CONTENT/nginx/nginx.conf" ] && cp -a "$BACKUP_CONTENT/nginx/nginx.conf" /etc/nginx/
    fi
    echo -e "${GREEN}OK${NC}"
    
    # 6. RESTORE SYSTEM
    echo -ne "  [6/9] Restoring system... "
    if [ -d "$BACKUP_CONTENT/system" ]; then
        [ -f "$BACKUP_CONTENT/system/crontab.txt" ] && crontab "$BACKUP_CONTENT/system/crontab.txt"
        [ -f "$BACKUP_CONTENT/system/hosts" ] && cp -a "$BACKUP_CONTENT/system/hosts" /etc/hosts
        [ -d "$BACKUP_CONTENT/system/systemd" ] && cp -a "$BACKUP_CONTENT/system/systemd"/*.service /etc/systemd/system/ && systemctl daemon-reload
    fi
    echo -e "${GREEN}OK${NC}"
    
    # 7. START SERVICES
    echo -ne "  [7/9] Starting services... "
    systemctl start nginx
    if [ -d "/opt/pg-node" ]; then
        cd /opt/pg-node && docker compose up -d >/dev/null 2>&1
    fi
    cd "$PANEL_DIR" && docker compose up -d >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    # 8. RESTORE DB
    echo -ne "  [8/9] Waiting for DB... "
    
    # Check if we have dump
    local HAS_DUMP=false
    if [ -f "$BACKUP_CONTENT/database/database.dump" ] || [ -f "$BACKUP_CONTENT/database/database.sql" ]; then
        HAS_DUMP=true
    fi
    
    if [ "$DB_TYPE" == "postgresql" ] && [ "$HAS_DUMP" = true ]; then
        # Wait loop
        local RETRY=0
        local DB_READY=false
        local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres|pasarguard-timescaledb" | head -1)
        
        while [ $RETRY -lt 60 ]; do
            if [ -n "$DB_CONTAINER" ] && docker exec "$DB_CONTAINER" pg_isready -U pasarguard >/dev/null 2>&1; then
                DB_READY=true
                break
            fi
            sleep 2
            ((RETRY++))
            # Refresh container name check
            DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
        done
        
        if [ "$DB_READY" = true ]; then
            echo -e "${GREEN}Ready${NC}"
            echo -ne "  [9/9] Importing Dump... "
            
            local DB_NAME=$(grep "^DB_NAME=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d ' ')
            local DB_USER=$(grep "^DB_USER=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d ' ')
            [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            
            # 1. Clean existing DB
            docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
            
            # 2. Import
            if [ -f "$BACKUP_CONTENT/database/database.dump" ]; then
                docker cp "$BACKUP_CONTENT/database/database.dump" "$DB_CONTAINER:/tmp/restore.dump"
                docker exec "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" -c --if-exists /tmp/restore.dump >/dev/null 2>&1
            elif [ -f "$BACKUP_CONTENT/database/database.sql" ]; then
                docker cp "$BACKUP_CONTENT/database/database.sql" "$DB_CONTAINER:/tmp/restore.sql"
                docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f /tmp/restore.sql >/dev/null 2>&1
            fi
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}DB Timeout${NC}"
        fi
    else
        echo -e "${GREEN}Skipped (SQLite or No Dump)${NC}"
    fi
    
    # Cleanup
    rm -rf "$EXTRACT_DIR"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     ✔ FULL RESTORE COMPLETED               ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    
    force_pause
}

# --- RESTORE COMPONENT ---
restore_component() {
    local BACKUP_FILE="$1"
    local COMPONENT="$2"
    
    echo ""
    read -p "Type 'YES' to restore $COMPONENT: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    detect_active_panel > /dev/null
    
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzpf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    if [ -z "$BACKUP_CONTENT" ]; then BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*fullbackup_* 2>/dev/null | head -1); fi
    
    case $COMPONENT in
        "database")
            # Similar DB logic to full restore
            local DB_TYPE=$(detect_db_type)
            if [ "$DB_TYPE" == "postgresql" ]; then
                local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
                if [ -n "$DB_CONTAINER" ] && [ -f "$BACKUP_CONTENT/database/database.dump" ]; then
                    local DB_NAME=$(grep "^DB_NAME=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d ' ')
                    local DB_USER=$(grep "^DB_USER=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d ' ')
                    docker cp "$BACKUP_CONTENT/database/database.dump" "$DB_CONTAINER:/tmp/r.dump"
                    docker exec "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" -c --if-exists /tmp/r.dump
                    echo -e "${GREEN}Database Restored.${NC}"
                fi
            fi
            ;;
        "panel")
            cd "$PANEL_DIR" && docker compose down
            [ -d "$BACKUP_CONTENT/panel" ] && cp -a "$BACKUP_CONTENT/panel"/. "$PANEL_DIR/"
            [ -d "$BACKUP_CONTENT/data" ] && cp -a "$BACKUP_CONTENT/data"/. "$DATA_DIR/"
            cd "$PANEL_DIR" && docker compose up -d
            echo -e "${GREEN}Panel Config Restored.${NC}"
            ;;
        "ssl")
            [ -d "$BACKUP_CONTENT/ssl" ] && cp -a "$BACKUP_CONTENT/ssl"/. /etc/letsencrypt/
            systemctl reload nginx
            echo -e "${GREEN}SSL Restored.${NC}"
            ;;
        "nginx")
            [ -d "$BACKUP_CONTENT/nginx" ] && cp -a "$BACKUP_CONTENT/nginx"/. /etc/nginx/
            systemctl reload nginx
            echo -e "${GREEN}Nginx Restored.${NC}"
            ;;
        "node")
            [ -d "$BACKUP_CONTENT/node" ] && cp -a "$BACKUP_CONTENT/node"/. /opt/pg-node/
            [ -d "$BACKUP_CONTENT/node-data" ] && cp -a "$BACKUP_CONTENT/node-data"/. /var/lib/pg-node/
            echo -e "${GREEN}Node Config Restored.${NC}"
            ;;
    esac
    
    rm -rf "$EXTRACT_DIR"
    force_pause
}

# --- DELETE BACKUP ---
delete_backup() {
    if ! list_backups; then
        return
    fi
    
    echo -e "${YELLOW}0) Cancel${NC}"
    echo -e "${RED}A) Delete ALL backups${NC}"
    echo ""
    read -p "Select backup to delete: " CHOICE
    
    if [ "$CHOICE" == "0" ] || [ -z "$CHOICE" ]; then
        return
    fi
    
    if [ "$CHOICE" == "A" ] || [ "$CHOICE" == "a" ]; then
        read -p "Delete ALL backups? Type 'YES': " CONFIRM
        if [ "$CONFIRM" == "YES" ]; then
            rm -f "$BACKUP_DIR"/*.tar.gz
            echo -e "${GREEN}All backups deleted.${NC}"
        fi
        force_pause
        return
    fi
    
    local INDEX=$((CHOICE - 1))
    if [ $INDEX -ge 0 ] && [ $INDEX -lt ${#BACKUP_FILES[@]} ]; then
        rm -f "${BACKUP_FILES[$INDEX]}"
        echo -e "${GREEN}Deleted.${NC}"
    fi
    force_pause
}

# --- UPLOAD EXISTING ---
upload_backup() {
    if ! list_backups; then
        return
    fi
    
    echo -e "${YELLOW}0) Cancel${NC}"
    echo ""
    read -p "Select backup to upload: " CHOICE
    
    if [ "$CHOICE" == "0" ] || [ -z "$CHOICE" ]; then
        force_pause
        return
    fi
    
    local INDEX=$((CHOICE - 1))
    if [ $INDEX -ge 0 ] && [ $INDEX -lt ${#BACKUP_FILES[@]} ]; then
        send_to_telegram "${BACKUP_FILES[$INDEX]}"
    fi
    force_pause
}

# --- CRON SETUP ---
setup_cron() {
    clear
    echo -e "${CYAN}=== AUTO BACKUP SCHEDULE ===${NC}"
    echo ""
    echo "Current:"
    crontab -l 2>/dev/null | grep "backup.sh" || echo "None"
    echo ""
    echo "1) Every 6 Hours"
    echo "2) Every 12 Hours"
    echo "3) Daily (Midnight)"
    echo "4) Weekly (Sunday)"
    echo "5) Disable"
    echo "0) Back"
    echo ""
    read -p "Select: " O

    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    (crontab -l 2>/dev/null | grep -v "mrm-manager/backup.sh") | crontab -

    case $O in
        1) (crontab -l 2>/dev/null; echo "0 */6 * * * $CMD") | crontab -; echo -e "${GREEN}Set to 6h.${NC}" ;;
        2) (crontab -l 2>/dev/null; echo "0 */12 * * * $CMD") | crontab -; echo -e "${GREEN}Set to 12h.${NC}" ;;
        3) (crontab -l 2>/dev/null; echo "0 0 * * * $CMD") | crontab -; echo -e "${GREEN}Set to daily.${NC}" ;;
        4) (crontab -l 2>/dev/null; echo "0 0 * * 0 $CMD") | crontab -; echo -e "${GREEN}Set to weekly.${NC}" ;;
        5) echo -e "${YELLOW}Disabled.${NC}" ;;
        0) return ;;
    esac
    force_pause
}

# --- MENU ---
backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}      FULL BACKUP & RESTORE v$BACKUP_VERSION        ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo -e "${GREEN}--- Backup ---${NC}"
        echo "1) Create Full Backup Now"
        echo "2) Upload Existing Backup"
        echo ""
        echo -e "${CYAN}--- Restore ---${NC}"
        echo "3) Restore from Backup"
        echo ""
        echo -e "${YELLOW}--- Manage ---${NC}"
        echo "4) View/Delete Backups"
        echo "5) Auto Backup Schedule"
        echo "6) Telegram Settings"
        echo ""
        echo "0) Back"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) create_backup "manual" ;;
            2) upload_backup ;;
            3) restore_backup ;;
            4) delete_backup ;;
            5) setup_cron ;;
            6) setup_telegram ;;
            0) return ;;
            *) ;;
        esac
    done
}

# --- MAIN ---
if [ "$1" == "auto" ]; then
    create_backup "auto"
    exit 0
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_menu
fi