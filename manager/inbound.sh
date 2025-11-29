#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Config file path
XRAY_CONFIG="/var/lib/pasarguard/config.json"

# --- Helper Functions ---
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }

gen_keys() { 
    # Try to generate keys via docker container
    local K=$(docker exec pasarguard xray x25519 2>/dev/null)
    if [ -z "$K" ]; then
        # Fallback if x25519 fails inside docker (rare)
        echo "Private: Error_Gen_Key Public: Error_Gen_Key"
    else
        echo "$K"
    fi
}

backup_config() {
    if [ -f "$XRAY_CONFIG" ]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%s)"
    fi
}

# --- 1. REALITY WIZARD ---
add_vless_reality() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      VLESS + REALITY (Advanced)             ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Inbound Name (Tag): " TAG
    [ -z "$TAG" ] && TAG="REALITY_$(date +%s)"
    
    read -p "Port [443]: " PORT
    [ -z "$PORT" ] && PORT="443"
    
    echo ""
    echo "Select Network / Transport:"
    echo "1) TCP + Vision (Best Speed & Stability)"
    echo "2) XHTTP (Newest - Best Anti-Censorship)"
    echo "3) gRPC (Good for weak networks)"
    read -p "Select: " NET_OPT
    
    local NETWORK="tcp"
    local FLOW_SETTING='"flow": "xtls-rprx-vision",'
    local STREAM_EXTRA=""
    
    case $NET_OPT in
        1) 
            NETWORK="tcp"
            ;;
        2) 
            NETWORK="xhttp"
            FLOW_SETTING="" # XHTTP usually doesn't use vision flow
            STREAM_EXTRA='"xhttpSettings": { "path": "/", "mode": "auto" },'
            ;;
        3)
            NETWORK="grpc"
            FLOW_SETTING=""
            STREAM_EXTRA='"grpcSettings": { "serviceName": "grpc" },'
            ;;
        *) return ;;
    esac
    
    read -p "Dest Domain (SNI) [e.g. www.yahoo.com]: " DEST
    [ -z "$DEST" ] && DEST="www.yahoo.com"
    
    echo -e "${BLUE}Generating X25519 Keys...${NC}"
    local KEYS=$(gen_keys)
    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    local SID=$(gen_short_id)
    local UUID=$(gen_uuid)
    
    if [[ "$PRIV" == *"Error"* ]]; then
        echo -e "${RED}Error generating keys. Ensure Panel is running.${NC}"
        pause; return
    fi
    
    # JSON Construction
    local JSON=$(cat <<EOF
{
    "tag": "$TAG",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "$UUID",
                $FLOW_SETTING
                "email": "user_$(date +%s)"
            }
        ],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "$NETWORK",
        "security": "reality",
        $STREAM_EXTRA
        "realitySettings": {
            "show": false,
            "dest": "$DEST:443",
            "xver": 0,
            "serverNames": [
                "$DEST",
                "www.$DEST"
            ],
            "privateKey": "$PRIV",
            "shortIds": [
                "$SID"
            ],
            "fingerprint": "chrome"
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }
}
EOF
)
    inject_json "$JSON"
    show_success_info "VLESS Reality ($NETWORK)" "$PORT" "UUID: $UUID" "SNI: $DEST" "Public Key: $PUB"
}

