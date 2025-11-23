#!/bin/bash

# ==========================================
# Project: MRM SSL PASARGUARD
# Version: v1.5
# Created for: Pasarguard Panel Management
# ==========================================

# --- Configuration ---
PROJECT_NAME="MRM SSL PASARGUARD"
VERSION="v1.5"
DEFAULT_PATH="/var/lib/pasarguard/certs"
ENV_FILE_PATH="/opt/pasarguard/.env"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# --- Helper Functions ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    if ! command -v certbot &> /dev/null || ! command -v openssl &> /dev/null || ! command -v nano &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing necessary dependencies...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl cron openssl nano -qq > /dev/null
    fi
}

check_port_80() {
    if lsof -Pi :80 -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${YELLOW}[WARN] Port 80 is busy. Temporarily stopping web services...${NC}"
        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null
        fuser -k 80/tcp 2>/dev/null
    fi
}

restore_services() {
    systemctl start nginx 2>/dev/null
    systemctl start apache2 2>/dev/null
}

# --- Main Features ---

generate_ssl() {
    echo ""
    echo -e "${CYAN}--- Step 1: Quantity ---${NC}"
    echo -e "How many domains do you want to add? (Type '${YELLOW}b${NC}' to go back)"
    read -p ">> " DOMAIN_COUNT

    if [[ "$DOMAIN_COUNT" == "b" || "$DOMAIN_COUNT" == "back" ]]; then return; fi

    if ! [[ "$DOMAIN_COUNT" =~ ^[0-9]+$ ]] || [ "$DOMAIN_COUNT" -lt 1 ]; then
        echo -e "${RED}Error: Please enter a valid number.${NC}"
        read -p "Press Enter..."
        return
    fi

    DOMAIN_LIST=()
    echo ""
    echo -e "${CYAN}--- Step 2: Enter Domains ---${NC}"
    
    for (( i=1; i<=DOMAIN_COUNT; i++ ))
    do
        read -p "Enter Domain #$i: " SINGLE_DOMAIN
        if [[ "$SINGLE_DOMAIN" == "b" || "$SINGLE_DOMAIN" == "back" ]]; then return; fi

        if [ ! -z "$SINGLE_DOMAIN" ]; then
            DOMAIN_LIST+=("$SINGLE_DOMAIN")
        fi
    done

    if [ ${#DOMAIN_LIST[@]} -eq 0 ]; then
        echo -e "${RED}No domains entered.${NC}"
        return
    fi

    echo ""
    echo -e "${CYAN}--- Step 3: Email ---${NC}"
    read -p "Enter Email (Type 'b' to go back): " EMAIL
    if [[ "$EMAIL" == "b" || "$EMAIL" == "back" ]]; then return; fi

    check_port_80
    
    SUCCESS_LIST=()
    FAIL_LIST=()

    for DOMAIN in "${DOMAIN_LIST[@]}"; do
        echo ""
        echo -e "${BLUE}--- Processing: $DOMAIN ---${NC}"
        
        SERVER_IP=$(curl -s https://api.ipify.org)
        DOMAIN_IP=$(dig +short $DOMAIN | head -n 1)
        if [ "$SERVER_IP" != "$DOMAIN_IP" ] && [ ! -z "$DOMAIN_IP" ]; then
            echo -e "${YELLOW}[WARN] IP Mismatch ($DOMAIN). Might fail.${NC}"
        fi

        certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
        
        if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
            echo -e "${GREEN}✔ Success: $DOMAIN${NC}"
            SUCCESS_LIST+=("$DOMAIN")
        else
            echo -e "${RED}✘ Failed: $DOMAIN${NC}"
            FAIL_LIST+=("$DOMAIN")
        fi
    done

    restore_services

    if [ ${#SUCCESS_LIST[@]} -eq 0 ]; then
        echo -e "\n${RED}No certificates were generated.${NC}"
        read -p "Press Enter..."
        return
    fi

    echo ""
    echo -e "${CYAN}--- Step 4: Storage ---${NC}"
    echo -e "Where should folders be saved? (Default: $DEFAULT_PATH)"
    read -p ">> " USER_PATH
    
    if [[ "$USER_PATH" == "b" || "$USER_PATH" == "back" ]]; then 
        echo -e "${YELLOW}Files kept in system path only.${NC}"
        read -p "Press Enter..."
        return
    fi

    USER_PATH=${USER_PATH%/} 
    if [ -z "$USER_PATH" ]; then USER_PATH="$DEFAULT_PATH"; fi

    echo -e "${BLUE}[INFO] Saving files...${NC}"

    for DOMAIN in "${SUCCESS_LIST[@]}"; do
        FINAL_DEST="$USER_PATH/$DOMAIN"
        mkdir -p "$FINAL_DEST"

        cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$FINAL_DEST/fullchain.pem"
        cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$FINAL_DEST/privkey.pem"
        chmod 644 "$FINAL_DEST/fullchain.pem"
        chmod 600 "$FINAL_DEST/privkey.pem"

        CRON_CMD="cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem $FINAL_DEST/fullchain.pem && cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem $FINAL_DEST/privkey.pem"
        (crontab -l 2>/dev/null | grep -v "$DOMAIN"; echo "0 3 * * * $CRON_CMD") | crontab -
        
        echo -e "${GREEN}Saved -> $FINAL_DEST${NC}"
    done

    echo ""
    echo -e "${GREEN}All operations completed.${NC}"
    if [ ${#FAIL_LIST[@]} -gt 0 ]; then
        echo -e "${RED}Failed Domains: ${FAIL_LIST[*]}${NC}"
    fi
    echo -e "${YELLOW}Press Enter to return to menu...${NC}"
    read
}

view_keys() {
    echo ""
    echo -e "${CYAN}--- View Keys Content ---${NC}"
    read -p "Enter Domain (Type 'b' to go back): " DOMAIN
    if [[ "$DOMAIN" == "b" || "$DOMAIN" == "back" ]]; then return; fi

    POSSIBLE_PATH="$DEFAULT_PATH/$DOMAIN"
    LE_PATH="/etc/letsencrypt/live/$DOMAIN"

    if [ -f "$POSSIBLE_PATH/fullchain.pem" ]; then
        TARGET_PATH="$POSSIBLE_PATH"
    elif [ -f "$LE_PATH/fullchain.pem" ]; then
        TARGET_PATH="$LE_PATH"
    else
        echo -e "${RED}Files not found for $DOMAIN.${NC}"
        read -p "Press Enter..."
        return
    fi
    
    echo -e "${CYAN}--- PUBLIC KEY (fullchain.pem) ---${NC}"
    cat "$TARGET_PATH/fullchain.pem"
    echo ""
    echo -e "${CYAN}--- PRIVATE KEY (privkey.pem) ---${NC}"
    cat "$TARGET_PATH/privkey.pem"
    echo ""
    read -p "Press Enter..."
}

show_location() {
    echo ""
    echo -e "${CYAN}--- Show SSL File Paths ---${NC}"
    read -p "Enter Domain (Type 'b' to go back): " DOMAIN
    if [[ "$DOMAIN" == "b" || "$DOMAIN" == "back" ]]; then return; fi

    PASAR_DIR="$DEFAULT_PATH/$DOMAIN"
    
    if [ ! -f "$PASAR_DIR/fullchain.pem" ]; then
        echo -e "${YELLOW}Not found in default path.${NC}"
        echo -e "Did you save it in a custom folder? (Leave empty to cancel)"
        read -p "Enter Path: " CUSTOM_USER_PATH
        
        if [ -z "$CUSTOM_USER_PATH" ]; then return; fi
        CUSTOM_USER_PATH=${CUSTOM_USER_PATH%/}
        PASAR_DIR="$CUSTOM_USER_PATH/$DOMAIN"
    fi

    echo ""
    if [ -f "$PASAR_DIR/fullchain.pem" ]; then
        echo -e "${GREEN}✔ Copy these paths to your panel:${NC}"
        echo -e "Public Key : ${YELLOW}$PASAR_DIR/fullchain.pem${NC}"
        echo -e "Private Key: ${YELLOW}$PASAR_DIR/privkey.pem${NC}"
    else
        echo -e "${RED}✘ Files not found in: $PASAR_DIR${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

check_status() {
    echo ""
    echo -e "${PURPLE}--- SSL Status Check ---${NC}"
    read -p "Enter Domain (Type 'b' to go back): " DOMAIN
    if [[ "$DOMAIN" == "b" || "$DOMAIN" == "back" ]]; then return; fi

    LE_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

    if [ -f "$LE_PATH" ]; then
        echo ""
        echo -e "${GREEN}✔ Valid Certificate FOUND${NC}"
        echo -e "-----------------------------------"
        
        START_DATE=$(openssl x509 -in "$LE_PATH" -noout -startdate | cut -d= -f2)
        END_DATE=$(openssl x509 -in "$LE_PATH" -noout -enddate | cut -d= -f2)
        ISSUER=$(openssl x509 -in "$LE_PATH" -noout -issuer | awk -F "CN=" '{print $2}')
        
        echo -e "Issuer    : ${CYAN}$ISSUER${NC}"
        echo -e "Valid From: ${YELLOW}$START_DATE${NC}"
        echo -e "Expires On: ${YELLOW}$END_DATE${NC}"
        echo -e "-----------------------------------"
        echo -e "${BLUE}Auto-Renewal is active.${NC}"
    else
        echo ""
        echo -e "${RED}✘ No SSL found for '$DOMAIN' on this server.${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

edit_env_config() {
    echo ""
    echo -e "${CYAN}--- Edit Panel Config (.env) ---${NC}"
    
    if [ -f "$ENV_FILE_PATH" ]; then
        echo -e "${YELLOW}Opening $ENV_FILE_PATH with nano...${NC}"
        echo -e "Press ${CYAN}Ctrl+X${NC}, then ${CYAN}Y${NC}, then ${CYAN}Enter${NC} to save and exit."
        read -p "Press Enter to open editor..."
        nano "$ENV_FILE_PATH"
        echo -e "${GREEN}✔ Editing finished.${NC}"
    else
        echo -e "${RED}✘ Config file not found at: $ENV_FILE_PATH${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

restart_panel() {
    echo ""
    echo -e "${CYAN}--- Restarting Pasarguard Panel ---${NC}"
    echo -e "${YELLOW}Executing: pasarguard restart${NC}"
    
    # Execute the command
    if command -v pasarguard &> /dev/null; then
        pasarguard restart
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✔ Panel restarted successfully.${NC}"
        else
            echo -e "${RED}✘ Failed to restart panel.${NC}"
        fi
    else
        echo -e "${RED}Error: 'pasarguard' command not found in PATH.${NC}"
        echo -e "Attempting systemctl fallback..."
        systemctl restart pasarguard 2>/dev/null
    fi
    
    echo ""
    read -p "Press Enter..."
}

# --- Menu Loop ---

check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     $PROJECT_NAME $VERSION     ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) Generate SSL (Single or Multi)"
    echo "2) View Keys (Print content)"
    echo "3) Show SSL File Paths"
    echo "4) Check SSL Status & Expiry"
    echo "5) Edit Config (.env)"
    echo "6) Restart Panel"
    echo "7) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select Option [1-7]: " OPTION

    case $OPTION in
        1) generate_ssl ;;
        2) view_keys ;;
        3) show_location ;;
        4) check_status ;;
        5) edit_env_config ;;
        6) restart_panel ;;
        7) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done