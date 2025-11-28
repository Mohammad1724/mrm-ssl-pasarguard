#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Backup Settings
BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10

create_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CREATE BACKUP                          ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    mkdir -p "$BACKUP_DIR"
    
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="pasarguard_backup_$TIMESTAMP"
    local BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    
    mkdir -p "$BACKUP_PATH"
    
    echo -e "${BLUE}[1/5] Backing up Panel Database...${NC}"
    if [ -f "/var/lib/pasarguard/db.sqlite3" ]; then
        cp "/var/lib/pasarguard/db.sqlite3" "$BACKUP_PATH/"
        echo -e "${GREEN}✔ Database saved${NC}"
    else
        echo -e "${YELLOW}! Database not found, skipping${NC}"
    fi
    
    echo -e "${BLUE}[2/5] Backing up Xray Config...${NC}"
    if [ -f "/var/lib/pasarguard/config.json" ]; then
        cp "/var/lib/pasarguard/config.json" "$BACKUP_PATH/"
        echo -e "${GREEN}✔ Xray config saved${NC}"
    fi
    
    echo -e "${BLUE}[3/5] Backing up SSL Certificates...${NC}"
    if [ -d "/var/lib/pasarguard/certs" ]; then
        cp -r "/var/lib/pasarguard/certs" "$BACKUP_PATH/"
        echo -e "${GREEN}✔ Certificates saved${NC}"
    fi
    
    echo -e "${BLUE}[4/5] Backing up Panel .env...${NC}"
    if [ -f "$PANEL_ENV" ]; then
        cp "$PANEL_ENV" "$BACKUP_PATH/"
        echo -e "${GREEN}✔ Panel config saved${NC}"
    fi
    
    echo -e "${BLUE}[5/5] Backing up Node .env...${NC}"
    if [ -f "$NODE_ENV" ]; then
        cp "$NODE_ENV" "$BACKUP_PATH/node.env"
        echo -e "${GREEN}✔ Node config saved${NC}"
    fi
    
    # Create archive
    echo -e "${BLUE}Creating archive...${NC}"
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$BACKUP_PATH"
    
    local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    local FILE_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
    
    echo -e "${GREEN}✔ Backup Complete!${NC}"
    echo ""
    echo -e "File: ${CYAN}$FINAL_FILE${NC}"
    echo -e "Size: ${CYAN}$FILE_SIZE${NC}"
    
    # Cleanup old backups
    local BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        echo -e "${YELLOW}Cleaning old backups (keeping last $MAX_BACKUPS)...${NC}"
        ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
    fi
    
    pause
}

restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE BACKUP                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}No backup directory found!${NC}"
        pause
        return
    fi
    
    echo -e "${BLUE}Available Backups:${NC}"
    echo ""
    
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        local fsize=$(du -h "$file" | cut -f1)
        local fdate=$(echo "$fname" | grep -oP '\d{8}_\d{6}' | head -1)
        backups[$i]="$file"
        echo -e "${GREEN}$i)${NC} $fname (${fsize})"
        ((i++))
    done
    
    if [ $i -eq 1 ]; then
        echo -e "${RED}No backups found!${NC}"
        pause
        return
    fi
    
    echo ""
    read -p "Select backup number (0 to cancel): " SEL
    
    [ "$SEL" == "0" ] && return
    
    local SELECTED_FILE="${backups[$SEL]}"
    
    if [ -z "$SELECTED_FILE" ] || [ ! -f "$SELECTED_FILE" ]; then
        echo -e "${RED}Invalid selection!${NC}"
        pause
        return
    fi
    
    echo ""
    echo -e "${RED}WARNING: This will overwrite current configuration!${NC}"
    read -p "Are you sure? (yes/no): " CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        pause
        return
    fi
    
    echo -e "${BLUE}Extracting backup...${NC}"
    
    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    tar -xzf "$SELECTED_FILE" -C "$TEMP_DIR"
    
    local EXTRACTED_DIR=$(ls -1 "$TEMP_DIR" | head -1)
    local RESTORE_PATH="$TEMP_DIR/$EXTRACTED_DIR"
    
    echo -e "${BLUE}Stopping services...${NC}"
    cd "$PANEL_DIR" 2>/dev/null && docker compose stop
    
    echo -e "${BLUE}Restoring files...${NC}"
    
    # Restore database
    if [ -f "$RESTORE_PATH/db.sqlite3" ]; then
        cp "$RESTORE_PATH/db.sqlite3" "/var/lib/pasarguard/"
        echo -e "${GREEN}✔ Database restored${NC}"
    fi
    
    # Restore config
    if [ -f "$RESTORE_PATH/config.json" ]; then
        cp "$RESTORE_PATH/config.json" "/var/lib/pasarguard/"
        echo -e "${GREEN}✔ Xray config restored${NC}"
    fi
    
    # Restore certs
    if [ -d "$RESTORE_PATH/certs" ]; then
        cp -r "$RESTORE_PATH/certs" "/var/lib/pasarguard/"
        echo -e "${GREEN}✔ Certificates restored${NC}"
    fi
    
    # Restore .env
    if [ -f "$RESTORE_PATH/.env" ]; then
        cp "$RESTORE_PATH/.env" "$PANEL_ENV"
        echo -e "${GREEN}✔ Panel config restored${NC}"
    fi
    
    # Restore node .env
    if [ -f "$RESTORE_PATH/node.env" ]; then
        cp "$RESTORE_PATH/node.env" "$NODE_ENV"
        echo -e "${GREEN}✔ Node config restored${NC}"
    fi
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    echo -e "${BLUE}Starting services...${NC}"
    cd "$PANEL_DIR" 2>/dev/null && docker compose up -d
    
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      BACKUP LIST                            ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}No backup directory found!${NC}"
        pause
        return
    fi
    
    echo ""
    printf "%-40s %-10s %-20s\n" "Filename" "Size" "Date"
    echo "----------------------------------------------------------------------"
    
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        local fsize=$(du -h "$file" | cut -f1)
        local fdate=$(stat -c %y "$file" | cut -d' ' -f1)
        printf "%-40s %-10s %-20s\n" "$fname" "$fsize" "$fdate"
    done
    
    echo ""
    local TOTAL=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    echo -e "Total Backups: ${CYAN}$TOTAL${NC}"
    
    pause
}

delete_backup() {
    clear
    echo -e "${RED}=== DELETE BACKUP ===${NC}"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}No backup directory!${NC}"
        pause
        return
    fi
    
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        backups[$i]="$file"
        echo -e "${GREEN}$i)${NC} $fname"
        ((i++))
    done
    
    [ $i -eq 1 ] && { echo "No backups."; pause; return; }
    
    echo ""
    read -p "Select backup to delete (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    
    local SELECTED="${backups[$SEL]}"
    [ -z "$SELECTED" ] && { echo "Invalid!"; pause; return; }
    
    read -p "Delete $(basename $SELECTED)? (y/n): " CONF
    if [ "$CONF" == "y" ]; then
        rm -f "$SELECTED"
        echo -e "${GREEN}✔ Deleted${NC}"
    fi
    
    pause
}

