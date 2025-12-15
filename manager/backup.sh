#!/bin/bash

# --- CONFIGURATION ---
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check dependencies
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# --- FORCED PAUSE ---
force_pause() {
    echo ""
    echo -e "${YELLOW}--- Press ENTER to continue ---${NC}"
    read -p ""
}

# --- DETECT PANEL (Using utils) ---
# Already done in utils.sh, variables are available.

# --- TELEGRAM SETUP ---
setup_telegram() {
    clear
    echo -e "${CYAN}=== TELEGRAM CONFIG ===${NC}"

    # Read current config
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
        # Try sending a simple message
        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d chat_id="$CHATID" \
            -d text="✅ Connection Test OK" > /tmp/tg_test.log

        if grep -q '"ok":true' /tmp/tg_test.log; then
             echo -e "${GREEN}✔ Connection Successful!${NC}"
        else
             echo -e "${RED}✘ Connection Failed!${NC}"
             cat /tmp/tg_test.log
        fi
    fi
    force_pause
}

# --- SEND LOGIC ---
send_to_telegram() {
    local FILE="$1"

    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}       STARTING TELEGRAM UPLOAD         ${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"

    if [ ! -f "$TG_CONFIG" ]; then
        echo -e "${RED}Error: Telegram not configured.${NC}"
        return 1
    fi

    # Read variables cleanly
    local TG_TOKEN=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'"' -f2)
    local TG_CHAT=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'"' -f2)

    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
        echo -e "${RED}Error: Config file empty or invalid.${NC}"
        return 1
    fi

    echo -e "Target: Chat ID $TG_CHAT"
    echo -e "File:   $FILE"

    # Check file size
    local FSIZE=$(du -k "$FILE" | cut -f1)
    echo -e "Size:   ${FSIZE} KB"

    if [ "$FSIZE" -gt 49000 ]; then
        echo -e "${RED}Warning: File is larger than 50MB. Telegram Bot API might reject it.${NC}"
    fi

    echo -e "${YELLOW}>> Uploading... (Please Wait)${NC}"

    # --- THE CRITICAL CURL COMMAND ---
    # We capture stdout and stderr to a log file to show you EXACTLY what happened
    local CAPTION="#Backup $PANEL_NAME $(date +%F_%R)"

    curl -s --connect-timeout 30 \
         -F chat_id="$TG_CHAT" \
         -F caption="$CAPTION" \
         -F document=@"$FILE" \
         "https://api.telegram.org/bot$TG_TOKEN/sendDocument" > /tmp/tg_debug.log 2>&1

    local EXIT_CODE=$?

    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}           UPLOAD RESULT                ${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"

    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}✘ CURL FAILED (Exit Code: $EXIT_CODE)${NC}"
        echo "Possible reasons: Network timeout, DNS issue, or Proxy needed."
        echo "Last lines of log:"
        tail -n 10 /tmp/tg_debug.log
    else
        # Check if Telegram said "ok":true
        if grep -q '"ok":true' /tmp/tg_debug.log; then
            echo -e "${GREEN}✔ SUCCESS: Telegram accepted the file.${NC}"
        else
            echo -e "${RED}✘ TELEGRAM API ERROR${NC}"
            echo "Response from Telegram:"
            grep "{" /tmp/tg_debug.log
        fi
    fi
}

