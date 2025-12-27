#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# ✅ اطمینان از تشخیص پنل و تنظیم DATA_DIR
detect_active_panel > /dev/null

# ==========================================
# 1. INSTALL / UPDATE
# ==========================================
install_theme_wizard() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      THEME INSTALLATION WIZARD              ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    # ✅ تشخیص مجدد پنل برای اطمینان
    detect_active_panel > /dev/null

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Python3 is required but not installed.${NC}"
        pause; return
    fi

    # ✅ بررسی DATA_DIR
    if [ -z "$DATA_DIR" ]; then
        echo -e "${RED}ERROR: DATA_DIR is not set!${NC}"
        pause; return
    fi

    TEMPLATE_FILE="$DATA_DIR/templates/subscription/index.html"
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    mkdir -p "$TEMPLATE_DIR"

    echo -e "${BLUE}Template Path: $TEMPLATE_FILE${NC}"

    # 1. Backup old file
    if [ -s "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "/tmp/index_old.html"
        echo -e "${GREEN}✔ Backup created.${NC}"
    else
        echo "" > "/tmp/index_old.html"
    fi

    # 2. Source Selection (Hybrid)
    local TEMP_DL="/tmp/index_dl.html"
    rm -f "$TEMP_DL"

    if [ -f "./index.html" ]; then
        echo -e "${GREEN}✔ Found local index.html. Using it.${NC}"
        cp "./index.html" "$TEMP_DL"
    elif [ -f "/opt/mrm-manager/index.html" ]; then
        echo -e "${GREEN}✔ Found local index.html in /opt/mrm-manager. Using it.${NC}"
        cp "/opt/mrm-manager/index.html" "$TEMP_DL"
    else
        echo -e "${BLUE}Downloading from GitHub...${NC}"
        echo -e "${BLUE}URL: $THEME_HTML_URL${NC}"
        
        # ✅ بررسی موفقیت دانلود
        if curl -sL -o "$TEMP_DL" "$THEME_HTML_URL"; then
            # بررسی اینکه فایل 404 نباشد
            if grep -q "404: Not Found" "$TEMP_DL" 2>/dev/null; then
                echo -e "${RED}✘ Download failed: 404 Not Found${NC}"
                echo -e "${YELLOW}Please check THEME_HTML_URL in utils.sh${NC}"
                pause; return
            fi
            echo -e "${GREEN}✔ Downloaded successfully.${NC}"
        else
            echo -e "${RED}✘ Download failed!${NC}"
            pause; return
        fi
    fi

    # ✅ بررسی سایز فایل
    local FILE_SIZE=$(stat -c%s "$TEMP_DL" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000 ]; then
        echo -e "${RED}✘ Downloaded file is too small ($FILE_SIZE bytes). Something went wrong.${NC}"
        cat "$TEMP_DL"
        pause; return
    fi
    echo -e "${GREEN}✔ File size OK: $FILE_SIZE bytes${NC}"

    # 3. Processing
    echo -e "${BLUE}Processing configuration...${NC}"

    export OLD_FILE="/tmp/index_old.html"
    export NEW_FILE="/tmp/index_dl.html"
    export FINAL_FILE="$TEMPLATE_FILE"

    cat > /tmp/mrm_theme_logic.py << 'PYEOF'
import os
import re
import sys

CYAN = '\033[0;36m'
YELLOW = '\033[1;33m'
GREEN = '\033[0;32m'
NC = '\033[0m'

old_path = os.environ.get('OLD_FILE')
new_path = os.environ.get('NEW_FILE')
final_path = os.environ.get('FINAL_FILE')

defaults = {
    'brand': 'FarsNetVIP',
    'bot': 'MyBot',
    'sup': 'Support',
    'news': 'خوش آمدید',
}

# --- IMPROVED REGEX LOGIC ---
try:
    with open(old_path, 'r', encoding='utf-8', errors='ignore') as f:
        old_content = f.read()
    
    m_brand = re.search(r'<title>(.*?)</title>', old_content)
    if m_brand and "__BRAND__" not in m_brand.group(1): 
        defaults['brand'] = m_brand.group(1)
    
    m_bot = re.search(r'href="https://t\.me/([^"]+)"[^>]*class="[^"]*renew-btn', old_content)
    if not m_bot:
        m_bot = re.search(r'href="https://t\.me/([^"]+)"[^>]*class="[^"]*bot-link', old_content)
    if m_bot: defaults['bot'] = m_bot.group(1)
    
    m_sup = re.search(r'href="https://t\.me/([^"]+)"[^>]*class="[^"]*btn-dark', old_content)
    if m_sup: defaults['sup'] = m_sup.group(1)
    
    m_news = re.search(r'id="nT">\s*([^<]+)\s*<', old_content)
    if m_news: defaults['news'] = m_news.group(1).strip()

except Exception as e:
    pass

print(f'\n{CYAN}=== Theme Settings ==={NC}')
print(f'Press {YELLOW}ENTER{NC} to keep the current value [in brackets].\n')

def get_input(label, key):
    try:
        val = input(f'{label} [{defaults[key]}]: ').strip()
        if not val: return defaults[key]
        return val
    except EOFError: return defaults[key]

new_brand = get_input('Brand Name', 'brand')
new_bot = get_input('Bot Username (No @)', 'bot')
new_sup = get_input('Support ID (No @)', 'sup')
new_news = get_input('News Text', 'news')

try:
    with open(new_path, 'r', encoding='utf-8', errors='ignore') as f: content = f.read()
    content = content.replace('__BRAND__', new_brand)
    content = content.replace('__BOT__', new_bot)
    content = content.replace('__SUP__', new_sup)
    content = content.replace('__NEWS__', new_news)
    with open(final_path, 'w', encoding='utf-8') as f: f.write(content)
    print(f'\n{GREEN}✔ Settings saved successfully.{NC}')
except Exception as e:
    print(f'\nError processing file: {e}')
    sys.exit(1)
PYEOF

    python3 /tmp/mrm_theme_logic.py
    PY_EXIT_CODE=$?
    rm -f /tmp/mrm_theme_logic.py

    if [ $PY_EXIT_CODE -eq 0 ]; then
        # ✅ بررسی فایل نهایی
        if [ ! -s "$TEMPLATE_FILE" ]; then
            echo -e "${RED}✘ Final file is empty!${NC}"
            pause; return
        fi

        if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"

        echo "CUSTOM_TEMPLATES_DIRECTORY=\"$DATA_DIR/templates/\"" >> "$PANEL_ENV"
        echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"

        # ✅ نمایش تنظیمات نهایی
        echo ""
        echo -e "${CYAN}=== Final Configuration ===${NC}"
        echo -e "Template: $TEMPLATE_FILE"
        echo -e "File Size: $(stat -c%s "$TEMPLATE_FILE") bytes"
        grep -E "CUSTOM_TEMPLATES|SUBSCRIPTION_PAGE" "$PANEL_ENV"
        echo ""

        # ✅ استفاده از down/up به جای restart
        echo -e "${BLUE}Restarting panel (down/up)...${NC}"
        cd "$PANEL_DIR" && docker compose down && docker compose up -d
        
        echo -e "${GREEN}✔ Theme Updated & Panel Restarted.${NC}"
        rm -f "/tmp/index_old.html" "/tmp/index_dl.html"
    else
        echo -e "${RED}✘ Python Script Failed.${NC}"
    fi
    pause
}

