#!/bin/bash

# Installer for MRM Manager v1.1
INSTALL_DIR="/opt/mrm-manager"
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

# 1. FIX: Check dependencies (support yum/dnf/apt)
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}Installing curl...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y curl
    elif command -v yum &> /dev/null; then
        yum install -y curl
    elif command -v dnf &> /dev/null; then
        dnf install -y curl
    fi
fi

echo -e "${BLUE}Installing MRM Manager v1.3...${NC}"
mkdir -p "$INSTALL_DIR"

FILES=(
    "utils.sh" "ui.sh" "ssl.sh" "node.sh" "theme.sh"
    "site.sh" "inbound.sh" "backup.sh" "domain_separator.sh"
    "port_manager.sh" "migrator.sh" "main.sh"
)

OPT_FILES=("index.html")

install_file() {
    local FILE=$1
    local IS_OPTIONAL=$2

    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (Local): $FILE${NC}"
        return 0
    fi

    # Removed -k for security unless absolutely necessary
    if curl -s -L -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Downloaded: $FILE${NC}"
        return 0
    else
        # Try with -k only if normal fail (fallback)
        if curl -s -L -k -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
             echo -e "${YELLOW}✔ Downloaded (Insecure Mode): $FILE${NC}"
             return 0
        fi

        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "${YELLOW}⚠ Skipped optional: $FILE${NC}"
            return 0
        else
            echo -e "${RED}✘ Failed to download: $FILE${NC}"
            return 1
        fi
    fi
}

echo -e "${YELLOW}Fetching files...${NC}"

for FILE in "${FILES[@]}"; do
    install_file "$FILE" "false" || exit 1
done

for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

# 2. FIX: Create a wrapper to handle directory path correctly
echo -e "#!/bin/bash
cd $INSTALL_DIR
exec ./main.sh \"\$@\"
" > /usr/local/bin/mrm

chmod +x /usr/local/bin/mrm
chmod +x "$INSTALL_DIR/main.sh"

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager.${NC}"
echo ""

# Run
mrm