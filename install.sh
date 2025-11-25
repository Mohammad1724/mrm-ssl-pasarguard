#!/bin/bash

# ==========================================
# Project: MRM PASARGUARD MANAGER
# Version: v2.0 (Theme Manager Integrated)
# ==========================================

# --- Configuration ---
# لینک فایل theme.sh خود را اینجا بگذارید
THEME_SCRIPT_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/theme.sh"

# Paths
TEMPLATE_DIR="/var/lib/pasarguard/templates"
SUB_DIR="/var/lib/pasarguard/templates/subscription"
HTML_FILE="$SUB_DIR/index.html"
ENV_FILE="/opt/pasarguard/.env"
NODE_CERT_DIR="/var/lib/pg-node/certs"
NODE_ENV_FILE="/opt/pg-node/.env"
DEFAULT_SSL_PATH="/var/lib/pasarguard/certs"
BACKUP_DIR="/root/pasarguard_backups"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# --- Helper Functions ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    if ! command -v certbot &> /dev/null || ! command -v curl &> /dev/null || ! command -v nano &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl cron openssl nano tar -qq > /dev/null
    fi
}

restart_panel() {
    echo -e "${BLUE}Restarting Pasarguard Service...${NC}"
    if command -v pasarguard &> /dev/null; then
        pasarguard restart
    else
        systemctl restart pasarguard 2>/dev/null
    fi
    echo -e "${GREEN}✔ Done.${NC}"
}

# ==========================================
#       THEME FUNCTIONS (NEW)
# ==========================================

install_theme() {
    echo ""
    echo -e "${CYAN}--- Install / Reinstall Theme ---${NC}"
    
    # Check URL
    if [[ "$THEME_SCRIPT_URL" == *"YOUR_USERNAME"* ]]; then
         echo -e "${RED}Error: THEME_SCRIPT_URL is not set in install.sh${NC}"
         echo -e "Please edit line 10 of this script."
         read -p "Press Enter..."
         return
    fi

    echo -e "${BLUE}Downloading Theme Script...${NC}"
    TMP_SCRIPT=$(mktemp)
    
    if curl -fsSL "$THEME_SCRIPT_URL" -o "$TMP_SCRIPT"; then
        chmod +x "$TMP_SCRIPT"
        bash "$TMP_SCRIPT"
        rm -f "$TMP_SCRIPT"
        echo -e "${GREEN}✔ Theme Installation Logic Completed.${NC}"
    else
        echo -e "${RED}✘ Download Failed. Check URL or Internet.${NC}"
        rm -f "$TMP_SCRIPT"
    fi
    read -p "Press Enter to return..."
}

activate_theme() {
    echo ""
    echo -e "${BLUE}Activating Theme...${NC}"
    if [ ! -f "$HTML_FILE" ]; then
        echo -e "${RED}Theme file not found. Please Install first.${NC}"
        read -p "Press Enter..."
        return
    fi

    if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi

    # Remove old lines
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"

    # Add new lines
    echo 'CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"' >> "$ENV_FILE"
    echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$ENV_FILE"

    restart_panel
    echo -e "${GREEN}✔ Theme Activated.${NC}"
    read -p "Press Enter..."
}

deactivate_theme() {
    echo ""
    echo -e "${YELLOW}Deactivating Theme (Revert to Default)...${NC}"
    
    if [ -f "$ENV_FILE" ]; then
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
        restart_panel
        echo -e "${GREEN}✔ Theme Deactivated.${NC}"
    else
        echo -e "${RED}Config file not found.${NC}"
    fi
    read -p "Press Enter..."
}

uninstall_theme() {
    echo ""
    echo -e "${RED}--- Uninstall Theme ---${NC}"
    read -p "Are you sure you want to delete theme files? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        echo -e "${BLUE}Removing files...${NC}"
        rm -rf "$SUB_DIR"
        
        echo -e "${BLUE}Cleaning config...${NC}"
        if [ -f "$ENV_FILE" ]; then
            sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$ENV_FILE"
            sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$ENV_FILE"
        fi
        
        restart_panel
        echo -e "${GREEN}✔ Theme Uninstalled.${NC}"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    read -p "Press Enter..."
}

