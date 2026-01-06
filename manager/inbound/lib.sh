#!/bin/bash

# ============================================
# INBOUND MANAGER - Library Functions
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
    mkdir -p "$INBOUND_BACKUP_DIR" "$INBOUND_EXPORT_DIR"
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

    # Fallback: local xray
    if command -v xray &> /dev/null; then
        xray x25519 2>/dev/null
        return 0
    fi

    echo "Private: ERROR Public: ERROR"
    return 1
}

# ============ BACKUP ============
backup_xray_config() {
    if [ -f "$XRAY_CONFIG" ]; then
        local BACKUP_FILE="$INBOUND_BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json"
        cp "$XRAY_CONFIG" "$BACKUP_FILE"
        ui_success "Config backed up: $BACKUP_FILE"
    fi
}

# ============ REQUIREMENTS CHECK ============
check_inbound_requirements() {
    local MISSING=false

    for cmd in python3 openssl jq; do
        if ! command -v $cmd &> /dev/null; then
            ui_warning "Installing $cmd..."
            apt-get install -y $cmd -qq > /dev/null
            if ! command -v $cmd &> /dev/null; then
                ui_error "Failed to install $cmd!"
                MISSING=true
            fi
        fi
    done

    inbound_init_paths

    if [ ! -f "$XRAY_CONFIG" ]; then
        ui_warning "Config not found, creating empty config..."
        echo '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[]}}' > "$XRAY_CONFIG"
    fi

    if [ "$MISSING" = true ]; then
        pause
        return 1
    fi
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
        local PORT=$(ui_input "Port" "$DEFAULT")

        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            ui_error "Invalid port number!"
            continue
        fi

        local CHECK=$(check_port_available "$PORT")
        if [[ "$CHECK" == USED:* ]]; then
            local EXISTING=$(echo "$CHECK" | cut -d: -f2)
            ui_error "Port $PORT is used by '$EXISTING'"
            continue
        fi

        echo "$PORT"
        return
    done
}

# ============ CERTIFICATE HELPER ============
get_available_certs() {
    local DOMAINS=()

    # Check panel certs directory
    if [ -d "$PANEL_DEF_CERTS" ]; then
        for d in "$PANEL_DEF_CERTS"/*/; do
            if [ -f "${d}fullchain.pem" ] || [ -f "${d}cert.pem" ]; then
                DOMAINS+=("$(basename "$d")")
            fi
        done
    fi

    # Check letsencrypt
    if [ -d "/etc/letsencrypt/live" ]; then
        for d in /etc/letsencrypt/live/*/; do
            local name=$(basename "$d")
            if [ -f "${d}fullchain.pem" ] && [[ ! " ${DOMAINS[*]} " =~ " $name " ]]; then
                DOMAINS+=("$name")
            fi
        done
    fi

    echo "${DOMAINS[@]}"
}

find_cert_paths() {
    local DOMAIN=$1

    if [ -f "$PANEL_DEF_CERTS/$DOMAIN/fullchain.pem" ]; then
        echo "$PANEL_DEF_CERTS/$DOMAIN/fullchain.pem|$PANEL_DEF_CERTS/$DOMAIN/privkey.pem"
    elif [ -f "$PANEL_DEF_CERTS/$DOMAIN/cert.pem" ]; then
        echo "$PANEL_DEF_CERTS/$DOMAIN/cert.pem|$PANEL_DEF_CERTS/$DOMAIN/key.pem"
    elif [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem|/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    else
        echo ""
    fi
}

# ============ PROTOCOL/TRANSPORT LISTS ============
declare -A PROTOCOLS=(
    [1]="vless|VLESS|Most secure, recommended"
    [2]="vmess|VMess|Good compatibility"
    [3]="trojan|Trojan|Simple and fast"
    [4]="shadowsocks|Shadowsocks|Classic protocol"
    [5]="socks|SOCKS5|Standard SOCKS proxy"
    [6]="http|HTTP|Simple HTTP proxy"
    [7]="dokodemo-door|Dokodemo|Transparent proxy"
)

declare -A TRANSPORTS=(
    [1]="tcp|TCP|Direct connection"
    [2]="ws|WebSocket|CDN compatible"
    [3]="grpc|gRPC|Low latency"
    [4]="xhttp|XHTTP|Best anti-detection"
    [5]="httpupgrade|HTTPUpgrade|CDN compatible"
    [6]="h2|HTTP/2|Multiplexing"
    [7]="kcp|mKCP|UDP based"
    [8]="quic|QUIC|UDP + TLS"
)

declare -A SECURITIES=(
    [1]="reality|Reality|Best anti-detection"
    [2]="tls|TLS|Standard encryption"
    [3]="none|None|No encryption"
)

# ============ SELECTION HELPERS ============
select_protocol() {
    echo ""
    echo -e "${UI_CYAN}Select Protocol:${UI_NC}"
    for key in $(echo "${!PROTOCOLS[@]}" | tr ' ' '\n' | sort -n); do
        IFS='|' read -r code name desc <<< "${PROTOCOLS[$key]}"
        printf "  %s) %-12s ${UI_DIM}%s${UI_NC}\n" "$key" "$name" "$desc"
    done
    echo ""

    local OPT=$(ui_input "Select" "1")
    if [ -n "${PROTOCOLS[$OPT]}" ]; then
        IFS='|' read -r code _ _ <<< "${PROTOCOLS[$OPT]}"
        echo "$code"
    else
        echo "vless"
    fi
}

select_transport() {
    echo ""
    echo -e "${UI_CYAN}Select Transport:${UI_NC}"
    for key in $(echo "${!TRANSPORTS[@]}" | tr ' ' '\n' | sort -n); do
        IFS='|' read -r code name desc <<< "${TRANSPORTS[$key]}"
        printf "  %s) %-12s ${UI_DIM}%s${UI_NC}\n" "$key" "$name" "$desc"
    done
    echo ""

    local OPT=$(ui_input "Select" "1")
    if [ -n "${TRANSPORTS[$OPT]}" ]; then
        IFS='|' read -r code _ _ <<< "${TRANSPORTS[$OPT]}"
        echo "$code"
    else
        echo "tcp"
    fi
}

select_security() {
    local TRANSPORT=$1
    echo ""
    echo -e "${UI_CYAN}Select Security:${UI_NC}"

    # Reality only works with tcp, grpc, h2
    if [[ "$TRANSPORT" =~ ^(tcp|grpc|h2)$ ]]; then
        echo "  1) Reality     ${UI_DIM}Best anti-detection${UI_NC}"
    fi
    echo "  2) TLS         ${UI_DIM}Standard encryption${UI_NC}"
    echo "  3) None        ${UI_DIM}No encryption (CDN)${UI_NC}"
    echo ""

    local OPT=$(ui_input "Select" "2")
    case $OPT in
        1) [[ "$TRANSPORT" =~ ^(tcp|grpc|h2)$ ]] && echo "reality" || echo "tls" ;;
        2) echo "tls" ;;
        3) echo "none" ;;
        *) echo "tls" ;;
    esac
}