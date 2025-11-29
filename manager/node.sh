#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

connect_node_wizard() {
    clear
    echo -e "${PURPLE}===========================================${NC}"
    echo -e "${YELLOW}      CONNECT NODE TO CORE WIZARD          ${NC}"
    echo -e "${PURPLE}===========================================${NC}"

    read -p "Core Panel IP/Domain: " CORE_HOST
    if [ -z "$CORE_HOST" ]; then return; fi
    read -p "Core Panel Port [443]: " CORE_PORT
    [ -z "$CORE_PORT" ] && CORE_PORT="443"

    echo ""
    echo -e "${BLUE}Checking for Node SSL...${NC}"

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
    restart_service "node"
    echo -e "${GREEN}✔ Node Setup Complete.${NC}"
    pause
}

edit_file() {
    if [ -f "$1" ]; then nano "$1"; else echo -e "${RED}File not found: $1${NC}"; pause; fi
}

# NEW: Show Node SSL Paths & Files
show_node_ssl() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      NODE SSL CERTIFICATES                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    if [ ! -d "$NODE_DEF_CERTS" ]; then
        echo -e "${RED}Node certificate directory not found!${NC}"
        echo -e "Expected: ${CYAN}$NODE_DEF_CERTS${NC}"
        pause
        return
    fi
    
    local FOUND=0
    
    for dir in "$NODE_DEF_CERTS"/*/; do
        [ -d "$dir" ] || continue
        FOUND=1
        local domain=$(basename "$dir")
        
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}Domain: $domain${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Certificate Path
        if [ -f "$dir/server.crt" ]; then
            echo -e "${BLUE}Certificate:${NC}"
            echo -e "  Path: ${CYAN}$dir/server.crt${NC}"
            
            # Show expiry date
            local EXPIRY=$(openssl x509 -enddate -noout -in "$dir/server.crt" 2>/dev/null | cut -d= -f2)
            if [ -n "$EXPIRY" ]; then
                echo -e "  Expires: ${CYAN}$EXPIRY${NC}"
            fi
            echo ""
        else
            echo -e "${RED}  Certificate not found (server.crt)${NC}"
        fi
        
        # Key Path
        if [ -f "$dir/server.key" ]; then
            echo -e "${BLUE}Private Key:${NC}"
            echo -e "  Path: ${CYAN}$dir/server.key${NC}"
            echo ""
        else
            echo -e "${RED}  Key not found (server.key)${NC}"
        fi
        
    done
    
    if [ $FOUND -eq 0 ]; then
        echo -e "${YELLOW}No certificates found in $NODE_DEF_CERTS${NC}"
        echo ""
        echo "To add certificates for node:"
        echo "1) Go to SSL Menu"
        echo "2) Generate new SSL"
        echo "3) Select 'Node Server' when asked"
    fi
    
    pause
}

# NEW: View Node SSL Content
view_node_ssl_content() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      VIEW NODE SSL CONTENT                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    if [ ! -d "$NODE_DEF_CERTS" ]; then
        echo -e "${RED}No certificates directory found!${NC}"
        pause
        return
    fi
    
    echo -e "${BLUE}Available Domains:${NC}"
    echo ""
    
    local i=1
    declare -a domains
    for dir in "$NODE_DEF_CERTS"/*/; do
        [ -d "$dir" ] || continue
        local domain=$(basename "$dir")
        domains[$i]="$domain"
        echo -e "  ${GREEN}$i)${NC} $domain"
        ((i++))
    done
    
    if [ $i -eq 1 ]; then
        echo -e "${YELLOW}No domains found.${NC}"
        pause
        return
    fi
    
    echo ""
    read -p "Select domain number: " NUM
    local SELECTED="${domains[$NUM]}"
    
    if [ -z "$SELECTED" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        pause
        return
    fi
    
    local TARGET_DIR="$NODE_DEF_CERTS/$SELECTED"
    
    echo ""
    echo "Which file to view?"
    echo "1) Certificate (server.crt)"
    echo "2) Private Key (server.key)"
    read -p "Select: " F_OPT
    
    local FILE=""
    case $F_OPT in
        1) FILE="server.crt" ;;
        2) FILE="server.key" ;;
        *) return ;;
    esac
    
    if [ -f "$TARGET_DIR/$FILE" ]; then
        clear
        echo -e "${YELLOW}━━━ $SELECTED / $FILE ━━━${NC}"
        echo ""
        cat "$TARGET_DIR/$FILE"
        echo ""
        echo -e "${YELLOW}━━━ END OF FILE ━━━${NC}"
    else
        echo -e "${RED}File not found!${NC}"
    fi
    
    pause
}

settings_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      PANEL & NODE SETTINGS                ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo -e "1) ${PURPLE}Connect Node to Core (Wizard)${NC}"
        echo "2) Edit Panel Config (.env)"
        echo "3) Edit Node Config (.env)"
        echo "4) Restart Main Panel"
        echo "5) Restart Node Service"
        echo -e "${CYAN}--- Node SSL ---${NC}"
        echo "6) Show Node SSL Paths"
        echo "7) View Node SSL Content"
        echo -e "${CYAN}----------------${NC}"
        echo "8) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " P_OPT
        case $P_OPT in
            1) connect_node_wizard ;;
            2) edit_file "$PANEL_ENV" ;;
            3) edit_file "$NODE_ENV" ;;
            4) restart_service "panel"; pause ;;
            5) restart_service "node"; pause ;;
            6) show_node_ssl ;;
            7) view_node_ssl_content ;;
            8) return ;;
            *) ;;
        esac
    done
}