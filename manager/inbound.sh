#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Config file path
XRAY_CONFIG="/var/lib/pasarguard/config.json"

# --- Helper Functions ---
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }

gen_keys() { 
    local K=$(docker exec pasarguard xray x25519 2>/dev/null)
    if [ -z "$K" ]; then
        echo "Private: ERROR Public: ERROR"
    else
        echo "$K"
    fi
}

backup_config() {
    if [ -f "$XRAY_CONFIG" ]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%s)"
        echo -e "${GREEN}✔ Config backed up${NC}"
    fi
}

check_requirements() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Python3 is required!${NC}"
        pause; return 1
    fi
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}OpenSSL is required!${NC}"
        pause; return 1
    fi
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "${RED}Config file not found: $XRAY_CONFIG${NC}"
        pause; return 1
    fi
    return 0
}

# --- 1. REALITY WIZARD ---
add_vless_reality() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      VLESS + REALITY                        ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    check_requirements || return

    read -p "Inbound Name (Tag): " TAG
    [ -z "$TAG" ] && TAG="REALITY_$(date +%s)"

    read -p "Port [443]: " PORT
    [ -z "$PORT" ] && PORT="443"

    echo ""
    echo "Select Network / Transport:"
    echo "1) TCP + Vision (Best Speed)"
    echo "2) XHTTP (Best Anti-Filter)"
    echo "3) gRPC"
    read -p "Select: " NET_OPT

    local NETWORK="tcp"
    local FLOW_LINE=""
    local STREAM_EXTRA=""

    case $NET_OPT in
        1) 
            NETWORK="tcp"
            FLOW_LINE='"flow": "xtls-rprx-vision",'
            ;;
        2) 
            NETWORK="xhttp"
            STREAM_EXTRA='"xhttpSettings": { "path": "/", "mode": "auto" },'
            ;;
        3)
            NETWORK="grpc"
            STREAM_EXTRA='"grpcSettings": { "serviceName": "grpc" },'
            ;;
        *) return ;;
    esac

    read -p "Dest Domain (SNI) [www.google.com]: " DEST
    [ -z "$DEST" ] && DEST="www.google.com"

    # Clean domain (remove www. if exists to avoid www.www.)
    local CLEAN_DEST=$(echo "$DEST" | sed 's/^www\.//')

    echo -e "${BLUE}Generating X25519 Keys...${NC}"
    local KEYS=$(gen_keys)
    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    local SID=$(gen_short_id)
    local UUID=$(gen_uuid)

    if [[ "$PRIV" == "ERROR" ]] || [[ -z "$PRIV" ]]; then
        echo -e "${RED}Error generating keys. Is Panel running?${NC}"
        pause; return
    fi

    # Build JSON properly
    backup_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
new_inbound = {
    "tag": "$TAG",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "$UUID",
                $([ -n "$FLOW_LINE" ] && echo '"flow": "xtls-rprx-vision",')
                "email": "user_$(date +%s)"
            }
        ],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "$NETWORK",
        "security": "reality",
        $([ "$NETWORK" == "xhttp" ] && echo '"xhttpSettings": { "path": "/", "mode": "auto" },')
        $([ "$NETWORK" == "grpc" ] && echo '"grpcSettings": { "serviceName": "grpc" },')
        "realitySettings": {
            "show": False,
            "dest": "$DEST:443",
            "xver": 0,
            "serverNames": ["$DEST", "www.$CLEAN_DEST"],
            "privateKey": "$PRIV",
            "shortIds": ["$SID"],
            "fingerprint": "chrome"
        }
    },
    "sniffing": {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"]
    }
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    # Check port conflict
    for ib in config['inbounds']:
        if ib.get('port') == $PORT:
            print(f"CONFLICT: Port $PORT is already used by '{ib.get('tag')}'")
            sys.exit(1)
    
    # Fix: Remove flow if not TCP
    if "$NETWORK" != "tcp" and "flow" in new_inbound["settings"]["clients"][0]:
        del new_inbound["settings"]["clients"][0]["flow"]
    
    config['inbounds'].append(new_inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print("OK")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ Inbound Created!${NC}"
        echo "-------------------------------------"
        echo -e "Type:       ${CYAN}VLESS Reality ($NETWORK)${NC}"
        echo -e "Port:       ${CYAN}$PORT${NC}"
        echo -e "UUID:       ${CYAN}$UUID${NC}"
        echo -e "SNI:        ${CYAN}$DEST${NC}"
        echo -e "Public Key: ${CYAN}$PUB${NC}"
        echo -e "Short ID:   ${CYAN}$SID${NC}"
        echo "-------------------------------------"
        echo ""
        read -p "Restart Panel? (y/n): " R
        [ "$R" == "y" ] && restart_service "panel"
    fi
    pause
}

