#!/bin/bash

# Load Utils if run standalone
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# ==========================================
# 1. INSTALL / UPDATE WIZARD (Smart Inputs)
# ==========================================
install_theme_wizard() {
    TEMPLATE_FILE="/var/lib/pasarguard/templates/subscription/index.html"
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    
    # --- تابع استخراج امن مقادیر فعلی ---
    get_val_py() {
        if [ -s "$TEMPLATE_FILE" ]; then
            python3 -c "
import re
try:
    with open('$TEMPLATE_FILE', 'r', encoding='utf-8', errors='ignore') as f:
        c = f.read()
    m = re.search(r'$1', c)
    print(m.group(1) if m else '')
except: pass
"
        fi
    }

    echo -e "${BLUE}Reading configuration...${NC}"

    # 1. استخراج مقادیر فعلی (اگر نصب باشد)
    if [ -s "$TEMPLATE_FILE" ]; then
        DEF_BRAND=$(get_val_py 'id="brandTxt"[^>]*data-text="([^"]+)"')
        if [ -z "$DEF_BRAND" ]; then DEF_BRAND=$(get_val_py 'id="brandTxt"[^>]*>([^<]+)<'); fi
        DEF_BOT=$(get_val_py 'class="bot-link".*href="https:\/\/t\.me\/([^"]+)"')
        DEF_SUP=$(get_val_py 'class="btn btn-dark".*href="https:\/\/t\.me\/([^"]+)"')
        DEF_NEWS=$(get_val_py 'id="nT">([^<]+)<')
    fi

    # 2. تنظیم پیش‌فرض اگر چیزی پیدا نشد (نصب بار اول)
    [ -z "$DEF_BRAND" ] && DEF_BRAND="FarsNetVIP"
    [ -z "$DEF_BOT" ] && DEF_BOT="MyBot"
    [ -z "$DEF_SUP" ] && DEF_SUP="Support"
    [ -z "$DEF_NEWS" ] && DEF_NEWS="خوش آمدید"

    # 3. دریافت ورودی از کاربر (Smart Input)
    echo -e "${CYAN}=== Theme Settings ===${NC}"
    echo -e "Press ${YELLOW}ENTER${NC} to accept the current value [in brackets]."
    echo ""

    read -p "Brand Name [$DEF_BRAND]: " IN_BRAND
    # اگر خالی بود (اینتر زد)، مقدار پیش‌فرض را بگذار
    [ -z "$IN_BRAND" ] && IN_BRAND="$DEF_BRAND"

    read -p "Bot Username (No @) [$DEF_BOT]: " IN_BOT
    [ -z "$IN_BOT" ] && IN_BOT="$DEF_BOT"

    read -p "Support ID (No @) [$DEF_SUP]: " IN_SUP
    [ -z "$IN_SUP" ] && IN_SUP="$DEF_SUP"

    read -p "News Text [$DEF_NEWS]: " IN_NEWS
    [ -z "$IN_NEWS" ] && IN_NEWS="$DEF_NEWS"

    # Links
    LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
    LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
    LNK_WIN="https://github.com/2dust/v2rayN/releases"

    # 4. دانلود فایل جدید
    echo -e "\n${BLUE}Downloading latest template...${NC}"
    mkdir -p "$TEMPLATE_DIR"
    local TEMP_DL="/tmp/index_dl.html"
    rm -f "$TEMP_DL"

    if curl -L -o "$TEMP_DL" "$THEME_HTML_URL"; then
        if [ -s "$TEMP_DL" ]; then
            mv "$TEMP_DL" "$TEMPLATE_FILE"
            echo -e "${GREEN}✔ Download successful.${NC}"
        else
            echo -e "${RED}✘ Downloaded file is empty! Check URL.${NC}"
            pause; return
        fi
    else
        echo -e "${RED}✘ Download failed! Connection error.${NC}"
        pause; return
    fi

    # 5. اعمال تغییرات
    echo -e "${BLUE}Applying configurations...${NC}"

    export IN_BRAND IN_BOT IN_SUP IN_NEWS LNK_AND LNK_IOS LNK_WIN TEMPLATE_FILE
    
    python3 - << 'EOF'
import os
import sys

file_path = os.environ.get('TEMPLATE_FILE')
brand = os.environ.get('IN_BRAND', 'FarsNetVIP')
bot = os.environ.get('IN_BOT', 'MyBot')
sup = os.environ.get('IN_SUP', 'Support')
news = os.environ.get('IN_NEWS', 'Welcome')
l_and = os.environ.get('LNK_AND', '#')
l_ios = os.environ.get('LNK_IOS', '#')
l_win = os.environ.get('LNK_WIN', '#')

try:
    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    if not content:
        sys.exit(1)

    content = content.replace('__BRAND__', brand)
    content = content.replace('__BOT__', bot)
    content = content.replace('__SUP__', sup)
    content = content.replace('__NEWS__', news)
    content = content.replace('__ANDROID__', l_and)
    content = content.replace('__IOS__', l_ios)
    content = content.replace('__WIN__', l_win)

    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)
    
    print("Template updated successfully.")
except Exception as e:
    print(f"Python Error: {e}")
    sys.exit(1)
EOF

    if [ $? -eq 0 ]; then
        # فعال‌سازی در کانفیگ
        if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$PANEL_ENV"
        echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"

        restart_service "panel"
        echo -e "${GREEN}✔ Theme Installed & Updated.${NC}"
    else
        echo -e "${RED}✘ Error applying config.${NC}"
    fi
    
    pause
}

# ==========================================
# 2. ACTIVATE THEME
# ==========================================
activate_theme() {
    echo -e "${BLUE}Activating Theme...${NC}"
    local T_FILE="/var/lib/pasarguard/templates/subscription/index.html"
    
    if [ ! -s "$T_FILE" ]; then
        echo -e "${RED}Theme file missing. Install first.${NC}"
        pause; return
    fi

    if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
    echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$PANEL_ENV"
    echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"

    restart_service "panel"
    echo -e "${GREEN}✔ Theme Activated.${NC}"
    pause
}

# ==========================================
# 3. DEACTIVATE THEME
# ==========================================
deactivate_theme() {
    echo -e "${YELLOW}Deactivating Theme...${NC}"
    if [ -f "$PANEL_ENV" ]; then
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        restart_service "panel"
        echo -e "${GREEN}✔ Theme Deactivated.${NC}"
    fi
    pause
}

# ==========================================
# 4. UNINSTALL THEME
# ==========================================
uninstall_theme() {
    echo -e "${RED}--- Uninstall Theme ---${NC}"
    read -p "Delete files? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        rm -rf "/var/lib/pasarguard/templates/subscription"
        deactivate_theme
        echo -e "${GREEN}✔ Files removed.${NC}"
    fi
    pause
}

# === MENU ===
theme_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      THEME MANAGER                        ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Install / Update Theme (Wizard)"
        echo "2) Activate Theme"
        echo "3) Deactivate Theme"
        echo "4) Uninstall Theme"
        echo "5) Back"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) install_theme_wizard ;;
            2) activate_theme ;;
            3) deactivate_theme ;;
            4) uninstall_theme ;;
            5) return ;;
            *) ;;
        esac
    done
}