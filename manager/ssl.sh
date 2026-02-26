#!/bin/bash

# ==========================================
# SSL MANAGEMENT MODULE v3.0 (Enhanced)
# Compatible with MRM Manager
# ==========================================

# ==========================================
# COLOR DEFINITIONS
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
ORANGE='\033[0;33m'
NC='\033[0m'
BOLD='\033[1m'

# ==========================================
# CONFIGURATION
# ==========================================
SSL_LOG_DIR="/var/log/ssl-manager"
SSL_LOG_FILE="$SSL_LOG_DIR/ssl-manager.log"
CERTBOT_DEBUG_LOG="/var/log/certbot_debug.log"
SERVERS_FILE="/opt/mrm-manager/ssl-servers.conf"
BACKUP_DIR="/opt/mrm-manager/ssl-backups"

# Expiry thresholds (days)
EXPIRY_WARNING_DAYS=14
EXPIRY_CRITICAL_DAYS=7

# Service states for cleanup
NGINX_WAS_RUNNING=false
APACHE_WAS_RUNNING=false

# ==========================================
# LOAD EXTERNAL MODULES (Safe)
# ==========================================
[ -f "/opt/mrm-manager/utils.sh" ] && source /opt/mrm-manager/utils.sh
[ -f "/opt/mrm-manager/ui.sh" ] && source /opt/mrm-manager/ui.sh

# ==========================================
# UI FALLBACK FUNCTIONS
# ==========================================
command -v ui_header &>/dev/null || ui_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}$1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

command -v ui_error &>/dev/null || ui_error() { echo -e "${RED}[✘] $1${NC}"; }
command -v ui_success &>/dev/null || ui_success() { echo -e "${GREEN}[✔] $1${NC}"; }
command -v ui_warning &>/dev/null || ui_warning() { echo -e "${YELLOW}[⚠] $1${NC}"; }
command -v ui_info &>/dev/null || ui_info() { echo -e "${BLUE}[ℹ] $1${NC}"; }
command -v pause &>/dev/null || pause() { echo ""; read -p "Press Enter to continue..."; }

# ==========================================
# CLEANUP TRAP (BUG FIX!)
# ==========================================
cleanup_on_exit() {
    [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null
    [ "$APACHE_WAS_RUNNING" = true ] && systemctl start apache2 2>/dev/null
}
trap cleanup_on_exit EXIT INT TERM

# ==========================================
# PANEL DETECTION (Fallback)
# ==========================================
detect_active_panel() {
    if [ -d "/opt/marzban" ]; then
        PANEL_DIR="/opt/marzban"
        PANEL_DEF_CERTS="/var/lib/marzban/certs"
        PANEL_ENV="/opt/marzban/.env"
        NODE_DEF_CERTS="/var/lib/marzban-node/certs"
        NODE_ENV="/opt/marzban-node/.env"
        echo "marzban"
    elif [ -d "/opt/x-ui" ] || [ -d "/opt/sanaei" ]; then
        PANEL_DIR="${PANEL_DIR:-/opt/x-ui}"
        PANEL_DEF_CERTS="/var/lib/x-ui/certs"
        PANEL_ENV="/opt/x-ui/.env"
        NODE_DEF_CERTS="/var/lib/x-ui/certs"
        NODE_ENV="/opt/x-ui/.env"
        echo "x-ui"
    elif [ -d "/opt/hiddify" ]; then
        PANEL_DIR="/opt/hiddify"
        PANEL_DEF_CERTS="/opt/hiddify/certs"
        PANEL_ENV="/opt/hiddify/.env"
        NODE_DEF_CERTS="/opt/hiddify/certs"
        NODE_ENV="/opt/hiddify/.env"
        echo "hiddify"
    elif [ -d "/opt/pasarguard" ]; then
        PANEL_DIR="/opt/pasarguard"
        PANEL_DEF_CERTS="/var/lib/pasarguard/certs"
        PANEL_ENV="/opt/pasarguard/.env"
        NODE_DEF_CERTS="/var/lib/pasarguard-node/certs"
        NODE_ENV="/opt/pasarguard-node/.env"
        echo "pasarguard"
    elif [ -d "/opt/rebecca" ]; then
        PANEL_DIR="/opt/rebecca"
        PANEL_DEF_CERTS="/var/lib/rebecca/certs"
        PANEL_ENV="/opt/rebecca/.env"
        NODE_DEF_CERTS="/var/lib/rebecca-node/certs"
        NODE_ENV="/opt/rebecca-node/.env"
        echo "rebecca"
    else
        PANEL_DIR="/opt/panel"
        PANEL_DEF_CERTS="/var/lib/panel/certs"
        PANEL_ENV="/opt/panel/.env"
        NODE_DEF_CERTS="/var/lib/node/certs"
        NODE_ENV="/opt/node/.env"
        echo "unknown"
    fi
}

# ==========================================
# SERVICE RESTART (Fallback)
# ==========================================
command -v restart_service &>/dev/null || restart_service() {
    local SERVICE_TYPE=$1
    local target_dir=""
    
    case $SERVICE_TYPE in
        panel) target_dir="$PANEL_DIR" ;;
        node) target_dir="$(dirname "$NODE_ENV")" ;;
    esac
    
    if [ -f "$target_dir/docker-compose.yml" ]; then
        cd "$target_dir" && docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null
    else
        systemctl restart "$(basename "$target_dir")" 2>/dev/null
    fi
}

# ==========================================
# LOGGING SYSTEM
# ==========================================
init_logging() {
    mkdir -p "$SSL_LOG_DIR" "$BACKUP_DIR"
    touch "$SSL_LOG_FILE"
    chmod 644 "$SSL_LOG_FILE"
}

log_message() {
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] [$1] $2" >> "$SSL_LOG_FILE"
}