# --- 2. STANDARD TLS WIZARD ---
add_standard_tls() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      STANDARD TLS                           ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    check_requirements || return

    read -p "Inbound Name (Tag): " TAG
    [ -z "$TAG" ] && TAG="TLS_$(date +%s)"

    read -p "Port [443]: " PORT
    [ -z "$PORT" ] && PORT="443"

    # Collect domains
    local DOMAINS=()
    echo ""
    echo "Enter domains with SSL certificates."
    echo "(Leave empty when done)"
    
    while true; do
        read -p "Domain: " DOMAIN
        [ -z "$DOMAIN" ] && break
        
        local C_PATH="/var/lib/pasarguard/certs/$DOMAIN/fullchain.pem"
        if [ -f "$C_PATH" ]; then
            DOMAINS+=("$DOMAIN")
            echo -e "${GREEN}✔ Added: $DOMAIN${NC}"
        else
            echo -e "${RED}✘ Certificate not found for $DOMAIN${NC}"
        fi
    done

    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED}No valid domains added.${NC}"
        pause; return
    fi

    echo ""
    echo "Select Protocol:"
    echo "1) VLESS"
    echo "2) VMess"
    echo "3) Trojan"
    read -p "Select: " P_OPT
    
    local PROTO="vless"
    [ "$P_OPT" == "2" ] && PROTO="vmess"
    [ "$P_OPT" == "3" ] && PROTO="trojan"

    echo ""
    echo "Select Network:"
    echo "1) WebSocket"
    echo "2) XHTTP"
    echo "3) TCP"
    echo "4) gRPC"
    read -p "Select: " N_OPT

    local NETWORK="ws"
    case $N_OPT in
        2) NETWORK="xhttp" ;;
        3) NETWORK="tcp" ;;
        4) NETWORK="grpc" ;;
    esac

    local UUID=$(gen_uuid)
    local PASS=$(openssl rand -hex 8)
    local AUTH_INFO=""
    
    if [ "$PROTO" == "trojan" ]; then
        AUTH_INFO="Password: $PASS"
    else
        AUTH_INFO="UUID: $UUID"
    fi

    backup_config

    # Build certs array
    local CERTS_JSON=""
    for d in "${DOMAINS[@]}"; do
        [ -n "$CERTS_JSON" ] && CERTS_JSON="$CERTS_JSON,"
        CERTS_JSON="$CERTS_JSON{\"certificateFile\": \"/var/lib/pasarguard/certs/$d/fullchain.pem\", \"keyFile\": \"/var/lib/pasarguard/certs/$d/privkey.pem\"}"
    done

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"

# Network settings
net_settings = {}
if "$NETWORK" == "ws":
    net_settings = {"wsSettings": {"path": "/"}}
elif "$NETWORK" == "xhttp":
    net_settings = {"xhttpSettings": {"path": "/", "mode": "auto"}}
elif "$NETWORK" == "grpc":
    net_settings = {"grpcSettings": {"serviceName": "grpc"}}

# Client settings
if "$PROTO" == "trojan":
    clients = [{"password": "$PASS", "email": "user_trojan"}]
else:
    clients = [{"id": "$UUID", "email": "user_$PROTO"}]

