#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10
TG_CONFIG="/root/.mrm_telegram"

# --- Critical Paths ---
PATH_DATA="/var/lib/pasarguard"
PATH_DB="/var/lib/postgresql/pasarguard"
PATH_OPT="/opt/pasarguard"
PATH_LE="/etc/letsencrypt"
PATH_NODE_ENV="/opt/pg-node/.env"
PATH_NODE_CERTS="/var/lib/pg-node/certs"

# Detect Docker Compose
if command -v docker-compose &> /dev/null; then D_COMPOSE="docker-compose"; else D_COMPOSE="docker compose"; fi

# --- TELEGRAM FUNCTIONS ---
setup_telegram() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      TELEGRAM BACKUP SETUP                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Enter Bot Token: " TOKEN
    read -p "Enter Chat ID: " CHATID
    
    if [ -z "$TOKEN" ] || [ -z "$CHATID" ]; then
        echo -e "${RED}Invalid input.${NC}"
        pause; return
    fi
    
    echo "TG_TOKEN=\"$TOKEN\"" > "$TG_CONFIG"
    echo "TG_CHAT=\"$CHATID\"" >> "$TG_CONFIG"
    chmod 600 "$TG_CONFIG"
    
    echo -e "${GREEN}✔ Telegram settings saved.${NC}"
    
    echo -e "${BLUE}Sending test message...${NC}"
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d chat_id="$CHATID" -d text="✅ MRM Backup Service Connected!" > /dev/null
        
    if [ $? -eq 0 ]; then echo -e "${GREEN}✔ Test successful.${NC}"; else echo -e "${RED}✘ Test failed. Check Token/ChatID.${NC}"; fi
    pause
}

send_to_telegram() {
    local FILE=$1
    if [ ! -f "$TG_CONFIG" ]; then return; fi
    source "$TG_CONFIG"
    
    echo -e "${BLUE}Uploading to Telegram...${NC}"
    
    local IP=$(curl -s ifconfig.me)
    local DATE=$(date)
    local CAPTION="📦 **MRM Full Backup**%0A📅 $DATE%0A🖥 IP: $IP"
    
    curl -s -F document=@"$FILE" -F caption="$CAPTION" -F parse_mode="Markdown" \
    "https://api.telegram.org/bot$TG_TOKEN/sendDocument?chat_id=$TG_CHAT" > /dev/null
    
    if [ $? -eq 0 ]; then echo -e "${GREEN}✔ Uploaded to Telegram.${NC}"; else echo -e "${RED}✘ Upload failed.${NC}"; fi
}

