#!/bin/bash

# ==========================================
#  PASARGUARD (TimescaleDB) -> REBEKA MIGRATOR
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
OLD_DIR="/opt/pasarguard"
NEW_DIR="/opt/rebeka"
BACKUP_FILE="/var/lib/pasarguard/migration.sqlite3"

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root.${NC}"
    exit 1
fi

clear
echo -e "${BLUE}=========================================${NC}"
echo -e "${YELLOW}   MIGRATION WIZARD: Pasarguard -> Rebeka ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# 1. Check Source
if [ ! -d "$OLD_DIR" ]; then
    echo -e "${RED}Error: Pasarguard directory not found at $OLD_DIR${NC}"
    exit 1
fi

echo -e "This script will:"
echo -e "1. Convert your TimescaleDB database to SQLite"
echo -e "2. Install Rebeka Panel"
echo -e "3. Move all Users, Settings, and SSL Certs"
echo -e "4. Switch panels with minimal downtime"
echo ""
read -p "Start Migration? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then exit; fi

# 2. Database Conversion (Export)
echo ""
echo -e "${BLUE}[1/6] Converting Database...${NC}"
cd "$OLD_DIR"

# Check if container is running
if ! docker ps | grep -q "pasarguard"; then
    echo -e "${YELLOW}Pasarguard is not running. Starting it to export data...${NC}"
    docker compose up -d
    sleep 10
fi

# Run Export Command
if docker compose exec pasarguard marzban-cli database dump --target /var/lib/marzban/migration.sqlite3; then
    echo -e "${GREEN}✔ Database converted successfully.${NC}"
else
    echo -e "${RED}✘ Failed to convert database! Migration aborted.${NC}"
    exit 1
fi

# 3. Download Rebeka
echo ""
echo -e "${BLUE}[2/6] Downloading Rebeka...${NC}"
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
echo -e "${BLUE}[3/6] Transferring Files...${NC}"

# Move Database
cp "$BACKUP_FILE" "$NEW_DIR/db.sqlite3"
echo -e "${GREEN}✔ Database transferred${NC}"

# Move SSL Certs
if [ -d "/var/lib/pasarguard/certs" ]; then
    mkdir -p "/var/lib/marzban/certs"
    cp -r "/var/lib/pasarguard/certs/." "/var/lib/marzban/certs/"
    echo -e "${GREEN}✔ SSL Certificates transferred${NC}"
fi

# Move Env (Settings) - BUT MODIFY IT
cp "$OLD_DIR/.env" "$NEW_DIR/.env"
# Remove database connection strings so Rebeka uses SQLite by default
sed -i '/SQLALCHEMY_DATABASE_URL/d' "$NEW_DIR/.env"
echo -e "${GREEN}✔ Settings transferred (Converted to SQLite)${NC}"

# Move Xray Config
if [ -f "$OLD_DIR/xray_config.json" ]; then
    cp "$OLD_DIR/xray_config.json" "$NEW_DIR/xray_config.json"
    echo -e "${GREEN}✔ Xray Config transferred${NC}"
fi

# 5. Stop Old Panel
echo ""
echo -e "${BLUE}[4/6] Stopping Pasarguard...${NC}"
cd "$OLD_DIR"
docker compose down
echo -e "${YELLOW}Pasarguard Stopped.${NC}"

# 6. Start New Panel
echo ""
echo -e "${BLUE}[5/6] Starting Rebeka...${NC}"
cd "$NEW_DIR"
docker compose up -d

echo ""
echo -e "${BLUE}[6/6] Verifying...${NC}"
sleep 10

if docker ps | grep -q "marzban"; then
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}   MIGRATION SUCCESSFUL! 🚀         ${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo -e "Rebeka is now running."
    echo -e "You can login with your OLD admin credentials."
else
    echo -e "${RED}✘ Rebeka failed to start!${NC}"
    echo -e "Checking logs..."
    docker compose logs --tail 20
    
    echo -e "\n${YELLOW}Rolling back to Pasarguard...${NC}"
    cd "$OLD_DIR"
    docker compose up -d
    echo -e "${GREEN}Pasarguard restored.${NC}"
fi
