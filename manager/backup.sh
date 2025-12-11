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
    PANEL_NAME="Unknown"
    PANEL_DIR="/opt/marzban"
    DATA_DIR="/var/lib/marzban"
fi

BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
MAX_BACKUPS=10

# Colors (if not already defined)
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Pause function (safe override)
backup_pause() { 
    echo ""
    read -rp "Press Enter to continue..." 
}

# --- TELEGRAM SETUP ---
setup_telegram() {
    clear
    echo -e "${CYAN}=== TELEGRAM SETUP ===${NC}"
    echo "Current Config:"
    if [ -f "$TG_CONFIG" ]; then 
        cat "$TG_CONFIG"
    else 
        echo "Not configured."
    fi
    echo ""

    read -rp "Bot Token: " TOKEN
    read -rp "Chat ID: " CHATID

    if [ -n "$TOKEN" ] && [ -n "$CHATID" ]; then
        echo "TG_TOKEN=\"$TOKEN\"" > "$TG_CONFIG"
        echo "TG_CHAT=\"$CHATID\"" >> "$TG_CONFIG"
        echo -e "${GREEN}Saved.${NC}"

        echo "Sending test message..."
        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d chat_id="$CHATID" \
            -d text="✅ MRM Backup Service Connected!"
        echo ""
    else
        echo "Cancelled."
    fi
    backup_pause
}

# --- SEND TO TELEGRAM ---
send_to_telegram() {
    local FILE="$1"
    
    if [ ! -f "$TG_CONFIG" ]; then 
        echo -e "${YELLOW}⚠ Telegram not configured. Skipping upload.${NC}"
        return 1
    fi
    
    # Read config safely
    local TG_TOKEN=""
    local TG_CHAT=""
    TG_TOKEN=$(grep "^TG_TOKEN=" "$TG_CONFIG" 2>/dev/null | cut -d'"' -f2)
    TG_CHAT=$(grep "^TG_CHAT=" "$TG_CONFIG" 2>/dev/null | cut -d'"' -f2)

    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then 
        echo -e "${YELLOW}⚠ Telegram config incomplete.${NC}"
        return 1
    fi

    if [ ! -f "$FILE" ]; then
        echo -e "${RED}✘ File not found: $FILE${NC}"
        return 1
    fi

    echo -e "${BLUE}>> Sending to Telegram...${NC}"
    
    local CAPTION="📦 Backup: $PANEL_NAME
📅 $(date '+%Y-%m-%d %H:%M')
💾 Size: $(du -h "$FILE" | cut -f1)"

    local RESPONSE
    RESPONSE=$(curl -s -X POST \
         -F chat_id="$TG_CHAT" \
         -F caption="$CAPTION" \
         -F document=@"$FILE" \
         "https://api.telegram.org/bot$TG_TOKEN/sendDocument" 2>&1)

    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo -e "${GREEN}✔ Sent to Telegram successfully!${NC}"
        return 0
    else
        echo -e "${RED}✘ Telegram send failed!${NC}"
        echo -e "${YELLOW}Error: $(echo "$RESPONSE" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)${NC}"
        return 1
    fi
}

