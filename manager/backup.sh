#!/bin/bash

# ============================================
# MRM BACKUP & RESTORE - FULL VERSION
# Supports: PostgreSQL, SQLite, Nodes, SSL, Nginx
# ============================================

# --- CONFIGURATION ---
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
BACKUP_VERSION="2.0"

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
            -d text="✅ MRM Backup - Connection Test OK" > /tmp/tg_test.log

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
        echo -e "${YELLOW}Telegram config incomplete. Skipping upload.${NC}"
        return 1
    fi

    local FSIZE=$(du -k "$FILE" | cut -f1)
    echo -e "${BLUE}Uploading to Telegram (${FSIZE} KB)...${NC}"

    if [ "$FSIZE" -gt 49000 ]; then
        echo -e "${YELLOW}Warning: File > 50MB, might fail.${NC}"
    fi

    local CAPTION="#FullBackup $(hostname) $(date +%F_%R)"

    curl -s --connect-timeout 60 --max-time 300 \
         -F chat_id="$TG_CHAT" \
         -F caption="$CAPTION" \
         -F document=@"$FILE" \
         "https://api.telegram.org/bot$TG_TOKEN/sendDocument" > /tmp/tg_debug.log 2>&1

    if grep -q '"ok":true' /tmp/tg_debug.log; then
        echo -e "${GREEN}✔ Uploaded to Telegram${NC}"
        return 0
    else
        echo -e "${RED}✘ Telegram upload failed${NC}"
        return 1
    fi
}

