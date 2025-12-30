#!/bin/bash

# Load utils safely
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# ==========================================
# CONFIGURATION - Panel Paths (CORRECTED)
# ==========================================
declare -A PANEL_PATHS=(
    ["marzban"]="/var/lib/marzban/certs"
    ["pasarguard"]="/var/lib/pasarguard/certs"
    ["rebecca"]="/var/lib/rebecca/certs"
)

declare -A PANEL_INSTALL_PATHS=(
    ["marzban"]="/opt/marzban"
    ["pasarguard"]="/opt/pasarguard"
    ["rebecca"]="/opt/Rebecca"
)

declare -A PANEL_ENV_FILES=(
    ["marzban"]="/opt/marzban/.env"
    ["pasarguard"]="/opt/pasarguard/.env"
    ["rebecca"]="/opt/Rebecca/.env"
)

declare -A NODE_PATHS=(
    ["marzban"]="/var/lib/marzban-node/certs"
    ["pasarguard"]="/var/lib/pasarguard-node/certs"
    ["rebecca"]="/var/lib/rebecca-node/certs"
)

declare -A NODE_INSTALL_PATHS=(
    ["marzban"]="/opt/marzban-node"
    ["pasarguard"]="/opt/pasarguard-node"
    ["rebecca"]="/opt/Rebecca-node"
)

declare -A NODE_ENV_FILES=(
    ["marzban"]="/opt/marzban-node/.env"
    ["pasarguard"]="/opt/pasarguard-node/.env"
    ["rebecca"]="/opt/Rebecca-node/.env"
)

# ==========================================
# LOGGING SYSTEM
# ==========================================
SSL_LOG_DIR="/var/log/ssl-manager"
SSL_LOG_FILE="$SSL_LOG_DIR/ssl-manager.log"
CERTBOT_DEBUG_LOG="/var/log/certbot_debug.log"

init_logging() {
    mkdir -p "$SSL_LOG_DIR"
    touch "$SSL_LOG_FILE"
    chmod 644 "$SSL_LOG_FILE"
}

log_message() {
    local LEVEL=$1
    local MESSAGE=$2
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] [$LEVEL] $MESSAGE" >> "$SSL_LOG_FILE"
}

log_info() { log_message "INFO" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_success() { log_message "SUCCESS" "$1"; }
log_warning() { log_message "WARNING" "$1"; }

# ==========================================
# PANEL DETECTION (AUTO-DETECT)
# ==========================================
detect_installed_panels() {
    local installed=()
    
    for panel in "marzban" "pasarguard" "rebecca"; do
        local install_path="${PANEL_INSTALL_PATHS[$panel]}"
        if [ -d "$install_path" ]; then
            installed+=("$panel")
        fi
    done
    
    echo "${installed[@]}"
}

# ==========================================
# PANEL SELECTION
# ==========================================
SELECTED_PANEL=""

select_panel() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       SELECT YOUR PANEL                     ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    # Auto-detect installed panels
    local installed_panels=($(detect_installed_panels))
    
    if [ ${#installed_panels[@]} -gt 0 ]; then
        echo -e "${GREEN}Detected installed panels:${NC}"
        for p in "${installed_panels[@]}"; do
            echo -e "  ✔ $p"
        done
        echo ""
    fi
    
    echo "1) Marzban"
    echo "2) Pasarguard"
    echo "3) Rebecca"
    echo "4) Custom Path"
    echo ""
    read -p "Select Panel: " PANEL_OPT

    case $PANEL_OPT in
        1) SELECTED_PANEL="marzban" ;;
        2) SELECTED_PANEL="pasarguard" ;;
        3) SELECTED_PANEL="rebecca" ;;
        4) SELECTED_PANEL="custom" ;;
        *) 
            echo -e "${RED}Invalid selection.${NC}"
            pause
            return 1
            ;;
    esac

    # Verify panel exists
    if [ "$SELECTED_PANEL" != "custom" ]; then
        local install_path="${PANEL_INSTALL_PATHS[$SELECTED_PANEL]}"
        if [ ! -d "$install_path" ]; then
            echo -e "${YELLOW}⚠ Warning: $SELECTED_PANEL not found at $install_path${NC}"
            read -p "Continue anyway? (y/N): " CONT
            if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi

    log_info "Panel selected: $SELECTED_PANEL"
    echo -e "${GREEN}✔ Selected: $SELECTED_PANEL${NC}"
    sleep 1
    return 0
}