activate_theme() {
    clear
    detect_active_panel > /dev/null
    
    local T_FILE="$DATA_DIR/templates/subscription/index.html"
    if [ ! -s "$T_FILE" ]; then 
        echo -e "${RED}Theme file missing or empty. Install first.${NC}"
        echo -e "${YELLOW}Expected path: $T_FILE${NC}"
        pause; return
    fi
    
    if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
    echo "CUSTOM_TEMPLATES_DIRECTORY=\"$DATA_DIR/templates/\"" >> "$PANEL_ENV"
    echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV"
    
    cd "$PANEL_DIR" && docker compose down && docker compose up -d
    echo -e "${GREEN}✔ Theme Activated.${NC}"
    pause
}

deactivate_theme() {
    clear
    detect_active_panel > /dev/null
    
    if [ -f "$PANEL_ENV" ]; then
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
        cd "$PANEL_DIR" && docker compose down && docker compose up -d
        echo -e "${GREEN}✔ Theme Deactivated.${NC}"
    fi
    pause
}

uninstall_theme() {
    clear
    detect_active_panel > /dev/null
    
    read -p "Delete theme files? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        rm -rf "$DATA_DIR/templates/subscription"
        if [ -f "$PANEL_ENV" ]; then
            sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV"
            sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV"
            cd "$PANEL_DIR" && docker compose down && docker compose up -d
        fi
        echo -e "${GREEN}✔ Theme removed & deactivated.${NC}"
    fi
    pause
}

is_theme_active() {
    if grep -q "SUBSCRIPTION_PAGE_TEMPLATE" "$PANEL_ENV" 2>/dev/null; then return 0; fi
    return 1
}

theme_menu() {
    while true; do
        clear
        detect_active_panel > /dev/null
        
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      THEME MANAGER                        ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo -e "Panel: ${CYAN}$PANEL_DIR${NC}"
        echo -e "Data:  ${CYAN}$DATA_DIR${NC}"
        if is_theme_active; then 
            echo -e "Status: ${GREEN}● Active${NC}"
        else 
            echo -e "Status: ${RED}● Inactive${NC}"
        fi
        echo ""
        echo "1) Install / Update Theme"
        echo "2) Activate Theme"
        echo "3) Deactivate Theme"
        echo "4) Uninstall Theme"
        echo "0) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) install_theme_wizard ;;
            2) activate_theme ;;
            3) deactivate_theme ;;
            4) uninstall_theme ;;
            0) return ;;
            *) ;;
        esac
    done
}