new_inbound = {
    "tag": "$TAG",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "$PROTO",
    "settings": {
        "clients": clients,
        "decryption": "none"
    },
    "streamSettings": {
        "network": "$NETWORK",
        "security": "tls",
        **net_settings,
        "tlsSettings": {
            "certificates": [$CERTS_JSON]
        }
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    for ib in config['inbounds']:
        if ib.get('port') == $PORT:
            print(f"CONFLICT: Port $PORT used by '{ib.get('tag')}'")
            sys.exit(1)
    
    config['inbounds'].append(new_inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("OK")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ Inbound Created!${NC}"
        echo "-------------------------------------"
        echo -e "Type:   ${CYAN}$PROTO + $NETWORK (TLS)${NC}"
        echo -e "Port:   ${CYAN}$PORT${NC}"
        echo -e "Auth:   ${CYAN}$AUTH_INFO${NC}"
        echo "-------------------------------------"
        read -p "Restart Panel? (y/n): " R
        [ "$R" == "y" ] && restart_service "panel"
    fi
    pause
}

# --- 3. NO-TLS WIZARD ---
add_notls_http() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      NoTLS / CDN                            ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    check_requirements || return

    read -p "Inbound Name (Tag): " TAG
    [ -z "$TAG" ] && TAG="NoTLS_$(date +%s)"

    read -p "Port [80]: " PORT
    [ -z "$PORT" ] && PORT="80"

    echo "Select Protocol:"
    echo "1) VLESS"
    echo "2) VMess"
    read -p "Select: " P_OPT
    
    local PROTO="vless"
    [ "$P_OPT" == "2" ] && PROTO="vmess"

    echo "Select Network:"
    echo "1) WebSocket"
    echo "2) HTTPUpgrade"
    read -p "Select: " N_OPT

    local NETWORK="ws"
    [ "$N_OPT" == "2" ] && NETWORK="httpupgrade"

    local UUID=$(gen_uuid)

    backup_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"

net_settings = {"wsSettings": {"path": "/"}} if "$NETWORK" == "ws" else {"httpupgradeSettings": {"path": "/"}}

new_inbound = {
    "tag": "$TAG",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "$PROTO",
    "settings": {
        "clients": [{"id": "$UUID", "email": "cdn_user"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "$NETWORK",
        "security": "none",
        **net_settings
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    for ib in config['inbounds']:
        if ib.get('port') == $PORT:
            print(f"CONFLICT: Port $PORT used")
            sys.exit(1)
    
    config['inbounds'].append(new_inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("OK")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ Inbound Created!${NC}"
        echo -e "UUID: ${CYAN}$UUID${NC}"
        read -p "Restart Panel? (y/n): " R
        [ "$R" == "y" ] && restart_service "panel"
    fi
    pause
}

# --- LIST & DELETE ---
list_inbounds() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CURRENT INBOUNDS                       ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    [ ! -f "$XRAY_CONFIG" ] && { echo "No config found."; pause; return; }

    python3 << 'PYEOF'
import json
try:
    with open("/var/lib/pasarguard/config.json", 'r') as f:
        d = json.load(f)
    inbounds = d.get('inbounds', [])
    if not inbounds:
        print("No inbounds configured.")
    else:
        print(f"{'#':<3} {'TAG':<25} {'PROTO':<8} {'PORT':<6} {'NET':<10}")
        print("-" * 55)
        for i, ib in enumerate(inbounds, 1):
            net = ib.get('streamSettings', {}).get('network', 'tcp')
            tag = ib.get('tag', 'N/A')[:24]
            print(f"{i:<3} {tag:<25} {ib.get('protocol','?'):<8} {ib.get('port','?'):<6} {net:<10}")
except Exception as e:
    print(f"Error: {e}")
PYEOF
    pause
}

delete_inbound() {
    clear
    list_inbounds
    echo ""
    read -p "Number to delete (0=cancel): " DEL_ID
    [ "$DEL_ID" == "0" ] && return

    backup_config

    python3 << PYEOF
import json
try:
    idx = int("$DEL_ID") - 1
    with open("/var/lib/pasarguard/config.json", 'r') as f:
        d = json.load(f)
    
    inbounds = d.get('inbounds', [])
    if 0 <= idx < len(inbounds):
        removed = inbounds.pop(idx)
        d['inbounds'] = inbounds
        with open("/var/lib/pasarguard/config.json", 'w') as f:
            json.dump(d, f, indent=2)
        print(f"Deleted: {removed.get('tag')}")
    else:
        print("Invalid number")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    read -p "Restart Panel? (y/n): " R
    [ "$R" == "y" ] && restart_service "panel"
    pause
}

# --- MENU ---
inbound_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      INBOUND WIZARD                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) VLESS + Reality"
        echo "2) Standard TLS (VLESS/VMess/Trojan)"
        echo "3) NoTLS / CDN"
        echo "4) List Inbounds"
        echo "5) Delete Inbound"
        echo "6) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) add_vless_reality ;;
            2) add_standard_tls ;;
            3) add_notls_http ;;
            4) list_inbounds ;;
            5) delete_inbound ;;
            6) return ;;
            *) ;;
        esac
    done
}