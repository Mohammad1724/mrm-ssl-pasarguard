#!/bin/bash

# --- CONFIG ---
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
MAX_BACKUPS=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---

# Function to clear input buffer and pause
safe_pause() {
    echo ""
    # Clear input buffer
    read -t 0.1 -n 10000 discard 2>/dev/null
    read -n 1 -s -r -p "Press any key to continue..."
    echo ""
}

detect_panel() {
    if [ -d "/opt/rebecca" ]; then
        PANEL_NAME="Rebecca"
        PANEL_DIR="/opt/rebecca"
        DATA_DIR="/var/lib/rebecca"
    elif [ -d "/opt/pasarguard" ]; then
        PANEL_NAME="Pasarguard"
        PANEL_DIR="/opt/pasarguard"
        DATA_DIR="/var/lib/pasarguard"
    else
        PANEL_NAME="Unknown"
        PANEL_DIR="/opt/marzban"
        DATA_DIR="/var/lib/marzban"
    fi
}

setup_telegram() {
    clear
    echo -e "${CYAN}=== TELEGRAM SETUP ===${NC}"
    
    local CUR_TOKEN=""
    local CUR_CHAT=""
    
    if [ -f "$TG_CONFIG" ]; then
        CUR_TOKEN=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'"' -f2)
        CUR_CHAT=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'"' -f2)
        echo -e "Current Chat ID: ${GREEN}$CUR_CHAT${NC}"
        echo -e "Current Token:   ${GREEN}${CUR_TOKEN:0:10}......${NC}"
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
        
        echo "Sending test message..."
        local RES=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d chat_id="$CHATID" \
            -d text="✅ MRM Backup Service Connected!")
            
        if echo "$RES" | grep -q '"ok":true'; then
            echo -e "${GREEN}✔ Test Successful!${NC}"
        else
            echo -e "${RED}✘ Test Failed!${NC}"
            echo "Response: $RES"
        fi
    else
        echo "Cancelled."
    fi
    safe_pause
}

send_to_telegram() {
    local FILE="$1"
    
    # Reload Config
    if [ ! -f "$TG_CONFIG" ]; then return 1; fi
    local TG_TOKEN=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'"' -f2)
    local TG_CHAT=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'"' -f2)

    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then return 1; fi

    echo -e "${BLUE}>> Uploading to Telegram (Please wait)...${NC}"
    
    local CAPTION="📦 Backup: $PANEL_NAME
📅 $(date '+%Y-%m-%d %H:%M')
💾 Size: $(du -h "$FILE" | cut -f1)"

    # Remove -s (silent) to show errors if any
    # Added --connect-timeout to fail faster if network is bad
    curl -v --connect-timeout 20 \
         -F chat_id="$TG_CHAT" \
         -F caption="$CAPTION" \
         -F document=@"$FILE" \
         "https://api.telegram.org/bot$TG_TOKEN/sendDocument" > /tmp/tg_result.json 2>&1
    
    local CURL_EXIT=$?
    
    if [ $CURL_EXIT -eq 0 ] && grep -q '"ok":true' /tmp/tg_result.json; then
        echo -e "${GREEN}✔ Upload Successful!${NC}"
        return 0
    else
        echo -e "${RED}✘ Upload Failed!${NC}"
        echo -e "${YELLOW}Debug Info:${NC}"
        cat /tmp/tg_result.json | grep -o '"description":"[^"]*"' 
        return 1
    fi
}

create_backup() {
    local MODE="$1"
    detect_panel
    
    if [ "$MODE" != "auto" ]; then
        clear
        echo -e "${CYAN}=== BACKUP PROCESS ===${NC}"
        echo -e "Panel: ${GREEN}$PANEL_NAME${NC}"
    fi

    if [ ! -d "$PANEL_DIR" ]; then
        echo -e "${RED}Panel directory not found!${NC}"
        [ "$MODE" != "auto" ] && safe_pause
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    local TS=$(date +%Y%m%d_%H%M%S)
    local NAME="backup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"

    # 1. DB
    echo -ne "Dumping DB... "
    local CID=$(docker ps --format '{{.ID}} {{.Names}}' | grep -iE "pasarguard|marzban|rebecca" | head -1 | awk '{print $1}')
    
    if [ -n "$CID" ]; then
        if docker exec "$CID" marzban-cli database dump --target /tmp/db_dump >/dev/null 2>&1; then
            docker cp "$CID:/tmp/db_dump" "$TMP/database.sqlite3"
            echo -e "${GREEN}OK (CLI)${NC}"
        elif [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp "$DATA_DIR/db.sqlite3" "$TMP/"
            echo -e "${GREEN}OK (Raw)${NC}"
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
    else
        if [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp "$DATA_DIR/db.sqlite3" "$TMP/"
            echo -e "${GREEN}OK (Offline)${NC}"
        else
            echo -e "${RED}No DB found${NC}"
        fi
    fi

    # 2. Files
    echo -ne "Archiving... "
    [ -d "$PANEL_DIR" ] && cp -r "$PANEL_DIR" "$TMP/config"
    [ -d "$DATA_DIR" ] && cp -r "$DATA_DIR" "$TMP/data"
    echo -e "${GREEN}OK${NC}"

    # 3. Zip
    cd "$BACKUP_DIR"
    tar -czf "${NAME}.tar.gz" -C "/tmp" "$NAME"
    rm -rf "$TMP"
    
    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"

    echo ""
    if [ -f "$FINAL_FILE" ]; then
        echo -e "${GREEN}✔ Created: $FINAL_FILE${NC}"
        
        # Check Telegram Config before trying
        if [ -f "$TG_CONFIG" ]; then
            send_to_telegram "$FINAL_FILE"
        else
            echo -e "${YELLOW}Telegram not configured.${NC}"
        fi
    else
        echo -e "${RED}Failed to create file.${NC}"
    fi

    if [ "$MODE" != "auto" ]; then
        safe_pause
    fi
}

setup_cron() {
    clear
    echo -e "${CYAN}=== AUTO BACKUP ===${NC}"
    echo "1) Every 6 Hours"
    echo "2) Daily"
    echo "3) Disable"
    read -p "Select: " O
    
    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    (crontab -l 2>/dev/null | grep -v "backup.sh") | crontab -

    case $O in
        1) (crontab -l 2>/dev/null; echo "0 */6 * * * $CMD") | crontab -; echo "Enabled (6h)." ;;
        2) (crontab -l 2>/dev/null; echo "0 0 * * * $CMD") | crontab -; echo "Enabled (Daily)." ;;
        *) echo "Disabled." ;;
    esac
    safe_pause
}

# --- MENU ---
backup_menu() {
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
            1) create_backup "manual" ;;
            2) setup_telegram ;;
            3) setup_cron ;;
            0) return ;;
            *) ;;
        esac
    done
}

# --- ENTRY POINT ---
if [ "$1" == "auto" ]; then
    create_backup "auto"
    exit 0
fi

# Run menu if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_menu
fi