log_info() { log_message "INFO" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_success() { log_message "SUCCESS" "$1"; }
log_warning() { log_message "WARNING" "$1"; }

# ==========================================
# INPUT VALIDATION (NEW!)
# ==========================================
validate_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

validate_email() {
    local email=$1
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

sanitize_input() {
    echo "$1" | sed 's/[;&|`$()]//g'
}

# ==========================================
# DEPENDENCY CHECK (NEW!)
# ==========================================
check_dependencies() {
    local missing=()
    command -v certbot &>/dev/null || missing+=("certbot")
    command -v openssl &>/dev/null || missing+=("openssl")
    command -v curl &>/dev/null || missing+=("curl")
    
    if [ ${#missing[@]} -gt 0 ]; then
        ui_error "Missing dependencies: ${missing[*]}"
        echo -e "${YELLOW}Install with: apt install ${missing[*]}${NC}"
        return 1
    fi
    return 0
}

# ==========================================
# DNS & IP VALIDATION
# ==========================================
validate_domain_dns() {
    local DOMAIN=$1
    local SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null)
    local DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{ print $1 }' | head -1)
    
    [ -z "$DOMAIN_IP" ] && command -v dig &>/dev/null && DOMAIN_IP=$(dig +short "$DOMAIN" A | head -1)

    echo -e "${YELLOW}[DNS Check] Validating domain: $DOMAIN${NC}"
    log_info "DNS Check - Domain: $DOMAIN, Server IP: $SERVER_IP, Domain IP: $DOMAIN_IP"

    if [ -z "$DOMAIN_IP" ]; then
        ui_error "Cannot resolve domain $DOMAIN"
        log_error "DNS resolution failed for $DOMAIN"
        return 1
    fi

    if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              ⚠️  DNS MISMATCH WARNING  ⚠️                 ║${NC}"
        echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║${NC}  Domain IP:  ${YELLOW}$DOMAIN_IP${NC}"
        echo -e "${RED}║${NC}  Server IP:  ${YELLOW}$SERVER_IP${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        log_warning "DNS mismatch for $DOMAIN"

        read -p "Continue anyway? (y/N): " CONTINUE_ANYWAY
        [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]] && return 1
    else
        ui_success "DNS OK: $DOMAIN → $DOMAIN_IP"
    fi
    return 0
}

# ==========================================
# PORT CHECK
# ==========================================
check_port_availability() {
    local PORT=$1
    if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
        local SERVICE=$(ss -tlnp 2>/dev/null | grep ":$PORT " | awk '{print $NF}' | head -1)
        ui_warning "Port $PORT is in use by: $SERVICE"
        return 1
    fi
    return 0
}

# ==========================================
# 🆕 CERTIFICATE EXPIRY FUNCTIONS (NEW!)
# ==========================================
get_cert_expiry_date() {
    local CERT_PATH=$1
    [ ! -f "$CERT_PATH" ] && echo "NOT_FOUND" && return 1
    openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2
}

get_cert_days_remaining() {
    local CERT_PATH=$1
    [ ! -f "$CERT_PATH" ] && echo "-1" && return 1
    
    local expiry_epoch=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 | xargs -I {} date -d "{}" +%s 2>/dev/null)
    local current_epoch=$(date +%s)
    
    [ -z "$expiry_epoch" ] && echo "-1" && return 1
    echo $(( (expiry_epoch - current_epoch) / 86400 ))
}

get_cert_status() {
    local days=$1
    if [ "$days" -lt 0 ]; then echo "EXPIRED"
    elif [ "$days" -le "$EXPIRY_CRITICAL_DAYS" ]; then echo "CRITICAL"
    elif [ "$days" -le "$EXPIRY_WARNING_DAYS" ]; then echo "WARNING"
    else echo "VALID"
    fi
}

get_status_color() {
    case $1 in
        EXPIRED|CRITICAL) echo "$RED" ;;
        WARNING) echo "$YELLOW" ;;
        VALID) echo "$GREEN" ;;
        *) echo "$NC" ;;
    esac
}

# ==========================================
# 🆕 SHOW CERTIFICATE EXPIRY STATUS (NEW FEATURE!)
# ==========================================
show_certificate_expiry() {
    ui_header "📅 CERTIFICATE EXPIRY STATUS"
    detect_active_panel > /dev/null

    local found_any=false
    declare -a expired_domains
    declare -a expiring_domains
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    printf "${CYAN}║${NC} %-30s │ %-19s │ %-6s │ %-10s${CYAN}║${NC}\n" "Domain" "Expiry Date" "Days" "Status"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════════╣${NC}"

    # Check Let's Encrypt certificates
    if [ -d "/etc/letsencrypt/live" ]; then
        for dir in /etc/letsencrypt/live/*/; do
            local domain=$(basename "$dir")
            [ "$domain" == "README" ] && continue
            [ ! -f "$dir/fullchain.pem" ] && continue
            
            found_any=true
            local cert_path="$dir/fullchain.pem"
            local expiry_date=$(get_cert_expiry_date "$cert_path")
            local days_remaining=$(get_cert_days_remaining "$cert_path")
            local status=$(get_cert_status "$days_remaining")
            local color=$(get_status_color "$status")
            
            # Track problematic domains
            if [ "$status" == "EXPIRED" ] || [ "$status" == "CRITICAL" ]; then
                expired_domains+=("$domain")
            elif [ "$status" == "WARNING" ]; then
                expiring_domains+=("$domain")
            fi
            
            local formatted_date=$(date -d "$expiry_date" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$expiry_date")
            
            printf "${CYAN}║${NC} %-30s │ %-19s │ ${color}%-6s${NC} │ ${color}%-10s${NC}${CYAN}║${NC}\n" \
                   "${domain:0:30}" "${formatted_date:0:19}" "$days_remaining" "$status"
        done
    fi
    
    # Check panel certificates (not in LE)
    if [ -d "$PANEL_DEF_CERTS" ]; then
        for dir in "$PANEL_DEF_CERTS"/*/; do
            [ ! -d "$dir" ] && continue
            local domain=$(basename "$dir")
            [ ! -f "$dir/fullchain.pem" ] && continue
            [ -d "/etc/letsencrypt/live/$domain" ] && continue  # Skip duplicates
            
            found_any=true
            local cert_path="$dir/fullchain.pem"
            local expiry_date=$(get_cert_expiry_date "$cert_path")
            local days_remaining=$(get_cert_days_remaining "$cert_path")
            local status=$(get_cert_status "$days_remaining")
            local color=$(get_status_color "$status")
            
            if [ "$status" == "EXPIRED" ] || [ "$status" == "CRITICAL" ]; then
                expired_domains+=("$domain")
            elif [ "$status" == "WARNING" ]; then
                expiring_domains+=("$domain")
            fi
            
            local formatted_date=$(date -d "$expiry_date" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$expiry_date")
            
            printf "${CYAN}║${NC} %-30s │ %-19s │ ${color}%-6s${NC} │ ${color}%-10s${NC}${CYAN}║${NC}\n" \
                   "${domain:0:28}[P]" "${formatted_date:0:19}" "$days_remaining" "$status"
        done
    fi
    
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    if [ "$found_any" = false ]; then
        echo -e "\n${YELLOW}  No certificates found.${NC}"
        pause
        return
    fi
    
    echo -e "\n${CYAN}Legend:${NC} [P] = Panel cert only"
    
    # Show alerts
    local total_expired=${#expired_domains[@]}
    local total_expiring=${#expiring_domains[@]}
    
    if [ $total_expired -gt 0 ]; then
        echo -e "\n${RED}🚨 $total_expired certificate(s) need IMMEDIATE renewal:${NC}"
        for d in "${expired_domains[@]}"; do
            echo -e "   ${RED}• $d${NC}"
        done
    fi
    
    if [ $total_expiring -gt 0 ]; then
        echo -e "\n${YELLOW}⚡ $total_expiring certificate(s) expiring soon:${NC}"
        for d in "${expiring_domains[@]}"; do
            echo -e "   ${YELLOW}• $d${NC}"
        done
    fi
    
    # Quick actions
    if [ $total_expired -gt 0 ] || [ $total_expiring -gt 0 ]; then
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "Quick Actions:"
        echo "1) 🔄 Renew ALL expiring/expired certificates"
        echo "2) 🎯 Renew specific certificate"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " RENEW_OPT
        
        case $RENEW_OPT in
            1) renew_expiring_certificates ;;
            2) renew_specific_certificate ;;
            0|*) return ;;
        esac
    else
        pause
    fi
}

