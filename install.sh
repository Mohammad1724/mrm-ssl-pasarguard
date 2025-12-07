#!/bin/bash

# Installer for MRM Manager v3.3
INSTALL_DIR="/opt/mrm-manager"

# --- نکته مهم: اگر فایل‌ها را در پوشه manager آپلود کردید، این آدرس درست است ---
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/manager"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${BLUE}Installing MRM Manager v3.3...${NC}"
mkdir -p "$INSTALL_DIR"

# List of files to install
FILES=(
    "utils.sh"
    "ui.sh"
    "ssl.sh"
    "node.sh"
    "theme.sh"
    "site.sh"
    "inbound.sh"
    "backup.sh"
    "monitor.sh"
    "domain_separator.sh"
    "port_manager.sh"
    "main.sh"
)

# Optional files
OPT_FILES=(
    "index.html"
)

# Function to install a file
install_file() {
    local FILE=$1
    local IS_OPTIONAL=$2
    
    # 1. Try Local Install
    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (Local): $FILE${NC}"
        return 0
    fi

    # 2. Try Online Install
    # -s: Silent
    # -L: Follow redirects
    # -k: Insecure (ignore SSL errors if any)
    # -f: Fail silently on 404 (don't write error to file)
    if curl -s -L -k -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Downloaded: $FILE${NC}"
        return 0
    else
        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "${YELLOW}⚠ Skipped optional: $FILE${NC}"
            return 0
        else
            echo -e "${RED}✘ Failed to download: $FILE${NC}"
            echo -e "${YELLOW}  Looking at: $REPO_URL/$FILE${NC}"
            return 1
        fi
    fi
}

echo -e "${YELLOW}Fetching files from GitHub...${NC}"

# Install Core Files
for FILE in "${FILES[@]}"; do
    install_file "$FILE" "false"
    if [ $? -ne 0 ]; then
        echo ""
        echo -e "${RED}CRITICAL ERROR: Could not install core files.${NC}"
        echo -e "1. Check if you uploaded '${YELLOW}$FILE${NC}' to GitHub."
        echo -e "2. Check if the file is inside the '${YELLOW}manager${NC}' folder in your repo."
        exit 1
    fi
done

# Install Optional Files
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

# Create shortcut command
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager.${NC}"
echo ""

# Run
bash "$INSTALL_DIR/main.sh"