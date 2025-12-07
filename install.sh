#!/bin/bash

# Installer for Modular MRM Manager
INSTALL_DIR="/opt/mrm-manager"
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${BLUE}Installing/Updating MRM Manager...${NC}"
mkdir -p "$INSTALL_DIR"

# Download Modules
echo -e "${BLUE}Downloading modules...${NC}"

curl -s -o "$INSTALL_DIR/utils.sh" "$REPO_URL/utils.sh" && echo -e "${GREEN}✔ utils.sh${NC}" || echo -e "${RED}✘ utils.sh${NC}"
curl -s -o "$INSTALL_DIR/ssl.sh" "$REPO_URL/ssl.sh" && echo -e "${GREEN}✔ ssl.sh${NC}" || echo -e "${RED}✘ ssl.sh${NC}"
curl -s -o "$INSTALL_DIR/node.sh" "$REPO_URL/node.sh" && echo -e "${GREEN}✔ node.sh${NC}" || echo -e "${RED}✘ node.sh${NC}"
curl -s -o "$INSTALL_DIR/theme.sh" "$REPO_URL/theme.sh" && echo -e "${GREEN}✔ theme.sh${NC}" || echo -e "${RED}✘ theme.sh${NC}"
curl -s -o "$INSTALL_DIR/site.sh" "$REPO_URL/site.sh" && echo -e "${GREEN}✔ site.sh${NC}" || echo -e "${RED}✘ site.sh${NC}"
curl -s -o "$INSTALL_DIR/inbound.sh" "$REPO_URL/inbound.sh" && echo -e "${GREEN}✔ inbound.sh${NC}" || echo -e "${RED}✘ inbound.sh${NC}"
curl -s -o "$INSTALL_DIR/backup.sh" "$REPO_URL/backup.sh" && echo -e "${GREEN}✔ backup.sh${NC}" || echo -e "${RED}✘ backup.sh${NC}"
curl -s -o "$INSTALL_DIR/monitor.sh" "$REPO_URL/monitor.sh" && echo -e "${GREEN}✔ monitor.sh${NC}" || echo -e "${RED}✘ monitor.sh${NC}"
curl -s -o "$INSTALL_DIR/domain_separator.sh" "$REPO_URL/domain_separator.sh" && echo -e "${GREEN}✔ domain_separator.sh${NC}" || echo -e "${RED}✘ domain_separator.sh${NC}"
curl -s -o "$INSTALL_DIR/port_manager.sh" "$REPO_URL/port_manager.sh" && echo -e "${GREEN}✔ port_manager.sh${NC}" || echo -e "${RED}✘ port_manager.sh${NC}"
curl -s -o "$INSTALL_DIR/main.sh" "$REPO_URL/main.sh" && echo -e "${GREEN}✔ main.sh${NC}" || echo -e "${RED}✘ main.sh${NC}"

# Make executable
chmod +x "$INSTALL_DIR/"*.sh

# Create shortcut command
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
echo -e "${GREEN}✔ Shortcut created: type 'mrm' to run${NC}"

echo -e "${GREEN}Installation Complete!${NC}"
echo ""

# Run
bash "$INSTALL_DIR/main.sh"