#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10
TG_CONFIG="/root/.mrm_telegram"

# --- Paths ---
PATH_PANEL_DATA="/var/lib/pasarguard"
PATH_OPT="/opt/pasarguard"
PATH_LE="/etc/letsencrypt"
PATH_NODE_ENV="/opt/pg-node/.env"
PATH_NODE_CERTS="/var/lib/pg-node/certs"

if command -v docker-compose &> /dev/null; then D_COMPOSE="docker-compose"; else D_COMPOSE="docker compose"; fi

# --- TELEGRAM ---
setup_telegram() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      TELEGRAM BACKUP SETUP                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo "1. Create a bot with @BotFather"
    echo "2. Get your User ID from @userinfobot"
    echo ""
    read -p "Bot Token: " TOKEN
    read -p "Chat ID: " CHATID
    
    if [ -z "$TOKEN" ] || [ -z "$CHATID" ]; then
        echo -e "${RED}Error: Token and Chat ID are required.${NC}"
        pause; return
    fi
    
    echo "TG_TOKEN=\"$TOKEN\"" > "$TG_CONFIG"
    echo "TG_CHAT=\"$CHATID\"" >> "$TG_CONFIG"
    chmod 600 "$TG_CONFIG"
    
    echo -e "${BLUE}Sending test message...${NC}"
    local TEST_RES=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id="$CHATID" -d text="✅ MRM Backup Service Connected!")
    
    if echo "$TEST_RES" | grep -q '"ok":true'; then
        echo -e "${GREEN}✔ Connection Successful!${NC}"
    else
        echo -e "${RED}✘ Failed to send test message. Check Token/ID.${NC}"
        echo "Response: $TEST_RES"
    fi
    pause
}

