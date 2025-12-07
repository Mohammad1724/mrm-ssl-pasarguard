#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10
TG_CONFIG="/root/.mrm_telegram"
PATH_PANEL_DATA="/var/lib/pasarguard"
PATH_OPT="/opt/pasarguard"
PATH_LE="/etc/letsencrypt"
PATH_NODE_ENV="/opt/pg-node/.env"
PATH_NODE_CERTS="/var/lib/pg-node/certs"

if command -v docker-compose &> /dev/null; then D_COMPOSE="docker-compose"; else D_COMPOSE="docker compose"; fi

setup_telegram() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      TELEGRAM BACKUP SETUP                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    read -p "Bot Token: " TOKEN
    read -p "Chat ID: " CHATID
    [ -z "$TOKEN" ] || [ -z "$CHATID" ] && return
    echo "TG_TOKEN=\"$TOKEN\"" > "$TG_CONFIG"
    echo "TG_CHAT=\"$CHATID\"" >> "$TG_CONFIG"
    chmod 600 "$TG_CONFIG"
    echo -e "${GREEN}✔ Saved.${NC}"
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id="$CHATID" -d text="✅ Backup Service Connected!" > /dev/null
    pause
}

send_to_telegram() {
    local FILE=$1
    if [ ! -f "$TG_CONFIG" ]; then return; fi
    source "$TG_CONFIG"
    echo -e "${BLUE}Uploading to Telegram...${NC}"
    local IP=$(curl -s ifconfig.me)
    local DATE=$(date)
    local CAPTION="📦 **MRM Hot Backup**%0A📅 $DATE%0A🖥 IP: $IP"
    curl -s -F document=@"$FILE" -F caption="$CAPTION" -F parse_mode="Markdown" "https://api.telegram.org/bot$TG_TOKEN/sendDocument?chat_id=$TG_CHAT" > /dev/null
}

create_backup() {
    if [ "$1" != "auto" ]; then
        clear
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${YELLOW}      CREATE HOT BACKUP (Zero Downtime)      ${NC}"
        echo -e "${CYAN}=============================================${NC}"
    fi

    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="mrm_hot_backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    mkdir -p "$TEMP_PATH"

    if [ "$1" != "auto" ]; then echo -e "${BLUE}Dumping Database...${NC}"; fi
    
    # FIXED: More specific grep to find the correct database container
    local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "pasarguard.*(timescaledb|postgres)" | head -1)
    # Fallback if specific naming not found
    if [ -z "$DB_CONTAINER" ]; then
         DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep "timescaledb\|postgres" | head -1)
    fi

    if [ -n "$DB_CONTAINER" ]; then
        docker exec "$DB_CONTAINER" pg_dumpall -U postgres -c --if-exists > "$TEMP_PATH/database_dump.sql" 2>/dev/null
        if [ -s "$TEMP_PATH/database_dump.sql" ]; then
            if [ "$1" != "auto" ]; then echo -e "${GREEN}✔ Database Dumped Successfully${NC}"; fi
        else
            echo -e "${RED}✘ Database Dump Failed! Is DB running?${NC}" >> /var/log/mrm_backup_error.log
        fi
    fi

    if [ "$1" != "auto" ]; then echo -e "${BLUE}Copying Configs...${NC}"; fi

    [ -d "$PATH_PANEL_DATA" ] && mkdir -p "$TEMP_PATH/var_lib_pasarguard" && cp -a "$PATH_PANEL_DATA/." "$TEMP_PATH/var_lib_pasarguard/"
    [ -d "$PATH_OPT" ] && mkdir -p "$TEMP_PATH/opt_pasarguard" && cp -a "$PATH_OPT/." "$TEMP_PATH/opt_pasarguard/"
    [ -d "$PATH_LE" ] && mkdir -p "$TEMP_PATH/etc_letsencrypt" && cp -a "$PATH_LE/." "$TEMP_PATH/etc_letsencrypt/"
    mkdir -p "$TEMP_PATH/nginx_backup"
    [ -d "/etc/nginx/conf.d" ] && cp -a "/etc/nginx/conf.d" "$TEMP_PATH/nginx_backup/"
    [ -d "/etc/nginx/sites-available" ] && cp -a "/etc/nginx/sites-available" "$TEMP_PATH/nginx_backup/"
    [ -f "$PATH_NODE_ENV" ] && mkdir -p "$TEMP_PATH/opt_pgnode" && cp -a "$PATH_NODE_ENV" "$TEMP_PATH/opt_pgnode/.env"
    [ -d "$PATH_NODE_CERTS" ] && mkdir -p "$TEMP_PATH/var_lib_pgnode_certs" && cp -a "$PATH_NODE_CERTS/." "$TEMP_PATH/var_lib_pgnode_certs/"

    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME" 2>/dev/null
    rm -rf "$TEMP_PATH"

    local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    if [ -f "$FINAL_FILE" ]; then
        if [ "$1" != "auto" ]; then echo -e "${GREEN}✔ Backup Created: ${FINAL_FILE}${NC}"; fi
        send_to_telegram "$FINAL_FILE"
    fi

    ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null
    if [ "$1" != "auto" ]; then pause; fi
}

restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE BACKUP                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    if [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then echo "No backups."; pause; return; fi
    local i=1; declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz); do
        echo -e "${GREEN}$i)${NC} $(basename $file) ($(du -h $file | cut -f1))"
        backups[$i]="$file"
        ((i++))
    done
    read -p "Select: " SEL; local FILE="${backups[$SEL]}"; [ -z "$FILE" ] && return
    echo -e "${RED}⚠ DANGER: This will OVERWRITE data. Services will restart.${NC}"
    read -p "Confirm? (yes/no): " CONF; [ "$CONF" != "yes" ] && return

    local TEMP_DIR="/tmp/mrm_restore_$$"; mkdir -p "$TEMP_DIR"
    tar -xzf "$FILE" -C "$TEMP_DIR"
    local ROOT="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    echo -e "${YELLOW}Stopping services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE down
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE down
    systemctl stop nginx

    echo -e "${BLUE}Restoring Configs...${NC}"
    [ -d "$ROOT/var_lib_pasarguard" ] && cp -a "$ROOT/var_lib_pasarguard/." "$PATH_PANEL_DATA/"
    [ -d "$ROOT/opt_pasarguard" ] && cp -a "$ROOT/opt_pasarguard/." "$PATH_OPT/"
    [ -d "$ROOT/etc_letsencrypt" ] && rm -rf "$PATH_LE" && cp -a "$ROOT/etc_letsencrypt" "/etc/"
    if [ -d "$ROOT/nginx_backup" ]; then
        [ -d "$ROOT/nginx_backup/conf.d" ] && cp -a "$ROOT/nginx_backup/conf.d/." "/etc/nginx/conf.d/"
        [ -d "$ROOT/nginx_backup/sites-available" ] && cp -a "$ROOT/nginx_backup/sites-available/." "/etc/nginx/sites-available/"
    fi

    echo -e "${BLUE}Starting Database Container for Import...${NC}"
    cd "$PANEL_DIR" && $D_COMPOSE up -d timescaledb 2>/dev/null || $D_COMPOSE up -d postgres 2>/dev/null
    sleep 10
    
    if [ -f "$ROOT/database_dump.sql" ]; then
        local DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "pasarguard.*(timescaledb|postgres)" | head -1)
        if [ -z "$DB_CONTAINER" ]; then DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep "timescaledb\|postgres" | head -1); fi
        
        if [ -n "$DB_CONTAINER" ]; then
            echo -e "${BLUE}Importing Database...${NC}"
            docker exec -i "$DB_CONTAINER" psql -U postgres < "$ROOT/database_dump.sql"
            echo -e "${GREEN}✔ Database Imported${NC}"
        fi
    else
        echo -e "${YELLOW}! No SQL dump found. Skipping DB restore.${NC}"
    fi

    echo -e "${YELLOW}Restarting all services...${NC}"
    cd "$PANEL_DIR" && $D_COMPOSE up -d
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE up -d
    systemctl restart nginx
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() { ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null; pause; }

setup_cron() {
    clear; echo -e "${CYAN}AUTO BACKUP${NC}"; echo "1) 6 Hours 2) 12 Hours 3) Daily 4) Weekly 5) Disable"; read -p "Opt: " OPT
    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"; local JOB=""
    case $OPT in
        1) JOB="0 */6 * * * $CMD" ;; 2) JOB="0 */12 * * * $CMD" ;; 3) JOB="0 3 * * * $CMD" ;; 4) JOB="0 3 * * 5 $CMD" ;;
        5) (crontab -l | grep -v "backup.sh") | crontab -; echo "Disabled."; pause; return ;;
    esac
    (crontab -l 2>/dev/null | grep -v "backup.sh"; echo "$JOB") | crontab -
    echo "Scheduled."; pause
}

if [ "$1" == "auto" ]; then create_backup "auto"; exit 0; fi

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== BACKUP & RESTORE ===${NC}"
        echo "1) Create Hot Backup (No Downtime)"
        echo "2) Restore Backup"
        echo "3) List Backups"
        echo "4) Setup Telegram"
        echo "5) Schedule Auto Backup"
        echo "6) Back"
        read -p "Select: " OPT
        case $OPT in 1) create_backup ;; 2) restore_backup ;; 3) list_backups ;; 4) setup_telegram ;; 5) setup_cron ;; 6) return ;; esac
    done
}