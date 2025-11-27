#!/bin/bash

# Load Utils if run standalone
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# ==========================================
# 1. INSTALL / UPDATE WIZARD (Your Logic)
# ==========================================
install_theme_wizard() {
    TEMPLATE_FILE="$PANEL_DIR/templates/subscription/index.html"
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    ENV_FILE="$PANEL_ENV"

    # --- تابع استخراج امن با پایتون ---
    get_val_py() {
        python3 -c "
import re
try:
    with open('$TEMPLATE_FILE', 'r', encoding='utf-8', errors='ignore') as f:
        c = f.read()
    m = re.search(r'$1', c)
    print(m.group(1) if m else '')
except: pass
"
    }

    echo -e "${BLUE}Reading current configuration...${NC}"

    if [ -f "$TEMPLATE_FILE" ]; then
        # استفاده از Regex پایتون برای خواندن مقادیر قبلی
        DEF_BRAND=$(get_val_py 'id="brandTxt"[^>]*data-text="([^"]+)"')
        if [ -z "$DEF_BRAND" ]; then DEF_BRAND=$(get_val_py 'id="brandTxt"[^>]*>([^<]+)<'); fi

        DEF_BOT=$(get_val_py 'class="bot-link".*href="https:\/\/t\.me\/([^"]+)"')
        DEF_SUP=$(get_val_py 'class="btn btn-dark".*href="https:\/\/t\.me\/([^"]+)"')
        DEF_NEWS=$(get_val_py 'id="nT">([^<]+)<')
    fi

    # Defaults
    [ -z "$DEF_BRAND" ] && DEF_BRAND="FarsNetVIP"
    [ -z "$DEF_BOT" ] && DEF_BOT="MyBot"
    [ -z "$DEF_SUP" ] && DEF_SUP="Support"
    [ -z "$DEF_NEWS" ] && DEF_NEWS="خوش آمدید"

    echo -e "${CYAN}=== Theme Installer Wizard ===${NC}"
    echo -e "Enter new values or press ${YELLOW}ENTER${NC} to keep current:"
    echo ""

    read -p "Brand Name [$DEF_BRAND]: " IN_BRAND
    read -p "Bot Username (No @) [$DEF_BOT]: " IN_BOT
    read -p "Support ID (No @) [$DEF_SUP]: " IN_SUP
    read -p "News Text [$DEF_NEWS]: " IN_NEWS

    [ -z "$IN_BRAND" ] && IN_BRAND="$DEF_BRAND"
    [ -z "$IN_BOT" ] && IN_BOT="$DEF_BOT"
    [ -z "$IN_SUP" ] && IN_SUP="$DEF_SUP"
    [ -z "$IN_NEWS" ] && IN_NEWS="$DEF_NEWS"

    # Links
    LNK_AND="https://play.google.com/store/apps/details?id=com.v2ray.ang"
    LNK_IOS="https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"
    LNK_WIN="https://github.com/2dust/v2rayN/releases"

    # دانلود
    echo -e "\n${BLUE}Downloading template...${NC}"
    mkdir -p "$TEMPLATE_DIR"

    if curl -fsSL "$THEME_SCRIPT_URL" -o "$TEMPLATE_FILE"; then
        echo -e "${GREEN}✔ Download successful.${NC}"
    else
        echo -e "${RED}✘ Download failed! Check URL.${NC}"
        pause
        return
    fi

    # جایگزینی امن با پایتون
    echo -e "${BLUE}Applying configurations (Safe Mode)...${NC}"

    export IN_BRAND IN_BOT IN_SUP IN_NEWS LNK_AND LNK_IOS LNK_WIN
    python3 - << 'EOF'
import os

# دریافت مسیر از متغیر محیطی یا پیش‌فرض
file_path = "/var/lib/pasarguard/templates/subscription/index.html"
# اگر مسیر متغیر محیطی ست شده بود از آن استفاده کن (اختیاری)
if os.environ.get('TEMPLATE_FILE'):
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

    # جایگزینی‌ها
    content = content.replace('__BRAND__', brand)
    content = content.replace('__BOT__', bot)
    content = content.replace('__SUP__', sup)
    content = content.replace('__NEWS__', news)
    content = content.replace('__ANDROID__', l_and)
    content = content.replace('__IOS__', l_ios)
    content = content.replace('__WIN__', l_win)

    # ذخیره با فرمت صحیح UTF-8
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)
    
    print("Template updated successfully with UTF-8 encoding.")
except Exception as e:
    print(f"Error updating template: {e}")
    exit(1)
EOF

    # فعال‌سازی در کانفیگ (Activate logic included here too)
    if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
    echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
    echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

    restart_service "panel"
    echo -e "${GREEN}✔ Theme Installed & Activated.${NC}"
    pause
}

# ==========================================
# 2. ACTIVATE THEME (Quick Enable)
# ==========================================
activate_theme() {
    echo -e "${BLUE}Activating Theme...${NC}"
    local T_FILE="$PANEL_DIR/templates/subscription/index.html"
    
    if [ ! -f "$T_FILE" ]; then
        echo -e "${RED}Theme file not found. Please Install first.${NC}"
        pause
        return
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
    echo -e "${YELLOW}Deactivating Theme (Default View)...${NC}"
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
    echo -e "${RED}--- Uninstall Theme Files ---${NC}"
    read -p "Delete theme files? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        rm -rf "$PANEL_DIR/templates/subscription"
        if [ -f "$PANEL_ENV" ]; then
            sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
            sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        fi
        restart_service "panel"
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