# --- 2. STANDARD TLS WIZARD (Multi-Cert Support) ---
add_standard_tls() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      STANDARD TLS (Multi-Protocol)          ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Inbound Name (Tag): " TAG
    [ -z "$TAG" ] && TAG="TLS_$(date +%s)"
    
    read -p "Port [443]: " PORT
    [ -z "$PORT" ] && PORT="443"
    
    # Domain Handling (Multi-Cert)
    local CERT_JSON_ARRAY=""
    local FIRST_DOMAIN=""
    
    while true; do
        read -p "Enter Domain with SSL (leave empty to finish): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            if [ -z "$CERT_JSON_ARRAY" ]; then return; else break; fi
        fi
        
        local C_PATH="/var/lib/pasarguard/certs/$DOMAIN/fullchain.pem"
        local K_PATH="/var/lib/pasarguard/certs/$DOMAIN/privkey.pem"
        
        if [ ! -f "$C_PATH" ]; then
            echo -e "${RED}Certificate not found for $DOMAIN${NC}"
            echo "Please generate SSL first via Menu > SSL Certificates"
        else
            if [ -n "$CERT_JSON_ARRAY" ]; then CERT_JSON_ARRAY="$CERT_JSON_ARRAY,"; fi
            CERT_JSON_ARRAY="$CERT_JSON_ARRAY { \"certificateFile\": \"$C_PATH\", \"keyFile\": \"$K_PATH\" }"
            [ -z "$FIRST_DOMAIN" ] && FIRST_DOMAIN="$DOMAIN"
            echo -e "${GREEN}Added cert for: $DOMAIN${NC}"
        fi
    done
    
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
    echo "1) WebSocket (WS)"
    echo "2) XHTTP (New)"
    echo "3) TCP"
    echo "4) gRPC"
    echo "5) SplitHTTP"
    echo "6) HTTPUpgrade"
    read -p "Select: " N_OPT
    
    local NETWORK="ws"
    local NET_SETTINGS='"wsSettings": { "path": "/" }'
    
    case $N_OPT in
        2) NETWORK="xhttp"; NET_SETTINGS='"xhttpSettings": { "path": "/", "mode": "auto" }' ;;
        3) NETWORK="tcp"; NET_SETTINGS='"tcpSettings": {}' ;;
        4) NETWORK="grpc"; NET_SETTINGS='"grpcSettings": { "serviceName": "grpc" }' ;;
        5) NETWORK="splithttp"; NET_SETTINGS='"splithttpSettings": { "path": "/" }' ;;
        6) NETWORK="httpupgrade"; NET_SETTINGS='"httpupgradeSettings": { "path": "/" }' ;;
    esac
    
    # Client Config
    local CLIENTS=""
    local INFO_AUTH=""
    
    if [ "$PROTO" == "trojan" ]; then
        local PASS=$(openssl rand -hex 8)
        CLIENTS="[{ \"password\": \"$PASS\", \"email\": \"user_trojan\" }]"
        INFO_AUTH="Password: $PASS"
    else
        local UUID=$(gen_uuid)
        CLIENTS="[{ \"id\": \"$UUID\", \"email\": \"user_$PROTO\" }]"
        INFO_AUTH="UUID: $UUID"
    fi
    
    local JSON=$(cat <<EOF
{
    "tag": "$TAG",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "$PROTO",
    "settings": {
        "clients": $CLIENTS,
        "decryption": "none"
    },
    "streamSettings": {
        "network": "$NETWORK",
        "security": "tls",
        $NET_SETTINGS,
        "tlsSettings": {
            "certificates": [ $CERT_JSON_ARRAY ]
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }
}
EOF
)
    inject_json "$JSON"
    show_success_info "$PROTO + $NETWORK (TLS)" "$PORT" "$INFO_AUTH" "Domains: $FIRST_DOMAIN..."
}

# --- 3. NO-TLS / CDN WIZARD ---
add_notls_http() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      NoTLS / CDN (HTTP Ports)               ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Inbound Name (Tag): " TAG
    [ -z "$TAG" ] && TAG="NoTLS_$(date +%s)"
    
    read -p "Port [80 or 8080]: " PORT
    [ -z "$PORT" ] && PORT="80"
    
    echo "Select Protocol:"
    echo "1) VLESS"
    echo "2) VMess"
    read -p "Select: " P_OPT
    local PROTO="vless"
    [ "$P_OPT" == "2" ] && PROTO="vmess"
    
    echo "Select Network (CDN Friendly):"
    echo "1) WebSocket (WS)"
    echo "2) HTTPUpgrade"
    echo "3) SplitHTTP"
    read -p "Select: " N_OPT
    
    local NETWORK="ws"
    local NET_SETTINGS='"wsSettings": { "path": "/" }'
    
    case $N_OPT in
        2) NETWORK="httpupgrade"; NET_SETTINGS='"httpupgradeSettings": { "path": "/" }' ;;
        3) NETWORK="splithttp"; NET_SETTINGS='"splithttpSettings": { "path": "/" }' ;;
    esac
    
    local UUID=$(gen_uuid)
    
    local JSON=$(cat <<EOF
{
    "tag": "$TAG",
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "$PROTO",
    "settings": {
        "clients": [{ "id": "$UUID", "email": "cdn_user" }],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "$NETWORK",
        "security": "none",
        $NET_SETTINGS
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }
}
EOF
)
    inject_json "$JSON"
    show_success_info "$PROTO + $NETWORK (NoTLS)" "$PORT" "UUID: $UUID"
}