# --- BACKUP POSTGRESQL ---
backup_postgresql() {
    local BACKUP_PATH="$1"
    
    echo -ne "  PostgreSQL Database... "
    
    # Get DB credentials from .env
    local DB_NAME=$(grep "^DB_NAME=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    local DB_USER=$(grep "^DB_USER=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    local DB_PASS=$(grep "^DB_PASSWORD=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    
    # Default values
    [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
    [ -z "$DB_USER" ] && DB_USER="pasarguard"
    
    # Try to find TimescaleDB container
    local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
    
    if [ -n "$DB_CONTAINER" ]; then
        # Dump using docker exec
        docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -F c -f /tmp/db_backup.dump 2>/dev/null
        
        if [ $? -eq 0 ]; then
            docker cp "$DB_CONTAINER:/tmp/db_backup.dump" "$BACKUP_PATH/database.dump" 2>/dev/null
            docker exec "$DB_CONTAINER" rm -f /tmp/db_backup.dump 2>/dev/null
            
            # Also create SQL format for compatibility
            docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -f /tmp/db_backup.sql 2>/dev/null
            docker cp "$DB_CONTAINER:/tmp/db_backup.sql" "$BACKUP_PATH/database.sql" 2>/dev/null
            docker exec "$DB_CONTAINER" rm -f /tmp/db_backup.sql 2>/dev/null
            
            echo -e "${GREEN}OK${NC}"
            return 0
        fi
    fi
    
    echo -e "${YELLOW}Failed (container not found)${NC}"
    return 1
}

# --- BACKUP SQLITE ---
backup_sqlite() {
    local BACKUP_PATH="$1"
    
    echo -ne "  SQLite Database... "
    
    if [ -f "$DATA_DIR/db.sqlite3" ]; then
        cp "$DATA_DIR/db.sqlite3" "$BACKUP_PATH/"
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${YELLOW}Not found${NC}"
        return 1
    fi
}

# --- CREATE FULL BACKUP ---
create_backup() {
    local MODE="$1"
    
    # Detect panel
    detect_active_panel > /dev/null
    local PANEL_NAME=$(basename "$PANEL_DIR")
    local DB_TYPE=$(detect_db_type)
    
    if [ "$MODE" != "auto" ]; then
        clear
        echo -e "${CYAN}============================================${NC}"
        echo -e "${CYAN}       CREATING FULL SYSTEM BACKUP          ${NC}"
        echo -e "${CYAN}============================================${NC}"
        echo ""
        echo -e "Panel:    ${GREEN}$PANEL_NAME${NC}"
        echo -e "Database: ${GREEN}$DB_TYPE${NC}"
        echo -e "Time:     ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo ""
    fi

    mkdir -p "$BACKUP_DIR"
    local TS=$(date +%Y%m%d_%H%M%S)
    local NAME="fullbackup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"
    
    # Create backup info file
    cat > "$TMP/backup_info.txt" << EOF
MRM Full Backup
===============
Version: $BACKUP_VERSION
Created: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Panel: $PANEL_NAME
Panel Dir: $PANEL_DIR
Data Dir: $DATA_DIR
Database: $DB_TYPE
EOF

    echo -e "${BLUE}[1/8] Database${NC}"
    mkdir -p "$TMP/database"
    if [ "$DB_TYPE" == "postgresql" ]; then
        backup_postgresql "$TMP/database"
    else
        backup_sqlite "$TMP/database"
    fi

    echo -e "${BLUE}[2/8] Panel Configuration${NC}"
    echo -ne "  Panel config ($PANEL_DIR)... "
    if [ -d "$PANEL_DIR" ]; then
        mkdir -p "$TMP/panel"
        cp -r "$PANEL_DIR"/* "$TMP/panel/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}Not found${NC}"
    fi

    echo -e "${BLUE}[3/8] Panel Data${NC}"
    echo -ne "  Panel data ($DATA_DIR)... "
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$TMP/data"
        cp -r "$DATA_DIR"/* "$TMP/data/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}Not found${NC}"
    fi

    echo -e "${BLUE}[4/8] Node Configuration${NC}"
    echo -ne "  Node config (/opt/pg-node)... "
    if [ -d "/opt/pg-node" ]; then
        mkdir -p "$TMP/node"
        cp -r /opt/pg-node/* "$TMP/node/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi
    
    # Node data directory
    echo -ne "  Node data (/var/lib/pg-node)... "
    if [ -d "/var/lib/pg-node" ]; then
        mkdir -p "$TMP/node-data"
        cp -r /var/lib/pg-node/* "$TMP/node-data/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    echo -e "${BLUE}[5/8] SSL Certificates${NC}"
    echo -ne "  Let's Encrypt certs... "
    if [ -d "/etc/letsencrypt" ]; then
        mkdir -p "$TMP/ssl"
        cp -rL /etc/letsencrypt/* "$TMP/ssl/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi
    
    # Panel certs
    echo -ne "  Panel certs ($DATA_DIR/certs)... "
    if [ -d "$DATA_DIR/certs" ]; then
        mkdir -p "$TMP/panel-certs"
        cp -r "$DATA_DIR/certs"/* "$TMP/panel-certs/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    echo -e "${BLUE}[6/8] Nginx Configuration${NC}"
    echo -ne "  Nginx sites-available... "
    if [ -d "/etc/nginx/sites-available" ]; then
        mkdir -p "$TMP/nginx/sites-available"
        cp -r /etc/nginx/sites-available/* "$TMP/nginx/sites-available/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi
    
    echo -ne "  Nginx sites-enabled... "
    if [ -d "/etc/nginx/sites-enabled" ]; then
        mkdir -p "$TMP/nginx/sites-enabled"
        cp -rL /etc/nginx/sites-enabled/* "$TMP/nginx/sites-enabled/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi
    
    echo -ne "  Nginx conf.d... "
    if [ -d "/etc/nginx/conf.d" ]; then
        mkdir -p "$TMP/nginx/conf.d"
        cp -r /etc/nginx/conf.d/* "$TMP/nginx/conf.d/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi
    
    echo -ne "  Nginx main config... "
    if [ -f "/etc/nginx/nginx.conf" ]; then
        cp /etc/nginx/nginx.conf "$TMP/nginx/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
    fi

    echo -e "${BLUE}[7/8] Cron Jobs & System${NC}"
    echo -ne "  Cron jobs... "
    mkdir -p "$TMP/system"
    crontab -l > "$TMP/system/crontab.txt" 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    echo -ne "  MRM Manager config... "
    if [ -f "/root/.mrm_telegram" ]; then
        cp /root/.mrm_telegram "$TMP/system/" 2>/dev/null
    fi
    if [ -d "/opt/mrm-manager" ]; then
        mkdir -p "$TMP/mrm-manager"
        cp -r /opt/mrm-manager/* "$TMP/mrm-manager/" 2>/dev/null
    fi
    echo -e "${GREEN}OK${NC}"

    echo -e "${BLUE}[8/8] Compressing${NC}"
    echo -ne "  Creating archive... "
    cd "$BACKUP_DIR"
    tar -czf "${NAME}.tar.gz" -C "/tmp" "$NAME" 2>/dev/null
    rm -rf "$TMP"
    
    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"
    local FINAL_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
    echo -e "${GREEN}OK ($FINAL_SIZE)${NC}"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}         BACKUP COMPLETED SUCCESSFULLY      ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "File: ${CYAN}$FINAL_FILE${NC}"
    echo -e "Size: ${CYAN}$FINAL_SIZE${NC}"
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
        
        # Detect backup type
        local TYPE="Standard"
        if [[ "$fname" == fullbackup_* ]]; then
            TYPE="${GREEN}Full${NC}"
        fi
        
        echo -e "${GREEN}$i)${NC} $fname"
        echo -e "   Type: $TYPE | Size: $fsize | Date: $fdate"
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
        echo "Cancelled."
        force_pause
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
    
    # Show restore options
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}           RESTORE OPTIONS                  ${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    echo -e "Selected: ${GREEN}$SELECTED_NAME${NC}"
    echo ""
    echo "What do you want to restore?"
    echo ""
    echo "1) Everything (Full Restore)"
    echo "2) Database Only"
    echo "3) Panel Config Only"
    echo "4) SSL Certificates Only"
    echo "5) Nginx Config Only"
    echo "6) Node Config Only"
    echo "0) Cancel"
    echo ""
    read -p "Select: " RESTORE_OPT
    
    case $RESTORE_OPT in
        1) restore_full "$SELECTED_FILE" ;;
        2) restore_database "$SELECTED_FILE" ;;
        3) restore_panel "$SELECTED_FILE" ;;
        4) restore_ssl "$SELECTED_FILE" ;;
        5) restore_nginx "$SELECTED_FILE" ;;
        6) restore_node "$SELECTED_FILE" ;;
        0) echo "Cancelled."; force_pause; return ;;
        *) echo "Invalid option."; force_pause; return ;;
    esac
}

# --- RESTORE FULL ---
restore_full() {
    local BACKUP_FILE="$1"
    
    echo ""
    echo -e "${RED}============================================${NC}"
    echo -e "${RED}     ⚠️  FULL RESTORE WARNING  ⚠️           ${NC}"
    echo -e "${RED}============================================${NC}"
    echo ""
    echo -e "This will restore:"
    echo "  • Database (all users, traffic data)"
    echo "  • Panel configuration"
    echo "  • Panel data & templates"
    echo "  • Node configuration"
    echo "  • SSL certificates"
    echo "  • Nginx configuration"
    echo "  • Cron jobs"
    echo ""
    echo -e "${RED}Current data will be REPLACED!${NC}"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    detect_active_panel > /dev/null
    local DB_TYPE=$(detect_db_type)
    
    echo ""
    echo -e "${CYAN}Starting full restore...${NC}"
    echo ""
    
    # Extract backup
    echo -ne "Extracting backup... "
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAILED${NC}"
        rm -rf "$EXTRACT_DIR"
        force_pause
        return
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Find backup content
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    
    if [ -z "$BACKUP_CONTENT" ] || [ ! -d "$BACKUP_CONTENT" ]; then
        echo -e "${RED}Invalid backup structure.${NC}"
        rm -rf "$EXTRACT_DIR"
        force_pause
        return
    fi
    
    # Stop services
    echo -ne "Stopping services... "
    cd "$PANEL_DIR" && docker compose down 2>/dev/null
    systemctl stop nginx 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    # Restore Panel Config
    echo -ne "Restoring panel config... "
    if [ -d "$BACKUP_CONTENT/panel" ]; then
        rm -rf "$PANEL_DIR"
        mkdir -p "$PANEL_DIR"
        cp -r "$BACKUP_CONTENT/panel"/* "$PANEL_DIR/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Restore Panel Data
    echo -ne "Restoring panel data... "
    if [ -d "$BACKUP_CONTENT/data" ]; then
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
        cp -r "$BACKUP_CONTENT/data"/* "$DATA_DIR/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Restore Node
    echo -ne "Restoring node config... "
    if [ -d "$BACKUP_CONTENT/node" ]; then
        rm -rf /opt/pg-node
        mkdir -p /opt/pg-node
        cp -r "$BACKUP_CONTENT/node"/* /opt/pg-node/ 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    echo -ne "Restoring node data... "
    if [ -d "$BACKUP_CONTENT/node-data" ]; then
        rm -rf /var/lib/pg-node
        mkdir -p /var/lib/pg-node
        cp -r "$BACKUP_CONTENT/node-data"/* /var/lib/pg-node/ 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Restore SSL
    echo -ne "Restoring SSL certificates... "
    if [ -d "$BACKUP_CONTENT/ssl" ]; then
        rm -rf /etc/letsencrypt
        mkdir -p /etc/letsencrypt
        cp -r "$BACKUP_CONTENT/ssl"/* /etc/letsencrypt/ 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Restore Panel Certs
    echo -ne "Restoring panel certs... "
    if [ -d "$BACKUP_CONTENT/panel-certs" ]; then
        mkdir -p "$DATA_DIR/certs"
        cp -r "$BACKUP_CONTENT/panel-certs"/* "$DATA_DIR/certs/" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Restore Nginx
    echo -ne "Restoring Nginx config... "
    if [ -d "$BACKUP_CONTENT/nginx" ]; then
        [ -d "$BACKUP_CONTENT/nginx/sites-available" ] && cp -r "$BACKUP_CONTENT/nginx/sites-available"/* /etc/nginx/sites-available/ 2>/dev/null
        [ -d "$BACKUP_CONTENT/nginx/conf.d" ] && cp -r "$BACKUP_CONTENT/nginx/conf.d"/* /etc/nginx/conf.d/ 2>/dev/null
        [ -f "$BACKUP_CONTENT/nginx/nginx.conf" ] && cp "$BACKUP_CONTENT/nginx/nginx.conf" /etc/nginx/ 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Restore Cron
    echo -ne "Restoring cron jobs... "
    if [ -f "$BACKUP_CONTENT/system/crontab.txt" ]; then
        crontab "$BACKUP_CONTENT/system/crontab.txt" 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Start services
    echo -ne "Starting panel... "
    cd "$PANEL_DIR" && docker compose up -d 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    echo -ne "Starting Nginx... "
    systemctl start nginx 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    # Restore Database (PostgreSQL needs special handling)
    if [ "$DB_TYPE" == "postgresql" ]; then
        echo -ne "Waiting for database to start... "
        sleep 10
        echo -e "${GREEN}OK${NC}"
        
        echo -ne "Restoring PostgreSQL database... "
        if [ -f "$BACKUP_CONTENT/database/database.dump" ]; then
            local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
            local DB_NAME=$(grep "^DB_NAME=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            local DB_USER=$(grep "^DB_USER=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            
            if [ -n "$DB_CONTAINER" ]; then
                docker cp "$BACKUP_CONTENT/database/database.dump" "$DB_CONTAINER:/tmp/" 2>/dev/null
                docker exec "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" -c --if-exists /tmp/database.dump 2>/dev/null
                docker exec "$DB_CONTAINER" rm -f /tmp/database.dump 2>/dev/null
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}Container not found${NC}"
            fi
        else
            echo -e "${YELLOW}No dump file${NC}"
        fi
    fi
    
    # Start Node
    echo -ne "Starting node... "
    if [ -d "/opt/pg-node" ]; then
        cd /opt/pg-node && docker compose up -d 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}Skipped${NC}"
    fi
    
    # Cleanup
    rm -rf "$EXTRACT_DIR"
    
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}     ✔ FULL RESTORE COMPLETED               ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    
    force_pause
}

# --- RESTORE DATABASE ONLY ---
restore_database() {
    local BACKUP_FILE="$1"
    
    echo ""
    echo -e "${YELLOW}Restoring database only...${NC}"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    detect_active_panel > /dev/null
    local DB_TYPE=$(detect_db_type)
    
    # Extract backup
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    
    if [ "$DB_TYPE" == "postgresql" ]; then
        if [ -f "$BACKUP_CONTENT/database/database.dump" ]; then
            local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
            local DB_NAME=$(grep "^DB_NAME=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            local DB_USER=$(grep "^DB_USER=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            [ -z "$DB_NAME" ] && DB_NAME="pasarguard"
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            
            docker cp "$BACKUP_CONTENT/database/database.dump" "$DB_CONTAINER:/tmp/" 2>/dev/null
            docker exec "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" -c --if-exists /tmp/database.dump 2>/dev/null
            echo -e "${GREEN}Database restored.${NC}"
        else
            echo -e "${RED}No database dump found.${NC}"
        fi
    else
        if [ -f "$BACKUP_CONTENT/database/db.sqlite3" ]; then
            cp "$BACKUP_CONTENT/database/db.sqlite3" "$DATA_DIR/"
            echo -e "${GREEN}Database restored.${NC}"
        else
            echo -e "${RED}No database file found.${NC}"
        fi
    fi
    
    rm -rf "$EXTRACT_DIR"
    force_pause
}

# --- RESTORE PANEL ONLY ---
restore_panel() {
    local BACKUP_FILE="$1"
    
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    detect_active_panel > /dev/null
    
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    
    cd "$PANEL_DIR" && docker compose down 2>/dev/null
    
    if [ -d "$BACKUP_CONTENT/panel" ]; then
        rm -rf "$PANEL_DIR"
        mkdir -p "$PANEL_DIR"
        cp -r "$BACKUP_CONTENT/panel"/* "$PANEL_DIR/"
    fi
    
    if [ -d "$BACKUP_CONTENT/data" ]; then
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
        cp -r "$BACKUP_CONTENT/data"/* "$DATA_DIR/"
    fi
    
    cd "$PANEL_DIR" && docker compose up -d
    
    rm -rf "$EXTRACT_DIR"
    echo -e "${GREEN}Panel restored.${NC}"
    force_pause
}

# --- RESTORE SSL ONLY ---
restore_ssl() {
    local BACKUP_FILE="$1"
    
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    
    if [ -d "$BACKUP_CONTENT/ssl" ]; then
        rm -rf /etc/letsencrypt
        mkdir -p /etc/letsencrypt
        cp -r "$BACKUP_CONTENT/ssl"/* /etc/letsencrypt/
        echo -e "${GREEN}SSL certificates restored.${NC}"
    else
        echo -e "${RED}No SSL backup found.${NC}"
    fi
    
    rm -rf "$EXTRACT_DIR"
    systemctl reload nginx 2>/dev/null
    force_pause
}

# --- RESTORE NGINX ONLY ---
restore_nginx() {
    local BACKUP_FILE="$1"
    
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    
    if [ -d "$BACKUP_CONTENT/nginx" ]; then
        [ -d "$BACKUP_CONTENT/nginx/sites-available" ] && cp -r "$BACKUP_CONTENT/nginx/sites-available"/* /etc/nginx/sites-available/
        [ -d "$BACKUP_CONTENT/nginx/conf.d" ] && cp -r "$BACKUP_CONTENT/nginx/conf.d"/* /etc/nginx/conf.d/
        systemctl reload nginx
        echo -e "${GREEN}Nginx config restored.${NC}"
    else
        echo -e "${RED}No Nginx backup found.${NC}"
    fi
    
    rm -rf "$EXTRACT_DIR"
    force_pause
}

# --- RESTORE NODE ONLY ---
restore_node() {
    local BACKUP_FILE="$1"
    
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        force_pause
        return
    fi
    
    local EXTRACT_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    local BACKUP_CONTENT=$(ls -d "$EXTRACT_DIR"/*backup_* 2>/dev/null | head -1)
    
    if [ -d "/opt/pg-node" ]; then
        cd /opt/pg-node && docker compose down 2>/dev/null
    fi
    
    if [ -d "$BACKUP_CONTENT/node" ]; then
        rm -rf /opt/pg-node
        mkdir -p /opt/pg-node
        cp -r "$BACKUP_CONTENT/node"/* /opt/pg-node/
    fi
    
    if [ -d "$BACKUP_CONTENT/node-data" ]; then
        rm -rf /var/lib/pg-node
        mkdir -p /var/lib/pg-node
        cp -r "$BACKUP_CONTENT/node-data"/* /var/lib/pg-node/
    fi
    
    if [ -d "/opt/pg-node" ]; then
        cd /opt/pg-node && docker compose up -d 2>/dev/null
    fi
    
    rm -rf "$EXTRACT_DIR"
    echo -e "${GREEN}Node restored.${NC}"
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
        echo "Cancelled."
        force_pause
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
    echo "3) Daily"
    echo "4) Weekly"
    echo "5) Disable"
    echo "0) Back"
    echo ""
    read -p "Select: " O

    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    (crontab -l 2>/dev/null | grep -v "mrm-manager/backup.sh") | crontab -

    case $O in
        1) (crontab -l 2>/dev/null; echo "0 */6 * * * $CMD") | crontab - ;;
        2) (crontab -l 2>/dev/null; echo "0 */12 * * * $CMD") | crontab - ;;
        3) (crontab -l 2>/dev/null; echo "0 0 * * * $CMD") | crontab - ;;
        4) (crontab -l 2>/dev/null; echo "0 0 * * 0 $CMD") | crontab - ;;
        5) echo "Disabled." ;;
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