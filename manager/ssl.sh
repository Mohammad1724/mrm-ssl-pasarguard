#!/bin/bash

# Load utils safely
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

_get_cert_action() {
    local EMAIL=$1
    shift
    local DOMAINS=("${@}")

    echo -e "${BLUE}Opening Port 80 temporarily...${NC}"
    # FIX: Check if UFW exists before using
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp > /dev/null 2>&1
    fi

    echo -e "${BLUE}Stopping web services...${NC}"
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
    # Kill any process on port 80 if fuser exists
    if command -v fuser &> /dev/null; then
        fuser -k 80/tcp 2>/dev/null
    fi

    # Build domain flags
    local DOM_FLAGS=""
    for D in "${DOMAINS[@]}"; do
        DOM_FLAGS="$DOM_FLAGS -d $D"
    done

    # Added --expand to fix the error
    certbot certonly --standalone --non-interactive --agree-tos --expand --email "$EMAIL" $DOM_FLAGS
    local CERTBOT_RESULT=$?

    systemctl start nginx 2>/dev/null

    if ! systemctl is-active --quiet nginx; then
        if command -v ufw &> /dev/null; then
             ufw delete allow 80/tcp > /dev/null 2>&1
        fi
    fi

    return $CERTBOT_RESULT
}

_process_panel() {
    local PRIMARY_DOM=$1
    echo -e "\n${CYAN}--- Configuring Panel SSL ---${NC}"

    echo "Where to save certificates?"
    echo "1) Default Path ($PANEL_DEF_CERTS/$PRIMARY_DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT

    local BASE_DIR="$PANEL_DEF_CERTS"
    if [[ "$PATH_OPT" == "2" ]]; then
        read -p "Enter Custom Base Directory: " BASE_DIR
    fi

    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        local C_FILE="$TARGET_DIR/fullchain.pem"
        local K_FILE="$TARGET_DIR/privkey.pem"
        
        # FIX: Secure Permissions
        chmod 644 "$C_FILE" "$K_FILE"

        if [ ! -f "$PANEL_ENV" ]; then touch "$PANEL_ENV"; fi

        echo -e "${BLUE}Cleaning up old config in .env...${NC}"
        sed -i '/UVICORN_SSL_CERTFILE/d' "$PANEL_ENV"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$PANEL_ENV"

        echo -e "${BLUE}Writing new SSL paths...${NC}"
        echo "UVICORN_SSL_CERTFILE = \"$C_FILE\"" >> "$PANEL_ENV"
        echo "UVICORN_SSL_KEYFILE = \"$K_FILE\"" >> "$PANEL_ENV"

        restart_service "panel"
        echo -e "${GREEN}✔ Panel SSL Updated.${NC}"
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
    else
        echo -e "${RED}Error copying files. (Certbot failed?)${NC}"
    fi
}

_process_node() {
    local PRIMARY_DOM=$1
    echo -e "\n${PURPLE}--- Configuring Node SSL ---${NC}"

    echo "Where to save certificates?"
    echo "1) Default Path ($NODE_DEF_CERTS/$PRIMARY_DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT

    local BASE_DIR="$NODE_DEF_CERTS"
    if [[ "$PATH_OPT" == "2" ]]; then
        read -p "Enter Custom Base Directory: " BASE_DIR
    fi

    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/server.crt" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/server.key"; then

        local C_FILE="$TARGET_DIR/server.crt"
        local K_FILE="$TARGET_DIR/server.key"
        
        chmod 644 "$C_FILE" "$K_FILE"

        if [ -f "$NODE_ENV" ]; then
            echo -e "${BLUE}Cleaning up Node config...${NC}"
            sed -i '/SSL_CERT_FILE/d' "$NODE_ENV"
            sed -i '/SSL_KEY_FILE/d' "$NODE_ENV"

            echo -e "${BLUE}Writing new SSL paths...${NC}"
            echo "SSL_CERT_FILE = \"$C_FILE\"" >> "$NODE_ENV"
            echo "SSL_KEY_FILE = \"$K_FILE\"" >> "$NODE_ENV"

            restart_service "node"
            echo -e "${GREEN}✔ Node SSL Updated.${NC}"
        else
            echo -e "${YELLOW}Node .env not found.${NC}"
        fi
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
    else
        echo -e "${RED}Error copying files.${NC}"
    fi
}