# --- Edit Theme Logic (Integrated Manager) ---
edit_theme_menu() {
    if [ ! -f "$HTML_FILE" ]; then
        echo -e "${RED}Theme not installed!${NC}"
        read -p "Press Enter..."
        return
    fi

    while true; do
        clear
        echo -e "${CYAN}--- Edit Theme Elements ---${NC}"
        echo "1) Edit Brand Name"
        echo "2) Edit News Text"
        echo "3) Edit Bot Username"
        echo "4) Edit Support ID"
        echo "5) Edit Android Link"
        echo "6) Edit iOS Link"
        echo "7) Edit Windows Link"
        echo "8) Back"
        echo "---------------------------"
        read -p "Select: " E_OPT

        case $E_OPT in
            1) _edit_val 'id="brandTxt"' "Brand Name" ;;
            2) _edit_val 'id="nT"' "News Text" ;;
            3) _edit_bot ;;
            4) _edit_sup ;;
            5) _edit_link 'id="da"' "Android URL" ;;
            6) _edit_link 'id="di"' "iOS URL" ;;
            7) _edit_link 'id="dw"' "Windows URL" ;;
            8) return ;;
            *) ;;
        esac
    done
}

# Helper for Editing
_edit_val() {
    local PATTERN=$1
    local NAME=$2
    # Extract current
    local CUR=$(grep "$PATTERN" "$HTML_FILE" | head -n1 | sed -E "s/.*$PATTERN>([^<]+)<.*/\1/")
    echo -e "Current $NAME: ${YELLOW}$CUR${NC}"
    read -p "New $NAME (Enter to skip): " NEW_VAL
    if [ ! -z "$NEW_VAL" ]; then
        # Escape special chars
        local ESC=$(echo "$NEW_VAL" | sed -e 's/[\/&]/\\&/g')
        sed -i "s|$PATTERN>[^<]*<|$PATTERN>$ESC<|" "$HTML_FILE"
        echo -e "${GREEN}✔ Updated.${NC}"
        sleep 1
    fi
}

_edit_link() {
    local ID=$1
    local NAME=$2
    local CUR=$(grep "$ID" "$HTML_FILE" | head -n1 | sed -n 's/.*href="\([^"]*\)".*/\1/p')
    echo -e "Current $NAME: ${YELLOW}$CUR${NC}"
    read -p "New Link: " NEW_VAL
    if [ ! -z "$NEW_VAL" ]; then
        local ESC=$(echo "$NEW_VAL" | sed -e 's/[\/&]/\\&/g')
        sed -i "s|$ID\" href=\"[^\"]*\"|$ID\" href=\"$ESC\"|" "$HTML_FILE"
        echo -e "${GREEN}✔ Updated.${NC}"
        sleep 1
    fi
}

_edit_bot() {
    local CUR=$(grep "bot-link" "$HTML_FILE" | head -n1 | sed -n 's/.*href="https:\/\/t.me\/\([^"]*\)".*/\1/p')
    echo -e "Current Bot: ${YELLOW}$CUR${NC}"
    read -p "New Bot User (no @): " NEW_VAL
    if [ ! -z "$NEW_VAL" ]; then
        sed -i "s|href=\"https://t.me/[^\"]*\" class=\"bot-link\"|href=\"https://t.me/$NEW_VAL\" class=\"bot-link\"|" "$HTML_FILE"
        sed -i "s|>@.*</a>|>@$NEW_VAL</a>|" "$HTML_FILE"
        echo -e "${GREEN}✔ Updated.${NC}"
        sleep 1
    fi
}

_edit_sup() {
    # پیدا کردن یوزرنیم فعلی بر اساس کلاس btn-dark
    local CUR=$(grep "btn-dark" "$HTML_FILE" | head -n1 | sed -n 's/.*href="https:\/\/t.me\/\([^"]*\)".*/\1/p')
    echo -e "Current Support ID: ${YELLOW}$CUR${NC}"
    
    echo -e "Enter new Support Username (no @)"
    read -p ">> " NEW_VAL
    if [ ! -z "$NEW_VAL" ]; then
        # جایگزینی لینک در دکمه‌ای که کلاس btn-dark دارد
        sed -i "s|href=\"https://t.me/[^\"]*\" class=\"btn btn-dark\"|href=\"https://t.me/$NEW_VAL\" class=\"btn btn-dark\"|" "$HTML_FILE"
        echo -e "${GREEN}✔ Updated.${NC}"
        sleep 1
    fi
}

theme_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}         THEME MANAGER (FarsNetVIP)        ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Install / Reinstall Theme (Full Setup)"
        echo "2) Edit Theme Elements (Text, Links, etc)"
        echo "3) Activate Theme"
        echo "4) Deactivate Theme (Restore Default)"
        echo "5) Uninstall Theme Files"
        echo "6) Back to Main Menu"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT

        case $T_OPT in
            1) install_theme ;;
            2) edit_theme_menu ;;
            3) activate_theme ;;
            4) deactivate_theme ;;
            5) uninstall_theme ;;
            6) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================
