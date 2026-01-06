#!/bin/bash

# ============================================
# INBOUND MANAGER - Library Functions
# Version: 2.1 (Fixed Display)
# ============================================

# ============ CONFIG PATHS ============
inbound_init_paths() {
    detect_active_panel > /dev/null

    if [ -f "$DATA_DIR/xray_config.json" ]; then
        XRAY_CONFIG="$DATA_DIR/xray_config.json"
    elif [ -f "$DATA_DIR/config.json" ]; then
        XRAY_CONFIG="$DATA_DIR/config.json"
    elif [ -f "$PANEL_DIR/xray_config.json" ]; then
        XRAY_CONFIG="$PANEL_DIR/xray_config.json"
    else
        XRAY_CONFIG="$DATA_DIR/xray_config.json"
    fi

    INBOUND_BACKUP_DIR="$DATA_DIR/backups/inbounds"
    INBOUND_EXPORT_DIR="$DATA_DIR/exports"
    mkdir -p "$INBOUND_BACKUP_DIR" "$INBOUND_EXPORT_DIR" 2>/dev/null
    
    export XRAY_CONFIG
    export INBOUND_BACKUP_DIR
    export INBOUND_EXPORT_DIR
}

# ============ GENERATORS ============
gen_uuid() { 
    cat /proc/sys/kernel/random/uuid 
}

gen_short_id() { 
    openssl rand -hex 8 
}

gen_password() { 
    openssl rand -base64 16 | tr -d '=/+' | head -c 16 
}

gen_ss_password() { 
    openssl rand -base64 32 
}

gen_random_port() { 
    shuf -i 10000-65000 -n 1 
}

# ============ XRAY CONTAINER ============
get_xray_container() {
    docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | \
        grep -iE "pasarguard|rebecca|marzban|xray" | \
        grep -v "mysql" | grep -v "mariadb" | \
        head -1 | awk '{print $1}'
}

gen_x25519_keys() {
    local CID=$(get_xray_container)

    if [ -n "$CID" ]; then
        local KEYS=$(docker exec "$CID" xray x25519 2>/dev/null)
        if [ -z "$KEYS" ]; then
            KEYS=$(docker exec "$CID" /usr/local/bin/xray x25519 2>/dev/null)
        fi
        if [ -n "$KEYS" ]; then
            echo "$KEYS"
            return 0
        fi
    fi

    if command -v xray &> /dev/null; then
        xray x25519 2>/dev/null
        return 0
    fi

    echo "Private: ERROR Public: ERROR"
    return 1
}

# ============ BACKUP ============
backup_xray_config() {
    inbound_init_paths
    if [ -f "$XRAY_CONFIG" ]; then
        local BACKUP_FILE="$INBOUND_BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json"
        cp "$XRAY_CONFIG" "$BACKUP_FILE"
    fi
}

# ============ REQUIREMENTS CHECK ============
check_inbound_requirements() {
    local MISSING=false

    for cmd in python3 openssl jq; do
        if ! command -v $cmd &> /dev/null; then
            apt-get install -y $cmd -qq > /dev/null 2>&1
            if ! command -v $cmd &> /dev/null; then
                MISSING=true
            fi
        fi
    done

    inbound_init_paths

    if [ ! -f "$XRAY_CONFIG" ]; then
        mkdir -p "$(dirname "$XRAY_CONFIG")"
        echo '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[]}}' > "$XRAY_CONFIG"
    fi

    [ "$MISSING" = true ] && return 1
    return 0
}

# ============ PORT VALIDATION ============
check_port_available() {
    local PORT=$1
    local EXCLUDE_TAG=${2:-""}

    python3 << PYEOF
import json
import sys
try:
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    for ib in config.get('inbounds', []):
        if ib.get('port') == $PORT:
            if "$EXCLUDE_TAG" and ib.get('tag') == "$EXCLUDE_TAG":
                continue
            print(f"USED:{ib.get('tag')}")
            sys.exit(1)
    print("OK")
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
PYEOF
}

input_port() {
    local DEFAULT=${1:-$(gen_random_port)}

    while true; do
        read -p "  Port [$DEFAULT]: " PORT
        [ -z "$PORT" ] && PORT="$DEFAULT"

        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "  ${UI_RED}✘ Invalid port!${UI_NC}"
            continue
        fi

        local CHECK=$(check_port_available "$PORT")
        if [[ "$CHECK" == USED:* ]]; then
            local EXISTING=$(echo "$CHECK" | cut -d: -f2)
            echo -e "  ${UI_RED}✘ Port used by '$EXISTING'${UI_NC}"
            continue
        fi

        echo "$PORT"
        return
    done
}

