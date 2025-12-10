#!/bin/bash

# Load utils if running standalone
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

migrate_to_rebeka() {
    local OLD_DIR="/opt/pasarguard"
    local NEW_DIR="/opt/rebeka"
    local BACKUP_FILE="/var/lib/pasarguard/migration.sqlite3"

    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}   MIGRATION WIZARD: Pasarguard -> Rebeka    ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ ! -d "$OLD_DIR" ]; then
        echo -e "${RED}Error: Pasarguard directory not found at $OLD_DIR${NC}"
        pause; return
    fi

    echo -e "This tool will convert your database and move everything to Rebeka."
    echo -e "${RED}Warning: Pasarguard will be STOPPED during this process.${NC}"
    echo ""
    read -p "Are you sure you want to migrate? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then return; fi

    # 1. Convert Database
    echo ""
    echo -e "${BLUE}[1/5] Converting Database...${NC}"
    cd "$OLD_DIR"
    
    if ! docker ps | grep -q "pasarguard"; then
        echo -e "${YELLOW}Starting Pasarguard to export data...${NC}"
        docker compose up -d; sleep 10
    fi

    if docker compose exec pasarguard marzban-cli database dump --target /var/lib/marzban/migration.sqlite3; then
        echo -e "${GREEN}✔ Database converted.${NC}"
    else
        echo -e "${RED}✘ Database conversion failed!${NC}"; pause; return
    fi

    # 2. Install Rebeka
    echo -e "${BLUE}[2/5] Downloading Rebeka...${NC}"
    if [ -d "$NEW_DIR" ]; then
        cd "$NEW_DIR" && git pull
    else
        git clone https://github.com/Rebeka-Panel/Rebeka "$NEW_DIR"
    fi

    if [ ! -d "$NEW_DIR" ]; then echo -e "${RED}Download failed.${NC}"; pause; return; fi

    # 3. Transfer Data
    echo -e "${BLUE}[3/5] Transferring Data...${NC}"
    cp "$BACKUP_FILE" "$NEW_DIR/db.sqlite3"
    
    if [ -d "/var/lib/pasarguard/certs" ]; then
        mkdir -p "/var/lib/marzban/certs"
        cp -r "/var/lib/pasarguard/certs/." "/var/lib/marzban/certs/"
    fi

    cp "$OLD_DIR/.env" "$NEW_DIR/.env"
    sed -i '/SQLALCHEMY_DATABASE_URL/d' "$NEW_DIR/.env" # Switch to SQLite
    
    [ -f "$OLD_DIR/xray_config.json" ] && cp "$OLD_DIR/xray_config.json" "$NEW_DIR/xray_config.json"

    # 4. Switch Panels
    echo -e "${BLUE}[4/5] Switching Panels...${NC}"
    cd "$OLD_DIR" && docker compose down
    echo -e "${YELLOW}Pasarguard Stopped.${NC}"
    
    cd "$NEW_DIR" && docker compose up -d
    echo -e "${GREEN}Rebeka Started.${NC}"

    # 5. Verify
    echo -e "${BLUE}[5/5] Verifying...${NC}"
    sleep 10
    if docker ps | grep -q "marzban"; then
        echo -e "${GREEN}✔ Migration Successful!${NC}"
        echo -e "You can now login to Rebeka with your old credentials."
        
        # Update utils.sh to point to new panel?
        # Ideally we should update PANEL_DIR, but for now we keep it simple.
    else
        echo -e "${RED}✘ Rebeka failed to start! Rolling back...${NC}"
        cd "$OLD_DIR" && docker compose up -d
        echo -e "${GREEN}Pasarguard Restored.${NC}"
    fi
    pause
}

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      MIGRATION TOOLS                      ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Migrate to Rebeka (Auto Convert DB)"
        echo "0) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) migrate_to_rebeka ;;
            0) return ;;
            *) ;;
        esac
    done
}