# --- CREATE BACKUP ---
create_backup() {
    local MODE="$1"
    
    # Manual mode: show header
    if [ "$MODE" != "auto" ]; then
        clear
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${YELLOW}      CREATING BACKUP                        ${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo ""
        echo -e "Panel: ${GREEN}$PANEL_NAME${NC}"
        echo -e "Dir:   ${GREEN}$PANEL_DIR${NC}"
        echo -e "Data:  ${GREEN}$DATA_DIR${NC}"
        echo ""
    fi

    # Check panel directory
    if [ ! -d "$PANEL_DIR" ]; then
        echo -e "${RED}✘ Error: Panel directory not found at $PANEL_DIR${NC}"
        [ "$MODE" != "auto" ] && backup_pause
        return 1
    fi

    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    local TS
    TS=$(date +%Y%m%d_%H%M%S)
    local NAME="backup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"

    # 1. Database Dump
    echo -ne "${BLUE}[1/3]${NC} Dumping Database... "
    
    local ORIGINAL_DIR
    ORIGINAL_DIR=$(pwd)
    cd "$PANEL_DIR" 2>/dev/null || {
        echo -e "${RED}Failed to cd${NC}"
        [ "$MODE" != "auto" ] && backup_pause
        return 1
    }

    local CID
    CID=$(docker compose ps -q 2>/dev/null | head -1)
    
    if [ -n "$CID" ]; then
        if docker exec "$CID" marzban-cli database dump --target /tmp/db_dump >/dev/null 2>&1; then
            docker cp "$CID:/tmp/db_dump" "$TMP/database.sqlite3" 2>/dev/null
            echo -e "${GREEN}OK (CLI)${NC}"
        else
            if [ -f "$DATA_DIR/db.sqlite3" ]; then
                cp "$DATA_DIR/db.sqlite3" "$TMP/" 2>/dev/null
                echo -e "${GREEN}OK (Direct Copy)${NC}"
            else
                echo -e "${YELLOW}Skipped (No DB found)${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}Skipped (Container not running)${NC}"
        if [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp "$DATA_DIR/db.sqlite3" "$TMP/" 2>/dev/null
            echo -e "${GREEN}   → Copied raw database${NC}"
        fi
    fi

    # 2. Archive Files
    echo -ne "${BLUE}[2/3]${NC} Archiving Files... "
    [ -d "$PANEL_DIR" ] && cp -r "$PANEL_DIR" "$TMP/config" 2>/dev/null
    [ -d "$DATA_DIR" ] && cp -r "$DATA_DIR" "$TMP/data" 2>/dev/null
    echo -e "${GREEN}OK${NC}"

    # 3. Compress
    echo -ne "${BLUE}[3/3]${NC} Compressing... "
    cd "$BACKUP_DIR" || cd /tmp
    tar -czf "${NAME}.tar.gz" -C "/tmp" "$NAME" 2>/dev/null
    rm -rf "$TMP"
    echo -e "${GREEN}Done${NC}"

    cd "$ORIGINAL_DIR" 2>/dev/null || true

    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"

    echo ""
    if [ -f "$FINAL_FILE" ]; then
        echo -e "${GREEN}✔ Backup Created: ${YELLOW}$FINAL_FILE${NC}"
        echo -e "${GREEN}✔ Size: $(du -h "$FINAL_FILE" | cut -f1)${NC}"
        echo ""
        
        # Send to Telegram
        send_to_telegram "$FINAL_FILE"
    else
        echo -e "${RED}✘ Failed to create backup file!${NC}"
    fi

    [ "$MODE" != "auto" ] && backup_pause
    return 0
}

# --- SETUP CRON ---
setup_cron() {
    clear
    echo -e "${CYAN}=== AUTO BACKUP SCHEDULE ===${NC}"
    echo ""
    echo "Current Cron Jobs:"
    crontab -l 2>/dev/null | grep "backup.sh" || echo "  (None configured)"
    echo ""
    echo "1) Every 6 Hours"
    echo "2) Every 12 Hours"  
    echo "3) Daily (Midnight)"
    echo "4) Disable Auto Backup"
    echo "0) Cancel"
    echo ""
    read -rp "Select: " O

    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    
    # Remove existing backup cron entries
    (crontab -l 2>/dev/null | grep -v "backup.sh") | crontab - 2>/dev/null

    case "$O" in
        1)
            (crontab -l 2>/dev/null; echo "0 */6 * * * $CMD") | crontab -
            echo -e "${GREEN}✔ Set to every 6 hours.${NC}"
            ;;
        2)
            (crontab -l 2>/dev/null; echo "0 */12 * * * $CMD") | crontab -
            echo -e "${GREEN}✔ Set to every 12 hours.${NC}"
            ;;
        3)
            (crontab -l 2>/dev/null; echo "0 0 * * * $CMD") | crontab -
            echo -e "${GREEN}✔ Set to daily at midnight.${NC}"
            ;;
        4)
            echo -e "${YELLOW}✔ Auto backup disabled.${NC}"
            ;;
        *)
            echo "Cancelled."
            ;;
    esac
    backup_pause
}

# --- BACKUP MENU (Called from main.sh) ---
backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${YELLOW}      BACKUP MANAGER                         ${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo ""
        echo "  1) Create Backup & Send to Telegram"
        echo "  2) Telegram Settings"
        echo "  3) Auto Backup Schedule (Cron)"
        echo ""
        echo "  0) Back to Main Menu"
        echo ""
        echo -e "${BLUE}=============================================${NC}"
        
        read -rp "Select: " OPT
        
        # Clean input (remove spaces/newlines)
        OPT=$(echo "$OPT" | tr -d '[:space:]')
        
        case "$OPT" in
            1) create_backup "manual" ;;
            2) setup_telegram ;;
            3) setup_cron ;;
            0|q|Q) return 0 ;;
            *) 
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# --- AUTO MODE (Called from Cron) ---
if [ "${1:-}" == "auto" ]; then
    create_backup "auto"
    exit 0
fi

# --- DIRECT EXECUTION (Not sourced from main.sh) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_menu
fi