#!/bin/bash

# ==========================================
# Project: MRM SSL PASARGUARD
# Version: v3.0
# Created for: Pasarguard Panel Management
# ==========================================

# --- Configuration ---
PROJECT_NAME="MRM SSL PASARGUARD"
VERSION="v3.0"

# Paths
DEFAULT_PATH="/var/lib/pasarguard/certs"
ENV_FILE_PATH="/opt/pasarguard/.env"
BACKUP_DIR="/root/pasarguard_backups"

# Node Paths
NODE_CERT_FILE="/var/lib/pg-node/certs/ssl_cert.pem"
NODE_ENV_FILE="/opt/pg-node/.env"

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
    if ! command -v certbot &> /dev/null || ! command -v openssl &> /dev/null || ! command -v nano &> /dev/null || ! command -v tar &> /dev/null; then
        echo -e "${BLUE}[INFO] Installing necessary dependencies...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y certbot lsof curl cron openssl nano tar -qq > /dev/null
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

# ==========================================
#       FEATURE FUNCTIONS
# ==========================================

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

delete_ssl() {
    echo ""
    echo -e "${RED}--- DELETE SSL CERTIFICATE ---${NC}"
    read -p "Enter Domain to DELETE (Type 'b' to cancel): " DOMAIN
    
    if [[ "$DOMAIN" == "b" || "$DOMAIN" == "back" ]]; then return; fi

    echo -e "${YELLOW}Are you sure you want to delete SSL for: $DOMAIN ?${NC}"
    read -p "Type 'yes' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" == "yes" ]]; then
        certbot delete --cert-name "$DOMAIN" --non-interactive
        
        if [ -d "$DEFAULT_PATH/$DOMAIN" ]; then
            rm -rf "$DEFAULT_PATH/$DOMAIN"
            echo -e "${GREEN}✔ Custom folder deleted.${NC}"
        fi
        
        (crontab -l 2>/dev/null | grep -v "$DOMAIN") | crontab -
        echo -e "${GREEN}✔ Auto-renewal cronjob removed.${NC}"
        
        echo -e "${GREEN}Deletion Complete.${NC}"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

backup_restore_menu() {
    echo ""
    echo -e "${CYAN}--- Backup & Restore SSL ---${NC}"
    echo "1) Backup SSL Certificates (Zip)"
    echo "2) Restore SSL Certificates"
    echo "3) Back"
    echo ""
    read -p "Select [1-3]: " BR_OPT
    
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
    
    case $BR_OPT in
        1)
            BACKUP_FILE="$BACKUP_DIR/ssl_backup_$TIMESTAMP.tar.gz"
            echo -e "${BLUE}Backing up $DEFAULT_PATH ...${NC}"
            if [ -d "$DEFAULT_PATH" ]; then
                tar -czf "$BACKUP_FILE" -C "$DEFAULT_PATH" .
                echo -e "${GREEN}✔ Backup saved at: $BACKUP_FILE${NC}"
            else
                echo -e "${RED}✘ Source directory not found ($DEFAULT_PATH).${NC}"
            fi
            ;;
        2)
            echo -e "${YELLOW}Enter full path to backup file (.tar.gz):${NC}"
            read -p "Path: " RESTORE_FILE
            if [ -f "$RESTORE_FILE" ]; then
                echo -e "${BLUE}Restoring to $DEFAULT_PATH ...${NC}"
                mkdir -p "$DEFAULT_PATH"
                tar -xzf "$RESTORE_FILE" -C "$DEFAULT_PATH"
                echo -e "${GREEN}✔ Restore completed.${NC}"
            else
                echo -e "${RED}✘ File not found.${NC}"
            fi
            ;;
        *) return ;;
    esac
    echo ""
    read -p "Press Enter..."
}

# --- PANEL & NODE FUNCTIONS ---

edit_env_config() {
    echo ""
    echo -e "${CYAN}--- Edit Panel Config (.env) ---${NC}"
    
    if [ -f "$ENV_FILE_PATH" ]; then
        echo -e "${YELLOW}Opening $ENV_FILE_PATH with nano...${NC}"
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

view_node_files_simple() {
    echo ""
    echo -e "${CYAN}--- View Node Configuration ---${NC}"
    echo -e "Which file do you want to see?"
    echo -e "${YELLOW}1)${NC} SSL Certificate (ssl_cert.pem)"
    echo -e "${YELLOW}2)${NC} Node Config (.env)"
    echo -e "${YELLOW}3)${NC} Cancel"
    echo ""
    read -p "Select [1-3]: " N_OPT

    case $N_OPT in
        1)
            echo ""
            echo -e "${YELLOW}Target: $NODE_CERT_FILE${NC}"
            if [ -f "$NODE_CERT_FILE" ]; then
                echo -e "${GREEN}--- CONTENT START ---${NC}"
                cat "$NODE_CERT_FILE"
                echo -e "\n${GREEN}--- CONTENT END ---${NC}"
            else
                echo -e "${RED}✘ File not found: $NODE_CERT_FILE${NC}"
            fi
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Target: $NODE_ENV_FILE${NC}"
            if [ -f "$NODE_ENV_FILE" ]; then
                echo -e "${GREEN}--- CONTENT START ---${NC}"
                cat "$NODE_ENV_FILE"
                echo -e "\n${GREEN}--- CONTENT END ---${NC}"
            else
                echo -e "${RED}✘ File not found: $NODE_ENV_FILE${NC}"
            fi
            ;;
        *) return ;;
    esac
    echo ""
    read -p "Press Enter..."
}

view_logs() {
    echo ""
    echo -e "${CYAN}--- View Pasarguard Logs (Last 50 lines) ---${NC}"
    if command -v pasarguard &> /dev/null; then
        journalctl -u pasarguard -n 50 --no-pager
    else
        echo -e "${RED}Pasarguard command/service not detected properly.${NC}"
    fi
    echo -e "\n${GREEN}----------------------------------${NC}"
    read -p "Press Enter..."
}

# ==========================================
#       MENU STRUCTURE
# ==========================================

# Sub-Menu: SSL Management
ssl_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}        SSL MANAGEMENT MENU                ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Generate SSL (Single or Multi)"
        echo "2) Show SSL File Paths"
        echo "3) Check SSL Status & Expiry"
        echo "4) Backup / Restore SSL"
        echo "5) Delete SSL (Remove Certs)"
        echo "6) Back to Main Menu"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select Option [1-6]: " S_OPT

        case $S_OPT in
            1) generate_ssl ;;
            2) show_location ;;
            3) check_status ;;
            4) backup_restore_menu ;;
            5) delete_ssl ;;
            6) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# Sub-Menu: Panel & Node Management
panel_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}     PANEL & NODE MANAGEMENT MENU          ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Edit Config (.env)"
        echo "2) Restart Panel"
        echo "3) View Node Configs (SSL & .env)"
        echo "4) View Service Logs"
        echo "5) Back to Main Menu"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select Option [1-5]: " P_OPT

        case $P_OPT in
            1) edit_env_config ;;
            2) restart_panel ;;
            3) view_node_files_simple ;;
            4) view_logs ;;
            5) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# Main Menu
check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}     $PROJECT_NAME $VERSION     ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "1) SSL Management (Generate, View, Backup...)"
    echo "2) Panel & Node Management (Edit, Restart...)"
    echo "3) Exit"
    echo -e "${BLUE}===========================================${NC}"
    read -p "Select Option [1-3]: " OPTION

    case $OPTION in
        1) ssl_menu ;;
        2) panel_menu ;;
        3) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done