# --- CORE UTILS ---

inject_json() {
    local JSON_DATA=$1
    backup_config
    
    echo -e "${BLUE}Injecting into config.json...${NC}"
    
    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
try:
    new_inbound = $JSON_DATA
    
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
        
    # Check for port conflict
    for ib in config['inbounds']:
        if ib.get('port') == new_inbound['port']:
            print("CONFLICT")
            sys.exit(0)
            
    config['inbounds'].append(new_inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("OK")
except Exception as e:
    print(f"ERROR: {e}")
PYEOF

    local RES=$?
    if [ $RES -eq 0 ]; then
        return 0
    else
        echo -e "${RED}Failed to update config.json${NC}"
        pause
        return 1
    fi
}

show_success_info() {
    echo -e "${GREEN}✔ Inbound Created Successfully!${NC}"
    echo "-------------------------------------"
    echo -e "Type:   ${CYAN}$1${NC}"
    echo -e "Port:   ${CYAN}$2${NC}"
    echo -e "Auth:   ${CYAN}$3${NC}"
    [ -n "$4" ] && echo -e "Extra:  ${CYAN}$4${NC}"
    [ -n "$5" ] && echo -e "Extra:  ${CYAN}$5${NC}"
    echo "-------------------------------------"
    echo ""
    read -p "Restart Panel to apply changes? (y/n): " R
    if [ "$R" == "y" ]; then
        restart_service "panel"
    fi
    pause
}

list_inbounds() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CURRENT INBOUNDS                       ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    if [ ! -f "$XRAY_CONFIG" ]; then echo "No config found."; pause; return; fi
    
    python3 << PYEOF
import json
try:
    with open("$XRAY_CONFIG", 'r') as f:
        d = json.load(f)
    print(f"{'#':<3} {'TAG':<25} {'PROTO':<8} {'PORT':<6} {'NET':<8}")
    print("-" * 60)
    for i, ib in enumerate(d.get('inbounds', []), 1):
        net = ib.get('streamSettings', {}).get('network', 'tcp')
        print(f"{i:<3} {ib.get('tag','N/A')[:24]:<25} {ib.get('protocol','N/A'):<8} {ib.get('port','N/A'):<6} {net:<8}")
except: pass
PYEOF
    pause
}

delete_inbound() {
    clear
    list_inbounds
    echo ""
    read -p "Enter Number to Delete (0 to cancel): " DEL_ID
    [ "$DEL_ID" == "0" ] && return
    
    backup_config
    
    python3 << PYEOF
import json
try:
    idx = int("$DEL_ID") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        d = json.load(f)
    
    if 0 <= idx < len(d.get('inbounds', [])):
        removed = d['inbounds'].pop(idx)
        print(f"DELETED: {removed.get('tag')}")
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(d, f, indent=2)
    else:
        print("Invalid Index")
except Exception as e:
    print(e)
PYEOF
    
    echo ""
    read -p "Restart Panel? (y/n): " R
    [ "$R" == "y" ] && restart_service "panel"
    pause
}

inbound_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      INBOUND WIZARD (Advanced)            ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) VLESS + REALITY (Vision / XHTTP / gRPC)"
        echo "2) Standard TLS (Multi-Cert / Multi-Proto)"
        echo "3) NoTLS / CDN (HTTPUpgrade / SplitHTTP)"
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