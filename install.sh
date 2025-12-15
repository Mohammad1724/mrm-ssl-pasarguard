#!/bin/bash

# Installer for MRM Manager v2.0
INSTALL_DIR="/opt/mrm-manager"
# لینک ریپازیتوری (مطمئن شوید درست است)
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

# 1. Dependency Check (Auto-Detect OS)
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

    # Try Local First
    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (Local): $FILE${NC}"
        return 0
    fi

    # Try Download (Secure)
    if curl -s -L -f -o "$INSTALL_DIR/$FILE" "$REPO_URL/$FILE"; then
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Downloaded: $FILE${NC}"
        return 0
    else
        # Try Download (Insecure Fallback)
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

# 3. Create Wrapper Command (FIXED)
# این بخش باعث می‌شود دستور mrm از هر پوشه‌ای کار کند
echo -e "#!/bin/bash
cd $INSTALL_DIR
# اجرای فایل اصلی با دسترسی‌های درست
bash ./main.sh \"\$@\"
" > /usr/local/bin/mrm

# اعمال دسترسی اجرا
chmod +x /usr/local/bin/mrm
chmod +x "$INSTALL_DIR/main.sh"

# 4. Finalize
# پاک کردن کش مسیرها تا دستور جدید شناسایی شود
hash -r 2>/dev/null

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager anytime.${NC}"
echo ""

# 5. Launch Immediately (FIXED)
# به جای mrm خالی، آدرس کامل را صدا می‌زنیم تا مطمئن شویم اجرا می‌شود
echo -e "${BLUE}Launching Manager...${NC}"
sleep 1
/usr/local/bin/mrm