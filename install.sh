#!/bin/bash

# Installer for MRM Manager v1.0
INSTALL_DIR="/opt/mrm-manager"
# لینک مستقیم به فایل‌های خام (Raw)
REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main"

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

echo -e "${BLUE}Installing MRM Manager v1.0...${NC}"
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
    
    # 1. اولویت با فایل لوکال (اگر دستی کپی کرده باشید)
    if [ -f "./$FILE" ]; then
        cp "./$FILE" "$INSTALL_DIR/$FILE"
        chmod +x "$INSTALL_DIR/$FILE"
        echo -e "${GREEN}✔ Installed (Local): $FILE${NC}"
        return 0
    fi

    # 2. دانلود از گیت‌هاب
    # فلگ -L برای دنبال کردن ریدارکت
    # فلگ -k برای نادیده گرفتن خطای SSL (در صورت مشکل سرور)
    # فلگ -f برای اینکه اگر فایل نبود (404) ارور بدهد نه اینکه فایل خالی بسازد
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
            echo -e "${YELLOW}  Check if '$FILE' exists in your GitHub repository!${NC}"
            return 1
        fi
    fi
}

# --- شروع نصب ---

echo -e "${YELLOW}Fetching files from GitHub...${NC}"

# نصب فایل‌های اصلی
for FILE in "${FILES[@]}"; do
    install_file "$FILE" "false"
    if [ $? -ne 0 ]; then
        echo ""
        echo -e "${RED}CRITICAL ERROR: Could not install core files.${NC}"
        echo -e "Make sure you have uploaded '${YELLOW}$FILE${NC}' to your GitHub repository."
        exit 1
    fi
done

# نصب فایل‌های اختیاری
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

# ساخت شورت‌کات
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${GREEN}✔ Installation Complete!${NC}"
echo -e "${YELLOW}Type 'mrm' to run the manager.${NC}"
echo ""

# اجرا
bash "$INSTALL_DIR/main.sh"