send_to_telegram() {
    local FILE=$1
    if [ ! -f "$TG_CONFIG" ]; then return; fi
    source "$TG_CONFIG"
    
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then return; fi

    echo -e "${BLUE}Uploading to Telegram...${NC}"
    
    local IP=$(curl -s --max-time 5 ifconfig.me || echo "Unknown IP")
    local DATE=$(date '+%Y-%m-%d %H:%M')
    local CAPTION="📦 **MRM Backup**
📅 Date: $DATE
🖥 IP: \`$IP\`
📂 File: $(basename "$FILE")"

    # Upload with progress bar (if pv installed) or silent
    # Use -F document=@... to upload file correctly
    local RESPONSE=$(curl -s -F chat_id="$TG_CHAT" \
                         -F caption="$CAPTION" \
                         -F parse_mode="Markdown" \
                         -F document=@"$FILE" \
                         "https://api.telegram.org/bot$TG_TOKEN/sendDocument")

    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo -e "${GREEN}✔ Uploaded to Telegram.${NC}"
    else
        echo -e "${RED}✘ Telegram Upload Failed!${NC}"
        echo "Error: $RESPONSE"
    fi
}

# --- BACKUP (HOT - NO DOWNTIME) ---
create_backup() {
    if [ "$1" != "auto" ]; then
        clear
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${YELLOW}      CREATE HOT BACKUP (Zero Downtime)      ${NC}"
        echo -e "${CYAN}=============================================${NC}"
    fi

    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="mrm_backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    mkdir -p "$TEMP_PATH"

    # 1. Database Dump (Smart Detection)
    if [ "$1" != "auto" ]; then echo -e "${BLUE}Dumping Database...${NC}"; fi
    
    # Try finding database container (Pasarguard/Marzban)
    local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "postgres|mysql|mariadb|timescaledb" | head -1)
    
    if [ -n "$DB_CONTAINER" ]; then
        # Check database type
        if docker exec "$DB_CONTAINER" command -v pg_dumpall &> /dev/null; then
            # Postgres/Timescale
            docker exec "$DB_CONTAINER" pg_dumpall -U postgres -c --if-exists > "$TEMP_PATH/database_dump.sql" 2>/dev/null
        elif docker exec "$DB_CONTAINER" command -v mysqldump &> /dev/null; then
            # MySQL/MariaDB
            docker exec "$DB_CONTAINER" mysqldump --all-databases -u root -p$(grep MARIADB_ROOT_PASSWORD "$PATH_OPT/.env" | cut -d= -f2) > "$TEMP_PATH/database_dump.sql" 2>/dev/null
        fi
        
        if [ -s "$TEMP_PATH/database_dump.sql" ]; then
            if [ "$1" != "auto" ]; then echo -e "${GREEN}✔ Database Dumped${NC}"; fi
        else
            echo -e "${RED}⚠ Database dump empty or failed.${NC}"
        fi
    fi

    # 2. Copy Config Files
    if [ "$1" != "auto" ]; then echo -e "${BLUE}Archiving Configs...${NC}"; fi

    [ -d "$PATH_PANEL_DATA" ] && mkdir -p "$TEMP_PATH/var_lib_pasarguard" && cp -a "$PATH_PANEL_DATA/." "$TEMP_PATH/var_lib_pasarguard/"
    [ -d "$PATH_OPT" ] && mkdir -p "$TEMP_PATH/opt_pasarguard" && cp -a "$PATH_OPT/." "$TEMP_PATH/opt_pasarguard/"
    [ -d "$PATH_LE" ] && mkdir -p "$TEMP_PATH/etc_letsencrypt" && cp -a "$PATH_LE/." "$TEMP_PATH/etc_letsencrypt/"

    # Nginx
    mkdir -p "$TEMP_PATH/nginx_backup"
    [ -d "/etc/nginx/conf.d" ] && cp -a "/etc/nginx/conf.d" "$TEMP_PATH/nginx_backup/"
    [ -d "/etc/nginx/sites-available" ] && cp -a "/etc/nginx/sites-available" "$TEMP_PATH/nginx_backup/"

    # 3. Compress
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME" 2>/dev/null
    rm -rf "$TEMP_PATH"

    local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    
    if [ -f "$FINAL_FILE" ]; then
        if [ "$1" != "auto" ]; then 
            echo -e "${GREEN}✔ Backup Created: $(basename $FINAL_FILE)${NC}"
            echo -e "${YELLOW}Size: $(du -h $FINAL_FILE | cut -f1)${NC}"
        fi
        
        # Send to Telegram
        send_to_telegram "$FINAL_FILE"
    else
        echo -e "${RED}✘ Backup Creation Failed!${NC}"
    fi

    # Rotate (Keep last N backups)
    ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null
    
    if [ "$1" != "auto" ]; then pause; fi
}

# --- RESTORE ---
restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE BACKUP                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    if [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then echo "No backups found."; pause; return; fi
    
    local i=1; declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz); do
        echo -e "${GREEN}$i)${NC} $(basename $file) ($(du -h $file | cut -f1))"
        backups[$i]="$file"
        ((i++))
    done
    read -p "Select backup to restore: " SEL
    local FILE="${backups[$SEL]}"
    
    if [ -z "$FILE" ]; then return; fi

    echo -e "${RED}⚠ DANGER: This will OVERWRITE current data. Services will restart.${NC}"
    read -p "Type 'restore' to confirm: " CONF
    if [ "$CONF" != "restore" ]; then echo "Cancelled."; pause; return; fi

    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    tar -xzf "$FILE" -C "$TEMP_DIR"
    local ROOT="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    echo -e "${YELLOW}Stopping services...${NC}"
    cd "$PANEL_DIR" && $D_COMPOSE down
    systemctl stop nginx

    echo -e "${BLUE}Restoring Files...${NC}"
    [ -d "$ROOT/var_lib_pasarguard" ] && cp -a "$ROOT/var_lib_pasarguard/." "$PATH_PANEL_DATA/"
    [ -d "$ROOT/opt_pasarguard" ] && cp -a "$ROOT/opt_pasarguard/." "$PATH_OPT/"
    [ -d "$ROOT/etc_letsencrypt" ] && rm -rf "$PATH_LE" && cp -a "$ROOT/etc_letsencrypt" "/etc/"
    
    if [ -d "$ROOT/nginx_backup" ]; then
        cp -a "$ROOT/nginx_backup/conf.d/." "/etc/nginx/conf.d/" 2>/dev/null
        cp -a "$ROOT/nginx_backup/sites-available/." "/etc/nginx/sites-available/" 2>/dev/null
    fi

    echo -e "${BLUE}Starting Database...${NC}"
    cd "$PANEL_DIR" && $D_COMPOSE up -d postgres mysql mariadb 2>/dev/null
    sleep 10

    # Restore DB
    if [ -f "$ROOT/database_dump.sql" ]; then
        echo -e "${BLUE}Importing Database...${NC}"
        local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "postgres|mysql|mariadb|timescaledb" | head -1)
        
        if [ -n "$DB_CONTAINER" ]; then
            if docker exec "$DB_CONTAINER" command -v psql &> /dev/null; then
                docker exec -i "$DB_CONTAINER" psql -U postgres < "$ROOT/database_dump.sql"
            elif docker exec "$DB_CONTAINER" command -v mysql &> /dev/null; then
                docker exec -i "$DB_CONTAINER" mysql -u root -p$(grep MARIADB_ROOT_PASSWORD "$PATH_OPT/.env" | cut -d= -f2) < "$ROOT/database_dump.sql"
            fi
            echo -e "${GREEN}✔ Database Restored${NC}"
        fi
    fi

    echo -e "${YELLOW}Restarting Services...${NC}"
    cd "$PANEL_DIR" && $D_COMPOSE up -d
    systemctl restart nginx
    
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() { ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null; pause; }

setup_cron() {
    clear; echo -e "${CYAN}AUTO BACKUP SCHEDULE${NC}"
    echo "1) Every 6 Hours"
    echo "2) Every 12 Hours"
    echo "3) Daily (3 AM)"
    echo "4) Weekly (Friday)"
    echo "5) Disable"
    read -p "Select: " OPT
    
    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    local JOB=""
    
    case $OPT in
        1) JOB="0 */6 * * * $CMD" ;;
        2) JOB="0 */12 * * * $CMD" ;;
        3) JOB="0 3 * * * $CMD" ;;
        4) JOB="0 3 * * 5 $CMD" ;;
        5) (crontab -l | grep -v "backup.sh") | crontab -; echo "Disabled."; pause; return ;;
    esac
    
    (crontab -l 2>/dev/null | grep -v "backup.sh"; echo "$JOB") | crontab -
    echo -e "${GREEN}✔ Scheduled.${NC}"
    pause
}

# Auto trigger
if [ "$1" == "auto" ]; then create_backup "auto"; exit 0; fi

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== BACKUP & RESTORE ===${NC}"
        echo "1) Create Hot Backup (No Downtime)"
        echo "2) Restore Backup"
        echo "3) List Backups"
        echo "4) Setup Telegram Bot"
        echo "5) Schedule Auto Backup"
        echo "6) Back"
        read -p "Select: " OPT
        case $OPT in 
            1) create_backup ;; 
            2) restore_backup ;; 
            3) list_backups ;; 
            4) setup_telegram ;; 
            5) setup_cron ;; 
            6) return ;; 
        esac
    done
}