get_panel_cert_path() {
    if [ "$SELECTED_PANEL" == "custom" ]; then
        read -p "Enter custom certificate path: " CUSTOM_PATH
        echo "$CUSTOM_PATH"
    else
        echo "${PANEL_PATHS[$SELECTED_PANEL]}"
    fi
}

get_panel_env_file() {
    if [ "$SELECTED_PANEL" == "custom" ]; then
        read -p "Enter custom .env file path: " CUSTOM_ENV
        echo "$CUSTOM_ENV"
    else
        echo "${PANEL_ENV_FILES[$SELECTED_PANEL]}"
    fi
}

get_panel_install_path() {
    if [ "$SELECTED_PANEL" == "custom" ]; then
        read -p "Enter custom install path: " CUSTOM_PATH
        echo "$CUSTOM_PATH"
    else
        echo "${PANEL_INSTALL_PATHS[$SELECTED_PANEL]}"
    fi
}

get_node_cert_path() {
    if [ "$SELECTED_PANEL" == "custom" ]; then
        read -p "Enter custom node certificate path: " CUSTOM_PATH
        echo "$CUSTOM_PATH"
    else
        echo "${NODE_PATHS[$SELECTED_PANEL]}"
    fi
}

get_node_env_file() {
    if [ "$SELECTED_PANEL" == "custom" ]; then
        read -p "Enter custom node .env file path: " CUSTOM_ENV
        echo "$CUSTOM_ENV"
    else
        echo "${NODE_ENV_FILES[$SELECTED_PANEL]}"
    fi
}

get_node_install_path() {
    if [ "$SELECTED_PANEL" == "custom" ]; then
        read -p "Enter custom node install path: " CUSTOM_PATH
        echo "$CUSTOM_PATH"
    else
        echo "${NODE_INSTALL_PATHS[$SELECTED_PANEL]}"
    fi
}

# ==========================================
# DNS & IP VALIDATION
# ==========================================
validate_domain_dns() {
    local DOMAIN=$1
    local SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)
    local DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | head -1)

    echo -e "${YELLOW}[DNS Check] Validating domain: $DOMAIN${NC}"
    log_info "DNS Check - Domain: $DOMAIN, Server IP: $SERVER_IP, Domain IP: $DOMAIN_IP"

    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}✘ Error: Cannot resolve domain $DOMAIN${NC}"
        echo -e "${YELLOW}  Make sure DNS record exists for this domain.${NC}"
        log_error "DNS resolution failed for $DOMAIN"
        return 1
    fi

    if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              ⚠️  DNS MISMATCH WARNING  ⚠️                 ║${NC}"
        echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║${NC}  Domain IP:  ${YELLOW}$DOMAIN_IP${NC}"
        echo -e "${RED}║${NC}  Server IP:  ${YELLOW}$SERVER_IP${NC}"
        echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║  SSL generation will likely FAIL!                        ║${NC}"
        echo -e "${RED}║  Fix your DNS records first.                             ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        log_warning "DNS mismatch - Domain: $DOMAIN points to $DOMAIN_IP but server is $SERVER_IP"
        
        echo ""
        read -p "Continue anyway? (y/N): " CONTINUE_ANYWAY
        if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
            return 1
        fi
        log_warning "User chose to continue despite DNS mismatch"
    else
        echo -e "${GREEN}✔ DNS OK: $DOMAIN → $DOMAIN_IP${NC}"
        log_info "DNS validation passed for $DOMAIN"
    fi

    return 0
}

# ==========================================
# PORT CHECK
# ==========================================
check_port_availability() {
    local PORT=$1
    if ss -tlnp | grep -q ":$PORT "; then
        local SERVICE=$(ss -tlnp | grep ":$PORT " | awk '{print $NF}')
        echo -e "${YELLOW}⚠ Port $PORT is in use by: $SERVICE${NC}"
        log_warning "Port $PORT is in use by $SERVICE"
        return 1
    fi
    return 0
}