_process_config() {
    local PRIMARY_DOM=$1
    echo -e "\n${ORANGE}--- Config SSL (Inbounds) ---${NC}"

    local TARGET_DIR="$PANEL_DEF_CERTS/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        # FIX: Do not use 755 for everything, security risk.
        chmod 755 "$TARGET_DIR"
        chmod 644 "$TARGET_DIR"/*.pem

        echo -e "${GREEN}✔ Files Saved.${NC}"
        echo -e ""
        echo -e "${YELLOW}Copy these paths to your Inbound Settings:${NC}"
        echo -e "Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
        echo -e "Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
    else
        echo -e "${RED}Error copying files.${NC}"
    fi
}

ssl_wizard() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}         SSL GENERATION WIZARD  v1.0             ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    read -p "How many domains? (e.g. 1, 2): " COUNT
    if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
        echo -e "${RED}Invalid number.${NC}"
        pause; return
    fi

    declare -a DOMAIN_LIST
    for (( i=1; i<=COUNT; i++ )); do
        read -p "Enter Domain $i: " D_INPUT
        if [ -n "$D_INPUT" ]; then
            DOMAIN_LIST+=("$D_INPUT")
        else
            echo -e "${RED}Domain cannot be empty.${NC}"
            i=$((i-1))
        fi
    done

    if [ ${#DOMAIN_LIST[@]} -eq 0 ]; then return; fi

    read -p "Enter Email: " MAIL
    if [ -z "$MAIL" ]; then
        echo -e "${RED}Email is required.${NC}"
        pause; return
    fi

    local PRIMARY_DOM=${DOMAIN_LIST[0]}

    _get_cert_action "$MAIL" "${DOMAIN_LIST[@]}"
    local RES=$?

    if [ $RES -ne 0 ] || [ ! -d "/etc/letsencrypt/live/$PRIMARY_DOM" ]; then
        echo -e "${RED}✘ SSL Generation Failed!${NC}"
        pause
        return
    fi

    echo -e "${GREEN}✔ Success! Primary Domain: $PRIMARY_DOM${NC}"
    echo ""
    echo "Where to use this certificate?"
    echo "1) Main Panel (Dashboard)"
    echo "2) Node Server"
    echo "3) Config Domain (Inbounds)"
    read -p "Select: " TYPE_OPT

    case $TYPE_OPT in
        1) _process_panel "$PRIMARY_DOM" ;;
        2) _process_node "$PRIMARY_DOM" ;;
        3) _process_config "$PRIMARY_DOM" ;;
        *) echo -e "${RED}Invalid.${NC}";;
    esac

    pause
}

show_detailed_paths() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       EXISTING SSL PATHS                    ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    echo -e "${ORANGE}--- Panel & Config Domains ---${NC}"
    if [ -d "$PANEL_DEF_CERTS" ]; then
        local found=0
        for dir in "$PANEL_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                found=1
                dom=$(basename "$dir")
                echo -e "${GREEN}Domain: $dom${NC}"
                echo -e "  ${YELLOW}Fullchain:${NC} ${CYAN}$dir/fullchain.pem${NC}"
                echo -e "  ${YELLOW}Privkey:${NC}   ${CYAN}$dir/privkey.pem${NC}"
                echo "--------------------------------------------"
            fi
        done
        [ $found -eq 0 ] && echo "No certificates found."
    else
        echo "Directory not found."
    fi

    echo ""
    echo -e "${PURPLE}--- Node Domains ---${NC}"
    if [ -d "$NODE_DEF_CERTS" ]; then
        local found=0
        for dir in "$NODE_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                found=1
                dom=$(basename "$dir")
                echo -e "${GREEN}Domain: $dom${NC}"
                echo -e "  ${YELLOW}Cert:${NC}      ${CYAN}$dir/server.crt${NC}"
                echo -e "  ${YELLOW}Key:${NC}       ${CYAN}$dir/server.key${NC}"
                echo "--------------------------------------------"
            fi
        done
        [ $found -eq 0 ] && echo "No certificates found."
    else
        echo "Directory not found."
    fi

    echo ""
    pause
}

view_cert_content() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       VIEW CERTIFICATE FILES                ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    if [ ! -d "$PANEL_DEF_CERTS" ]; then
        echo -e "${RED}No certificates directory found at $PANEL_DEF_CERTS${NC}"
        pause
        return
    fi

    echo -e "${BLUE}Available Domains:${NC}"

    local i=1
    declare -a domains
    for dir in "$PANEL_DEF_CERTS"/*; do
        if [ -d "$dir" ]; then
            dom=$(basename "$dir")
            domains[$i]=$dom
            echo -e "${GREEN}$i)${NC} $dom"
            ((i++))
        fi
    done

    if [ $i -eq 1 ]; then
        echo "No domains found."
        pause
        return
    fi

    echo ""
    read -p "Select Number: " NUM
    local SELECTED_DOM=${domains[$NUM]}

    if [ -z "$SELECTED_DOM" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        pause
        return
    fi

    local TARGET_DIR="$PANEL_DEF_CERTS/$SELECTED_DOM"

    echo ""
    echo -e "Selected: ${CYAN}$SELECTED_DOM${NC}"
    echo "Which file?"
    echo "1) Fullchain (Public Key)"
    echo "2) Private Key"
    read -p "Select: " F_OPT

    local FILE=""
    local HEADER=""

    if [ "$F_OPT" == "1" ]; then 
        FILE="fullchain.pem"
        HEADER="FULLCHAIN / PUBLIC KEY"
    elif [ "$F_OPT" == "2" ]; then 
        FILE="privkey.pem"
        HEADER="PRIVATE KEY (Keep Secret)"
    else 
        return 
    fi

    if [ -f "$TARGET_DIR/$FILE" ]; then
        clear
        echo -e "${YELLOW}--- START OF $HEADER ---${NC}"
        echo -e "${GREEN}"
        cat "$TARGET_DIR/$FILE"
        echo -e "${NC}"
        echo -e "${YELLOW}--- END OF $HEADER ---${NC}"
        echo -e "\n(Select and copy the content above)"
    else
        echo -e "${RED}File $FILE not found in $TARGET_DIR${NC}"
    fi
    pause
}

ssl_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SSL MANAGEMENT                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Request New SSL (Multi-Domain Wizard)"
        echo "2) Show SSL File Paths"
        echo "3) View Certificate Files"
        echo "4) Domain List (LetsEncrypt)"
        echo "5) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " S_OPT
        case $S_OPT in
            1) ssl_wizard ;;
            2) show_detailed_paths ;;
            3) view_cert_content ;;
            4) ls -1 /etc/letsencrypt/live 2>/dev/null; pause ;;
            5) return ;;
            *) ;;
        esac
    done
}