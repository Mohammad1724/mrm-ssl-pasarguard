#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

connect_node_wizard() {
    clear
    echo -e "${PURPLE}===========================================${NC}"
    echo -e "${YELLOW}      CONNECT NODE TO CORE WIZARD          ${NC}"
    echo -e "${PURPLE}===========================================${NC}"
    
    # 1. Get Core Info
    read -p "Core Panel IP/Domain: " CORE_HOST
    if [ -z "$CORE_HOST" ]; then return; fi
    read -p "Core Panel Port [443]: " CORE_PORT
    [ -z "$CORE_PORT" ] && CORE_PORT="443"
    
    # 2. Detect SSL inside DOMAIN FOLDER (Smart Detection)
    echo ""
    echo -e "${BLUE}Checking for Node SSL...${NC}"
    
    # Find first domain folder in node certs
    local FIRST_CERT_DIR=$(find "$NODE_DEF_CERTS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
    
    local CERT_FILE=""
    local KEY_FILE=""
    
    if [[ -n "$FIRST_CERT_DIR" && -f "$FIRST_CERT_DIR/server.crt" ]]; then
        echo -e "${GREEN}✔ Found SSL for $(basename "$FIRST_CERT_DIR")${NC}"
        CERT_FILE="$FIRST_CERT_DIR/server.crt"
        KEY_FILE="$FIRST_CERT_DIR/server.key"
    else
        echo -e "${YELLOW}SSL not found in default path.${NC}"
        echo "1) Enter custom path"
        echo "2) Continue without SSL"
        read -p "Select: " C_OPT
        if [[ "$C_OPT" == "1" ]]; then
            read -p "Path to Cert: " CERT_FILE
            read -p "Path to Key: " KEY_FILE
        fi
    fi
    
    # 3. Generate .env
    if [ ! -d "$NODE_DIR" ]; then
        echo -e "${RED}Node directory ($NODE_DIR) not found!${NC}"
        pause
        return
    fi
    
    echo -e "\n${BLUE}Writing configuration...${NC}"
    cat > "$NODE_ENV" <<EOF
SERVICE_PROTOCOL=wss
SERVICE_HOST=$CORE_HOST
SERVICE_PORT=$CORE_PORT
EOF

    if [ -n "$CERT_FILE" ]; then
        echo "SSL_CERT_FILE=\"$CERT_FILE\"" >> "$NODE_ENV"
        echo "SSL_KEY_FILE=\"$KEY_FILE\"" >> "$NODE_ENV"
        echo "SSL_CLIENT_CERT_FILE=\"$CERT_FILE\"" >> "$NODE_ENV"
    else
        echo "INSECURE=true" >> "$NODE_ENV"
    fi
    
    echo -e "${GREEN}✔ Configuration Saved.${NC}"
    
    # Restart Node
    restart_service "node"
    
    echo -e "${GREEN}✔ Node Setup Complete.${NC}"
    pause
}

edit_file() {
    if [ -f "$1" ]; then nano "$1"; else echo -e "${RED}File not found: $1${NC}"; pause; fi
}

settings_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SETTINGS & UTILITIES                 ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo -e "1) ${PURPLE}Connect Node to Core (Wizard)${NC}"
        echo -e "2) Edit Panel Config (.env)"
        echo -e "3) Edit Node Config (.env)"
        echo "4) Restart Main Panel"
        echo "5) Restart Node Service"
        echo "6) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " P_OPT
        case $P_OPT in
            1) connect_node_wizard ;;
            2) edit_file "$PANEL_ENV" ;;
            3) edit_file "$NODE_ENV" ;;
            4) restart_service "panel"; pause ;;
            5) restart_service "node"; pause ;;
            6) return ;;
            *) ;;
        esac
    done
}