# --- BACKUP CORE ---
create_backup() {
    if [ "$1" != "auto" ]; then
        clear
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${YELLOW}      CREATE FULL SERVER BACKUP              ${NC}"
        echo -e "${CYAN}=============================================${NC}"
    fi

    # Check Disk Space
    local FREE_SPACE=$(df -k /root | awk 'NR==2 {print $4}')
    if [ "$FREE_SPACE" -lt 512000 ]; then
        if [ "$1" != "auto" ]; then
            echo -e "${RED}Warning: Low disk space.${NC}"
            read -p "Continue? (y/n): " CONT
            [ "$CONT" != "y" ] && return
        else
            return
        fi
    fi

    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="mrm_full_backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"

    mkdir -p "$TEMP_PATH"

    if [ "$1" != "auto" ]; then echo -e "${YELLOW}Stopping services...${NC}"; fi
    
    # Stop Services
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE stop > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE stop > /dev/null 2>&1
    systemctl stop nginx > /dev/null 2>&1

    # Backup Files (Using 'cp -a' to preserve permissions)
    if [ "$1" != "auto" ]; then echo -e "${BLUE}Copying files...${NC}"; fi

    # 1. Panel Data
    [ -d "$PATH_DATA" ] && mkdir -p "$TEMP_PATH/var_lib_pasarguard" && cp -a "$PATH_DATA/." "$TEMP_PATH/var_lib_pasarguard/"
    
    # 2. Database
    [ -d "$PATH_DB" ] && mkdir -p "$TEMP_PATH/var_lib_postgresql" && cp -a "$PATH_DB/." "$TEMP_PATH/var_lib_postgresql/"
    
    # 3. Docker Configs
    [ -d "$PATH_OPT" ] && mkdir -p "$TEMP_PATH/opt_pasarguard" && cp -a "$PATH_OPT/." "$TEMP_PATH/opt_pasarguard/"
    
    # 4. SSL & Nginx
    [ -d "$PATH_LE" ] && mkdir -p "$TEMP_PATH/etc_letsencrypt" && cp -a "$PATH_LE/." "$TEMP_PATH/etc_letsencrypt/"
    
    mkdir -p "$TEMP_PATH/nginx_backup"
    [ -d "/etc/nginx/conf.d" ] && cp -a "/etc/nginx/conf.d" "$TEMP_PATH/nginx_backup/"
    [ -d "/etc/nginx/sites-available" ] && cp -a "/etc/nginx/sites-available" "$TEMP_PATH/nginx_backup/"
    
    # 5. Node Configs
    [ -f "$PATH_NODE_ENV" ] && mkdir -p "$TEMP_PATH/opt_pgnode" && cp -a "$PATH_NODE_ENV" "$TEMP_PATH/opt_pgnode/.env"
    [ -d "$PATH_NODE_CERTS" ] && mkdir -p "$TEMP_PATH/var_lib_pgnode_certs" && cp -a "$PATH_NODE_CERTS/." "$TEMP_PATH/var_lib_pgnode_certs/"

    # Restart Services
    if [ "$1" != "auto" ]; then echo -e "${YELLOW}Restarting services...${NC}"; fi
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE up -d > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE up -d > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1

    # Compress
    cd "$BACKUP_DIR"
    if tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME" 2>/dev/null; then
        rm -rf "$TEMP_PATH"
        local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
        
        if [ "$1" != "auto" ]; then
            local SIZE=$(du -h "$FINAL_FILE" | cut -f1)
            echo ""
            echo -e "${GREEN}✔ Backup Created Successfully!${NC}"
            echo -e "File: ${CYAN}$FINAL_FILE${NC}"
            echo -e "Size: ${CYAN}$SIZE${NC}"
        fi
        
        # Send to Telegram
        send_to_telegram "$FINAL_FILE"
    else
        echo -e "${RED}✘ Compression Failed!${NC}"
    fi

    # Rotate Old Backups
    ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null
    
    if [ "$1" != "auto" ]; then pause; fi
}

# --- RESTORE ---
restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE BACKUP                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    # Check if backups exist
    if [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${RED}No backups found in local directory!${NC}"
        echo ""
        echo -e "${YELLOW}--- HOW TO RESTORE FROM EXTERNAL FILE ---${NC}"
        echo -e "1. Upload your .tar.gz backup file to this server."
        echo -e "2. Place it in this folder: ${GREEN}$BACKUP_DIR${NC}"
        echo -e "   (Run: mkdir -p $BACKUP_DIR)"
        echo -e "3. Come back here and try again."
        echo ""
        pause
        return
    fi

    echo -e "${BLUE}Available Backups in ${GREEN}$BACKUP_DIR${NC}:"
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz); do
        echo -e "${GREEN}$i)${NC} $(basename $file) ($(du -h $file | cut -f1))"
        backups[$i]="$file"
        ((i++))
    done

    echo ""
    echo -e "${YELLOW}Tip: To restore a file from Telegram, upload it to ${GREEN}$BACKUP_DIR${YELLOW} first.${NC}"
    echo ""

    read -p "Select backup to restore (0 to cancel): " SEL
    local FILE="${backups[$SEL]}"
    [ -z "$FILE" ] && return

    echo ""
    echo -e "${RED}⚠ DANGER: This will DELETE current data and RESTORE from backup.${NC}"
    read -p "Are you sure? (yes/no): " CONF
    [ "$CONF" != "yes" ] && return

    echo -e "${BLUE}Verifying backup...${NC}"
    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    
    if ! tar -xzf "$FILE" -C "$TEMP_DIR"; then
        echo -e "${RED}✘ Backup file corrupted! Aborting.${NC}"
        rm -rf "$TEMP_DIR"
        pause; return
    fi
    
    local ROOT="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    echo -e "${YELLOW}Stopping services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE down
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE down
    systemctl stop nginx

    echo -e "${BLUE}Restoring files...${NC}"

    # Panel Data
    if [ -d "$ROOT/var_lib_pasarguard" ]; then
        mkdir -p "$PATH_DATA"
        cp -a "$ROOT/var_lib_pasarguard/." "$PATH_DATA/"
    fi
    
    # Database (Wipe & Replace)
    if [ -d "$ROOT/var_lib_postgresql" ]; then
        mkdir -p "$PATH_DB"
        rm -rf "${PATH_DB:?}/"*
        cp -a "$ROOT/var_lib_postgresql/." "$PATH_DB/"
    fi

    # Configs
    if [ -d "$ROOT/opt_pasarguard" ]; then
        mkdir -p "$PATH_OPT"
        cp -a "$ROOT/opt_pasarguard/." "$PATH_OPT/"
    fi

    # SSL
    if [ -d "$ROOT/etc_letsencrypt" ]; then
        rm -rf "$PATH_LE"
        cp -a "$ROOT/etc_letsencrypt" "/etc/"
    fi

    # Nginx
    if [ -d "$ROOT/nginx_backup" ]; then
        [ -d "$ROOT/nginx_backup/conf.d" ] && cp -a "$ROOT/nginx_backup/conf.d/." "/etc/nginx/conf.d/"
        [ -d "$ROOT/nginx_backup/sites-available" ] && cp -a "$ROOT/nginx_backup/sites-available/." "/etc/nginx/sites-available/"
    fi
    
    # Node
    if [ -d "$ROOT/opt_pgnode" ]; then
        mkdir -p "$(dirname $PATH_NODE_ENV)"
        cp -a "$ROOT/opt_pgnode/.env" "$PATH_NODE_ENV"
    fi
    if [ -d "$ROOT/var_lib_pgnode_certs" ]; then
        mkdir -p "$PATH_NODE_CERTS"
        cp -a "$ROOT/var_lib_pgnode_certs/." "$PATH_NODE_CERTS/"
    fi

    echo -e "${YELLOW}Restarting services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE up -d
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE up -d
    systemctl restart nginx

    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() {
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null
    pause
}

