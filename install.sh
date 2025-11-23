#!/bin/bash

# ==========================================
# Project: MRM SSL PASARGUARD
# Version: v1.0
# Created for: Pasarguard Panel Management
# ==========================================

# --- Configuration ---
PROJECT_NAME="MRM SSL PASARGUARD"
VERSION="v1.0"
DEFAULT_PATH="/var/lib/pasarguard/certs"

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
    # Check if dependencies are installed, if not, install them silently
    if ! command -v certbot &> /dev/null || ! command -v openssl &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing necessary dependencies...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl cron openssl -qq > /dev/null
    fi
}

check_port_80() {
    # Check if Port 80 is occupied by Nginx/Apache
    if lsof -Pi :80 -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${YELLOW}[WARN] Port 80 is busy. Temporarily stopping web services...${NC}"
        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null
        fuser -k 80/tcp 2>/dev/null
    fi
}

restore_services() {
    # Restart web services after Certbot finishes
    systemctl start nginx 2>/dev/null
    systemctl start apache2 2>/dev/null
}

# --- Main Features ---

generate_ssl() {
    echo ""
    echo -e "${CYAN}--- Step 1: Quantity ---${NC}"
    echo -e "How many domains do you want to add? (Type '${YELLOW}b${NC}' to go back)"
    read -p ">> " DOMAIN_COUNT

    # Back Check
    if [[ "$DOMAIN_COUNT" == "b" || "$DOMAIN_COUNT" == "back" ]]; then return; fi

    # Validation
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
        # Back Check inside loop
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

    # Start Processing
    check_port_80
    
    SUCCESS_LIST=()
    FAIL_LIST=()

    for DOMAIN in "${DOMAIN_LIST[@]}"; do
        echo ""
        echo -e "${BLUE}--- Processing: $DOMAIN ---${NC}"
        
        # IP Check (Safety feature)
        SERVER_IP=$(curl -s https://api.ipify.org)
        DOMAIN_IP=$(dig +short $DOMAIN | head -n 1)
        if [ "$SERVER_IP" != "$DOMAIN_IP" ] && [ ! -z "$DOMAIN_IP" ]; then
            echo -e "${YELLOW}[WARN] IP Mismatch ($DOMAIN). Might fail.${NC}"
        fi

        # Request SSL
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
    
    # Back Check
    if [[ "$USER_PATH" == "b" || "$USER_PATH" == "back" ]]; then 
        echo -e "${YELLOW}Files are in /etc/letsencrypt but were NOT copied to custom path.${NC}"
        read -p "Press Enter..."
        return
    fi

    USER_PATH=${USER_PATH%/} 
    if [ -z "$USER_PATH" ]; then USER_PATH="$DEFAULT_PATH"; fi

    echo -e "${BLUE}[INFO] Saving files...${NC}"

    for DOMAIN in "${SUCCESS_LIST[@]}"; do
        FINAL_DEST="$USER_PATH/$DOMAIN"
        mkdir -p "$FINAL_DEST"

        # Copy Files
        cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$FINAL_DEST/fullchain.pem"
        cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$FINAL_DEST/privkey.pem"
        
        # Set Permissions
        chmod 644 "$FINAL_DEST/fullchain.pem"
        chmod 600 "$FINAL_DEST/privkey.pem"

        # Setup Auto-Renewal Cronjob (Prevents duplicates)
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

    # Try default path first, then letsencrypt path
    POSSIBLE_PATH="$DEFAULT_PATH/$DOMAIN"
    LE_PATH="/etc/letsencrypt/live/$DOMAIN"

    if [ -f "$POSSIBLE_PATH/fullchain.pem" ]; then
        TARGET_PATH="$POSSIBLE_PATH"
    elif [ -f "$LE_PATH/fullchain.pem" ]; then
        TARGET_PATH="$LE_PATH"
    else
        echo -e "${RED}Certificate files not found for $DOMAIN.${NC}"
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

# --- Menu Loop ---

check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     $PROJECT_NAME $VERSION     ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) Generate SSL (Single or Multi)"
    echo "2) View Keys (Print to console)"
    echo "3) Check SSL Status & Expiry"
    echo "4) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select Option [1-4]: " OPTION

    case $OPTION in
        1) generate_ssl ;;
        2) view_keys ;;
        3) check_status ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