# ============ SIMPLE INPUT ============
simple_input() {
    local LABEL=$1
    local DEFAULT=$2
    local RESULT=""
    
    if [ -n "$DEFAULT" ]; then
        read -p "  $LABEL [$DEFAULT]: " RESULT
        [ -z "$RESULT" ] && RESULT="$DEFAULT"
    else
        read -p "  $LABEL: " RESULT
    fi
    echo "$RESULT"
}

simple_confirm() {
    local MSG=$1
    local DEFAULT=${2:-n}
    local PROMPT="[y/N]"
    [ "$DEFAULT" == "y" ] && PROMPT="[Y/n]"
    
    read -p "  $MSG $PROMPT: " REPLY
    [ -z "$REPLY" ] && REPLY=$DEFAULT
    [[ "$REPLY" =~ ^[Yy]$ ]] && return 0 || return 1
}

# ============ CERTIFICATE FUNCTIONS ============

get_all_ssl_domains() {
    local DOMAINS=()
    
    # Panel certs
    if [ -d "$PANEL_DEF_CERTS" ]; then
        for d in "$PANEL_DEF_CERTS"/*/; do
            [ -d "$d" ] || continue
            local name=$(basename "$d")
            if [ -f "${d}fullchain.pem" ] || [ -f "${d}cert.pem" ]; then
                DOMAINS+=("$name")
            fi
        done
    fi
    
    # Marzban certs
    for dir in "/var/lib/marzban/certs" "/var/lib/rebecca/certs"; do
        if [ -d "$dir" ]; then
            for d in "$dir"/*/; do
                [ -d "$d" ] || continue
                local name=$(basename "$d")
                if [ -f "${d}fullchain.pem" ] && [[ ! " ${DOMAINS[*]} " =~ " $name " ]]; then
                    DOMAINS+=("$name")
                fi
            done
        fi
    done
    
    # Letsencrypt
    if [ -d "/etc/letsencrypt/live" ]; then
        for d in /etc/letsencrypt/live/*/; do
            [ -d "$d" ] || continue
            local name=$(basename "$d")
            [[ "$name" == "README" ]] && continue
            if [ -f "${d}fullchain.pem" ] && [[ ! " ${DOMAINS[*]} " =~ " $name " ]]; then
                DOMAINS+=("$name")
            fi
        done
    fi
    
    echo "${DOMAINS[@]}"
}

find_cert_paths() {
    local DOMAIN=$1
    
    # Panel certs
    if [ -f "$PANEL_DEF_CERTS/$DOMAIN/fullchain.pem" ]; then
        echo "$PANEL_DEF_CERTS/$DOMAIN/fullchain.pem|$PANEL_DEF_CERTS/$DOMAIN/privkey.pem"
        return
    fi
    
    # Marzban/Rebecca
    for dir in "/var/lib/marzban/certs" "/var/lib/rebecca/certs"; do
        if [ -f "$dir/$DOMAIN/fullchain.pem" ]; then
            echo "$dir/$DOMAIN/fullchain.pem|$dir/$DOMAIN/privkey.pem"
            return
        fi
    done
    
    # Letsencrypt
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem|/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        return
    fi
    
    echo ""
}

get_cert_expiry() {
    local CERT_FILE=$1
    if [ -f "$CERT_FILE" ]; then
        openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 | cut -d' ' -f1-3
    fi
}

select_tls_certificates() {
    local DOMAINS_STR=$(get_all_ssl_domains)
    local DOMAINS=($DOMAINS_STR)
    
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo ""
        echo -e "  ${UI_YELLOW}⚠ No SSL certificates found!${UI_NC}"
        echo "  Get SSL from: Main Menu → SSL Certificates"
        echo ""
        return 2
    fi
    
    echo ""
    echo -e "  ${UI_CYAN}Available SSL Certificates:${UI_NC}"
    echo ""
    
    local i=1
    for domain in "${DOMAINS[@]}"; do
        local PATHS=$(find_cert_paths "$domain")
        local EXPIRY=""
        if [ -n "$PATHS" ]; then
            local CERT=$(echo "$PATHS" | cut -d'|' -f1)
            EXPIRY=$(get_cert_expiry "$CERT")
        fi
        
        if [ -n "$EXPIRY" ]; then
            printf "    %2d) %-30s ${UI_DIM}%s${UI_NC}\n" "$i" "$domain" "$EXPIRY"
        else
            printf "    %2d) %s\n" "$i" "$domain"
        fi
        ((i++))
    done
    
    echo ""
    printf "    %2d) ${UI_YELLOW}Enter manually${UI_NC}\n" "$i"
    printf "     0) Cancel\n"
    echo ""
    echo -e "  ${UI_DIM}Tip: 1,2,3 or 1-3 for multiple${UI_NC}"
    echo ""
    
    read -p "  Select [1]: " SELECTION
    [ -z "$SELECTION" ] && SELECTION="1"
    
    [[ "$SELECTION" == "0" ]] && return 1
    [[ "$SELECTION" == "$i" ]] && return 2
    
    # Parse selection
    local SELECTED=()
    IFS=',' read -ra PARTS <<< "$SELECTION"
    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | xargs)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((j=${BASH_REMATCH[1]}; j<=${BASH_REMATCH[2]}; j++)); do
                [ "$j" -ge 1 ] && [ "$j" -le ${#DOMAINS[@]} ] && SELECTED+=("${DOMAINS[$((j-1))]}")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            [ "$part" -ge 1 ] && [ "$part" -le ${#DOMAINS[@]} ] && SELECTED+=("${DOMAINS[$((part-1))]}")
        fi
    done
    
    [ ${#SELECTED[@]} -eq 0 ] && return 1
    
    echo "${SELECTED[@]}"
    return 0
}

# ============ PROTOCOL/TRANSPORT DISPLAY ============

show_protocols() {
    echo ""
    echo -e "  ${UI_CYAN}Protocol:${UI_NC}"
    echo "    1) VLESS      ${UI_DIM}(Recommended)${UI_NC}"
    echo "    2) VMess"
    echo "    3) Trojan"
    echo "    4) Shadowsocks"
    echo "    5) SOCKS5"
    echo "    6) HTTP"
    echo "    7) Dokodemo-door"
    echo ""
}

show_transports() {
    echo ""
    echo -e "  ${UI_CYAN}Transport:${UI_NC}"
    echo "    1) TCP         ${UI_DIM}(Direct)${UI_NC}"
    echo "    2) WebSocket   ${UI_DIM}(CDN OK)${UI_NC}"
    echo "    3) gRPC        ${UI_DIM}(Low latency)${UI_NC}"
    echo "    4) XHTTP       ${UI_DIM}(Anti-detect)${UI_NC}"
    echo "    5) HTTPUpgrade ${UI_DIM}(CDN OK)${UI_NC}"
    echo "    6) HTTP/2"
    echo "    7) mKCP        ${UI_DIM}(UDP)${UI_NC}"
    echo "    8) QUIC        ${UI_DIM}(UDP+TLS)${UI_NC}"
    echo ""
}

show_security() {
    local TRANSPORT=$1
    echo ""
    echo -e "  ${UI_CYAN}Security:${UI_NC}"
    if [[ "$TRANSPORT" =~ ^(tcp|grpc|h2)$ ]]; then
        echo "    1) Reality     ${UI_DIM}(Best)${UI_NC}"
    fi
    echo "    2) TLS"
    echo "    3) None        ${UI_DIM}(For CDN)${UI_NC}"
    echo ""
}

get_protocol() {
    local OPT=$1
    case $OPT in
        1) echo "vless" ;;
        2) echo "vmess" ;;
        3) echo "trojan" ;;
        4) echo "shadowsocks" ;;
        5) echo "socks" ;;
        6) echo "http" ;;
        7) echo "dokodemo-door" ;;
        *) echo "vless" ;;
    esac
}

get_transport() {
    local OPT=$1
    case $OPT in
        1) echo "tcp" ;;
        2) echo "ws" ;;
        3) echo "grpc" ;;
        4) echo "xhttp" ;;
        5) echo "httpupgrade" ;;
        6) echo "h2" ;;
        7) echo "kcp" ;;
        8) echo "quic" ;;
        *) echo "tcp" ;;
    esac
}

get_security() {
    local OPT=$1
    local TRANSPORT=$2
    case $OPT in
        1) [[ "$TRANSPORT" =~ ^(tcp|grpc|h2)$ ]] && echo "reality" || echo "tls" ;;
        2) echo "tls" ;;
        3) echo "none" ;;
        *) echo "tls" ;;
    esac
}