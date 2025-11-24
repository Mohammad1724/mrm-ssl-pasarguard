#!/bin/bash

# ==========================================
# Project: MRM SSL PASARGUARD
# Version: v1.7 (Updated Menu)
# Created for: Pasarguard Panel Management
# ==========================================

# --- Configuration ---
PROJECT_NAME="MRM SSL PASARGUARD"
VERSION="v1.7"

# >>> IMPORTANT: UPDATE THIS URL TO YOUR THEME FILE LOCATION <<<
THEME_SCRIPT_URL="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/theme.sh"

# Core Paths
DEFAULT_PATH="/var/lib/pasarguard/certs"
ENV_FILE_PATH="/opt/pasarguard/.env"
BACKUP_DIR="/root/pasarguard_backups"

# Node Paths
NODE_CERT_DIR="/var/lib/pg-node/certs"
NODE_CERT_FILE="/var/lib/pg-node/certs/ssl_cert.pem"
NODE_KEY_FILE="/var/lib/pg-node/certs/ssl_key.pem"
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
    # Install essentials quietly
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
#       SSL FUNCTIONS
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

list_all_certs() {
    echo ""
    echo -e "${CYAN}--- All Active Certificates (Dashboard) ---${NC}"
    
    if [ ! -d "/etc/letsencrypt/live" ]; then
        echo -e "${RED}No certificates found on this server.${NC}"
        read -p "Press Enter..."
        return
    fi

    echo -e "${BLUE}Scan in progress...${NC}"
    echo ""
    printf "%-30s %-25s %-15s\n" "DOMAIN" "EXPIRY DATE" "DAYS LEFT"
    echo "------------------------------------------------------------------------"

    FOUND_COUNT=0
    
    for d in /etc/letsencrypt/live/*; do
        if [ -d "$d" ]; then
            DOMAIN=$(basename "$d")
            CERT_FILE="$d/fullchain.pem"
            
            if [ ! -f "$CERT_FILE" ]; then continue; fi
            
            FOUND_COUNT=$((FOUND_COUNT+1))
            END_DATE=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
            
            if [ -z "$END_DATE" ]; then continue; fi

            EXP_TIMESTAMP=$(date -d "$END_DATE" +%s 2>/dev/null)
            NOW_TIMESTAMP=$(date +%s)
            
            if [ -z "$EXP_TIMESTAMP" ]; then continue; fi

            DIFF_SEC=$((EXP_TIMESTAMP - NOW_TIMESTAMP))
            DAYS_LEFT=$((DIFF_SEC / 86400))
            
            if [ "$DAYS_LEFT" -lt 10 ]; then COLOR=$RED; elif [ "$DAYS_LEFT" -lt 30 ]; then COLOR=$YELLOW; else COLOR=$GREEN; fi
            FORMATTED_DATE=$(date -d "$END_DATE" +"%Y-%m-%d")
            
            printf "%-30s %-25s ${COLOR}%-15s${NC}\n" "$DOMAIN" "$FORMATTED_DATE" "$DAYS_LEFT Days"
        fi
    done

    if [ $FOUND_COUNT -eq 0 ]; then
        echo -e "${YELLOW}No active certificates found.${NC}"
    fi
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
    echo -e "${PURPLE}--- SSL Status Check (Single) ---${NC}"
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

force_renew_sync() {
    echo ""
    echo -e "${RED}--- Fix & Update All SSLs ---${NC}"
    echo -e "This will renew ALL certificates and sync them to panel folder."
    read -p "Are you sure? (y/n): " CONFIRM
    
    if [[ "$CONFIRM" == "y" ]]; then
        echo -e "${BLUE}Stopping web services...${NC}"
        systemctl stop nginx 2>/dev/null
        fuser -k 80/tcp 2>/dev/null

        certbot renew --force-renewal
        
        for d in /etc/letsencrypt/live/*; do
            if [ -d "$d" ]; then
                DOMAIN=$(basename "$d")
                TARGET_DIR="$DEFAULT_PATH/$DOMAIN"
                # Only sync if destination folder exists (to be safe)
                if [ -d "$TARGET_DIR" ]; then
                    cp -L "$d/fullchain.pem" "$TARGET_DIR/fullchain.pem"
                    cp -L "$d/privkey.pem" "$TARGET_DIR/privkey.pem"
                    chmod 644 "$TARGET_DIR/fullchain.pem"
                    chmod 600 "$TARGET_DIR/privkey.pem"
                    echo -e "${GREEN}Synced: $DOMAIN${NC}"
                fi
            fi
        done

        restore_services
        if command -v pasarguard &> /dev/null; then pasarguard restart; fi
        echo -e "${GREEN}✔ Completed.${NC}"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

delete_ssl() {
    echo ""
    echo -e "${RED}--- Remove an SSL ---${NC}"
    read -p "Enter Domain to DELETE (Type 'b' to cancel): " DOMAIN
    if [[ "$DOMAIN" == "b" || "$DOMAIN" == "back" ]]; then return; fi

    echo -e "${YELLOW}Are you sure you want to delete SSL for: $DOMAIN ?${NC}"
    read -p "Type 'yes' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" == "yes" ]]; then
        certbot delete --cert-name "$DOMAIN" --non-interactive
        if [ -d "$DEFAULT_PATH/$DOMAIN" ]; then rm -rf "$DEFAULT_PATH/$DOMAIN"; echo -e "${GREEN}✔ Custom folder deleted.${NC}"; fi
        (crontab -l 2>/dev/null | grep -v "$DOMAIN") | crontab -
        echo -e "${GREEN}Deletion Complete.${NC}"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

backup_restore_menu() {
    echo ""
    echo -e "${CYAN}--- Backup or Restore SSLs ---${NC}"
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
            echo -e "${BLUE}Backing up...${NC}"
            if [ -d "$DEFAULT_PATH" ]; then
                tar -czf "$BACKUP_FILE" -C "$DEFAULT_PATH" .
                echo -e "${GREEN}✔ Backup saved at: $BACKUP_FILE${NC}"
            else
                echo -e "${RED}✘ Source directory not found.${NC}"
            fi
            ;;
        2)
            echo -e "${YELLOW}Enter full path to backup file (.tar.gz):${NC}"
            read -p "Path: " RESTORE_FILE
            if [ -f "$RESTORE_FILE" ]; then
                echo -e "${BLUE}Restoring...${NC}"
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

# ==========================================
#       PANEL & NODE FUNCTIONS
# ==========================================

edit_env_config() {
    echo ""
    echo -e "${CYAN}--- Edit Panel Settings (.env) ---${NC}"
    if [ -f "$ENV_FILE_PATH" ]; then
        echo -e "${YELLOW}Opening config file...${NC}"
        echo -e "Press ${CYAN}Ctrl+X${NC}, then ${CYAN}Y${NC}, then ${CYAN}Enter${NC} to save."
        read -p "Press Enter to open editor..."
        nano "$ENV_FILE_PATH"
        echo -e "${GREEN}✔ Done.${NC}"
    else
        echo -e "${RED}✘ File not found: $ENV_FILE_PATH${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

restart_panel() {
    echo ""
    echo -e "${CYAN}--- Restart Panel Service ---${NC}"
    echo -e "${YELLOW}Executing: pasarguard restart${NC}"
    if command -v pasarguard &> /dev/null; then
        pasarguard restart
        if [ $? -eq 0 ]; then echo -e "${GREEN}✔ Panel restarted.${NC}"; else echo -e "${RED}✘ Failed.${NC}"; fi
    else
        systemctl restart pasarguard 2>/dev/null
        echo -e "${YELLOW}Attempted via systemctl.${NC}"
    fi
    echo ""
    read -p "Press Enter..."
}

set_panel_ssl() {
    echo ""
    echo -e "${CYAN}--- Set Panel Domain (SSL) ---${NC}"
    echo -e "This will update the panel to use one of your generated SSLs."
    echo -e "${BLUE}Scanning for available domains...${NC}"
    echo ""

    if [ ! -d "$DEFAULT_PATH" ]; then
        echo -e "${RED}No SSLs found in $DEFAULT_PATH${NC}"
        read -p "Press Enter..."
        return
    fi

    DOMAINS=($(ls -1 "$DEFAULT_PATH"))

    if [ ${#DOMAINS[@]} -eq 0 ]; then
       echo -e "${RED}No SSL folders found.${NC}"
       read -p "Press Enter..."
       return
    fi

    i=1
    for d in "${DOMAINS[@]}"; do
        echo -e "${YELLOW}$i)${NC} $d"
        ((i++))
    done
    echo -e "${YELLOW}$i)${NC} Cancel"

    echo ""
    read -p "Select Domain for Panel [1-${#DOMAINS[@]}]: " CHOICE

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#DOMAINS[@]} ]; then
        INDEX=$((CHOICE-1))
        SELECTED_DOMAIN=${DOMAINS[$INDEX]}
        
        FULL_CERT_PATH="$DEFAULT_PATH/$SELECTED_DOMAIN/fullchain.pem"
        FULL_KEY_PATH="$DEFAULT_PATH/$SELECTED_DOMAIN/privkey.pem"

        if [[ -f "$FULL_CERT_PATH" && -f "$ENV_FILE_PATH" ]]; then
            echo -e "${BLUE}Updating .env for $SELECTED_DOMAIN...${NC}"
            
            # Improved Regex: handles #, spaces, tabs at start of line
            sed -i "s|^#*[[:space:]]*UVICORN_SSL_CERTFILE.*|UVICORN_SSL_CERTFILE = \"$FULL_CERT_PATH\"|g" "$ENV_FILE_PATH"
            sed -i "s|^#*[[:space:]]*UVICORN_SSL_KEYFILE.*|UVICORN_SSL_KEYFILE = \"$FULL_KEY_PATH\"|g" "$ENV_FILE_PATH"
            
            echo -e "${GREEN}✔ Config updated!${NC}"
            echo -e "Restarting Panel to apply changes..."
            restart_panel
        else
            echo -e "${RED}Error: SSL files missing or .env not found.${NC}"
        fi
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
}

setup_telegram_backup() {
    echo ""
    echo -e "${CYAN}--- Setup Telegram Backup ---${NC}"
    echo -e "Configure your bot for automatic backups."
    echo ""
    
    read -p "Enter Bot Token: " BOT_TOKEN
    read -p "Enter Chat ID: " CHAT_ID
    
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo -e "${RED}Inputs cannot be empty.${NC}"
        return
    fi

    if [ -f "$ENV_FILE_PATH" ]; then
        echo -e "${BLUE}Updating .env...${NC}"
        
        sed -i "s|^#*[[:space:]]*BACKUP_TELEGRAM_BOT_KEY.*|BACKUP_TELEGRAM_BOT_KEY=$BOT_TOKEN|g" "$ENV_FILE_PATH"
        sed -i "s|^#*[[:space:]]*BACKUP_TELEGRAM_CHAT_ID.*|BACKUP_TELEGRAM_CHAT_ID=$CHAT_ID|g" "$ENV_FILE_PATH"
        sed -i "s|^#*[[:space:]]*BACKUP_SERVICE_ENABLED.*|BACKUP_SERVICE_ENABLED=true|g" "$ENV_FILE_PATH"
        
        echo -e "${GREEN}✔ Telegram Backup Configured!${NC}"
        echo -e "Restarting Panel..."
        restart_panel
    else
        echo -e "${RED}Config file not found.${NC}"
    fi
}

install_theme_wrapper() {
    echo ""
    echo -e "${BLUE}Downloading FarsNetVIP Theme...${NC}"
    echo -e "URL: ${YELLOW}$THEME_SCRIPT_URL${NC}"
    
    # Check if url is placeholder
    if [[ "$THEME_SCRIPT_URL" == *"YOUR_USERNAME"* ]]; then
         echo -e "${RED}Error: You haven't updated the Theme URL in this script yet!${NC}"
         echo -e "Please open this script with nano and edit line 14."
         read -p "Press Enter..."
         return
    fi

    bash <(curl -Ls "$THEME_SCRIPT_URL")
    echo ""
    read -p "Press Enter to return..."
}

deploy_to_node() {
    echo ""
    echo -e "${CYAN}--- Apply SSL to Node ---${NC}"
    echo -e "Copies a domain's SSL to Node folder."
    
    read -p "Enter Domain Name (e.g. panel.example.com): " DOMAIN
    if [[ "$DOMAIN" == "b" || "$DOMAIN" == "back" || -z "$DOMAIN" ]]; then return; fi

    SOURCE_CERT="$DEFAULT_PATH/$DOMAIN/fullchain.pem"
    SOURCE_KEY="$DEFAULT_PATH/$DOMAIN/privkey.pem"

    if [[ ! -f "$SOURCE_CERT" ]]; then
        # Try fallback system path
        SOURCE_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        SOURCE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        if [[ ! -f "$SOURCE_CERT" ]]; then
            echo -e "${RED}✘ SSL not found.${NC}"
            read -p "Press Enter..."
            return
        fi
    fi

    echo -e "${BLUE}Applying...${NC}"
    mkdir -p "$NODE_CERT_DIR"

    if [ -f "$NODE_CERT_FILE" ]; then
        cp "$NODE_CERT_FILE" "$NODE_CERT_FILE.bak"
        echo -e "${YELLOW}Backup of old node cert created (.bak).${NC}"
    fi

    cp -L "$SOURCE_CERT" "$NODE_CERT_FILE"
    cp -L "$SOURCE_KEY" "$NODE_KEY_FILE"
    chmod 644 "$NODE_CERT_FILE"
    chmod 600 "$NODE_KEY_FILE"

    echo -e "${GREEN}✔ Node SSL Updated.${NC}"
    read -p "Press Enter..."
}

view_node_files_simple() {
    echo ""
    echo -e "${CYAN}--- View Node Files ---${NC}"
    echo -e "Which file?"
    echo -e "${YELLOW}1)${NC} SSL Certificate (ssl_cert.pem)"
    echo -e "${YELLOW}2)${NC} Node Config (node .env)"
    echo -e "${YELLOW}3)${NC} Cancel"
    echo ""
    read -p "Select [1-3]: " N_OPT

    case $N_OPT in
        1)
            echo -e "${YELLOW}Target: $NODE_CERT_FILE${NC}"
            if [ -f "$NODE_CERT_FILE" ]; then cat "$NODE_CERT_FILE"; else echo -e "${RED}File not found${NC}"; fi
            ;;
        2)
            echo -e "${YELLOW}Target: $NODE_ENV_FILE${NC}"
            if [ -f "$NODE_ENV_FILE" ]; then cat "$NODE_ENV_FILE"; else echo -e "${RED}File not found${NC}"; fi
            ;;
        *) return ;;
    esac
    echo ""
    read -p "Press Enter..."
}

change_panel_port() {
    echo ""
    echo -e "${CYAN}--- Change Panel Port ---${NC}"
    
    if [ ! -f "$ENV_FILE_PATH" ]; then
        echo -e "${RED}Config file not found.${NC}"
        read -p "Press Enter..."
        return
    fi

    # Regex matches even if commented out (# UVICORN_PORT)
    CURRENT_PORT=$(grep "^#*[[:space:]]*UVICORN_PORT" "$ENV_FILE_PATH" | cut -d '=' -f2 | tr -d ' ' | head -n 1)
    echo -e "Current Port: ${YELLOW}$CURRENT_PORT${NC}"
    
    read -p "Enter New Port (e.g. 2096): " NEW_PORT
    
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid port number.${NC}"
        return
    fi

    if [[ "$NEW_PORT" == "$CURRENT_PORT" ]]; then
        echo -e "${YELLOW}Port is already set to $NEW_PORT.${NC}"
        return
    fi

    echo -e "${BLUE}Updating config...${NC}"
    sed -i "s|^#*[[:space:]]*UVICORN_PORT.*|UVICORN_PORT = $NEW_PORT|g" "$ENV_FILE_PATH"
    
    echo -e "${GREEN}✔ Port changed to $NEW_PORT.${NC}"
    echo -e "Restarting Panel..."
    restart_panel
}

# ==========================================
#       MENU STRUCTURE
# ==========================================

ssl_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SSL CERTIFICATES MENU                ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Get New SSL Certificate"
        echo "2) See All Active SSLs"
        echo "3) Find SSL File Locations"
        echo "4) Check Expiry Date"
        echo "5) Backup or Restore SSLs"
        echo "6) Fix & Update All SSLs (Emergency)"
        echo "7) Remove an SSL"
        echo "8) Back to Main Menu"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select Option [1-8]: " S_OPT

        case $S_OPT in
            1) generate_ssl ;;
            2) list_all_certs ;;
            3) show_location ;;
            4) check_status ;;
            5) backup_restore_menu ;;
            6) force_renew_sync ;;
            7) delete_ssl ;;
            8) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

panel_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      PANEL & NODE SETTINGS                ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Edit Panel Settings (.env)"
        echo "2) Restart Panel Service"
        echo "3) Set Panel Domain (SSL) [Auto-Config]"
        echo "4) Apply SSL to Node (Fix Connection)"
        echo "5) Setup Telegram Backup"
        echo "6) Change Panel Port"
        echo "7) View Node Files (node .env)"
        echo "8) Install FarsNetVIP Theme"
        echo "9) Back to Main Menu"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select Option [1-9]: " P_OPT

        case $P_OPT in
            1) edit_env_config ;;
            2) restart_panel ;;
            3) set_panel_ssl ;;
            4) deploy_to_node ;;
            5) setup_telegram_backup ;;
            6) change_panel_port ;;
            7) view_node_files_simple ;;
            8) install_theme_wrapper ;;
            9) return ;;
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
    echo "1) SSL Certificates Menu"
    echo "2) Panel & Node Settings"
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