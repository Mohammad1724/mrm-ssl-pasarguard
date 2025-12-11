#!/bin/bash

# --- 1. DETECT PANEL ---
if [ -d "/opt/rebecca" ]; then
    PANEL_NAME="Rebecca"
    PANEL_DIR="/opt/rebecca"
    DATA_DIR="/var/lib/rebecca"
elif [ -d "/opt/pasarguard" ]; then
    PANEL_NAME="Pasarguard"
    PANEL_DIR="/opt/pasarguard"
    DATA_DIR="/var/lib/pasarguard"
else
    # Fallback default
    PANEL_NAME="Unknown"
    PANEL_DIR="/opt/marzban"
    DATA_DIR="/var/lib/marzban"
fi

BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
MAX_BACKUPS=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

pause() { 
    echo ""
    read -p "Press Enter to continue..." 
}

# --- TELEGRAM ---
setup_telegram() {
    clear
    echo -e "${CYAN}=== TELEGRAM SETUP ===${NC}"
    echo "Current Config:"
    if [ -f "$TG_CONFIG" ]; then cat "$TG_CONFIG"; else echo "Not configured."; fi
    echo ""
    
    read -p "Bot Token: " TOKEN
    read -p "Chat ID: " CHATID
    
    if [ -n "$TOKEN" ] && [ -n "$CHATID" ]; then
        echo "TG_TOKEN=\"$TOKEN\"" > "$TG_CONFIG"
        echo "TG_CHAT=\"$CHATID\"" >> "$TG_CONFIG"
        echo -e "${GREEN}Saved.${NC}"
        
        # Test
        echo "Sending test message..."
        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d chat_id="$CHATID" \
            -d text="✅ MRM Backup Service Connected!"
    else
        echo "Cancelled."
    fi
    pause
}

send_to_telegram() {
    local FILE=$1
    if [ ! -f "$TG_CONFIG" ]; then return; fi
    source "$TG_CONFIG"
    
    if [ -z "$TG_TOKEN" ]; then return; fi

    echo -e "${BLUE}>> Sending to Telegram...${NC}"
    local CAPTION="📦 **Backup: $PANEL_NAME**%0A📅 $(date '+%Y-%m-%d %H:%M')"
    
    # Verbose output to see errors
    curl -v -F chat_id="$TG_CHAT" \
         -F caption="$CAPTION" \
         -F parse_mode="Markdown" \
         -F document=@"$FILE" \
         "https://api.telegram.org/bot$TG_TOKEN/sendDocument" 2>&1 | grep "{" 
}

# --- BACKUP LOGIC ---
create_backup() {
    local MODE=$1
    if [ "$MODE" != "auto" ]; then
        clear
        echo -e "${CYAN}=== CREATING BACKUP ===${NC}"
        echo "Panel: $PANEL_NAME"
        echo "Dir:   $PANEL_DIR"
    fi

    # Check if panel exists
    if [ ! -d "$PANEL_DIR" ]; then
        echo -e "${RED}Error: Panel directory not found at $PANEL_DIR${NC}"
        if [ "$MODE" != "auto" ]; then pause; fi
        return
    fi

    mkdir -p "$BACKUP_DIR"
    local TS=$(date +%Y%m%d_%H%M%S)
    local NAME="backup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"

    # 1. DB Dump
    echo -ne "Dumping Database... "
    cd "$PANEL_DIR" || return
    
    # Try Marzban CLI first (Universal)
    local CID=$(docker compose ps -q | head -1)
    if [ -n "$CID" ]; then
        if docker exec "$CID" marzban-cli database dump --target /tmp/db_dump >/dev/null 2>&1; then
            docker cp "$CID:/tmp/db_dump" "$TMP/database.sqlite3"
            echo -e "${GREEN}OK (CLI)${NC}"
        else
            echo -e "${YELLOW}CLI Failed (Trying Raw)${NC}"
            # Fallback for raw files if CLI fails
            if [ -f "$DATA_DIR/db.sqlite3" ]; then
                cp "$DATA_DIR/db.sqlite3" "$TMP/"
                echo -e "${GREEN}OK (Copy)${NC}"
            fi
        fi
    else
        echo -e "${RED}Container Not Running${NC}"
    fi

    # 2. Files
    echo -ne "Archiving Files... "
    [ -d "$PANEL_DIR" ] && cp -r "$PANEL_DIR" "$TMP/config"
    [ -d "$DATA_DIR" ] && cp -r "$DATA_DIR" "$TMP/data"
    echo -e "${GREEN}OK${NC}"

    # 3. Compress
    echo -ne "Compressing... "
    cd "$BACKUP_DIR"
    tar -czf "${NAME}.tar.gz" -C "/tmp" "$NAME"
    rm -rf "$TMP"
    echo -e "${GREEN}Done${NC}"

    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"
    
    if [ -f "$FINAL_FILE" ]; then
        send_to_telegram "$FINAL_FILE"
        echo -e "${GREEN}Backup Saved: ${YELLOW}$FINAL_FILE${NC}"
    else
        echo -e "${RED}Failed to create file!${NC}"
    fi

    if [ "$MODE" != "auto" ]; then pause; fi
}

# --- CRON ---
setup_cron() {
    clear
    echo "Current Cron Jobs:"
    crontab -l | grep "backup.sh"
    echo ""
    echo "1) Every 6 Hours"
    echo "2) Daily"
    echo "3) Disable"
    read -p "Select: " O
    
    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    (crontab -l | grep -v "backup.sh") | crontab -
    
    if [ "$O" == "1" ]; then
        (crontab -l; echo "0 */6 * * * $CMD") | crontab -
        echo "Set to 6 hours."
    elif [ "$O" == "2" ]; then
        (crontab -l; echo "0 0 * * * $CMD") | crontab -
        echo "Set to daily."
    else
        echo "Disabled."
    fi
    pause
}

# Auto Mode
if [ "$1" == "auto" ]; then
    create_backup "auto"
    exit 0
fi

# Menu
while true; do
    clear
    echo -e "${BLUE}=== BACKUP MANAGER ===${NC}"
    echo "1) Create Backup & Send"
    echo "2) Telegram Settings"
    echo "3) Auto Backup Schedule"
    echo "0) Back"
    echo ""
    read -p "Select: " OPT
    case $OPT in
        1) create_backup ;;
        2) setup_telegram ;;
        3) setup_cron ;;
        0) exit ;;
        *) ;;
    esac
done