# --- BACKUP LOGIC ---
create_backup() {
    local MODE="$1"
    
    # Refresh panel detection
    if [ -z "$PANEL_NAME" ]; then source /opt/mrm-manager/utils.sh; fi

    if [ "$MODE" != "auto" ]; then
        clear
        echo -e "${CYAN}Creating Backup for $PANEL_NAME...${NC}"
    fi

    if [ ! -d "$PANEL_DIR" ]; then
        echo -e "${RED}Panel directory ($PANEL_DIR) not found!${NC}"
        [ "$MODE" != "auto" ] && force_pause
        return
    fi

    mkdir -p "$BACKUP_DIR"
    local TS=$(date +%Y%m%d_%H%M%S)
    local NAME="backup_${PANEL_NAME}_${TS}"
    local TMP="/tmp/$NAME"
    mkdir -p "$TMP"

    # 1. DB
    echo -ne "Exporting DB... "
    # FIX: Find correct container ID excluding mysql/node
    local CID=$(docker ps --format '{{.ID}} {{.Names}}' | grep -iE "$PANEL_NAME|marzban|pasarguard|rebecca" | grep -v "mysql" | grep -v "node" | head -1 | awk '{print $1}')
    local CLI_CMD=$(get_panel_cli)

    if [ -n "$CID" ]; then
        # FIX: Use dynamic CLI command
        if docker exec "$CID" $CLI_CMD database dump --target /tmp/db_dump >/dev/null 2>&1; then
            docker cp "$CID:/tmp/db_dump" "$TMP/database.sqlite3"
            echo -e "${GREEN}OK (CLI)${NC}"
        elif [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp "$DATA_DIR/db.sqlite3" "$TMP/"
            echo -e "${GREEN}OK (Raw Copy)${NC}"
        else
            echo -e "${YELLOW}Failed${NC}"
        fi
    else
        # Container down? Try raw copy
        if [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp "$DATA_DIR/db.sqlite3" "$TMP/"
            echo -e "${GREEN}OK (Offline Copy)${NC}"
        else
            echo -e "${RED}No DB Found${NC}"
        fi
    fi

    # 2. Files
    echo -ne "Copying Files... "
    [ -d "$PANEL_DIR" ] && cp -r "$PANEL_DIR" "$TMP/config"
    [ -d "$DATA_DIR" ] && cp -r "$DATA_DIR" "$TMP/data"
    echo -e "${GREEN}OK${NC}"

    # 3. Compress
    echo -ne "Compressing... "
    cd "$BACKUP_DIR"
    tar -czf "${NAME}.tar.gz" -C "/tmp" "$NAME" >/dev/null 2>&1
    rm -rf "$TMP"
    echo -e "${GREEN}Done${NC}"

    local FINAL_FILE="$BACKUP_DIR/${NAME}.tar.gz"

    if [ -f "$FINAL_FILE" ]; then
        echo -e "${GREEN}Backup stored at: $FINAL_FILE${NC}"
        # CALL SENDER
        send_to_telegram "$FINAL_FILE"
    else
        echo -e "${RED}Failed to create tar file.${NC}"
    fi

    # ALWAYS PAUSE IN MANUAL MODE
    if [ "$MODE" != "auto" ]; then
        force_pause
    fi
}

# --- CRON SETUP ---
setup_cron() {
    clear
    echo "Current Cron:"
    crontab -l 2>/dev/null | grep "backup.sh" || echo "None"
    echo ""
    echo "1) Every 6 Hours"
    echo "2) Daily"
    echo "3) Disable"
    read -p "Select: " O

    local CMD="/bin/bash /opt/mrm-manager/backup.sh auto"
    (crontab -l 2>/dev/null | grep -v "backup.sh") | crontab -

    case $O in
        1) (crontab -l 2>/dev/null; echo "0 */6 * * * $CMD") | crontab -; echo "Set to 6h." ;;
        2) (crontab -l 2>/dev/null; echo "0 0 * * * $CMD") | crontab -; echo "Set to Daily." ;;
        *) echo "Disabled." ;;
    esac
    force_pause
}

# --- MENU ---
backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== BACKUP MENU ===${NC}"
        echo "1) Create Backup & Send (Debug Mode)"
        echo "2) Telegram Settings"
        echo "3) Auto Backup"
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

# --- MAIN ENTRY ---
if [ "$1" == "auto" ]; then
    create_backup "auto"
    exit 0
fi

# If run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_menu
fi