# ==========================================
# 🆕 RENEW EXPIRING CERTIFICATES (NEW!)
# ==========================================
renew_expiring_certificates() {
    ui_header "🔄 RENEWING EXPIRING CERTIFICATES"
    init_logging
    detect_active_panel > /dev/null

    log_info "Starting bulk certificate renewal"

    declare -a domains_to_renew

    # Find certificates needing renewal
    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        [ ! -f "$dir/fullchain.pem" ] && continue
        
        local days=$(get_cert_days_remaining "$dir/fullchain.pem")
        [ "$days" -le "$EXPIRY_WARNING_DAYS" ] && domains_to_renew+=("$domain")
    done

    if [ ${#domains_to_renew[@]} -eq 0 ]; then
        ui_success "No certificates need renewal!"
        pause
        return
    fi

    echo -e "${YELLOW}Certificates to renew:${NC}"
    for d in "${domains_to_renew[@]}"; do
        local days=$(get_cert_days_remaining "/etc/letsencrypt/live/$d/fullchain.pem")
        local status=$(get_cert_status "$days")
        local color=$(get_status_color "$status")
        echo -e "  ${color}• $d ($days days)${NC}"
    done
    echo ""

    read -p "Proceed with renewal? (Y/n): " PROCEED
    [[ "$PROCEED" =~ ^[Nn]$ ]] && return

    # Stop services
    echo -e "\n${YELLOW}[1/4] Stopping web services...${NC}"
    
    if systemctl is-active --quiet nginx; then
        NGINX_WAS_RUNNING=true
        systemctl stop nginx 2>/dev/null
    fi

    if systemctl is-active --quiet apache2; then
        APACHE_WAS_RUNNING=true
        systemctl stop apache2 2>/dev/null
    fi

    sleep 2

    # Renew certificates
    echo -e "${YELLOW}[2/4] Renewing certificates...${NC}"
    
    local renewed=0 failed=0
    
    for domain in "${domains_to_renew[@]}"; do
        echo -ne "  Renewing ${CYAN}$domain${NC}... "
        
        if certbot renew --cert-name "$domain" --standalone --non-interactive >> "$CERTBOT_DEBUG_LOG" 2>&1; then
            echo -e "${GREEN}✔${NC}"
            log_success "Renewed certificate for $domain"
            ((renewed++))
        else
            echo -e "${RED}✘${NC}"
            log_error "Failed to renew certificate for $domain"
            ((failed++))
        fi
    done

    # Update copied certificates
    echo -e "${YELLOW}[3/4] Updating certificate paths...${NC}"
    
    for domain in "${domains_to_renew[@]}"; do
        local le_path="/etc/letsencrypt/live/$domain"
        
        # Update panel certs
        if [ -d "$PANEL_DEF_CERTS/$domain" ]; then
            cp -L "$le_path/fullchain.pem" "$PANEL_DEF_CERTS/$domain/" 2>/dev/null
            cp -L "$le_path/privkey.pem" "$PANEL_DEF_CERTS/$domain/" 2>/dev/null
            chmod 644 "$PANEL_DEF_CERTS/$domain/"*.pem 2>/dev/null
            echo -e "  ${GREEN}✔${NC} Panel cert: $domain"
        fi
        
        # Update node certs
        if [ -d "$NODE_DEF_CERTS/$domain" ] && [ "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]; then
            cp -L "$le_path/fullchain.pem" "$NODE_DEF_CERTS/$domain/" 2>/dev/null
            cp -L "$le_path/privkey.pem" "$NODE_DEF_CERTS/$domain/" 2>/dev/null
            chmod 644 "$NODE_DEF_CERTS/$domain/"*.pem 2>/dev/null
            echo -e "  ${GREEN}✔${NC} Node cert: $domain"
        fi
    done

    # Restart services
    echo -e "${YELLOW}[4/4] Restarting services...${NC}"

    [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null && NGINX_WAS_RUNNING=false
    [ "$APACHE_WAS_RUNNING" = true ] && systemctl start apache2 2>/dev/null && APACHE_WAS_RUNNING=false

    restart_service "panel"
    restart_service "node"

    # Summary
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}✔ Renewed: $renewed${NC}"
    echo -e "  ${RED}✘ Failed:  $failed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    log_info "Bulk renewal completed. Renewed: $renewed, Failed: $failed"

    # Offer sync
    if [ -f "$SERVERS_FILE" ] && [ -s "$SERVERS_FILE" ]; then
        echo ""
        read -p "Sync renewed certificates to other servers? (y/N): " SYNC_NOW
        if [[ "$SYNC_NOW" =~ ^[Yy]$ ]]; then
            for domain in "${domains_to_renew[@]}"; do
                sync_domain_to_all_servers "$domain"
            done
        fi
    fi

    pause
}

# ==========================================
# 🆕 RENEW SPECIFIC CERTIFICATE (NEW!)
# ==========================================
renew_specific_certificate() {
    ui_header "🎯 RENEW SPECIFIC CERTIFICATE"
    detect_active_panel > /dev/null

    echo -e "${YELLOW}Select certificate to renew:${NC}\n"

    local idx=1
    declare -a domains

    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        [ ! -f "$dir/fullchain.pem" ] && continue
        
        local days=$(get_cert_days_remaining "$dir/fullchain.pem")
        local status=$(get_cert_status "$days")
        local color=$(get_status_color "$status")
        
        domains[$idx]="$domain"
        printf "%2d) %-35s ${color}[%s - %d days]${NC}\n" "$idx" "$domain" "$status" "$days"
        ((idx++))
    done

    if [ $idx -eq 1 ]; then
        ui_error "No certificates found."
        pause
        return
    fi

    echo ""
    read -p "Select (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return

    local SELECTED_DOMAIN=${domains[$SEL]}
    if [ -z "$SELECTED_DOMAIN" ]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    echo -e "\n${YELLOW}Renewing: ${CYAN}$SELECTED_DOMAIN${NC}\n"

    # Stop services
    if systemctl is-active --quiet nginx; then
        NGINX_WAS_RUNNING=true
        systemctl stop nginx 2>/dev/null
    fi
    if systemctl is-active --quiet apache2; then
        APACHE_WAS_RUNNING=true
        systemctl stop apache2 2>/dev/null
    fi

    sleep 2

    # Renew
    echo -e "${YELLOW}Requesting renewal from Let's Encrypt...${NC}"
    
    if certbot renew --cert-name "$SELECTED_DOMAIN" --standalone --non-interactive --force-renewal > "$CERTBOT_DEBUG_LOG" 2>&1; then
        ui_success "Certificate renewed successfully!"
        log_success "Renewed certificate for $SELECTED_DOMAIN"
        
        # Update paths
        local le_path="/etc/letsencrypt/live/$SELECTED_DOMAIN"
        
        if [ -d "$PANEL_DEF_CERTS/$SELECTED_DOMAIN" ]; then
            cp -L "$le_path/fullchain.pem" "$PANEL_DEF_CERTS/$SELECTED_DOMAIN/"
            cp -L "$le_path/privkey.pem" "$PANEL_DEF_CERTS/$SELECTED_DOMAIN/"
            chmod 644 "$PANEL_DEF_CERTS/$SELECTED_DOMAIN/"*.pem
            ui_success "Updated panel certificate"
        fi
        
        if [ -d "$NODE_DEF_CERTS/$SELECTED_DOMAIN" ] && [ "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]; then
            cp -L "$le_path/fullchain.pem" "$NODE_DEF_CERTS/$SELECTED_DOMAIN/"
            cp -L "$le_path/privkey.pem" "$NODE_DEF_CERTS/$SELECTED_DOMAIN/"
            chmod 644 "$NODE_DEF_CERTS/$SELECTED_DOMAIN/"*.pem
            ui_success "Updated node certificate"
        fi
    else
        ui_error "Certificate renewal failed!"
        echo -e "\n${YELLOW}Certbot output:${NC}"
        tail -n 20 "$CERTBOT_DEBUG_LOG"
        log_error "Failed to renew certificate for $SELECTED_DOMAIN"
    fi

    # Restore services
    [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null && NGINX_WAS_RUNNING=false
    [ "$APACHE_WAS_RUNNING" = true ] && systemctl start apache2 2>/dev/null && APACHE_WAS_RUNNING=false

    restart_service "panel"
    restart_service "node"

    # Offer sync
    if [ -f "$SERVERS_FILE" ] && [ -s "$SERVERS_FILE" ]; then
        echo ""
        read -p "Sync to other servers? (y/N): " SYNC_NOW
        [[ "$SYNC_NOW" =~ ^[Yy]$ ]] && sync_domain_to_all_servers "$SELECTED_DOMAIN"
    fi

    pause
}

# ==========================================
# SYNC HELPER FUNCTION
# ==========================================
sync_domain_to_all_servers() {
    local DOMAIN=$1
    local CERT_PATH="/etc/letsencrypt/live/$DOMAIN"

    [ ! -d "$CERT_PATH" ] && ui_error "Certificate not found: $DOMAIN" && return 1

    echo -e "\n${YELLOW}Syncing $DOMAIN to all servers...${NC}"

    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo -ne "  ${YELLOW}[$name]${NC} $host ... "
        if sync_to_server "$host" "$port" "$user" "$path" "$DOMAIN" "$CERT_PATH" "$panel"; then
            echo -e "${GREEN}✔${NC}"
        else
            echo -e "${RED}✘${NC}"
        fi
    done < "$SERVERS_FILE"
}

# ==========================================
# 🆕 BACKUP CERTIFICATES (NEW!)
# ==========================================
backup_certificates() {
    ui_header "💾 BACKUP CERTIFICATES"
    init_logging
    detect_active_panel > /dev/null

    local BACKUP_NAME="ssl-backup-$(date +%Y%m%d-%H%M%S)"
    local BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

    mkdir -p "$BACKUP_PATH"

    echo -e "${YELLOW}Creating backup...${NC}\n"

    # Backup Let's Encrypt
    if [ -d "/etc/letsencrypt" ]; then
        echo "  Backing up Let's Encrypt..."
        cp -r /etc/letsencrypt "$BACKUP_PATH/" 2>/dev/null
    fi

    # Backup panel certs
    if [ -d "$PANEL_DEF_CERTS" ]; then
        echo "  Backing up panel certificates..."
        mkdir -p "$BACKUP_PATH/panel-certs"
        cp -r "$PANEL_DEF_CERTS"/* "$BACKUP_PATH/panel-certs/" 2>/dev/null
    fi

    # Backup node certs
    if [ -d "$NODE_DEF_CERTS" ] && [ "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]; then
        echo "  Backing up node certificates..."
        mkdir -p "$BACKUP_PATH/node-certs"
        cp -r "$NODE_DEF_CERTS"/* "$BACKUP_PATH/node-certs/" 2>/dev/null
    fi

    # Create tarball
    echo "  Creating compressed archive..."
    cd "$BACKUP_DIR"
    tar -czf "$BACKUP_NAME.tar.gz" "$BACKUP_NAME" 2>/dev/null
    rm -rf "$BACKUP_PATH"

    local FINAL_PATH="$BACKUP_DIR/$BACKUP_NAME.tar.gz"
    local SIZE=$(du -h "$FINAL_PATH" 2>/dev/null | cut -f1)

    echo ""
    ui_success "Backup created!"
    echo -e "  ${YELLOW}Path:${NC} $FINAL_PATH"
    echo -e "  ${YELLOW}Size:${NC} $SIZE"

    log_success "Backup created: $FINAL_PATH"
    pause
}

# ==========================================
# 🆕 SETUP AUTO-RENEWAL CRON (NEW!)
# ==========================================
setup_auto_renewal() {
    ui_header "⏰ SETUP AUTO-RENEWAL"
    detect_active_panel > /dev/null

    local CRON_FILE="/etc/cron.d/ssl-auto-renew"
    local SCRIPT_PATH="/opt/mrm-manager/ssl-renew-hook.sh"

    echo -e "${YELLOW}This will setup automatic certificate renewal.${NC}\n"
    echo "Schedule: Daily at 3:00 AM"
    echo "Action: Renew + update panel/node paths + restart services"
    echo ""

    read -p "Proceed? (Y/n): " PROCEED
    [[ "$PROCEED" =~ ^[Nn]$ ]] && return

    # Create renewal hook script
    cat > "$SCRIPT_PATH" << 'HOOK_EOF'
#!/bin/bash
# Auto-generated by MRM Manager

PANEL_DEF_CERTS="__PANEL_CERTS__"
NODE_DEF_CERTS="__NODE_CERTS__"

for dir in /etc/letsencrypt/live/*/; do
    domain=$(basename "$dir")
    [ "$domain" == "README" ] && continue
    
    # Update panel certs
    if [ -d "$PANEL_DEF_CERTS/$domain" ]; then
        cp -L "$dir/fullchain.pem" "$PANEL_DEF_CERTS/$domain/"
        cp -L "$dir/privkey.pem" "$PANEL_DEF_CERTS/$domain/"
        chmod 644 "$PANEL_DEF_CERTS/$domain/"*.pem
    fi
    
    # Update node certs
    if [ -d "$NODE_DEF_CERTS/$domain" ] && [ "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]; then
        cp -L "$dir/fullchain.pem" "$NODE_DEF_CERTS/$domain/"
        cp -L "$dir/privkey.pem" "$NODE_DEF_CERTS/$domain/"
        chmod 644 "$NODE_DEF_CERTS/$domain/"*.pem
    fi
done

# Restart services
systemctl reload nginx 2>/dev/null || true
HOOK_EOF

    # Replace placeholders
    sed -i "s|__PANEL_CERTS__|$PANEL_DEF_CERTS|g" "$SCRIPT_PATH"
    sed -i "s|__NODE_CERTS__|$NODE_DEF_CERTS|g" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # Create cron job
    cat > "$CRON_FILE" << EOF
# SSL Auto-Renewal - MRM Manager
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * * root certbot renew --quiet --deploy-hook "$SCRIPT_PATH"
EOF

    chmod 644 "$CRON_FILE"

    ui_success "Auto-renewal configured!"
    echo -e "  ${YELLOW}Cron:${NC} $CRON_FILE"
    echo -e "  ${YELLOW}Hook:${NC} $SCRIPT_PATH"
    echo -e "\n${CYAN}Test with:${NC} certbot renew --dry-run"

    log_success "Auto-renewal cron configured"
    pause
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
    check_dependencies || return 1

    log_info "========== SSL Generation Started =========="
    log_info "Email: $EMAIL, Domains: ${DOMAINS[*]}"

    echo -e "${YELLOW}[1/6] Network & DNS Validation...${NC}"

    if ! curl -s --connect-timeout 15 https://acme-v02.api.letsencrypt.org/directory > /dev/null; then
        ui_error "Let's Encrypt API unreachable!"
        log_error "Let's Encrypt API unreachable"
        return 1
    fi

    echo -e "${YELLOW}[2/6] DNS Validation...${NC}"
    for D in "${DOMAINS[@]}"; do
        validate_domain_dns "$D" || return 1
    done

    echo -e "${YELLOW}[3/6] Firewall Configuration...${NC}"
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp > /dev/null 2>&1
        ufw allow 443/tcp > /dev/null 2>&1
    fi

    echo -e "${YELLOW}[4/6] Stopping services...${NC}"

    if systemctl is-active --quiet nginx; then
        NGINX_WAS_RUNNING=true
        systemctl stop nginx 2>/dev/null
    fi
    if systemctl is-active --quiet apache2; then
        APACHE_WAS_RUNNING=true
        systemctl stop apache2 2>/dev/null
    fi
    command -v fuser &>/dev/null && fuser -k 80/tcp 2>/dev/null

    sleep 2
    if ! check_port_availability 80; then
        ui_error "Port 80 still in use!"
        [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null && NGINX_WAS_RUNNING=false
        return 1
    fi

    # Build domain flags
    local DOM_FLAGS=""
    for D in "${DOMAINS[@]}"; do
        DOM_FLAGS="$DOM_FLAGS -d $D"
    done

    echo -e "${YELLOW}[5/6] Requesting Certificate...${NC}"
    echo -e "${CYAN}This may take up to 2 minutes...${NC}"

    certbot certonly --standalone \
        --non-interactive --agree-tos \
        --email "$EMAIL" \
        --preferred-challenges http \
        --http-01-port 80 \
        $DOM_FLAGS > "$CERTBOT_DEBUG_LOG" 2>&1

    local CERTBOT_RESULT=$?

    echo -e "${YELLOW}[6/6] Restoring Services...${NC}"

    [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null && NGINX_WAS_RUNNING=false
    [ "$APACHE_WAS_RUNNING" = true ] && systemctl start apache2 2>/dev/null && APACHE_WAS_RUNNING=false

    if [ $CERTBOT_RESULT -eq 0 ]; then
        ui_success "SSL Generation Successful!"
        log_success "SSL generated for ${DOMAINS[*]}"
    else
        ui_error "SSL Generation Failed!"
        tail -n 15 "$CERTBOT_DEBUG_LOG"
        log_error "Certbot failed with code $CERTBOT_RESULT"
    fi

    return $CERTBOT_RESULT
}

# ==========================================
# PROCESS PANEL SSL
# ==========================================
_process_panel() {
    local PRIMARY_DOM=$1
    detect_active_panel > /dev/null

    echo -e "\n${CYAN}--- Configuring Panel SSL ---${NC}"

    [ ! -f "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" ] && ui_error "Source not found!" && return 1

    echo "Storage options:"
    echo "1) Default ($PANEL_DEF_CERTS/$PRIMARY_DOM)"
    echo "2) Custom"
    read -p "Select: " PATH_OPT

    local BASE_DIR="$PANEL_DEF_CERTS"
    [[ "$PATH_OPT" == "2" ]] && read -p "Enter path: " BASE_DIR && BASE_DIR=$(sanitize_input "$BASE_DIR")

    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        chmod 644 "$TARGET_DIR"/*.pem

        [ ! -f "$PANEL_ENV" ] && touch "$PANEL_ENV"

        sed -i '/UVICORN_SSL_CERTFILE/d' "$PANEL_ENV"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$PANEL_ENV"
        echo "UVICORN_SSL_CERTFILE = \"$TARGET_DIR/fullchain.pem\"" >> "$PANEL_ENV"
        echo "UVICORN_SSL_KEYFILE = \"$TARGET_DIR/privkey.pem\"" >> "$PANEL_ENV"

        restart_service "panel"

        ui_success "Panel SSL Updated!"
        echo -e "  Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
        echo -e "  Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
        log_success "Panel SSL configured for $PRIMARY_DOM"
    else
        ui_error "Copy failed!"
        return 1
    fi
}

# ==========================================
# PROCESS NODE SSL
# ==========================================
_process_node() {
    local PRIMARY_DOM=$1
    detect_active_panel > /dev/null
    
    echo -e "\n${PURPLE}--- Configuring Node SSL ---${NC}"

    [ ! -f "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" ] && ui_error "Source not found!" && return 1

    echo "Storage options:"
    echo "1) Default ($NODE_DEF_CERTS/$PRIMARY_DOM)"
    echo "2) Custom"
    read -p "Select: " PATH_OPT

    local BASE_DIR="$NODE_DEF_CERTS"
    [[ "$PATH_OPT" == "2" ]] && read -p "Enter path: " BASE_DIR && BASE_DIR=$(sanitize_input "$BASE_DIR")

    local TARGET_DIR="$BASE_DIR/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        chmod 644 "$TARGET_DIR"/*.pem

        if [ -f "$NODE_ENV" ]; then
            sed -i '/SSL_CERT_FILE/d' "$NODE_ENV"
            sed -i '/SSL_KEY_FILE/d' "$NODE_ENV"
            echo "SSL_CERT_FILE = \"$TARGET_DIR/fullchain.pem\"" >> "$NODE_ENV"
            echo "SSL_KEY_FILE = \"$TARGET_DIR/privkey.pem\"" >> "$NODE_ENV"
            restart_service "node"
            ui_success "Node SSL Updated!"
        else
            ui_warning "Node .env not found - manual config needed"
        fi

        echo -e "  Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
        echo -e "  Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
        log_success "Node SSL configured for $PRIMARY_DOM"
    else
        ui_error "Copy failed!"
        return 1
    fi
}

# ==========================================
# PROCESS CONFIG SSL (INBOUNDS)
# ==========================================
_process_config() {
    local PRIMARY_DOM=$1
    detect_active_panel > /dev/null
    
    echo -e "\n${ORANGE}--- Config SSL (Inbounds) ---${NC}"

    [ ! -f "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" ] && ui_error "Source not found!" && return 1

    local TARGET_DIR="$PANEL_DEF_CERTS/$PRIMARY_DOM"
    mkdir -p "$TARGET_DIR"

    if cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/fullchain.pem" "$TARGET_DIR/" && \
       cp -L "/etc/letsencrypt/live/$PRIMARY_DOM/privkey.pem" "$TARGET_DIR/"; then

        chmod 755 "$TARGET_DIR"
        chmod 644 "$TARGET_DIR"/*.pem

        ui_success "Files Saved!"
        echo -e "\n${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║     Copy these paths to your Inbound Settings:           ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}  Cert: ${CYAN}$TARGET_DIR/fullchain.pem${NC}"
        echo -e "${YELLOW}║${NC}  Key:  ${CYAN}$TARGET_DIR/privkey.pem${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        log_success "Inbound SSL configured for $PRIMARY_DOM"
    else
        ui_error "Copy failed!"
        return 1
    fi
}

# ==========================================
# SSL WIZARD
# ==========================================
ssl_wizard() {
    ui_header "🔐 SSL GENERATION WIZARD"
    init_logging
    detect_active_panel > /dev/null

    check_dependencies || { pause; return; }

    echo -e "${CYAN}Panel: $(basename $PANEL_DIR)${NC}"
    echo -e "${CYAN}Certs: $PANEL_DEF_CERTS${NC}\n"

    read -p "How many domains? (1-10): " COUNT
    if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 10 ]; then
        ui_error "Invalid number."
        pause; return
    fi

    declare -a DOMAIN_LIST
    for (( i=1; i<=COUNT; i++ )); do
        read -p "Domain $i: " D_INPUT
        D_INPUT=$(sanitize_input "$D_INPUT")
        
        if [ -z "$D_INPUT" ]; then
            ui_error "Cannot be empty."; i=$((i-1)); continue
        fi
        if ! validate_domain "$D_INPUT"; then
            ui_error "Invalid format: $D_INPUT"; i=$((i-1)); continue
        fi
        DOMAIN_LIST+=("$D_INPUT")
    done

    [ ${#DOMAIN_LIST[@]} -eq 0 ] && return

    read -p "Email: " MAIL
    MAIL=$(sanitize_input "$MAIL")
    
    if [ -z "$MAIL" ] || ! validate_email "$MAIL"; then
        ui_error "Invalid email."
        pause; return
    fi

    local PRIMARY_DOM=${DOMAIN_LIST[0]}

    _get_cert_action "$MAIL" "${DOMAIN_LIST[@]}" || { pause; return; }

    [ ! -d "/etc/letsencrypt/live/$PRIMARY_DOM" ] && { ui_error "Certificate not found!"; pause; return; }

    ui_success "Success! Primary: $PRIMARY_DOM\n"

    echo "Where to use this certificate?"
    echo "1) Panel (Dashboard)"
    echo "2) Node Server"
    echo "3) Config (Inbounds)"
    echo "4) All"
    read -p "Select: " TYPE_OPT

    case $TYPE_OPT in
        1) _process_panel "$PRIMARY_DOM" ;;
        2) _process_node "$PRIMARY_DOM" ;;
        3) _process_config "$PRIMARY_DOM" ;;
        4) _process_panel "$PRIMARY_DOM"; _process_node "$PRIMARY_DOM"; _process_config "$PRIMARY_DOM" ;;
        *) ui_error "Invalid selection." ;;
    esac

    offer_multi_server_sync "$PRIMARY_DOM"
    log_info "========== SSL Generation Completed =========="
    pause
}

# ==========================================
# MULTI-SERVER FUNCTIONS
# ==========================================
multi_server_menu() {
    while true; do
        ui_header "🌐 MULTI-SERVER SSL SYNC"

        echo "1) 📋 List Servers"
        echo "2) ➕ Add Server"
        echo "3) ➖ Remove Server"
        echo "4) 🔄 Sync to All"
        echo "5) 🔄 Sync to Specific"
        echo "6) 🔑 Setup SSH Key"
        echo "7) 🧪 Test Connections"
        echo ""
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
        esac
    done
}

list_servers() {
    ui_header "📋 CONFIGURED SERVERS"

    if [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ]; then
        ui_warning "No servers configured."
        pause; return
    fi

    printf "${GREEN}%-3s │ %-17s │ %-17s │ %-5s │ %s${NC}\n" "ID" "Name" "Host" "Port" "Path"
    echo "────┼───────────────────┼───────────────────┼───────┼──────────────────"

    local idx=1
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        printf "%-3s │ %-17s │ %-17s │ %-5s │ %s\n" "$idx" "$name" "$host" "$port" "$path"
        ((idx++))
    done < "$SERVERS_FILE"

    pause
}

add_server() {
    ui_header "➕ ADD SERVER"

    read -p "Name: " SERVER_NAME
    [ -z "$SERVER_NAME" ] && ui_error "Required." && pause && return
    SERVER_NAME=$(sanitize_input "$SERVER_NAME")

    read -p "IP/Host: " SERVER_HOST
    [ -z "$SERVER_HOST" ] && ui_error "Required." && pause && return
    SERVER_HOST=$(sanitize_input "$SERVER_HOST")

    read -p "SSH Port [22]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-22}

    read -p "SSH User [root]: " SERVER_USER
    SERVER_USER=${SERVER_USER:-root}

    echo -e "\nPanel type:"
    echo "1) Marzban"
    echo "2) Pasarguard"
    echo "3) Rebecca"
    echo "4) X-UI"
    echo "5) Custom"
    read -p "Select: " PANEL_TYPE

    local REMOTE_PATH="" PANEL_NAME=""

    case $PANEL_TYPE in
        1) PANEL_NAME="marzban"; REMOTE_PATH="/var/lib/marzban/certs" ;;
        2) PANEL_NAME="pasarguard"; REMOTE_PATH="/var/lib/pasarguard/certs" ;;
        3) PANEL_NAME="rebecca"; REMOTE_PATH="/var/lib/rebecca/certs" ;;
        4) PANEL_NAME="x-ui"; REMOTE_PATH="/var/lib/x-ui/certs" ;;
        5) PANEL_NAME="custom"; read -p "Remote path: " REMOTE_PATH ;;
        *) ui_error "Invalid."; pause; return ;;
    esac

    touch "$SERVERS_FILE"
    echo "${SERVER_NAME}|${SERVER_HOST}|${SERVER_PORT}|${SERVER_USER}|${REMOTE_PATH}|${PANEL_NAME}" >> "$SERVERS_FILE"

    ui_success "Server added!"
    log_info "Added server: $SERVER_NAME ($SERVER_HOST)"

    read -p "Test connection? (Y/n): " TEST_NOW
    [[ ! "$TEST_NOW" =~ ^[Nn]$ ]] && test_server_connection "$SERVER_HOST" "$SERVER_PORT" "$SERVER_USER"

    pause
}

remove_server() {
    ui_header "➖ REMOVE SERVER"

    [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ] && ui_warning "No servers." && pause && return

    local idx=1
    declare -a server_names
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo "$idx) $name ($host)"
        server_names[$idx]="$name"
        ((idx++))
    done < "$SERVERS_FILE"

    read -p "Select (0=cancel): " SEL
    [ "$SEL" == "0" ] && return

    local REMOVE_NAME=${server_names[$SEL]}
    [ -z "$REMOVE_NAME" ] && ui_error "Invalid." && pause && return

    grep -v "^${REMOVE_NAME}|" "$SERVERS_FILE" > "${SERVERS_FILE}.tmp"
    mv "${SERVERS_FILE}.tmp" "$SERVERS_FILE"

    ui_success "Removed: $REMOVE_NAME"
    log_info "Removed server: $REMOVE_NAME"
    pause
}

test_server_connection() {
    local HOST=$1 PORT=$2 USER=$3
    echo -e "${YELLOW}Testing $USER@$HOST:$PORT...${NC}"

    if ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$PORT" "$USER@$HOST" "echo OK" 2>/dev/null; then
        ui_success "Connected!"
        return 0
    else
        ui_error "Failed!"
        echo -e "${YELLOW}Check: SSH running, key configured, firewall allows port $PORT${NC}"
        return 1
    fi
}

test_all_connections() {
    ui_header "🧪 TEST ALL CONNECTIONS"

    [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ] && ui_warning "No servers." && pause && return

    local success=0 failed=0

    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo -ne "${YELLOW}[$name]${NC} $host:$port ... "
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$port" "$user@$host" "exit" 2>/dev/null; then
            echo -e "${GREEN}✔${NC}"; ((success++))
        else
            echo -e "${RED}✘${NC}"; ((failed++))
        fi
    done < "$SERVERS_FILE"

    echo -e "\n${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"
    pause
}

setup_ssh_keys() {
    ui_header "🔑 SETUP SSH KEY"

    if [ ! -f ~/.ssh/id_rsa ]; then
        echo -e "${YELLOW}Generating SSH key...${NC}"
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        ui_success "Key generated."
    else
        ui_success "Key exists."
    fi

    [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ] && ui_warning "No servers." && pause && return

    echo -e "\n${YELLOW}Select server:${NC}\n"

    local idx=1
    declare -a hosts ports users
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo "$idx) $name ($host)"
        hosts[$idx]="$host"; ports[$idx]="$port"; users[$idx]="$user"
        ((idx++))
    done < "$SERVERS_FILE"

    echo "$idx) All servers"
    echo "0) Cancel"
    read -p "Select: " SEL

    [ "$SEL" == "0" ] && return

    if [ "$SEL" == "$idx" ]; then
        for ((i=1; i<idx; i++)); do
            echo -e "\n${YELLOW}Setting up ${hosts[$i]}...${NC}"
            ssh-copy-id -p "${ports[$i]}" "${users[$i]}@${hosts[$i]}" 2>/dev/null
        done
    else
        [ -z "${hosts[$SEL]}" ] && ui_error "Invalid." && pause && return
        ssh-copy-id -p "${ports[$SEL]}" "${users[$SEL]}@${hosts[$SEL]}"
    fi

    ui_success "SSH key setup complete!"
    pause
}

sync_to_server() {
    local HOST=$1 PORT=$2 USER=$3 REMOTE_BASE=$4 DOMAIN=$5 LOCAL_PATH=$6 PANEL=$7
    local REMOTE_PATH="$REMOTE_BASE/$DOMAIN"

    # Create directory
    ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$PORT" "$USER@$HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null || return 1

    # Copy files
    scp -o ConnectTimeout=10 -o BatchMode=yes -P "$PORT" \
        "$LOCAL_PATH/fullchain.pem" "$USER@$HOST:$REMOTE_PATH/" 2>/dev/null || return 1
    scp -o ConnectTimeout=10 -o BatchMode=yes -P "$PORT" \
        "$LOCAL_PATH/privkey.pem" "$USER@$HOST:$REMOTE_PATH/" 2>/dev/null || return 1

    # Set permissions and restart
    ssh -o BatchMode=yes -p "$PORT" "$USER@$HOST" "
        chmod 644 $REMOTE_PATH/*.pem 2>/dev/null
        [ -n '$PANEL' ] && [ '$PANEL' != 'custom' ] && {
            cd /opt/$PANEL 2>/dev/null && docker compose restart 2>/dev/null || systemctl restart $PANEL 2>/dev/null
        }
    " 2>/dev/null

    log_success "Synced $DOMAIN to $HOST"
    return 0
}

sync_all_servers() {
    ui_header "🔄 SYNC TO ALL SERVERS"

    [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ] && ui_warning "No servers." && pause && return

    echo -e "${YELLOW}Select certificate:${NC}\n"

    local idx=1
    declare -a domains

    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        domains[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done

    [ $idx -eq 1 ] && ui_error "No certificates." && pause && return

    read -p "Select: " CERT_SEL
    local SELECTED=${domains[$CERT_SEL]}
    [ -z "$SELECTED" ] && ui_error "Invalid." && pause && return

    local CERT_PATH="/etc/letsencrypt/live/$SELECTED"

    echo -e "\n${YELLOW}Syncing $SELECTED...${NC}\n"

    local success=0 failed=0

    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo -ne "${YELLOW}[$name]${NC} $host ... "
        if sync_to_server "$host" "$port" "$user" "$path" "$SELECTED" "$CERT_PATH" "$panel"; then
            echo -e "${GREEN}✔${NC}"; ((success++))
        else
            echo -e "${RED}✘${NC}"; ((failed++))
        fi
    done < "$SERVERS_FILE"

    echo -e "\n${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"
    pause
}

sync_specific_server() {
    ui_header "🔄 SYNC TO SPECIFIC SERVER"

    [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ] && ui_warning "No servers." && pause && return

    echo -e "${YELLOW}Select server:${NC}\n"

    local idx=1
    declare -a names hosts ports users paths panels
    while IFS='|' read -r name host port user path panel; do
        [ -z "$name" ] && continue
        echo "$idx) $name ($host)"
        names[$idx]="$name"; hosts[$idx]="$host"; ports[$idx]="$port"
        users[$idx]="$user"; paths[$idx]="$path"; panels[$idx]="$panel"
        ((idx++))
    done < "$SERVERS_FILE"

    read -p "Select: " SERVER_SEL
    [ -z "${hosts[$SERVER_SEL]}" ] && ui_error "Invalid." && pause && return

    echo -e "\n${YELLOW}Select certificate:${NC}\n"

    idx=1
    declare -a domains

    for dir in /etc/letsencrypt/live/*/; do
        local domain=$(basename "$dir")
        [ "$domain" == "README" ] && continue
        domains[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done

    [ $idx -eq 1 ] && ui_error "No certificates." && pause && return

    read -p "Select: " CERT_SEL
    local SELECTED=${domains[$CERT_SEL]}
    [ -z "$SELECTED" ] && ui_error "Invalid." && pause && return

    local CERT_PATH="/etc/letsencrypt/live/$SELECTED"

    echo -e "\n${YELLOW}Syncing $SELECTED to ${names[$SERVER_SEL]}...${NC}"

    if sync_to_server "${hosts[$SERVER_SEL]}" "${ports[$SERVER_SEL]}" "${users[$SERVER_SEL]}" \
                      "${paths[$SERVER_SEL]}" "$SELECTED" "$CERT_PATH" "${panels[$SERVER_SEL]}"; then
        ui_success "Sync completed!"
    else
        ui_error "Sync failed!"
    fi

    pause
}

offer_multi_server_sync() {
    [ ! -f "$SERVERS_FILE" ] || [ ! -s "$SERVERS_FILE" ] && return

    local count=$(wc -l < "$SERVERS_FILE")
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}$count server(s) configured.${NC}"
    read -p "Sync to servers? (y/N): " SYNC_NOW

    if [[ "$SYNC_NOW" =~ ^[Yy]$ ]]; then
        sync_domain_to_all_servers "$1"
    fi
}

# ==========================================
# SHOW SSL PATHS
# ==========================================
show_detailed_paths() {
    ui_header "📁 SSL FILE PATHS"
    detect_active_panel > /dev/null

    echo -e "${GREEN}--- Panel Certificates ---${NC}"
    if [ -d "$PANEL_DEF_CERTS" ] && [ "$(ls -A $PANEL_DEF_CERTS 2>/dev/null)" ]; then
        for dir in "$PANEL_DEF_CERTS"/*; do
            [ -d "$dir" ] || continue
            local dom=$(basename "$dir")
            echo -e "  ${YELLOW}$dom${NC}"
            [ -f "$dir/fullchain.pem" ] && echo -e "    Cert: ${CYAN}$dir/fullchain.pem${NC}"
            [ -f "$dir/privkey.pem" ] && echo -e "    Key:  ${CYAN}$dir/privkey.pem${NC}"
        done
    else
        echo "  No certificates."
    fi

    echo -e "\n${PURPLE}--- Node Certificates ---${NC}"
    if [ -d "$NODE_DEF_CERTS" ] && [ "$(ls -A $NODE_DEF_CERTS 2>/dev/null)" ]; then
        for dir in "$NODE_DEF_CERTS"/*; do
            [ -d "$dir" ] || continue
            local dom=$(basename "$dir")
            echo -e "  ${YELLOW}$dom${NC}"
            [ -f "$dir/fullchain.pem" ] && echo -e "    Cert: ${CYAN}$dir/fullchain.pem${NC}"
            [ -f "$dir/privkey.pem" ] && echo -e "    Key:  ${CYAN}$dir/privkey.pem${NC}"
        done
    else
        echo "  No certificates."
    fi

    pause
}

# ==========================================
# VIEW CERTIFICATE CONTENT
# ==========================================
view_cert_content() {
    ui_header "📄 VIEW CERTIFICATE"
    detect_active_panel > /dev/null

    declare -a all_certs
    local idx=1

    for dir in "$PANEL_DEF_CERTS"/* "$NODE_DEF_CERTS"/*; do
        [ -d "$dir" ] || continue
        local dom=$(basename "$dir")
        local type="panel"
        [[ "$dir" == "$NODE_DEF_CERTS"* ]] && type="node"
        all_certs[$idx]="$dir"
        echo -e "$idx) [$type] $dom"
        ((idx++))
    done

    [ $idx -eq 1 ] && echo "No certificates." && pause && return

    read -p "Select: " NUM
    local SELECTED=${all_certs[$NUM]}
    [ -z "$SELECTED" ] && ui_error "Invalid." && pause && return

    echo -e "\n1) Certificate (fullchain.pem)"
    echo "2) Private Key (privkey.pem)"
    read -p "Select: " F_OPT

    local FILE=""
    [ "$F_OPT" == "1" ] && FILE="fullchain.pem"
    [ "$F_OPT" == "2" ] && FILE="privkey.pem"

    if [ -f "$SELECTED/$FILE" ]; then
        clear
        echo -e "${YELLOW}--- $FILE ---${NC}"
        cat "$SELECTED/$FILE"
        echo -e "${YELLOW}--- END ---${NC}"
    else
        ui_error "File not found."
    fi
    pause
}

# ==========================================
# VIEW LOGS
# ==========================================
view_ssl_logs() {
    ui_header "📋 SSL LOGS"

    echo "1) SSL Manager Log (last 50)"
    echo "2) Certbot Log (last 50)"
    echo "3) Clear Logs"
    echo "0) Back"
    read -p "Select: " OPT

    case $OPT in
        1) [ -f "$SSL_LOG_FILE" ] && tail -n 50 "$SSL_LOG_FILE" || echo "Not found."; pause ;;
        2) [ -f "$CERTBOT_DEBUG_LOG" ] && tail -n 50 "$CERTBOT_DEBUG_LOG" || echo "Not found."; pause ;;
        3) > "$SSL_LOG_FILE" 2>/dev/null; > "$CERTBOT_DEBUG_LOG" 2>/dev/null; ui_success "Cleared."; pause ;;
    esac
}

# ==========================================
# RENEW ALL CERTIFICATES (Legacy)
# ==========================================
renew_certificates() {
    ui_header "🔄 RENEW ALL CERTIFICATES"
    init_logging

    if systemctl is-active --quiet nginx; then
        NGINX_WAS_RUNNING=true
        systemctl stop nginx 2>/dev/null
    fi
    if systemctl is-active --quiet apache2; then
        APACHE_WAS_RUNNING=true
        systemctl stop apache2 2>/dev/null
    fi

    echo -e "${YELLOW}Renewing...${NC}"
    certbot renew --standalone > "$CERTBOT_DEBUG_LOG" 2>&1
    local RESULT=$?

    [ "$NGINX_WAS_RUNNING" = true ] && systemctl start nginx 2>/dev/null && NGINX_WAS_RUNNING=false
    [ "$APACHE_WAS_RUNNING" = true ] && systemctl start apache2 2>/dev/null && APACHE_WAS_RUNNING=false

    [ $RESULT -eq 0 ] && ui_success "Renewal completed!" || { ui_error "Renewal failed!"; tail -n 20 "$CERTBOT_DEBUG_LOG"; }

    pause
}

# ==========================================
# 🆕 MAIN SSL MENU (UPDATED!)
# ==========================================
ssl_menu() {
    init_logging

    while true; do
        clear
        ui_header "🔐 SSL MANAGEMENT"
        detect_active_panel > /dev/null

        echo -e "${CYAN}Panel: $(basename $PANEL_DIR)${NC}\n"
        
        echo "1) 🔐 Request New SSL Certificate"
        echo "2) 📅 View Certificate Expiry Status"   # 🆕 NEW!
        echo "3) 📁 Show SSL File Paths"
        echo "4) 📄 View Certificate Content"
        echo "5) 🔄 Smart Renew (Expiring Only)"      # 🆕 NEW!
        echo "6) 🔄 Force Renew All"
        echo "7) 🌐 Multi-Server Sync"
        echo "8) 💾 Backup Certificates"              # 🆕 NEW!
        echo "9) ⏰ Setup Auto-Renewal"               # 🆕 NEW!
        echo "10) 📋 View Logs"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) ssl_wizard ;;
            2) show_certificate_expiry ;;          # 🆕 NEW!
            3) show_detailed_paths ;;
            4) view_cert_content ;;
            5) show_certificate_expiry ;;          # 🆕 Goes to expiry view with renew options
            6) renew_certificates ;;
            7) multi_server_menu ;;
            8) backup_certificates ;;              # 🆕 NEW!
            9) setup_auto_renewal ;;               # 🆕 NEW!
            10) view_ssl_logs ;;
            0) return ;;
        esac
    done
}

# ==========================================
# ENTRY POINT (if run directly)
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ssl_menu
fi