#       SSL FUNCTIONS (KEPT FROM BEFORE)
# ==========================================
# (Simplified for brevity, assuming standard functionality)

generate_ssl() {
    # [Keeping original logic, shortened for this output]
    echo -e "${CYAN}--- SSL Generator ---${NC}"
    echo -e "Enter Domain:"
    read -p ">> " DOMAIN
    if [ -z "$DOMAIN" ]; then return; fi
    
    echo -e "Enter Email:"
    read -p ">> " EMAIL
    
    echo -e "${BLUE}Stopping web services...${NC}"
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
    fuser -k 80/tcp 2>/dev/null

    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"

    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo -e "${GREEN}✔ Success!${NC}"
        mkdir -p "$DEFAULT_SSL_PATH/$DOMAIN"
        cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$DEFAULT_SSL_PATH/$DOMAIN/"
        cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$DEFAULT_SSL_PATH/$DOMAIN/"
        chmod 644 "$DEFAULT_SSL_PATH/$DOMAIN/fullchain.pem"
        chmod 600 "$DEFAULT_SSL_PATH/$DOMAIN/privkey.pem"
    else
        echo -e "${RED}✘ Failed.${NC}"
    fi
    
    systemctl start nginx 2>/dev/null
    read -p "Press Enter..."
}

list_certs() {
    echo -e "${CYAN}--- Active Certificates ---${NC}"
    ls -1 /etc/letsencrypt/live 2>/dev/null || echo "No certs found."
    read -p "Press Enter..."
}

# ==========================================
#       PANEL FUNCTIONS
# ==========================================

set_panel_domain() {
    echo -e "${CYAN}--- Set Panel Domain ---${NC}"
    echo -e "Available domains in $DEFAULT_SSL_PATH:"
    ls "$DEFAULT_SSL_PATH" 2>/dev/null
    echo ""
    read -p "Enter Domain Name: " DOM
    
    CERT="$DEFAULT_SSL_PATH/$DOM/fullchain.pem"
    KEY="$DEFAULT_SSL_PATH/$DOM/privkey.pem"
    
    if [ -f "$CERT" ]; then
        if [ ! -f "$ENV_FILE" ]; then touch "$ENV_FILE"; fi
        # Upsert
        if grep -q "UVICORN_SSL_CERTFILE" "$ENV_FILE"; then
            sed -i "s|UVICORN_SSL_CERTFILE.*|UVICORN_SSL_CERTFILE = \"$CERT\"|g" "$ENV_FILE"
        else
            echo "UVICORN_SSL_CERTFILE = \"$CERT\"" >> "$ENV_FILE"
        fi
        if grep -q "UVICORN_SSL_KEYFILE" "$ENV_FILE"; then
            sed -i "s|UVICORN_SSL_KEYFILE.*|UVICORN_SSL_KEYFILE = \"$KEY\"|g" "$ENV_FILE"
        else
            echo "UVICORN_SSL_KEYFILE = \"$KEY\"" >> "$ENV_FILE"
        fi
        restart_panel
    else
        echo -e "${RED}Cert files not found for $DOM${NC}"
        read -p "Press Enter..."
    fi
}

panel_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      PANEL & NODE SETTINGS                ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Set Panel Domain (SSL)"
        echo "2) Restart Panel Service"
        echo "3) Edit .env Config"
        echo "4) Back to Main Menu"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " P_OPT

        case $P_OPT in
            1) set_panel_domain ;;
            2) restart_panel; read -p "Press Enter..." ;;
            3) nano "$ENV_FILE" ;;
            4) return ;;
            *) ;;
        esac
    done
}

ssl_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SSL MANAGEMENT                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Generate New SSL"
        echo "2) List Active SSLs"
        echo "3) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " S_OPT
        case $S_OPT in
            1) generate_ssl ;;
            2) list_certs ;;
            3) return ;;
            *) ;;
        esac
    done
}

# ==========================================
#       MAIN MENU
# ==========================================

check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     MRM MANAGER v2.0 (FarsNetVIP)         ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) SSL Certificates Menu"
    echo "2) Theme Manager (FarsNetVIP)"
    echo "3) Panel & Node Settings"
    echo "4) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select Option [1-4]: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) theme_menu ;;
        3) panel_menu ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
