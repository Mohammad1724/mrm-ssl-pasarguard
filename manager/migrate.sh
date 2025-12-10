#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
OLD_DIR="/opt/pasarguard"
NEW_DIR="/opt/rebeka"
BACKUP_DIR="/root/migration_backup"

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root.${NC}"
    exit 1
fi

clear
echo -e "${BLUE}=========================================${NC}"
echo -e "${YELLOW}   PASARGUARD TO REBEKA MIGRATOR         ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# 1. Check Old Panel
if [ ! -d "$OLD_DIR" ]; then
    echo -e "${RED}Error: Pasarguard directory not found at $OLD_DIR${NC}"
    # Try finding Marzban just in case
    if [ -d "/opt/marzban" ]; then
        echo -e "${YELLOW}Found Marzban instead. Using it as source...${NC}"
        OLD_DIR="/opt/marzban"
    else
        exit 1
    fi
fi

echo -e "Source Panel: ${CYAN}$OLD_DIR${NC}"
echo -e "Target Panel: ${CYAN}$NEW_DIR${NC}"
echo ""
echo -e "${YELLOW}Warning: This will STOP Pasarguard and START Rebeka.${NC}"
echo -e "Downtime will be less than 10 seconds."
read -p "Are you ready? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then exit; fi

# 2. Backup
echo ""
echo -e "${BLUE}[1/5] Creating Backup...${NC}"
mkdir -p "$BACKUP_DIR"
cp -r "$OLD_DIR" "$BACKUP_DIR/panel_backup_$(date +%s)"
echo -e "${GREEN}✔ Backup saved in $BACKUP_DIR${NC}"

# 3. Install Rebeka (Clone Repo)
echo ""
echo -e "${BLUE}[2/5] Downloading Rebeka...${NC}"
if [ -d "$NEW_DIR" ]; then
    echo -e "${YELLOW}Rebeka directory exists. Updating...${NC}"
    cd "$NEW_DIR" && git pull
else
    git clone https://github.com/Rebeka-Panel/Rebeka "$NEW_DIR"
fi

if [ ! -d "$NEW_DIR" ]; then
    echo -e "${RED}Failed to download Rebeka.${NC}"
    exit 1
fi

# 4. Transfer Data
echo ""
echo -e "${BLUE}[3/5] Transferring Data...${NC}"

# Copy ENV (Settings)
if [ -f "$OLD_DIR/.env" ]; then
    cp "$OLD_DIR/.env" "$NEW_DIR/.env"
    echo -e "${GREEN}✔ Settings (.env) transferred${NC}"
else
    echo -e "${RED}✘ .env not found! Generating default...${NC}"
    cp "$NEW_DIR/.env.example" "$NEW_DIR/.env"
fi

# Copy Database (Users)
if [ -f "$OLD_DIR/db.sqlite3" ]; then
    cp "$OLD_DIR/db.sqlite3" "$NEW_DIR/db.sqlite3"
    echo -e "${GREEN}✔ Database (Users) transferred${NC}"
elif [ -f "$OLD_DIR/db.sqlite" ]; then
    cp "$OLD_DIR/db.sqlite" "$NEW_DIR/db.sqlite3"
    echo -e "${GREEN}✔ Database transferred${NC}"
else
    echo -e "${YELLOW}⚠ No SQLite database found. Are you using MySQL? If so, configure .env manually.${NC}"
fi

# Copy Certs (SSL)
if [ -d "/var/lib/pasarguard/certs" ]; then
    mkdir -p "/var/lib/marzban/certs"
    cp -r "/var/lib/pasarguard/certs/." "/var/lib/marzban/certs/"
    echo -e "${GREEN}✔ SSL Certificates transferred${NC}"
elif [ -d "/var/lib/marzban/certs" ]; then
    echo -e "${GREEN}✔ SSL Certificates already in place${NC}"
fi

# Copy Xray Config (Optional but recommended)
if [ -f "$OLD_DIR/xray_config.json" ]; then
    cp "$OLD_DIR/xray_config.json" "$NEW_DIR/xray_config.json"
    echo -e "${GREEN}✔ Xray Config transferred${NC}"
fi

# 5. The Switch
echo ""
echo -e "${BLUE}[4/5] Switching Panels (Downtime Starts)...${NC}"

# Stop Old
cd "$OLD_DIR"
docker compose down --remove-orphans
echo -e "${YELLOW}Pasarguard Stopped.${NC}"

# Start New
cd "$NEW_DIR"
docker compose up -d --remove-orphans

echo ""
echo -e "${BLUE}[5/5] Checking Status...${NC}"
sleep 5

if docker ps | grep -q "rebeka"; then
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}   MIGRATION SUCCESSFUL! 🚀         ${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo -e "Rebeka is running."
    echo -e "You can login with your OLD username/password."
    echo ""
    echo -e "To create an admin (if needed):"
    echo -e "${CYAN}cd $NEW_DIR && marzban cli admin create${NC}"
else
    echo -e "${RED}✘ Rebeka failed to start!${NC}"
    echo -e "${YELLOW}Rolling back to Pasarguard...${NC}"
    cd "$OLD_DIR"
    docker compose up -d
    echo -e "${GREEN}Pasarguard restored.${NC}"
fi