upload_to_telegram() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      UPLOAD TO TELEGRAM                     ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    # Check for saved bot token
    local TG_CONFIG="/root/.mrm_telegram"
    local BOT_TOKEN=""
    local CHAT_ID=""
    
    if [ -f "$TG_CONFIG" ]; then
        source "$TG_CONFIG"
        echo -e "Saved Bot: ${CYAN}${BOT_TOKEN:0:10}...${NC}"
        echo -e "Saved Chat ID: ${CYAN}$CHAT_ID${NC}"
        echo ""
        read -p "Use saved settings? (y/n): " USE_SAVED
        if [ "$USE_SAVED" != "y" ]; then
            BOT_TOKEN=""
            CHAT_ID=""
        fi
    fi
    
    if [ -z "$BOT_TOKEN" ]; then
        echo ""
        echo -e "${YELLOW}How to get Bot Token:${NC}"
        echo "1. Go to @BotFather in Telegram"
        echo "2. Create a new bot or use existing"
        echo "3. Copy the token"
        echo ""
        read -p "Bot Token: " BOT_TOKEN
        [ -z "$BOT_TOKEN" ] && { echo "Cancelled."; pause; return; }
    fi
    
    if [ -z "$CHAT_ID" ]; then
        echo ""
        echo -e "${YELLOW}How to get Chat ID:${NC}"
        echo "1. Send a message to your bot"
        echo "2. Go to: https://api.telegram.org/bot<TOKEN>/getUpdates"
        echo "3. Find 'chat':{'id': YOUR_ID}"
        echo ""
        read -p "Chat ID: " CHAT_ID
        [ -z "$CHAT_ID" ] && { echo "Cancelled."; pause; return; }
    fi
    
    # Save settings
    echo "BOT_TOKEN=\"$BOT_TOKEN\"" > "$TG_CONFIG"
    echo "CHAT_ID=\"$CHAT_ID\"" >> "$TG_CONFIG"
    chmod 600 "$TG_CONFIG"
    
    # Select backup to upload
    echo ""
    echo -e "${BLUE}Select backup to upload:${NC}"
    
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        local fsize=$(du -h "$file" | cut -f1)
        backups[$i]="$file"
        echo -e "${GREEN}$i)${NC} $fname ($fsize)"
        ((i++))
    done
    
    [ $i -eq 1 ] && { echo "No backups found!"; pause; return; }
    
    read -p "Select (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    
    local SELECTED="${backups[$SEL]}"
    [ -z "$SELECTED" ] && { echo "Invalid!"; pause; return; }
    
    local FILE_SIZE=$(stat -c%s "$SELECTED")
    local MAX_SIZE=$((50 * 1024 * 1024)) # 50MB Telegram limit
    
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        echo -e "${RED}File too large for Telegram (max 50MB)!${NC}"
        pause
        return
    fi
    
    echo -e "${BLUE}Uploading to Telegram...${NC}"
    
    local RESPONSE=$(curl -s -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
        -F chat_id="$CHAT_ID" \
        -F document=@"$SELECTED" \
        -F caption="🔒 Pasarguard Backup - $(date '+%Y-%m-%d %H:%M')")
    
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo -e "${GREEN}✔ Uploaded Successfully!${NC}"
    else
        echo -e "${RED}✘ Upload Failed!${NC}"
        echo "$RESPONSE"
    fi
    
    pause
}

auto_backup_setup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      AUTO BACKUP (CRON)                     ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    echo "Setup automatic daily backup?"
    echo ""
    echo "1) Enable Daily Backup (3:00 AM)"
    echo "2) Enable Weekly Backup (Sunday 3:00 AM)"
    echo "3) Disable Auto Backup"
    echo "4) Back"
    read -p "Select: " CRON_OPT
    
    local CRON_CMD="/opt/mrm-manager/backup.sh auto"
    
    case $CRON_OPT in
        1)
            (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 3 * * * $CRON_CMD") | crontab -
            echo -e "${GREEN}✔ Daily backup enabled at 3:00 AM${NC}"
            ;;
        2)
            (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 3 * * 0 $CRON_CMD") | crontab -
            echo -e "${GREEN}✔ Weekly backup enabled (Sunday 3:00 AM)${NC}"
            ;;
        3)
            crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
            echo -e "${YELLOW}Auto backup disabled${NC}"
            ;;
        *) return ;;
    esac
    
    pause
}

# Auto backup mode (called by cron)
if [ "$1" == "auto" ]; then
    source /opt/mrm-manager/utils.sh
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_NAME="auto_backup_$TIMESTAMP"
    BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    mkdir -p "$BACKUP_PATH"
    
    [ -f "/var/lib/pasarguard/db.sqlite3" ] && cp "/var/lib/pasarguard/db.sqlite3" "$BACKUP_PATH/"
    [ -f "/var/lib/pasarguard/config.json" ] && cp "/var/lib/pasarguard/config.json" "$BACKUP_PATH/"
    [ -d "/var/lib/pasarguard/certs" ] && cp -r "/var/lib/pasarguard/certs" "$BACKUP_PATH/"
    [ -f "$PANEL_ENV" ] && cp "$PANEL_ENV" "$BACKUP_PATH/"
    
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$BACKUP_PATH"
    
    # Keep only last 10
    ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +11 | xargs rm -f 2>/dev/null
    
    exit 0
fi

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      BACKUP & RESTORE                     ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Create Backup Now"
        echo "2) Restore from Backup"
        echo "3) List All Backups"
        echo "4) Delete Backup"
        echo "5) Upload to Telegram"
        echo "6) Auto Backup (Cron)"
        echo "7) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) create_backup ;;
            2) restore_backup ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) upload_to_telegram ;;
            6) auto_backup_setup ;;
            7) return ;;
            *) ;;
        esac
    done
}