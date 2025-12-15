#!/bin/bash

# Installer for MRM Manager v2.1 (Fix Loop Issue)
INSTALL_DIR="/opt/mrm-manager"
# لینک ریپازیتوری شما
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

# 1. Dependency Check
echo -e "${BLUE}Checking dependencies...${NC}"
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}Installing curl...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y curl -qq
    elif command -v yum &> /dev/null; then
        yum install -y curl
    elif command -v dnf &> /dev/null; then
        dnf install -y curl
    fi
fi

# 2. Setup Directory
echo -e "${BLUE}Installing MRM Manager...${NC}"
rm -rf "$INSTALL_DIR" # Clean old install to prevent conflicts
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

    # Download Forcefully (Overwrite)
    if curl -s -L -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Downloaded: $FILE${NC}"
        return 0
    else
        # Try Insecure Fallback
        if curl -s -L -k -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
             echo -e "${YELLOW}✔ Downloaded (Insecure Mode): $FILE${NC}"
             chmod +x "$INSTALL_DIR/$FILE"
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

# 3. Create Wrapper Command (FIXED LOOP ISSUE)
# استفاده از exec برای جلوگیری از Fork Bomb
# استفاده از مسیر کامل /bin/bash
echo -e "#!/bin/bash
cd $INSTALL_DIR
exec /bin/bash ./main.sh \"\$@\"
" > /usr/local/bin/mrm

chmod +x /usr/local/bin/mrm
chmod +x "$INSTALL_DIR/main.sh"

# Refresh Hash
hash -r 2>/dev/null

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager.${NC}"
echo ""