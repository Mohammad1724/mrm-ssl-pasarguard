#!/bin/bash

# Load Utils if run standalone
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# ==========================================
# 1. INSTALL / UPDATE WIZARD (Python Input Mode)
# ==========================================
install_theme_wizard() {
    TEMPLATE_FILE="/var/lib/pasarguard/templates/subscription/index.html"
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    
    # 1. دانلود فایل جدید (اول دانلود می‌کنیم که روی فایل جدید کار کنیم)
    echo -e "\n${BLUE}Downloading latest template...${NC}"
    mkdir -p "$TEMPLATE_DIR"
    local TEMP_DL="/tmp/index_dl.html"
    rm -f "$TEMP_DL"

    if curl -L -o "$TEMP_DL" "$THEME_HTML_URL"; then
        if [ -s "$TEMP_DL" ]; then
            # اگر فایل قبلی هست، نگهش دار برای خواندن مقادیر
            if [ -f "$TEMPLATE_FILE" ]; then
                cp "$TEMPLATE_FILE" "/tmp/index_old.html"
            else
                echo "" > "/tmp/index_old.html" # فایل خالی بساز
            fi
            
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

    # 2. اجرای اسکریپت پایتون برای دریافت ورودی و جایگزینی
    # (این روش مشکل کاراکترهای خاص مثل • را حل می‌کند)
    
    export TEMPLATE_FILE
    
    python3 -c "
import os
import re

# رنگ‌ها برای خروجی پایتون
CYAN = '\033[0;36m'
YELLOW = '\033[1;33m'
GREEN = '\033[0;32m'
NC = '\033[0m'

file_path = os.environ.get('TEMPLATE_FILE')
old_file_path = '/tmp/index_old.html'

# مقادیر پیش‌فرض
defaults = {
    'brand': 'FarsNetVIP',
    'bot': 'MyBot',
    'sup': 'Support',
    'news': 'خوش آمدید • Welcome',
    'l_and': 'https://play.google.com/store/apps/details?id=com.v2ray.ang',
    'l_ios': 'https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690',
    'l_win': 'https://github.com/2dust/v2rayN/releases'
}

# تلاش برای خواندن مقادیر قبلی از فایل قدیمی
try:
    with open(old_file_path, 'r', encoding='utf-8', errors='ignore') as f:
        old_content = f.read()
        
    # استخراج هوشمند
    m_brand = re.search(r'id=\"brandTxt\"[^>]*data-text=\"([^\"]+)\"', old_content)
    if m_brand: defaults['brand'] = m_brand.group(1)
    
    m_bot = re.search(r'class=\"bot-link\".*href=\"https:\/\/t\.me\/([^\"]+)\"', old_content)
    if m_bot: defaults['bot'] = m_bot.group(1)
    
    m_sup = re.search(r'class=\"btn btn-dark\".*href=\"https:\/\/t\.me\/([^\"]+)\"', old_content)
    if m_sup: defaults['sup'] = m_sup.group(1)
    
    m_news = re.search(r'id=\"nT\">([^<]+)<', old_content)
    if m_news: defaults['news'] = m_news.group(1)

except:
    pass

# --- دریافت ورودی از کاربر ---
print(f'{CYAN}=== Theme Settings (UTF-8 Safe) ==={NC}')
print(f'Press {YELLOW}ENTER{NC} to accept the current value [in brackets].\n')

def get_input(label, key):
    val = input(f'{label} [{defaults[key]}]: ').strip()
    if not val:
        return defaults[key]
    return val

new_brand = get_input('Brand Name', 'brand')
new_bot = get_input('Bot Username (No @)', 'bot')
new_sup = get_input('Support ID (No @)', 'sup')
new_news = get_input('News Text', 'news')

# --- اعمال تغییرات روی فایل جدید ---
try:
    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    content = content.replace('__BRAND__', new_brand)
    content = content.replace('__BOT__', new_bot)
    content = content.replace('__SUP__', new_sup)
    content = content.replace('__NEWS__', new_news)
    
    # لینک‌ها ثابت هستند (یا می‌توانستیم بپرسیم)
    content = content.replace('__ANDROID__', defaults['l_and'])
    content = content.replace('__IOS__', defaults['l_ios'])
    content = content.replace('__WIN__', defaults['l_win'])

    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)
        
    print(f'\n{GREEN}✔ Configuration applied successfully.{NC}')

except Exception as e:
    print(f'\nError: {e}')
    exit(1)
"

    # بررسی موفقیت پایتون
    if [ $? -eq 0 ]; then
        if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$PANEL_ENV"
        echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"

        restart_service "panel"
        echo -e "${GREEN}✔ Theme Installed & Updated.${NC}"
    else
        echo -e "${RED}✘ Python Script Failed.${NC}"
    fi
    
    # پاک کردن فایل موقت
    rm -f "/tmp/index_old.html"
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