# --- SCHEDULER ---
setup_cron() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      AUTO BACKUP SCHEDULER                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    echo -e "${BLUE}Current Schedule:${NC}"
    crontab -l 2>/dev/null | grep "backup.sh" || echo "No schedule set."
    echo ""
    
    echo "Choose Frequency:"
    echo "1) Every Hour"
    echo "2) Every 2 Hours"
    echo "3) Every 4 Hours"
    echo "4) Every 6 Hours"
    echo "5) Every 12 Hours"
    echo "6) Daily (Set Hour)"
    echo "7) Weekly (Set Day)"
    echo "8) Disable Auto Backup"
    echo "9) Back"
    
    read -p "Select: " OPT
    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    local JOB=""
    
    case $OPT in
        1) JOB="0 * * * * $CMD" ;;
        2) JOB="0 */2 * * * $CMD" ;;
        3) JOB="0 */4 * * * $CMD" ;;
        4) JOB="0 */6 * * * $CMD" ;;
        5) JOB="0 */12 * * * $CMD" ;;
        6) read -p "Hour (0-23): " H; JOB="0 $H * * * $CMD" ;;
        7) read -p "Day (0=Sun...6=Sat): " D; JOB="0 03 * * $D $CMD" ;;
        8) (crontab -l | grep -v "backup.sh") | crontab -; echo -e "${GREEN}✔ Disabled.${NC}"; pause; return ;;
        9) return ;;
        *) echo "Invalid"; pause; return ;;
    esac
    
    (crontab -l 2>/dev/null | grep -v "backup.sh"; echo "$JOB") | crontab -
    echo -e "${GREEN}✔ Schedule updated.${NC}"
    pause
}

# --- AUTO MODE TRIGGER ---
if [ "$1" == "auto" ]; then
    create_backup "auto"
    exit 0
fi

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      BACKUP & RESTORE                     ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Create Full Backup (Now)"
        echo "2) Restore Backup"
        echo "3) List Backups"
        echo "4) Setup Telegram (Bot Token)"
        echo "5) Schedule Auto Backup (Cron)"
        echo "6) Back"
        read -p "Select: " OPT
        case $OPT in
            1) create_backup ;;
            2) restore_backup ;;
            3) list_backups ;;
            4) setup_telegram ;;
            5) setup_cron ;;
            6) return ;;
            *) ;;
        esac
    done
}