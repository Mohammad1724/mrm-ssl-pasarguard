#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

XRAY_CONFIG="/var/lib/pasarguard/config.json"

gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }

get_xray_container() {
    local CID=$(docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | grep -i "pasarguard" | head -1 | awk '{print $1}')
    echo "$CID"
}

gen_keys() { 
    local CID=$(get_xray_container)
    if [ -z "$CID" ]; then
        echo "Private: ERROR Public: ERROR"
        return
    fi
    local K=$(docker exec "$CID" xray x25519 2>/dev/null)
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

# FIXED: Added jq check
check_requirements() {
    local MISSING=false
    
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Python3 is required!${NC}"
        MISSING=true
    fi
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}OpenSSL is required!${NC}"
        MISSING=true
    fi
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}jq not found. Installing...${NC}"
        apt-get install -y jq -qq > /dev/null 2>&1
        if ! command -v jq &> /dev/null; then
            echo -e "${RED}Failed to install jq!${NC}"
            MISSING=true
        fi
    fi
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "${RED}Config file not found: $XRAY_CONFIG${NC}"
        MISSING=true
    fi
    
    if [ "$MISSING" = true ]; then
        pause
        return 1
    fi
    return 0
}

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
    local USE_FLOW="false"

    case $NET_OPT in
        1) NETWORK="tcp"; USE_FLOW="true" ;;
        2) NETWORK="xhttp"; USE_FLOW="false" ;;
        3) NETWORK="grpc"; USE_FLOW="false" ;;
        *) return ;;
    esac

    read -p "Dest Domain (SNI) [www.google.com]: " DEST
    [ -z "$DEST" ] && DEST="www.google.com"

    local CLEAN_DEST=$(echo "$DEST" | sed 's/^www\.//')

    echo -e "${BLUE}Generating X25519 Keys...${NC}"
    local KEYS=$(gen_keys)
    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    local SID=$(gen_short_id)
    local UUID=$(gen_uuid)
    local EMAIL="user_$(date +%s)"

    if [[ "$PRIV" == "ERROR" ]] || [[ -z "$PRIV" ]]; then
        echo -e "${RED}Error generating keys. Is Panel running?${NC}"
        pause; return
    fi

    backup_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
tag = "$TAG"
port = $PORT
network = "$NETWORK"
use_flow = $USE_FLOW
dest = "$DEST"
clean_dest = "$CLEAN_DEST"
priv_key = "$PRIV"
short_id = "$SID"
uuid = "$UUID"
email = "$EMAIL"

client = {"id": uuid, "email": email}
if use_flow:
    client["flow"] = "xtls-rprx-vision"

stream_settings = {
    "network": network,
    "security": "reality",
    "realitySettings": {
        "show": False,
        "dest": f"{dest}:443",
        "xver": 0,
        "serverNames": [dest, f"www.{clean_dest}"],
        "privateKey": priv_key,
        "shortIds": [short_id],
        "fingerprint": "chrome"
    }
}

if network == "xhttp":
    stream_settings["xhttpSettings"] = {"path": "/", "mode": "auto"}
elif network == "grpc":
    stream_settings["grpcSettings"] = {"serviceName": "grpc"}

new_inbound = {
    "tag": tag,
    "listen": "0.0.0.0",
    "port": port,
    "protocol": "vless",
    "settings": {"clients": [client], "decryption": "none"},
    "streamSettings": stream_settings,
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print(f"CONFLICT: Port {port} is already used by '{ib.get('tag')}'")
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
        echo -e "Type:       ${CYAN}VLESS Reality ($NETWORK)${NC}"
        echo -e "Port:       ${CYAN}$PORT${NC}"
        echo -e "UUID:       ${CYAN}$UUID${NC}"
        echo -e "SNI:        ${CYAN}$DEST${NC}"
        echo -e "Public Key: ${CYAN}$PUB${NC}"
        echo -e "Short ID:   ${CYAN}$SID${NC}"
        echo "-------------------------------------"
        read -p "Restart Panel? (y/n): " R
        [ "$R" == "y" ] && restart_service "panel"
    fi
    pause
}

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
    local EMAIL="user_$(date +%s)"

    backup_config

    local DOMAINS_JSON=$(printf '%s\n' "${DOMAINS[@]}" | jq -R . | jq -s .)

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
tag = "$TAG"
port = $PORT
protocol = "$PROTO"
network = "$NETWORK"
uuid = "$UUID"
password = "$PASS"
email = "$EMAIL"
domains = $DOMAINS_JSON

certificates = []
for d in domains:
    certificates.append({
        "certificateFile": f"/var/lib/pasarguard/certs/{d}/fullchain.pem",
        "keyFile": f"/var/lib/pasarguard/certs/{d}/privkey.pem"
    })

if protocol == "trojan":
    clients = [{"password": password, "email": email}]
else:
    clients = [{"id": uuid, "email": email}]

stream_settings = {
    "network": network,
    "security": "tls",
    "tlsSettings": {"certificates": certificates}
}

if network == "ws":
    stream_settings["wsSettings"] = {"path": "/"}
elif network == "xhttp":
    stream_settings["xhttpSettings"] = {"path": "/", "mode": "auto"}
elif network == "grpc":
    stream_settings["grpcSettings"] = {"serviceName": "grpc"}

new_inbound = {
    "tag": tag,
    "listen": "0.0.0.0",
    "port": port,
    "protocol": protocol,
    "settings": {"clients": clients, "decryption": "none"},
    "streamSettings": stream_settings,
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print(f"CONFLICT: Port {port} used by '{ib.get('tag')}'")
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
        if [ "$PROTO" == "trojan" ]; then
            echo -e "Pass:   ${CYAN}$PASS${NC}"
        else
            echo -e "UUID:   ${CYAN}$UUID${NC}"
        fi
        echo "-------------------------------------"
        read -p "Restart Panel? (y/n): " R
        [ "$R" == "y" ] && restart_service "panel"
    fi
    pause
}

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
    local EMAIL="cdn_user_$(date +%s)"

    backup_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
tag = "$TAG"
port = $PORT
protocol = "$PROTO"
network = "$NETWORK"
uuid = "$UUID"
email = "$EMAIL"

stream_settings = {"network": network, "security": "none"}
if network == "ws":
    stream_settings["wsSettings"] = {"path": "/"}
else:
    stream_settings["httpupgradeSettings"] = {"path": "/"}

new_inbound = {
    "tag": tag,
    "listen": "0.0.0.0",
    "port": port,
    "protocol": protocol,
    "settings": {"clients": [{"id": uuid, "email": email}], "decryption": "none"},
    "streamSettings": stream_settings,
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print(f"CONFLICT: Port {port} used")
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