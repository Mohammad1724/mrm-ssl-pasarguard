#!/bin/bash

# Load utils safely
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

_get_cert_action() {
    local DOMAIN=$1
    local EMAIL=$2
    
    echo -e "${BLUE}Opening Port 80 temporarily...${NC}"
    ufw allow 80/tcp > /dev/null 2>&1
    
    echo -e "${BLUE}Stopping web services...${NC}"
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
    fuser -k 80/tcp 2>/dev/null

    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
    
    systemctl start nginx 2>/dev/null
}

_process_panel() {
    local DOM=$1
    echo -e "\n${CYAN}--- Configuring Panel SSL ---${NC}"
    
    echo "Where to save certificates?"
    echo "1) Default Path ($PANEL_DEF_CERTS/$DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT
    
    local BASE_DIR="$PANEL_DEF_CERTS"
    if [[ "$PATH_OPT" == "2" ]]; then
        read -p "Enter Custom Base Directory: " BASE_DIR
    fi
    
    local TARGET_DIR="$BASE_DIR/$DOM"
    mkdir -p "$TARGET_DIR"
    
    if cp -L "/etc/letsencrypt/live/$DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$DOM/privkey.pem" "$TARGET_DIR/"; then
       
        local C_FILE="$TARGET_DIR/fullchain.pem"
        local K_FILE="$TARGET_DIR/privkey.pem"
        
        if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi
        
        echo -e "${BLUE}Updating Panel .env...${NC}"
        sed -i '/UVICORN_SSL_CERTFILE/d' "$PANEL_ENV"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$PANEL_ENV"
        
        echo "UVICORN_SSL_CERTFILE=\"$C_FILE\"" >> "$PANEL_ENV"
        echo "UVICORN_SSL_KEYFILE=\"$K_FILE\"" >> "$PANEL_ENV"
        
        restart_service "panel"
        echo -e "${GREEN}✔ Panel SSL Updated.${NC}"
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
    else
        echo -e "${RED}Error copying files.${NC}"
    fi
}

_process_node() {
    local DOM=$1
    echo -e "\n${PURPLE}--- Configuring Node SSL ---${NC}"
    
    echo "Where to save certificates?"
    echo "1) Default Path ($NODE_DEF_CERTS/$DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT
    
    local BASE_DIR="$NODE_DEF_CERTS"
    if [[ "$PATH_OPT" == "2" ]]; then
        read -p "Enter Custom Base Directory: " BASE_DIR
    fi
    
    local TARGET_DIR="$BASE_DIR/$DOM"
    mkdir -p "$TARGET_DIR"
    
    # Copy with Node naming convention (server.crt/key)
    cp -L "/etc/letsencrypt/live/$DOM/fullchain.pem" "$TARGET_DIR/server.crt"
    cp -L "/etc/letsencrypt/live/$DOM/privkey.pem" "$TARGET_DIR/server.key"
    
    local C_FILE="$TARGET_DIR/server.crt"
    local K_FILE="$TARGET_DIR/server.key"
    
    if [ -f "$NODE_ENV" ]; then
        echo -e "${BLUE}Updating Node .env...${NC}"
        sed -i '/SSL_CERT_FILE/d' "$NODE_ENV"
        sed -i '/SSL_KEY_FILE/d' "$NODE_ENV"
        
        echo "SSL_CERT_FILE=\"$C_FILE\"" >> "$NODE_ENV"
        echo "SSL_KEY_FILE=\"$K_FILE\"" >> "$NODE_ENV"
        
        restart_service "node"
        echo -e "${GREEN}✔ Node SSL Updated.${NC}"
    else
        echo -e "${RED}Node .env not found at $NODE_ENV${NC}"
    fi
    echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
}

_process_config() {
    local DOM=$1
    echo -e "\n${ORANGE}--- Config SSL (Inbounds) ---${NC}"
    
    # Always save to Panel Certs folder structure so Xray can see it
    local TARGET_DIR="$PANEL_DEF_CERTS/$DOM"
    
    mkdir -p "$TARGET_DIR"
    cp -L "/etc/letsencrypt/live/$DOM/fullchain.pem" "$TARGET_DIR/"
    cp -L "/etc/letsencrypt/live/$DOM/privkey.pem" "$TARGET_DIR/"
    
    chmod -R 755 "$PANEL_DEF_CERTS"
    
    echo -e "${GREEN}✔ Files Saved.${NC}"
    echo -e ""
    echo -e "${YELLOW}Copy these paths to your Inbound Settings:${NC}"
    echo -e "Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
    echo -e "Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
}

ssl_wizard() {
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}         SSL GENERATION WIZARD               ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Enter Domain: " DOM
    if [ -z "$DOM" ]; then return; fi
    read -p "Enter Email: " MAIL
    
    _get_cert_action "$DOM" "$MAIL"
    
    if [ ! -d "/etc/letsencrypt/live/$DOM" ]; then
        echo -e "${RED}✘ SSL Generation Failed!${NC}"
        pause
        return
    fi
    
    echo -e "${GREEN}✔ Success! What is this for?${NC}"
    echo "1) Main Panel"
    echo "2) Node Server"
    echo "3) Config Domain"
    read -p "Select: " TYPE_OPT
    
    case $TYPE_OPT in
        1) _process_panel "$DOM" ;;
        2) _process_node "$DOM" ;;
        3) _process_config "$DOM" ;;
        *) echo -e "${RED}Invalid.${NC}";;
    esac
    
    pause
}

show_detailed_paths() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       EXISTING SSL CERTIFICATES             ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    echo -e "${ORANGE}--- Panel & Config Domains ---${NC}"
    if [ -d "$PANEL_DEF_CERTS" ]; then
        for dir in "$PANEL_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                echo -e "${GREEN}Domain: $(basename "$dir")${NC}"
                echo -e "  Path: ${BLUE}$dir/${NC}"
                echo "--------------------------------------------"
            fi
        done
    fi
    
    echo ""
    echo -e "${PURPLE}--- Node Domains ---${NC}"
    if [ -d "$NODE_DEF_CERTS" ]; then
        for dir in "$NODE_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                echo -e "${GREEN}Domain: $(basename "$dir")${NC}"
                echo -e "  Path: ${BLUE}$dir/${NC}"
                echo "--------------------------------------------"
            fi
        done
    fi
    echo ""
    pause
}

ssl_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SSL MANAGEMENT                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Request New SSL (Wizard)"
        echo "2) Show Exact File Paths"
        echo "3) List LetsEncrypt Certs"
        echo "4) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " S_OPT
        case $S_OPT in
            1) ssl_wizard ;;
            2) show_detailed_paths ;;
            3) ls -1 /etc/letsencrypt/live 2>/dev/null; pause ;;
            4) return ;;
            *) ;;
        esac
    done
}