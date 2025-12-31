#!/bin/bash

# ==========================================
# SSL MANAGEMENT MODULE v2.1
# Compatible with MRM Manager
# ==========================================

# Load utils if not already loaded
if [ -z "$PANEL_DIR" ]; then 
    source /opt/mrm-manager/utils.sh
    source /opt/mrm-manager/ui.sh
fi

# ==========================================
# LOGGING SYSTEM
# ==========================================
SSL_LOG_DIR="/var/log/ssl-manager"
SSL_LOG_FILE="$SSL_LOG_DIR/ssl-manager.log"
CERTBOT_DEBUG_LOG="/var/log/certbot_debug.log"
SERVERS_FILE="/opt/mrm-manager/ssl-servers.conf"

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
# DNS & IP VALIDATION
# ==========================================
validate_domain_dns() {
    local DOMAIN=$1
    local SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)
    local DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | head -1)

    echo -e "${YELLOW}[DNS Check] Validating domain: $DOMAIN${NC}"
    log_info "DNS Check - Domain: $DOMAIN, Server IP: $SERVER_IP, Domain IP: $DOMAIN_IP"

    if [ -z "$DOMAIN_IP" ]; then
        ui_error "Cannot resolve domain $DOMAIN"
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
        ui_success "DNS OK: $DOMAIN → $DOMAIN_IP"
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
        ui_warning "Port $PORT is in use by: $SERVICE"
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
    detect_active_panel > /dev/null
    
    log_info "========== SSL Generation Started =========="
    log_info "Email: $EMAIL"
    log_info "Domains: ${DOMAINS[*]}"
    log_info "Active Panel: $(detect_active_panel)"

    echo -e "${YELLOW}[Step 1/6] Network & DNS Validation...${NC}"
    
    # Check internet connectivity to Let's Encrypt API
    if ! curl -s --connect-timeout 15 https://acme-v02.api.letsencrypt.org/directory > /dev/null; then
        ui_error "Let's Encrypt API is unreachable. Check your internet/firewall!"
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
        ui_error "Port 80 is still in use!"
        log_error "Port 80 still in use after stopping services"
        [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null
        return 1
    fi
    ui_success "Port 80 is available"

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
        ui_success "SSL Generation Successful!"
        log_success "SSL certificate generated successfully for ${DOMAINS[*]}"
    else
        ui_error "SSL Generation Failed!"
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
# PROCESS PANEL SSL
# ==========================================
_process_panel() {
    local PRIMARY_DOM=$1
    detect_active_panel > /dev/null
    
    echo -e "\n${CYAN}--- Configuring Panel SSL ($(basename $PANEL_DIR)) ---${NC}"

    echo "Certificate storage options:"
    echo "1) Default Path ($PANEL_DEF_CERTS/$PRIMARY_DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT

    local BASE_DIR="$PANEL_DEF_CERTS"
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

        if [ ! -f "$PANEL_ENV" ]; then 
            touch "$PANEL_ENV"
            log_warning ".env file created at $PANEL_ENV"
        fi

        echo -e "${BLUE}Cleaning up old config in .env...${NC}"
        sed -i '/UVICORN_SSL_CERTFILE/d' "$PANEL_ENV"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$PANEL_ENV"

        echo -e "${BLUE}Writing new SSL paths...${NC}"
        echo "UVICORN_SSL_CERTFILE = \"$C_FILE\"" >> "$PANEL_ENV"
        echo "UVICORN_SSL_KEYFILE = \"$K_FILE\"" >> "$PANEL_ENV"

        restart_service "panel"

        ui_success "Panel SSL Updated Successfully!"
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
        echo -e "Certificate: ${CYAN}$C_FILE${NC}"
        echo -e "Private Key: ${CYAN}$K_FILE${NC}"
        
        log_success "Panel SSL configured - Cert: $C_FILE, Key: $K_FILE"
    else
        ui_error "Error copying certificate files!"
        log_error "Failed to copy certificate files to $TARGET_DIR"
    fi
}

# ==========================================
# PROCESS NODE SSL
# ==========================================
_process_node() {
    local PRIMARY_DOM=$1
    echo -e "\n${PURPLE}--- Configuring Node SSL ---${NC}"

    echo "Certificate storage options:"
    echo "1) Default Path ($NODE_DEF_CERTS/$PRIMARY_DOM)"
    echo "2) Custom Path"
    read -p "Select: " PATH_OPT

    local BASE_DIR="$NODE_DEF_CERTS"
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

        if [ -f "$NODE_ENV" ]; then
            echo -e "${BLUE}Cleaning up Node config...${NC}"
            sed -i '/SSL_CERT_FILE/d' "$NODE_ENV"
            sed -i '/SSL_KEY_FILE/d' "$NODE_ENV"

            echo -e "${BLUE}Writing new SSL paths...${NC}"
            echo "SSL_CERT_FILE = \"$C_FILE\"" >> "$NODE_ENV"
            echo "SSL_KEY_FILE = \"$K_FILE\"" >> "$NODE_ENV"

            restart_service "node"

            ui_success "Node SSL Updated Successfully!"
            log_success "Node SSL configured - Cert: $C_FILE, Key: $K_FILE"
        else
            ui_warning "Node .env not found at $NODE_ENV"
            echo -e "${YELLOW}Please manually configure SSL paths.${NC}"
            log_warning "Node .env not found at $NODE_ENV"
        fi
        
        echo -e "Files saved in: ${YELLOW}$TARGET_DIR${NC}"
        echo -e "Certificate: ${CYAN}$C_FILE${NC}"
        echo -e "Private Key: ${CYAN}$K_FILE${NC}"
    else
        ui_error "Error copying certificate files!"
        log_error "Failed to copy node certificate files to $TARGET_DIR"
    fi
}

# ==========================================
# PROCESS CONFIG SSL (INBOUNDS)
# ==========================================
_process_config() {
    local PRIMARY_DOM=$1
    echo -e "\n${ORANGE}--- Config SSL (Inbounds) ---${NC}"

    local TARGET_DIR="$PANEL_DEF_CERTS/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    log_info "Copying inbound certificates to $TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        chmod 755 "$TARGET_DIR"
        chmod 644 "$TARGET_DIR"/*.pem

        ui_success "Files Saved Successfully!"
        echo -e ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║         Copy these paths to your Inbound Settings:       ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC} Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
        echo -e "${YELLOW}║${NC} Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        
        log_success "Inbound SSL configured - Path: $TARGET_DIR"
    else
        ui_error "Error copying certificate files!"
        log_error "Failed to copy inbound certificate files to $TARGET_DIR"
    fi
}

# ==========================================
# SSL WIZARD (MAIN FUNCTION)
# ==========================================
ssl_wizard() {
    ui_header "SSL GENERATION WIZARD v2.1"
    init_logging
    detect_active_panel > /dev/null
    
    echo -e "${CYAN}Active Panel: $(basename $PANEL_DIR)${NC}"
    echo -e "${CYAN}Certs Path: $PANEL_DEF_CERTS${NC}"
    echo ""

    # Get domains
    read -p "How many domains? (e.g. 1, 2): " COUNT
    if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
        ui_error "Invalid number."
        log_error "Invalid domain count entered: $COUNT"
        pause; return
    fi

    declare -a DOMAIN_LIST
    for (( i=1; i<=COUNT; i++ )); do
        read -p "Enter Domain $i: " D_INPUT
        if [ -n "$D_INPUT" ]; then
            DOMAIN_LIST+=("$D_INPUT")
        else
            ui_error "Domain cannot be empty."
            i=$((i-1))
        fi
    done

    if [ ${#DOMAIN_LIST[@]} -eq 0 ]; then 
        log_error "No domains entered"
        return
    fi

    # Get email
    read -p "Enter Email: " MAIL
    if [ -z "$MAIL" ]; then
        ui_error "Email is required."
        log_error "No email entered"
        pause; return
    fi

    local PRIMARY_DOM=${DOMAIN_LIST[0]}

    # Get certificate
    _get_cert_action "$MAIL" "${DOMAIN_LIST[@]}"
    local RES=$?

    if [ $RES -ne 0 ] || [ ! -d "/etc/letsencrypt/live/$PRIMARY_DOM" ]; then
        ui_error "SSL Generation Failed!"
        echo -e "${YELLOW}Check logs: $SSL_LOG_FILE${NC}"
        echo -e "${YELLOW}Certbot log: $CERTBOT_DEBUG_LOG${NC}"
        pause
        return
    fi

    ui_success "Success! Primary Domain: $PRIMARY_DOM"
    echo ""
    
    # Configure usage
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
        *) ui_error "Invalid selection.";;
    esac

    # Offer multi-server sync if servers are configured
    offer_multi_server_sync "$PRIMARY_DOM"

    log_info "========== SSL Generation Completed =========="
    pause
}

# ==========================================
# WILDCARD SSL WITH DNS CHALLENGE
# ==========================================
wildcard_ssl_wizard() {
    ui_header "WILDCARD SSL (*.domain.com)"
    init_logging
    
    echo -e "${YELLOW}⚠️  Wildcard SSL requires DNS Challenge${NC}"
    echo -e "${YELLOW}    You need access to your DNS provider${NC}"
    echo ""

    # Get base domain
    read -p "Enter base domain (e.g. example.com): " BASE_DOMAIN
    if [ -z "$BASE_DOMAIN" ]; then
        ui_error "Domain cannot be empty."
        pause
        return
    fi

    # Get email
    read -p "Enter Email: " MAIL
    if [ -z "$MAIL" ]; then
        ui_error "Email is required."
        pause
        return
    fi

    log_info "Wildcard SSL requested for *.$BASE_DOMAIN"

    # Select DNS provider
    echo ""
    echo -e "${CYAN}Select your DNS Provider:${NC}"
    echo "1) Cloudflare"
    echo "2) Manual DNS (Add TXT record yourself)"
    echo ""
    read -p "Select: " DNS_PROVIDER

    case $DNS_PROVIDER in
        1) wildcard_cloudflare "$BASE_DOMAIN" "$MAIL" ;;
        2) wildcard_manual "$BASE_DOMAIN" "$MAIL" ;;
        *) ui_error "Invalid selection." ;;
    esac

    pause
}

# ------------------------------------------
# Wildcard with Cloudflare API
# ------------------------------------------
wildcard_cloudflare() {
    local BASE_DOMAIN=$1
    local EMAIL=$2

    echo -e "\n${CYAN}--- Cloudflare DNS Challenge ---${NC}"
    
    # Check if cloudflare plugin is installed
    if ! pip3 list 2>/dev/null | grep -q certbot-dns-cloudflare; then
        ui_spinner_start "Installing Cloudflare DNS plugin..."
        pip3 install certbot-dns-cloudflare > /dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            apt install python3-certbot-dns-cloudflare -y > /dev/null 2>&1
        fi
        ui_spinner_stop
        ui_success "Cloudflare plugin installed"
    fi

    # Get Cloudflare credentials
    echo ""
    echo -e "${YELLOW}You need Cloudflare API Token with DNS edit permissions${NC}"
    echo -e "${CYAN}Get it from: https://dash.cloudflare.com/profile/api-tokens${NC}"
    echo ""
    
    read -p "Enter Cloudflare API Token: " CF_API_TOKEN
    if [ -z "$CF_API_TOKEN" ]; then
        ui_error "API Token is required."
        return 1
    fi

    # Create credentials file
    local CF_CREDS_DIR="/root/.secrets/cloudflare"
    local CF_CREDS_FILE="$CF_CREDS_DIR/cloudflare.ini"
    
    mkdir -p "$CF_CREDS_DIR"
    chmod 700 "$CF_CREDS_DIR"
    
    cat > "$CF_CREDS_FILE" << EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
    
    chmod 600 "$CF_CREDS_FILE"
    log_info "Cloudflare credentials saved to $CF_CREDS_FILE"

    ui_spinner_start "Requesting Wildcard Certificate..."

    # Request wildcard certificate
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CF_CREDS_FILE" \
        --dns-cloudflare-propagation-seconds 60 \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        -d "$BASE_DOMAIN" \
        -d "*.$BASE_DOMAIN" > "$CERTBOT_DEBUG_LOG" 2>&1

    local RESULT=$?
    ui_spinner_stop

    if [ $RESULT -eq 0 ]; then
        ui_success "Wildcard SSL Generated Successfully!"
        echo -e "${GREEN}  Domains: $BASE_DOMAIN, *.$BASE_DOMAIN${NC}"
        log_success "Wildcard SSL generated for *.$BASE_DOMAIN"
        
        _process_wildcard_cert "$BASE_DOMAIN"
    else
        ui_error "Wildcard SSL Generation Failed!"
        echo -e "${YELLOW}Last 15 lines of log:${NC}"
        tail -n 15 "$CERTBOT_DEBUG_LOG"
        log_error "Wildcard SSL failed for *.$BASE_DOMAIN"
    fi
}

# ------------------------------------------
# Wildcard with Manual DNS
# ------------------------------------------
wildcard_manual() {
    local BASE_DOMAIN=$1
    local EMAIL=$2

    echo -e "\n${CYAN}--- Manual DNS Challenge ---${NC}"
    echo -e "${YELLOW}You will need to add TXT records to your DNS${NC}"
    echo ""

    certbot certonly \
        --manual \
        --preferred-challenges dns \
        --email "$EMAIL" \
        --agree-tos \
        -d "$BASE_DOMAIN" \
        -d "*.$BASE_DOMAIN"

    local RESULT=$?

    if [ $RESULT -eq 0 ]; then
        ui_success "Wildcard SSL Generated Successfully!"
        log_success "Wildcard SSL generated for *.$BASE_DOMAIN (manual)"
        
        _process_wildcard_cert "$BASE_DOMAIN"
    else
        ui_error "Wildcard SSL Generation Failed!"
        log_error "Wildcard SSL failed for *.$BASE_DOMAIN (manual)"
    fi
}

# ------------------------------------------
# Process Wildcard Certificate
# ------------------------------------------
_process_wildcard_cert() {
    local BASE_DOMAIN=$1
    
    echo ""
    echo -e "${GREEN}Certificate Location:${NC}"
    echo -e "  Cert: ${CYAN}/etc/letsencrypt/live/$BASE_DOMAIN/fullchain.pem${NC}"
    echo -e "  Key:  ${CYAN}/etc/letsencrypt/live/$BASE_DOMAIN/privkey.pem${NC}"
    echo ""
    
    echo "Where to use this wildcard certificate?"
    echo "1) Main Panel (Dashboard)"
    echo "2) Node Server"
    echo "3) Config Domain (Inbounds)"
    echo "4) All of the above"
    echo "5) Just show paths (don't copy)"
    read -p "Select: " TYPE_OPT

    case $TYPE_OPT in
        1) _process_panel "$BASE_DOMAIN" ;;
        2) _process_node "$BASE_DOMAIN" ;;
        3) _process_config "$BASE_DOMAIN" ;;
        4) 
            _process_panel "$BASE_DOMAIN"
            _process_node "$BASE_DOMAIN"
            _process_config "$BASE_DOMAIN"
            ;;
        5) echo -e "${YELLOW}Use these paths in your configuration.${NC}" ;;
        *) ;;
    esac
}

# ==========================================
# MULTI-SERVER SSL SYNC
# ==========================================
multi_server_menu() {
    while true; do
        ui_header "MULTI-SERVER SSL SYNC"
        
        echo "1) 📋 List Configured Servers"
        echo "2) ➕ Add New Server"
        echo "3) ➖ Remove Server"
        echo "4) 🔄 Sync SSL to All Servers"
        echo "5) 🔄 Sync SSL to Specific Server"
        echo "6) 🔑 Setup SSH Key (Passwordless)"
        echo "7) 🧪 Test Connection to All Servers"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) list_servers ;;
            2) add_server ;;
            3) remove_server ;;
            4) sync_all_servers ;;
            5) sync_specific_server ;;
            6) setup_ssh_keys ;;
            7) test_all_connections ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ------------------------------------------
# List Servers
# ------------------------------------------
list_servers() {
    ui_header "CONFIGURED SERVERS"

    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured yet."
        echo -e "Use 'Add New Server' to add one."
        pause
        return
    fi

    echo -e "${GREEN}ID  │ Name              │ Host              │ Port  │ Path${NC}"
    echo "────┼───────────────────┼───────────────────┼───────┼──────────────────"
    
    local idx=1
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        printf "%-3s │ %-17s │ %-17s │ %-5s │ %s\n" "$idx" "$name" "$host" "$port" "$path"
        ((idx++))
    done < "$SERVERS_FILE"

    echo ""
    pause
}

# ------------------------------------------
# Add Server
# ------------------------------------------
add_server() {
    ui_header "ADD NEW SERVER"

    read -p "Server Name (e.g. node-germany): " SERVER_NAME
    if [ -z "$SERVER_NAME" ]; then
        ui_error "Name is required."
        pause
        return
    fi

    read -p "Server IP/Host: " SERVER_HOST
    if [ -z "$SERVER_HOST" ]; then
        ui_error "Host is required."
        pause
        return
    fi

    read -p "SSH Port [22]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-22}

    read -p "SSH User [root]: " SERVER_USER
    SERVER_USER=${SERVER_USER:-root}

    echo ""
    echo "Select panel type on this server:"
    echo "1) Pasarguard"
    echo "2) Marzban"
    echo "3) Rebecca"
    echo "4) Custom"
    read -p "Select: " PANEL_TYPE

    local REMOTE_PATH=""
    local PANEL_NAME=""
    
    case $PANEL_TYPE in
        1) 
            PANEL_NAME="pasarguard"
            REMOTE_PATH="/var/lib/pasarguard/certs"
            ;;
        2) 
            PANEL_NAME="marzban"
            REMOTE_PATH="/var/lib/marzban/certs"
            ;;
        3) 
            PANEL_NAME="rebecca"
            REMOTE_PATH="/var/lib/rebecca/certs"
            ;;
        4)
            PANEL_NAME="custom"
            read -p "Enter remote certificate path: " REMOTE_PATH
            ;;
        *)
            ui_error "Invalid selection."
            pause
            return
            ;;
    esac

    touch "$SERVERS_FILE"
    echo "${SERVER_NAME}|${SERVER_HOST}|${SERVER_PORT}|${SERVER_USER}|${REMOTE_PATH}|${PANEL_NAME}" >> "$SERVERS_FILE"

    ui_success "Server added successfully!"
    log_info "Added server: $SERVER_NAME ($SERVER_HOST)"

    echo ""
    read -p "Test connection now? (Y/n): " TEST_NOW
    if [[ ! "$TEST_NOW" =~ ^[Nn]$ ]]; then
        test_server_connection "$SERVER_HOST" "$SERVER_PORT" "$SERVER_USER"
    fi

    pause
}

# ------------------------------------------
# Remove Server
# ------------------------------------------
remove_server() {
    ui_header "REMOVE SERVER"

    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured."
        pause
        return
    fi

    echo -e "${YELLOW}Select server to remove:${NC}"
    echo ""

    local idx=1
    declare -a server_names
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo "$idx) $name ($host)"
        server_names[$idx]="$name"
        ((idx++))
    done < "$SERVERS_FILE"

    echo ""
    read -p "Select (0 to cancel): " SEL

    if [ "$SEL" == "0" ]; then
        return
    fi

    local REMOVE_NAME=${server_names[$SEL]}
    if [ -z "$REMOVE_NAME" ]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    grep -v "^${REMOVE_NAME}|" "$SERVERS_FILE" > "${SERVERS_FILE}.tmp"
    mv "${SERVERS_FILE}.tmp" "$SERVERS_FILE"

    ui_success "Server '$REMOVE_NAME' removed."
    log_info "Removed server: $REMOVE_NAME"
    pause
}

# ------------------------------------------
# Test Server Connection
# ------------------------------------------
test_server_connection() {
    local HOST=$1
    local PORT=$2
    local USER=$3

    echo -e "${YELLOW}Testing connection to $USER@$HOST:$PORT...${NC}"
    
    if ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$PORT" "$USER@$HOST" "echo 'OK'" 2>/dev/null; then
        ui_success "Connection successful!"
        return 0
    else
        ui_error "Connection failed!"
        echo -e "${YELLOW}Make sure:${NC}"
        echo -e "  1. SSH is running on the remote server"
        echo -e "  2. SSH key is configured (use 'Setup SSH Key' option)"
        echo -e "  3. Firewall allows port $PORT"
        return 1
    fi
}

# ------------------------------------------
# Test All Connections
# ------------------------------------------
test_all_connections() {
    ui_header "TESTING ALL CONNECTIONS"

    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured."
        pause
        return
    fi

    local success=0
    local failed=0

    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        
        echo -ne "${YELLOW}[$name]${NC} $host:$port ... "
        
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$port" "$user@$host" "exit" 2>/dev/null; then
            echo -e "${GREEN}✔ OK${NC}"
            ((success++))
        else
            echo -e "${RED}✘ FAILED${NC}"
            ((failed++))
        fi
    done < "$SERVERS_FILE"

    echo ""
    echo -e "${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"
    pause
}

# ------------------------------------------
# Setup SSH Keys
# ------------------------------------------
setup_ssh_keys() {
    ui_header "SETUP SSH KEY"

    # Check if key exists
    if [ ! -f ~/.ssh/id_rsa ]; then
        echo -e "${YELLOW}No SSH key found. Generating...${NC}"
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        ui_success "SSH key generated."
    else
        ui_success "SSH key already exists."
    fi

    echo ""
    
    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured. Add a server first."
        pause
        return
    fi

    echo -e "${YELLOW}Select server to setup SSH key:${NC}"
    echo ""

    local idx=1
    declare -a hosts ports users
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo "$idx) $name ($host)"
        hosts[$idx]="$host"
        ports[$idx]="$port"
        users[$idx]="$user"
        ((idx++))
    done < "$SERVERS_FILE"

    echo "$idx) All servers"
    echo "0) Cancel"
    echo ""
    read -p "Select: " SEL

    if [ "$SEL" == "0" ]; then
        return
    fi

    if [ "$SEL" == "$idx" ]; then
        for ((i=1; i<idx; i++)); do
            echo -e "\n${YELLOW}Setting up ${hosts[$i]}...${NC}"
            ssh-copy-id -p "${ports[$i]}" "${users[$i]}@${hosts[$i]}" 2>/dev/null
        done
    else
        local HOST=${hosts[$SEL]}
        local PORT=${ports[$SEL]}
        local USER=${users[$SEL]}

        if [ -z "$HOST" ]; then
            ui_error "Invalid selection."
            pause
            return
        fi

        echo -e "${YELLOW}Copying SSH key to $USER@$HOST:$PORT...${NC}"
        ssh-copy-id -p "$PORT" "$USER@$HOST"
    fi

    ui_success "SSH key setup complete!"
    pause
}

# ------------------------------------------
# Sync to Single Server
# ------------------------------------------
sync_to_server() {
    local HOST=$1
    local PORT=$2
    local USER=$3
    local REMOTE_BASE_PATH=$4
    local DOMAIN=$5
    local LOCAL_CERT_PATH=$6
    local PANEL=$7

    local REMOTE_PATH="$REMOTE_BASE_PATH/$DOMAIN"

    log_info "Syncing to $USER@$HOST:$PORT - Path: $REMOTE_PATH"

    # Create remote directory
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$PORT" "$USER@$HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null; then
        log_error "Failed to create directory on $HOST"
        return 1
    fi

    # Copy certificate files
    if ! scp -o ConnectTimeout=10 -o BatchMode=yes -P "$PORT" \
        "$LOCAL_CERT_PATH/fullchain.pem" \
        "$USER@$HOST:$REMOTE_PATH/fullchain.pem" 2>/dev/null; then
        log_error "Failed to copy fullchain.pem to $HOST"
        return 1
    fi

    if ! scp -o ConnectTimeout=10 -o BatchMode=yes -P "$PORT" \
        "$LOCAL_CERT_PATH/privkey.pem" \
        "$USER@$HOST:$REMOTE_PATH/privkey.pem" 2>/dev/null; then
        log_error "Failed to copy privkey.pem to $HOST"
        return 1
    fi

    # Also copy as server.crt/server.key for node compatibility
    ssh -o BatchMode=yes -p "$PORT" "$USER@$HOST" "
        cp $REMOTE_PATH/fullchain.pem $REMOTE_PATH/server.crt 2>/dev/null
        cp $REMOTE_PATH/privkey.pem $REMOTE_PATH/server.key 2>/dev/null
        chmod 644 $REMOTE_PATH/*.pem $REMOTE_PATH/*.crt $REMOTE_PATH/*.key 2>/dev/null
    " 2>/dev/null

    # Restart remote service
    if [ "$PANEL" != "custom" ] && [ -n "$PANEL" ]; then
        ssh -o BatchMode=yes -p "$PORT" "$USER@$HOST" "
            cd /opt/$PANEL 2>/dev/null && docker compose restart 2>/dev/null ||
            systemctl restart $PANEL 2>/dev/null
        " 2>/dev/null
    fi

    log_success "Synced $DOMAIN to $HOST"
    return 0
}

# ------------------------------------------
# Sync All Servers
# ------------------------------------------
sync_all_servers() {
    ui_header "SYNC SSL TO ALL SERVERS"

    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured."
        pause
        return
    fi

    # Select domain
    echo -e "${YELLOW}Select certificate to sync:${NC}"
    echo ""

    local idx=1
    declare -a domains
    
    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        domains[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done

    if [ $idx -eq 1 ]; then
        ui_error "No certificates found."
        pause
        return
    fi

    echo ""
    read -p "Select certificate: " CERT_SEL
    local SELECTED_DOMAIN=${domains[$CERT_SEL]}

    if [ -z "$SELECTED_DOMAIN" ]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    local CERT_PATH="/etc/letsencrypt/live/$SELECTED_DOMAIN"

    echo ""
    echo -e "${YELLOW}Syncing $SELECTED_DOMAIN to all servers...${NC}"
    echo ""

    log_info "Starting multi-server sync for $SELECTED_DOMAIN"

    local success=0
    local failed=0

    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        
        echo -ne "${YELLOW}[$name]${NC} Syncing to $host ... "
        
        if sync_to_server "$host" "$port" "$user" "$path" "$SELECTED_DOMAIN" "$CERT_PATH" "$panel"; then
            echo -e "${GREEN}✔ Done${NC}"
            ((success++))
        else
            echo -e "${RED}✘ Failed${NC}"
            ((failed++))
        fi
    done < "$SERVERS_FILE"

    echo ""
    echo -e "${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"
    log_info "Multi-server sync completed. Success: $success, Failed: $failed"
    pause
}

# ------------------------------------------
# Sync Specific Server
# ------------------------------------------
sync_specific_server() {
    ui_header "SYNC SSL TO SPECIFIC SERVER"

    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured."
        pause
        return
    fi

    # Select server
    echo -e "${YELLOW}Select server:${NC}"
    echo ""

    local idx=1
    declare -a names hosts ports users paths panels
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo "$idx) $name ($host)"
        names[$idx]="$name"
        hosts[$idx]="$host"
        ports[$idx]="$port"
        users[$idx]="$user"
        paths[$idx]="$path"
        panels[$idx]="$panel"
        ((idx++))
    done < "$SERVERS_FILE"

    echo ""
    read -p "Select server: " SERVER_SEL

    local S_HOST=${hosts[$SERVER_SEL]}
    if [ -z "$S_HOST" ]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    # Select certificate
    echo ""
    echo -e "${YELLOW}Select certificate to sync:${NC}"
    echo ""

    idx=1
    declare -a domains
    
    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        domains[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done

    if [ $idx -eq 1 ]; then
        ui_error "No certificates found."
        pause
        return
    fi

    echo ""
    read -p "Select certificate: " CERT_SEL
    local SELECTED_DOMAIN=${domains[$CERT_SEL]}

    if [ -z "$SELECTED_DOMAIN" ]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    local CERT_PATH="/etc/letsencrypt/live/$SELECTED_DOMAIN"

    echo ""
    echo -e "${YELLOW}Syncing $SELECTED_DOMAIN to ${names[$SERVER_SEL]}...${NC}"

    if sync_to_server "${hosts[$SERVER_SEL]}" "${ports[$SERVER_SEL]}" "${users[$SERVER_SEL]}" \
                      "${paths[$SERVER_SEL]}" "$SELECTED_DOMAIN" "$CERT_PATH" "${panels[$SERVER_SEL]}"; then
        ui_success "Sync completed successfully!"
    else
        ui_error "Sync failed!"
    fi

    pause
}

# ------------------------------------------
# Quick Sync Offer
# ------------------------------------------
offer_multi_server_sync() {
    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        return
    fi

    local server_count=$(wc -l < "$SERVERS_FILE")
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}You have $server_count server(s) configured.${NC}"
    read -p "Sync this certificate to other servers? (y/N): " SYNC_NOW
    
    if [[ "$SYNC_NOW" =~ ^[Yy]$ ]]; then
        local DOMAIN=$1
        local CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
        
        echo ""
        while IFS='|' read -r name host port user path panel; do
            [ -z "$name" ] && continue
            echo -ne "${YELLOW}[$name]${NC} Syncing ... "
            if sync_to_server "$host" "$port" "$user" "$path" "$DOMAIN" "$CERT_PATH" "$panel"; then
                echo -e "${GREEN}✔${NC}"
            else
                echo -e "${RED}✘${NC}"
            fi
        done < "$SERVERS_FILE"
    fi
}

# ==========================================
# SHOW EXISTING SSL PATHS
# ==========================================
show_detailed_paths() {
    ui_header "EXISTING SSL PATHS"
    detect_active_panel > /dev/null

    echo -e "${GREEN}--- Panel Certificates ($PANEL_DEF_CERTS) ---${NC}"
    if [ -d "$PANEL_DEF_CERTS" ] && [ "$(ls -A $PANEL_DEF_CERTS 2>/dev/null)" ]; then
        for dir in "$PANEL_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                local dom=$(basename "$dir")
                echo -e "  ${YELLOW}Domain:${NC} $dom"
                [ -f "$dir/fullchain.pem" ] && echo -e "    Cert: ${CYAN}$dir/fullchain.pem${NC}"
                [ -f "$dir/privkey.pem" ] && echo -e "    Key:  ${CYAN}$dir/privkey.pem${NC}"
            fi
        done
    else
        echo "  No certificates found."
    fi

    echo ""
    echo -e "${PURPLE}--- Node Certificates ($NODE_DEF_CERTS) ---${NC}"
    if [ -d "$NODE_DEF_CERTS" ] && [ "$(ls -A $NODE_DEF_CERTS 2>/dev/null)" ]; then
        for dir in "$NODE_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                local dom=$(basename "$dir")
                echo -e "  ${YELLOW}Domain:${NC} $dom"
                [ -f "$dir/server.crt" ] && echo -e "    Cert: ${CYAN}$dir/server.crt${NC}"
                [ -f "$dir/server.key" ] && echo -e "    Key:  ${CYAN}$dir/server.key${NC}"
            fi
        done
    else
        echo "  No certificates found."
    fi

    echo ""
    pause
}

# ==========================================
# VIEW CERTIFICATE CONTENT
# ==========================================
view_cert_content() {
    ui_header "VIEW CERTIFICATE FILES"
    detect_active_panel > /dev/null

    declare -a all_certs
    local idx=1

    if [ -d "$PANEL_DEF_CERTS" ]; then
        for dir in "$PANEL_DEF_CERTS"/*; do
            if [ -d "$dir" ]; then
                local dom=$(basename "$dir")
                all_certs[$idx]="$dir"
                echo -e "${GREEN}$idx)${NC} [panel] $dom"
                ((idx++))
            fi
        done
    fi

    if [ $idx -eq 1 ]; then
        echo "No certificates found."
        pause
        return
    fi

    echo ""
    read -p "Select Number: " NUM
    local SELECTED_DIR=${all_certs[$NUM]}

    if [ -z "$SELECTED_DIR" ]; then
        ui_error "Invalid selection."
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
    
    if [ "$F_OPT" == "1" ]; then 
        [ -f "$SELECTED_DIR/fullchain.pem" ] && FILE="fullchain.pem"
        [ -f "$SELECTED_DIR/server.crt" ] && FILE="server.crt"
    elif [ "$F_OPT" == "2" ]; then 
        [ -f "$SELECTED_DIR/privkey.pem" ] && FILE="privkey.pem"
        [ -f "$SELECTED_DIR/server.key" ] && FILE="server.key"
    fi

    if [ -n "$FILE" ] && [ -f "$SELECTED_DIR/$FILE" ]; then
        clear
        echo -e "${YELLOW}--- START OF FILE ---${NC}"
        echo -e "${GREEN}"
        cat "$SELECTED_DIR/$FILE"
        echo -e "${NC}"
        echo -e "${YELLOW}--- END OF FILE ---${NC}"
    else
        ui_error "File not found."
    fi
    pause
}

# ==========================================
# VIEW LOGS
# ==========================================
view_ssl_logs() {
    ui_header "SSL MANAGER LOGS"
    
    echo "1) View SSL Manager Log (Last 50 lines)"
    echo "2) View Certbot Debug Log (Last 50 lines)"
    echo "3) Clear All Logs"
    echo "4) Export Logs"
    echo "0) Back"
    echo ""
    read -p "Select: " LOG_OPT

    case $LOG_OPT in
        1)
            if [ -f "$SSL_LOG_FILE" ]; then
                echo -e "\n${YELLOW}--- SSL Manager Log ---${NC}"
                tail -n 50 "$SSL_LOG_FILE"
            else
                ui_error "Log file not found."
            fi
            ;;
        2)
            if [ -f "$CERTBOT_DEBUG_LOG" ]; then
                echo -e "\n${YELLOW}--- Certbot Debug Log ---${NC}"
                tail -n 50 "$CERTBOT_DEBUG_LOG"
            else
                ui_error "Certbot log not found."
            fi
            ;;
        3)
            > "$SSL_LOG_FILE" 2>/dev/null
            > "$CERTBOT_DEBUG_LOG" 2>/dev/null
            ui_success "Logs cleared."
            ;;
        4)
            local EXPORT_FILE="/root/ssl-logs-$(date '+%Y%m%d-%H%M%S').txt"
            {
                echo "=== SSL Manager Log ==="
                cat "$SSL_LOG_FILE" 2>/dev/null
                echo ""
                echo "=== Certbot Log ==="
                cat "$CERTBOT_DEBUG_LOG" 2>/dev/null
            } > "$EXPORT_FILE"
            ui_success "Exported to: $EXPORT_FILE"
            ;;
        0) return ;;
    esac
    pause
}

# ==========================================
# CERTIFICATE INFO
# ==========================================
show_cert_info() {
    ui_header "CERTIFICATE INFORMATION"

    if [ ! -d "/etc/letsencrypt/live" ]; then
        ui_error "No Let's Encrypt certificates found."
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
    ui_header "RENEW SSL CERTIFICATES"
    init_logging
    
    log_info "Starting certificate renewal"

    ui_spinner_start "Stopping web services..."
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
    ui_spinner_stop

    ui_spinner_start "Renewing certificates..."
    certbot renew --standalone > "$CERTBOT_DEBUG_LOG" 2>&1
    local RESULT=$?
    ui_spinner_stop

    systemctl start nginx 2>/dev/null

    if [ $RESULT -eq 0 ]; then
        ui_success "Certificate renewal completed!"
        log_success "Certificate renewal completed"
    else
        ui_error "Certificate renewal failed!"
        tail -n 20 "$CERTBOT_DEBUG_LOG"
        log_error "Certificate renewal failed"
    fi
    
    pause
}

# ==========================================
# REVOKE CERTIFICATE
# ==========================================
revoke_certificate() {
    ui_header "REVOKE SSL CERTIFICATE"
    
    if [ ! -d "/etc/letsencrypt/live" ]; then
        ui_error "No certificates found."
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
    read -p "Select certificate to revoke (0 to cancel): " SEL
    
    if [ "$SEL" == "0" ]; then
        return
    fi

    local DOMAIN=${certs[$SEL]}
    if [ -z "$DOMAIN" ]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    echo -e "${RED}⚠️ WARNING: This will permanently revoke $DOMAIN${NC}"
    read -p "Type 'yes' to confirm: " CONFIRM

    if [ "$CONFIRM" == "yes" ]; then
        certbot revoke --cert-path "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" --non-interactive 2>/dev/null
        certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null
        ui_success "Certificate revoked and deleted."
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
        ui_header "SSL MANAGEMENT v2.1"
        detect_active_panel > /dev/null
        
        echo -e "${CYAN}Active Panel: $(basename $PANEL_DIR)${NC}"
        echo ""
        echo "1)  🔐 Request New SSL Certificate"
        echo "2)  🌟 Request Wildcard SSL (*.domain.com)"
        echo "3)  📁 Show SSL File Paths"
        echo "4)  📄 View Certificate Content"
        echo "5)  ℹ️  Certificate Information & Expiry"
        echo "6)  🔄 Renew All Certificates"
        echo "7)  🗑️  Revoke Certificate"
        echo "8)  🌐 Multi-Server Sync"
        echo "9)  📋 View Logs"
        echo "10) 📜 Domain List (Let's Encrypt)"
        echo ""
        echo "0)  ↩️  Back"
        echo ""
        read -p "Select: " S_OPT
        
        case $S_OPT in
            1) ssl_wizard ;;
            2) wildcard_ssl_wizard ;;
            3) show_detailed_paths ;;
            4) view_cert_content ;;
            5) show_cert_info ;;
            6) renew_certificates ;;
            7) revoke_certificate ;;
            8) multi_server_menu ;;
            9) view_ssl_logs ;;
            10) 
                echo ""
                ls -1 /etc/letsencrypt/live 2>/dev/null || echo "No certificates found."
                pause 
                ;;
            0) return ;;
            *) ;;
        esac
    done
}