# ==========================================
# MAIN CERTIFICATE FUNCTION
# ==========================================
_get_cert_action() {
    local EMAIL=$1
    shift
    local DOMAINS=("${@}")

    init_logging
    log_info "========== SSL Generation Started =========="
    log_info "Email: $EMAIL"
    log_info "Domains: ${DOMAINS[*]}"
    log_info "Panel: $SELECTED_PANEL"

    echo -e "${YELLOW}[Step 1/6] Network & DNS Validation...${NC}"
    
    # Check internet connectivity to Let's Encrypt API
    if ! curl -s --connect-timeout 15 https://acme-v02.api.letsencrypt.org/directory > /dev/null; then
        echo -e "${RED}✘ Error: Let's Encrypt API is unreachable. Check your internet/firewall!${NC}"
        log_error "Let's Encrypt API unreachable"
        return 1
    fi
    log_info "Let's Encrypt API is reachable"

    # Validate DNS for all domains
    echo -e "${YELLOW}[Step 2/6] DNS Validation for all domains...${NC}"
    for D in "${DOMAINS[@]}"; do
        if ! validate_domain_dns "$D"; then
            log_error "DNS validation failed for $D"
            return 1
        fi
    done

    echo -e "${YELLOW}[Step 3/6] Preparing Firewall (Port 80 & 443)...${NC}"
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp > /dev/null 2>&1
        ufw allow 443/tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        log_info "Firewall configured for ports 80 and 443"
    fi

    echo -e "${YELLOW}[Step 4/6] Stopping conflicting services...${NC}"
    
    # Store service states for restoration
    local NGINX_WAS_RUNNING=false
    local APACHE_WAS_RUNNING=false
    
    if systemctl is-active --quiet nginx; then
        NGINX_WAS_RUNNING=true
        systemctl stop nginx 2>/dev/null
        log_info "Stopped nginx"
    fi
    
    if systemctl is-active --quiet apache2; then
        APACHE_WAS_RUNNING=true
        systemctl stop apache2 2>/dev/null
        log_info "Stopped apache2"
    fi
    
    if command -v fuser &> /dev/null; then
        fuser -k 80/tcp 2>/dev/null
    fi
    
    # Verify port 80 is free
    sleep 2
    if ! check_port_availability 80; then
        echo -e "${RED}✘ Error: Port 80 is still in use!${NC}"
        log_error "Port 80 still in use after stopping services"
        # Try to restore services before failing
        [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null
        return 1
    fi
    echo -e "${GREEN}✔ Port 80 is available${NC}"

    # Build domain flags
    local DOM_FLAGS=""
    for D in "${DOMAINS[@]}"; do
        DOM_FLAGS="$DOM_FLAGS -d $D"
    done

    echo -e "${YELLOW}[Step 5/6] Requesting Certificate from Let's Encrypt...${NC}"
    echo -e "${CYAN}Info: This may take up to 2 minutes. Please wait...${NC}"
    log_info "Running certbot with domains: $DOM_FLAGS"

    # Run certbot with debug logging
    certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        --preferred-challenges http \
        --http-01-port 80 \
        $DOM_FLAGS > "$CERTBOT_DEBUG_LOG" 2>&1
    
    local CERTBOT_RESULT=$?

    echo -e "${YELLOW}[Step 6/6] Restoring Services...${NC}"
    
    if [ "$NGINX_WAS_RUNNING" = true ]; then
        systemctl start nginx 2>/dev/null
        log_info "Restored nginx"
    fi
    
    if [ "$APACHE_WAS_RUNNING" = true ]; then
        systemctl start apache2 2>/dev/null
        log_info "Restored apache2"
    fi

    if [ $CERTBOT_RESULT -eq 0 ]; then
        echo -e "${GREEN}✔ SSL Generation Successful!${NC}"
        log_success "SSL certificate generated successfully for ${DOMAINS[*]}"
    else
        echo -e "${RED}✘ SSL Generation Failed!${NC}"
        echo -e "${YELLOW}Last 15 lines of debug log:${NC}"
        echo -e "${CYAN}----------------------------------------${NC}"
        tail -n 15 "$CERTBOT_DEBUG_LOG"
        echo -e "${CYAN}----------------------------------------${NC}"
        
        log_error "Certbot failed with exit code $CERTBOT_RESULT"
        log_error "Certbot output: $(cat $CERTBOT_DEBUG_LOG)"
    fi

    return $CERTBOT_RESULT
}

# ==========================================
# RESTART PANEL SERVICE
# ==========================================
restart_panel_service() {
    local INSTALL_PATH=$(get_panel_install_path)
    
    echo -e "${BLUE}Restarting $SELECTED_PANEL service...${NC}"
    log_info "Restarting $SELECTED_PANEL at $INSTALL_PATH"
    
    if [ -f "$INSTALL_PATH/docker-compose.yml" ] || [ -f "$INSTALL_PATH/docker-compose.yaml" ]; then
        cd "$INSTALL_PATH" && docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null
    else
        systemctl restart "$SELECTED_PANEL" 2>/dev/null
    fi
}

restart_node_service() {
    local INSTALL_PATH=$(get_node_install_path)
    
    echo -e "${BLUE}Restarting $SELECTED_PANEL node service...${NC}"
    log_info "Restarting $SELECTED_PANEL node at $INSTALL_PATH"
    
    if [ -f "$INSTALL_PATH/docker-compose.yml" ] || [ -f "$INSTALL_PATH/docker-compose.yaml" ]; then
        cd "$INSTALL_PATH" && docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null
    else
        systemctl restart "$SELECTED_PANEL-node" 2>/dev/null
    fi
}

# ==========================================
# PROCESS PANEL SSL
# ==========================================
_process_panel() {
    local PRIMARY_DOM=$1
    echo -e "\n${CYAN}--- Configuring Panel SSL ($SELECTED_PANEL) ---${NC}"

    local BASE_DIR=$(get_panel_cert_path)
    local ENV_FILE=$(get_panel_env_file)

    echo "Certificate storage options:"
    echo "1) Default Path ($BASE_DIR/$PRIMARY_DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT

    if [[ "$PATH_OPT" == "2" ]]; then
        read -p "Enter Custom Base Directory: " BASE_DIR
    fi

    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    log_info "Copying certificates to $TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        local C_FILE="$TARGET_DIR/fullchain.pem"
        local K_FILE="$TARGET_DIR/privkey.pem"

        chmod 644 "$C_FILE" "$K_FILE"

        if [ ! -f "$ENV_FILE" ]; then 
            touch "$ENV_FILE"
            log_warning ".env file created at $ENV_FILE"
        fi

        echo -e "${BLUE}Cleaning up old config in .env...${NC}"
        sed -i '/UVICORN_SSL_CERTFILE/d' "$ENV_FILE"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$ENV_FILE"

        echo -e "${BLUE}Writing new SSL paths...${NC}"
        echo "UVICORN_SSL_CERTFILE = \"$C_FILE\"" >> "$ENV_FILE"
        echo "UVICORN_SSL_KEYFILE = \"$K_FILE\"" >> "$ENV_FILE"

        # Restart the appropriate service
        if [ "$SELECTED_PANEL" != "custom" ]; then
            restart_panel_service
        fi

        echo -e "${GREEN}✔ Panel SSL Updated Successfully!${NC}"
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
        echo -e "Certificate: ${CYAN}$C_FILE${NC}"
        echo -e "Private Key: ${CYAN}$K_FILE${NC}"
        
        log_success "Panel SSL configured - Cert: $C_FILE, Key: $K_FILE"
    else
        echo -e "${RED}Error copying certificate files!${NC}"
        log_error "Failed to copy certificate files to $TARGET_DIR"
    fi
}

# ==========================================
# PROCESS NODE SSL
# ==========================================
_process_node() {
    local PRIMARY_DOM=$1
    echo -e "\n${PURPLE}--- Configuring Node SSL ($SELECTED_PANEL) ---${NC}"

    local BASE_DIR=$(get_node_cert_path)
    local ENV_FILE=$(get_node_env_file)

    echo "Certificate storage options:"
    echo "1) Default Path ($BASE_DIR/$PRIMARY_DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT

    if [[ "$PATH_OPT" == "2" ]]; then
        read -p "Enter Custom Base Directory: " BASE_DIR
    fi

    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    log_info "Copying node certificates to $TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/server.crt" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/server.key"; then

        local C_FILE="$TARGET_DIR/server.crt"
        local K_FILE="$TARGET_DIR/server.key"

        chmod 644 "$C_FILE" "$K_FILE"

        if [ -f "$ENV_FILE" ]; then
            echo -e "${BLUE}Cleaning up Node config...${NC}"
            sed -i '/SSL_CERT_FILE/d' "$ENV_FILE"
            sed -i '/SSL_KEY_FILE/d' "$ENV_FILE"

            echo -e "${BLUE}Writing new SSL paths...${NC}"
            echo "SSL_CERT_FILE = \"$C_FILE\"" >> "$ENV_FILE"
            echo "SSL_KEY_FILE = \"$K_FILE\"" >> "$ENV_FILE"

            # Restart node service
            if [ "$SELECTED_PANEL" != "custom" ]; then
                restart_node_service
            fi

            echo -e "${GREEN}✔ Node SSL Updated Successfully!${NC}"
            log_success "Node SSL configured - Cert: $C_FILE, Key: $K_FILE"
        else
            echo -e "${YELLOW}Node .env not found at $ENV_FILE${NC}"
            echo -e "${YELLOW}Please manually configure SSL paths.${NC}"
            log_warning "Node .env not found at $ENV_FILE"
        fi
        
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
        echo -e "Certificate: ${CYAN}$C_FILE${NC}"
        echo -e "Private Key: ${CYAN}$K_FILE${NC}"
    else
        echo -e "${RED}Error copying certificate files!${NC}"
        log_error "Failed to copy node certificate files to $TARGET_DIR"
    fi
}

# ==========================================
# PROCESS CONFIG SSL (INBOUNDS)
# ==========================================
_process_config() {
    local PRIMARY_DOM=$1
    echo -e "\n${ORANGE}--- Config SSL (Inbounds) ---${NC}"

    local BASE_DIR=$(get_panel_cert_path)
    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    log_info "Copying inbound certificates to $TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        chmod 755 "$TARGET_DIR"
        chmod 644 "$TARGET_DIR"/*.pem

        echo -e "${GREEN}✔ Files Saved Successfully!${NC}"
        echo -e ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║         Copy these paths to your Inbound Settings:       ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC} Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
        echo -e "${YELLOW}║${NC} Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        
        log_success "Inbound SSL configured - Path: $TARGET_DIR"
    else
        echo -e "${RED}Error copying certificate files!${NC}"
        log_error "Failed to copy inbound certificate files to $TARGET_DIR"
    fi
}

# ==========================================
# SSL WIZARD (MAIN FUNCTION)
# ==========================================
ssl_wizard() {
    clear
    init_logging
    
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       SSL GENERATION WIZARD  v2.0          ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    # Step 1: Select Panel
    if ! select_panel; then
        return
    fi

    # Step 2: Get domains
    echo ""
    read -p "How many domains? (e.g. 1, 2): " COUNT
    if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
        echo -e "${RED}Invalid number.${NC}"
        log_error "Invalid domain count entered: $COUNT"
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

    if [ ${#DOMAIN_LIST[@]} -eq 0 ]; then 
        log_error "No domains entered"
        return
    fi

    # Step 3: Get email
    read -p "Enter Email: " MAIL
    if [ -z "$MAIL" ]; then
        echo -e "${RED}Email is required.${NC}"
        log_error "No email entered"
        pause; return
    fi

    local PRIMARY_DOM=${DOMAIN_LIST[0]}

    # Step 4: Get certificate
    _get_cert_action "$MAIL" "${DOMAIN_LIST[@]}"
    local RES=$?

    if [ $RES -ne 0 ] || [ ! -d "/etc/letsencrypt/live/$PRIMARY_DOM" ]; then
        echo -e "${RED}✘ SSL Generation Failed!${NC}"
        echo -e "${YELLOW}Check logs: $SSL_LOG_FILE${NC}"
        echo -e "${YELLOW}Certbot log: $CERTBOT_DEBUG_LOG${NC}"
        pause
        return
    fi

    echo -e "${GREEN}✔ Success! Primary Domain: $PRIMARY_DOM${NC}"
    echo ""
    
    # Step 5: Configure usage
    echo "Where to use this certificate?"
    echo "1) Main Panel (Dashboard)"
    echo "2) Node Server"
    echo "3) Config Domain (Inbounds)"
    echo "4) All of the above"
    read -p "Select: " TYPE_OPT

    case $TYPE_OPT in
        1) _process_panel "$PRIMARY_DOM" ;;
        2) _process_node "$PRIMARY_DOM" ;;
        3) _process_config "$PRIMARY_DOM" ;;
        4) 
            _process_panel "$PRIMARY_DOM"
            _process_node "$PRIMARY_DOM"
            _process_config "$PRIMARY_DOM"
            ;;
        *) echo -e "${RED}Invalid selection.${NC}";;
    esac

    log_info "========== SSL Generation Completed =========="
    pause
}

# ==========================================
# SHOW EXISTING SSL PATHS
# ==========================================
show_detailed_paths() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       EXISTING SSL PATHS                    ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    for panel in "marzban" "pasarguard" "rebecca"; do
        local CERT_PATH="${PANEL_PATHS[$panel]}"
        local NODE_PATH="${NODE_PATHS[$panel]}"
        
        if [ -d "$CERT_PATH" ] && [ "$(ls -A $CERT_PATH 2>/dev/null)" ]; then
            echo -e "\n${GREEN}━━━ ${panel^^} Panel ━━━${NC}"
            for dir in "$CERT_PATH"/*; do
                if [ -d "$dir" ]; then
                    dom=$(basename "$dir")
                    echo -e "  ${YELLOW}Domain:${NC} $dom"
                    [ -f "$dir/fullchain.pem" ] && echo -e "    Cert: ${CYAN}$dir/fullchain.pem${NC}"
                    [ -f "$dir/privkey.pem" ] && echo -e "    Key:  ${CYAN}$dir/privkey.pem${NC}"
                fi
            done
        fi
        
        if [ -d "$NODE_PATH" ] && [ "$(ls -A $NODE_PATH 2>/dev/null)" ]; then
            echo -e "\n${PURPLE}━━━ ${panel^^} Node ━━━${NC}"
            for dir in "$NODE_PATH"/*; do
                if [ -d "$dir" ]; then
                    dom=$(basename "$dir")
                    echo -e "  ${YELLOW}Domain:${NC} $dom"
                    [ -f "$dir/server.crt" ] && echo -e "    Cert: ${CYAN}$dir/server.crt${NC}"
                    [ -f "$dir/server.key" ] && echo -e "    Key:  ${CYAN}$dir/server.key${NC}"
                fi
            done
        fi
    done

    echo ""
    pause
}

# ==========================================
# VIEW CERTIFICATE CONTENT
# ==========================================
view_cert_content() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       VIEW CERTIFICATE FILES                ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    declare -a all_certs
    local idx=1

    for panel in "marzban" "pasarguard" "rebecca"; do
        local CERT_PATH="${PANEL_PATHS[$panel]}"
        if [ -d "$CERT_PATH" ]; then
            for dir in "$CERT_PATH"/*; do
                if [ -d "$dir" ]; then
                    dom=$(basename "$dir")
                    all_certs[$idx]="$dir"
                    echo -e "${GREEN}$idx)${NC} [${panel}] $dom"
                    ((idx++))
                fi
            done
        fi
    done

    if [ $idx -eq 1 ]; then
        echo "No certificates found."
        pause
        return
    fi

    echo ""
    read -p "Select Number: " NUM
    local SELECTED_DIR=${all_certs[$NUM]}

    if [ -z "$SELECTED_DIR" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        pause
        return
    fi

    echo ""
    echo -e "Selected: ${CYAN}$SELECTED_DIR${NC}"
    echo "Which file?"
    echo "1) Fullchain / Certificate"
    echo "2) Private Key"
    read -p "Select: " F_OPT

    local FILE=""
    local HEADER=""

    if [ "$F_OPT" == "1" ]; then 
        [ -f "$SELECTED_DIR/fullchain.pem" ] && FILE="fullchain.pem"
        [ -f "$SELECTED_DIR/server.crt" ] && FILE="server.crt"
        HEADER="CERTIFICATE / PUBLIC KEY"
    elif [ "$F_OPT" == "2" ]; then 
        [ -f "$SELECTED_DIR/privkey.pem" ] && FILE="privkey.pem"
        [ -f "$SELECTED_DIR/server.key" ] && FILE="server.key"
        HEADER="PRIVATE KEY (Keep Secret)"
    else 
        return 
    fi

    if [ -n "$FILE" ] && [ -f "$SELECTED_DIR/$FILE" ]; then
        clear
        echo -e "${YELLOW}--- START OF $HEADER ---${NC}"
        echo -ne "${GREEN}"
        cat "$SELECTED_DIR/$FILE"
        echo -e "${NC}"
        echo -e "${YELLOW}--- END OF $HEADER ---${NC}"
        echo -e "\n(Select and copy the content above)"
    else
        echo -e "${RED}File not found in $SELECTED_DIR${NC}"
    fi
    pause
}

# ==========================================
# VIEW LOGS
# ==========================================
view_ssl_logs() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       SSL MANAGER LOGS                      ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo "1) View SSL Manager Log (Last 50 lines)"
    echo "2) View Certbot Debug Log (Last 50 lines)"
    echo "3) View Full SSL Manager Log"
    echo "4) View Full Certbot Log"
    echo "5) Clear All Logs"
    echo "6) Export Logs to File"
    echo "7) Back"
    echo ""
    read -p "Select: " LOG_OPT

    case $LOG_OPT in
        1)
            if [ -f "$SSL_LOG_FILE" ]; then
                echo -e "\n${YELLOW}--- Last 50 lines of SSL Manager Log ---${NC}"
                tail -n 50 "$SSL_LOG_FILE"
            else
                echo -e "${RED}Log file not found.${NC}"
            fi
            ;;
        2)
            if [ -f "$CERTBOT_DEBUG_LOG" ]; then
                echo -e "\n${YELLOW}--- Last 50 lines of Certbot Debug Log ---${NC}"
                tail -n 50 "$CERTBOT_DEBUG_LOG"
            else
                echo -e "${RED}Certbot log file not found.${NC}"
            fi
            ;;
        3)
            if [ -f "$SSL_LOG_FILE" ]; then
                less "$SSL_LOG_FILE"
            else
                echo -e "${RED}Log file not found.${NC}"
            fi
            ;;
        4)
            if [ -f "$CERTBOT_DEBUG_LOG" ]; then
                less "$CERTBOT_DEBUG_LOG"
            else
                echo -e "${RED}Certbot log file not found.${NC}"
            fi
            ;;
        5)
            read -p "Are you sure you want to clear all logs? (y/N): " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                > "$SSL_LOG_FILE" 2>/dev/null
                > "$CERTBOT_DEBUG_LOG" 2>/dev/null
                echo -e "${GREEN}✔ Logs cleared.${NC}"
            fi
            ;;
        6)
            local EXPORT_FILE="/root/ssl-logs-$(date '+%Y%m%d-%H%M%S').txt"
            {
                echo "========== SSL Manager Log =========="
                cat "$SSL_LOG_FILE" 2>/dev/null || echo "No log file found"
                echo ""
                echo "========== Certbot Debug Log =========="
                cat "$CERTBOT_DEBUG_LOG" 2>/dev/null || echo "No log file found"
            } > "$EXPORT_FILE"
            echo -e "${GREEN}✔ Logs exported to: $EXPORT_FILE${NC}"
            ;;
        7) return ;;
    esac
    pause
}

# ==========================================
# CERTIFICATE INFO
# ==========================================
show_cert_info() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       CERTIFICATE INFORMATION               ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ ! -d "/etc/letsencrypt/live" ]; then
        echo -e "${RED}No Let's Encrypt certificates found.${NC}"
        pause
        return
    fi

    for dir in /etc/letsencrypt/live/*/; do
        if [ -d "$dir" ]; then
            local domain=$(basename "$dir")
            [ "$domain" == "README" ] && continue
            
            local cert_file="$dir/fullchain.pem"
            if [ -f "$cert_file" ]; then
                echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${YELLOW}Domain:${NC} $domain"
                
                local expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                local now_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                
                echo -e "${YELLOW}Expires:${NC} $expiry"
                
                if [ $days_left -lt 0 ]; then
                    echo -e "${RED}Status: EXPIRED! ❌${NC}"
                elif [ $days_left -lt 7 ]; then
                    echo -e "${RED}Days Left: $days_left ⚠️ EXPIRES SOON!${NC}"
                elif [ $days_left -lt 30 ]; then
                    echo -e "${YELLOW}Days Left: $days_left${NC}"
                else
                    echo -e "${GREEN}Days Left: $days_left ✔${NC}"
                fi
                
                local issuer=$(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | sed 's/issuer=//')
                echo -e "${YELLOW}Issuer:${NC} $issuer"
                echo ""
            fi
        fi
    done
    pause
}

# ==========================================
# RENEW CERTIFICATES
# ==========================================
renew_certificates() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       RENEW SSL CERTIFICATES                ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    init_logging
    log_info "Starting certificate renewal"

    echo -e "${YELLOW}Stopping web services...${NC}"
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null

    echo -e "${YELLOW}Renewing certificates...${NC}"
    certbot renew --standalone > "$CERTBOT_DEBUG_LOG" 2>&1
    local RESULT=$?

    echo -e "${YELLOW}Starting web services...${NC}"
    systemctl start nginx 2>/dev/null

    if [ $RESULT -eq 0 ]; then
        echo -e "${GREEN}✔ Certificate renewal completed!${NC}"
        log_success "Certificate renewal completed"
        
        # Ask if user wants to update panel certificates
        echo ""
        read -p "Update panel certificates with renewed files? (y/N): " UPDATE_PANEL
        if [[ "$UPDATE_PANEL" =~ ^[Yy]$ ]]; then
            select_panel
            # Copy renewed certs to panel locations
            for dir in /etc/letsencrypt/live/*/; do
                local domain=$(basename "$dir")
                [ "$domain" == "README" ] && continue
                
                local TARGET_DIR="$(get_panel_cert_path)/$domain"
                if [ -d "$TARGET_DIR" ]; then
                    cp -L "$dir/fullchain.pem" "$TARGET_DIR/" 2>/dev/null
                    cp -L "$dir/privkey.pem" "$TARGET_DIR/" 2>/dev/null
                    echo -e "${GREEN}✔ Updated: $domain${NC}"
                fi
            done
            restart_panel_service
        fi
    else
        echo -e "${RED}✘ Certificate renewal failed!${NC}"
        echo -e "${YELLOW}Check log: $CERTBOT_DEBUG_LOG${NC}"
        log_error "Certificate renewal failed"
        tail -n 20 "$CERTBOT_DEBUG_LOG"
    fi
    
    pause
}

# ==========================================
# REVOKE CERTIFICATE (NEW)
# ==========================================
revoke_certificate() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}       REVOKE SSL CERTIFICATE                ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    if [ ! -d "/etc/letsencrypt/live" ]; then
        echo -e "${RED}No certificates found.${NC}"
        pause
        return
    fi

    echo -e "${YELLOW}Available certificates:${NC}"
    local idx=1
    declare -a certs
    
    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        certs[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done

    if [ $idx -eq 1 ]; then
        echo "No certificates found."
        pause
        return
    fi

    echo ""
    read -p "Select certificate to revoke (or 0 to cancel): " SEL
    
    if [ "$SEL" == "0" ]; then
        return
    fi

    local DOMAIN=${certs[$SEL]}
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        pause
        return
    fi

    echo -e "${RED}⚠️ WARNING: This will permanently revoke the certificate for $DOMAIN${NC}"
    read -p "Are you sure? Type 'yes' to confirm: " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        certbot revoke --cert-path "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" --non-interactive
        certbot delete --cert-name "$DOMAIN" --non-interactive
        echo -e "${GREEN}✔ Certificate revoked and deleted.${NC}"
        log_info "Certificate revoked for $DOMAIN"
    else
        echo "Cancelled."
    fi
    
    pause
}

# ==========================================
# MAIN SSL MENU
# ==========================================
ssl_menu() {
    init_logging
    
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      SSL MANAGEMENT v2.0                  ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo ""
        echo "1) 🔐 Request New SSL Certificate"
        echo "2) 📁 Show SSL File Paths"
        echo "3) 📄 View Certificate Content"
        echo "4) ℹ️  Certificate Information & Expiry"
        echo "5) 🔄 Renew All Certificates"
        echo "6) 🗑️  Revoke Certificate"
        echo "7) 📋 View Logs"
        echo "8) 📜 Domain List (Let's Encrypt)"
        echo "9) ↩️  Back"
        echo ""
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " S_OPT
        
        case $S_OPT in
            1) ssl_wizard ;;
            2) show_detailed_paths ;;
            3) view_cert_content ;;
            4) show_cert_info ;;
            5) renew_certificates ;;
            6) revoke_certificate ;;
            7) view_ssl_logs ;;
            8) 
                echo ""
                ls -1 /etc/letsencrypt/live 2>/dev/null || echo "No certificates found."
                pause 
                ;;
            9) return ;;
            *) ;;
        esac
    done
}