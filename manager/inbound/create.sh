#!/bin/bash

# ============================================
# INBOUND MANAGER - Create Functions
# Version: 2.2 (Fixed Python Boolean)
# ============================================

# ============ STREAM SETTINGS ============

build_tcp_settings() {
    local USE_HTTP=$1
    if [ "$USE_HTTP" == "y" ]; then
        local HOST=$(simple_input "HTTP Host" "www.google.com")
        local PATH=$(simple_input "HTTP Path" "/")
        echo "{\"header\":{\"type\":\"http\",\"request\":{\"path\":[\"$PATH\"],\"headers\":{\"Host\":[\"$HOST\"]}}}}"
    else
        echo "{\"header\":{\"type\":\"none\"}}"
    fi
}

build_ws_settings() {
    local PATH=$(simple_input "WS Path" "/ws")
    local HOST=$(simple_input "Host Header (Enter=skip)" "")
    [ -n "$HOST" ] && echo "{\"path\":\"$PATH\",\"headers\":{\"Host\":\"$HOST\"}}" || echo "{\"path\":\"$PATH\"}"
}

build_grpc_settings() {
    local SVC=$(simple_input "Service Name" "grpc")
    simple_confirm "Multi Mode?" "n" && echo "{\"serviceName\":\"$SVC\",\"multiMode\":true}" || echo "{\"serviceName\":\"$SVC\"}"
}

build_xhttp_settings() {
    local PATH=$(simple_input "XHTTP Path" "/xhttp")
    echo ""
    echo "    Mode: 1) auto  2) packet-up  3) stream-up"
    read -p "    Select [1]: " MODE_OPT
    local MODE="auto"
    case $MODE_OPT in 2) MODE="packet-up" ;; 3) MODE="stream-up" ;; esac
    echo "{\"path\":\"$PATH\",\"mode\":\"$MODE\"}"
}

build_httpupgrade_settings() {
    local PATH=$(simple_input "Path" "/hu")
    echo "{\"path\":\"$PATH\"}"
}

build_h2_settings() {
    local PATH=$(simple_input "H2 Path" "/h2")
    echo "{\"path\":\"$PATH\"}"
}

build_kcp_settings() {
    echo ""
    echo "    Header: 1) none 2) srtp 3) utp 4) wechat-video 5) dtls 6) wireguard"
    read -p "    Select [1]: " H_OPT
    local HEADER="none"
    case $H_OPT in 2) HEADER="srtp" ;; 3) HEADER="utp" ;; 4) HEADER="wechat-video" ;; 5) HEADER="dtls" ;; 6) HEADER="wireguard" ;; esac
    echo "{\"header\":{\"type\":\"$HEADER\"},\"mtu\":1350,\"tti\":50}"
}

build_quic_settings() {
    echo "{\"security\":\"none\",\"header\":{\"type\":\"none\"}}"
}

# ============ SECURITY SETTINGS ============

build_reality_settings() {
    echo ""
    echo -e "  ${UI_CYAN}── Reality Settings ──${UI_NC}"
    echo ""

    local DEST=$(simple_input "SNI Domain" "www.google.com")
    local CLEAN_DEST=$(echo "$DEST" | sed 's/^www\.//')

    echo -e "  ${UI_DIM}Generating keys...${UI_NC}"
    local KEYS=$(gen_x25519_keys)
    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

    if [[ "$PRIV" == "ERROR" ]] || [[ -z "$PRIV" ]]; then
        echo -e "  ${UI_RED}✘ Key generation failed!${UI_NC}"
        PRIV=$(simple_input "Private Key" "")
        PUB=$(simple_input "Public Key" "")
    else
        echo -e "  ${UI_GREEN}✔ Keys generated${UI_NC}"
    fi

    local SID=$(gen_short_id)
    echo "$PUB" > /tmp/reality_pub
    echo "$SID" > /tmp/reality_sid

    echo ""
    echo "    Fingerprint: 1) chrome 2) firefox 3) safari 4) random"
    read -p "    Select [1]: " FP_OPT
    local FP="chrome"
    case $FP_OPT in 2) FP="firefox" ;; 3) FP="safari" ;; 4) FP="random" ;; esac

    cat << EOF
{"show":false,"dest":"$DEST:443","xver":0,"serverNames":["$DEST","www.$CLEAN_DEST"],"privateKey":"$PRIV","shortIds":["$SID"],"fingerprint":"$FP"}
EOF
}

build_tls_settings() {
    echo ""
    echo -e "  ${UI_CYAN}── TLS Certificates ──${UI_NC}"
    
    local CERTS_ARRAY=()
    local RESULT
    RESULT=$(select_tls_certificates)
    local STATUS=$?
    
    if [ $STATUS -eq 0 ] && [ -n "$RESULT" ]; then
        for domain in $RESULT; do
            local PATHS=$(find_cert_paths "$domain")
            if [ -n "$PATHS" ]; then
                local CERT=$(echo "$PATHS" | cut -d'|' -f1)
                local KEY=$(echo "$PATHS" | cut -d'|' -f2)
                CERTS_ARRAY+=("{\"certificateFile\":\"$CERT\",\"keyFile\":\"$KEY\"}")
                echo -e "  ${UI_GREEN}✔ Added: $domain${UI_NC}"
            fi
        done
    elif [ $STATUS -eq 2 ]; then
        echo ""
        echo "  Enter domains (empty=done):"
        while true; do
            local DOMAIN=$(simple_input "Domain" "")
            [ -z "$DOMAIN" ] && break
            local PATHS=$(find_cert_paths "$DOMAIN")
            if [ -n "$PATHS" ]; then
                local CERT=$(echo "$PATHS" | cut -d'|' -f1)
                local KEY=$(echo "$PATHS" | cut -d'|' -f2)
                CERTS_ARRAY+=("{\"certificateFile\":\"$CERT\",\"keyFile\":\"$KEY\"}")
                echo -e "  ${UI_GREEN}✔ Added: $DOMAIN${UI_NC}"
            else
                echo -e "  ${UI_YELLOW}Not found, enter paths:${UI_NC}"
                local CERT=$(simple_input "Cert path" "")
                local KEY=$(simple_input "Key path" "")
                [ -f "$CERT" ] && [ -f "$KEY" ] && CERTS_ARRAY+=("{\"certificateFile\":\"$CERT\",\"keyFile\":\"$KEY\"}")
            fi
        done
    fi
    
    local CERTS_JSON="[]"
    [ ${#CERTS_ARRAY[@]} -gt 0 ] && CERTS_JSON=$(printf '%s\n' "${CERTS_ARRAY[@]}" | jq -s '.')
    
    echo "{\"certificates\":$CERTS_JSON,\"alpn\":[\"h2\",\"http/1.1\"]}"
}

# ============ CLIENT SETTINGS ============

build_vless_client() {
    local FLOW=$1
    local UUID=$(gen_uuid)
    local EMAIL="user_$(date +%s)"

    EMAIL=$(simple_input "Email" "$EMAIL")
    UUID=$(simple_input "UUID" "$UUID")

    echo "$UUID" > /tmp/last_uuid
    echo "$EMAIL" > /tmp/last_email

    [ -n "$FLOW" ] && echo "{\"id\":\"$UUID\",\"email\":\"$EMAIL\",\"flow\":\"$FLOW\"}" || echo "{\"id\":\"$UUID\",\"email\":\"$EMAIL\"}"
}

build_vmess_client() {
    local UUID=$(gen_uuid)
    local EMAIL="user_$(date +%s)"
    EMAIL=$(simple_input "Email" "$EMAIL")
    UUID=$(simple_input "UUID" "$UUID")
    echo "$UUID" > /tmp/last_uuid
    echo "{\"id\":\"$UUID\",\"email\":\"$EMAIL\",\"alterId\":0}"
}

build_trojan_client() {
    local PASS=$(gen_password)
    local EMAIL="user_$(date +%s)"
    EMAIL=$(simple_input "Email" "$EMAIL")
    PASS=$(simple_input "Password" "$PASS")
    echo "$PASS" > /tmp/last_pass
    echo "{\"password\":\"$PASS\",\"email\":\"$EMAIL\"}"
}

build_ss_settings() {
    echo ""
    echo "    Method: 1) 2022-blake3-aes-128-gcm 2) aes-256-gcm 3) chacha20-poly1305"
    read -p "    Select [1]: " M_OPT
    local METHOD="2022-blake3-aes-128-gcm"
    case $M_OPT in 2) METHOD="aes-256-gcm" ;; 3) METHOD="chacha20-poly1305" ;; esac
    local PASS=$(gen_ss_password)
    PASS=$(simple_input "Password" "$PASS")
    echo "$PASS" > /tmp/last_pass
    echo "{\"method\":\"$METHOD\",\"password\":\"$PASS\",\"network\":\"tcp,udp\"}"
}

# ============ ADVANCED CREATOR ============

create_advanced_inbound() {
    clear
    check_inbound_requirements || return

    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}CREATE CUSTOM INBOUND${UI_NC}               ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"

    # Step 1: Protocol
    echo ""
    echo -e "  ${UI_GREEN}Step 1/7: Protocol${UI_NC}"
    show_protocols
    read -p "  Select [1]: " P_OPT
    [ -z "$P_OPT" ] && P_OPT="1"
    local PROTOCOL=$(get_protocol "$P_OPT")
    echo -e "  ${UI_GREEN}✔${UI_NC} Protocol: $PROTOCOL"

    # Step 2: Transport
    echo ""
    echo -e "  ${UI_GREEN}Step 2/7: Transport${UI_NC}"
    show_transports
    read -p "  Select [1]: " T_OPT
    [ -z "$T_OPT" ] && T_OPT="1"
    local TRANSPORT=$(get_transport "$T_OPT")
    echo -e "  ${UI_GREEN}✔${UI_NC} Transport: $TRANSPORT"

    # Step 3: Security
    echo ""
    echo -e "  ${UI_GREEN}Step 3/7: Security${UI_NC}"
    show_security "$TRANSPORT"
    read -p "  Select [2]: " S_OPT
    [ -z "$S_OPT" ] && S_OPT="2"
    local SECURITY=$(get_security "$S_OPT" "$TRANSPORT")
    echo -e "  ${UI_GREEN}✔${UI_NC} Security: $SECURITY"

    # Validate
    if [[ "$SECURITY" == "reality" ]] && [[ ! "$TRANSPORT" =~ ^(tcp|grpc|h2)$ ]]; then
        echo -e "  ${UI_RED}✘ Reality needs TCP/gRPC/H2!${UI_NC}"
        pause
        return
    fi

    # Step 4: Basic Info
    echo ""
    echo -e "  ${UI_GREEN}Step 4/7: Basic Info${UI_NC}"
    echo ""
    local DEFAULT_TAG="${PROTOCOL^^}_${TRANSPORT^^}_$(date +%s)"
    local TAG=$(simple_input "Tag" "$DEFAULT_TAG")
    local PORT=$(input_port "")
    local LISTEN=$(simple_input "Listen" "0.0.0.0")
    echo -e "  ${UI_GREEN}✔${UI_NC} Tag: $TAG, Port: $PORT"

    # Step 5: Transport Settings
    echo ""
    echo -e "  ${UI_GREEN}Step 5/7: Transport Settings${UI_NC}"
    local TRANSPORT_SETTINGS="{}"
    case $TRANSPORT in
        tcp)
            simple_confirm "HTTP Camouflage?" "n" && TRANSPORT_SETTINGS=$(build_tcp_settings "y") || TRANSPORT_SETTINGS=$(build_tcp_settings "n")
            ;;
        ws) TRANSPORT_SETTINGS=$(build_ws_settings) ;;
        grpc) TRANSPORT_SETTINGS=$(build_grpc_settings) ;;
        xhttp) TRANSPORT_SETTINGS=$(build_xhttp_settings) ;;
        httpupgrade) TRANSPORT_SETTINGS=$(build_httpupgrade_settings) ;;
        h2) TRANSPORT_SETTINGS=$(build_h2_settings) ;;
        kcp) TRANSPORT_SETTINGS=$(build_kcp_settings) ;;
        quic) TRANSPORT_SETTINGS=$(build_quic_settings) ;;
    esac
    echo -e "  ${UI_GREEN}✔${UI_NC} Transport configured"

    # Step 6: Security Settings
    echo ""
    echo -e "  ${UI_GREEN}Step 6/7: Security Settings${UI_NC}"
    local SECURITY_SETTINGS="{}"
    local FLOW=""

    case $SECURITY in
        reality)
            SECURITY_SETTINGS=$(build_reality_settings)
            [ "$TRANSPORT" == "tcp" ] && [ "$PROTOCOL" == "vless" ] && FLOW="xtls-rprx-vision"
            ;;
        tls)
            SECURITY_SETTINGS=$(build_tls_settings)
            ;;
    esac
    echo -e "  ${UI_GREEN}✔${UI_NC} Security configured"

    # Step 7: Client Settings
    echo ""
    echo -e "  ${UI_GREEN}Step 7/7: Client Settings${UI_NC}"
    echo ""
    local SETTINGS=""
    local CLIENT=""

    case $PROTOCOL in
        vless)
            CLIENT=$(build_vless_client "$FLOW")
            SETTINGS="{\"clients\":[$CLIENT],\"decryption\":\"none\"}"
            ;;
        vmess)
            CLIENT=$(build_vmess_client)
            SETTINGS="{\"clients\":[$CLIENT]}"
            ;;
        trojan)
            CLIENT=$(build_trojan_client)
            SETTINGS="{\"clients\":[$CLIENT]}"
            ;;
        shadowsocks)
            SETTINGS=$(build_ss_settings)
            ;;
        socks)
            if simple_confirm "Require Auth?" "n"; then
                local USER=$(simple_input "Username" "")
                local PASS=$(simple_input "Password" "")
                SETTINGS="{\"auth\":\"password\",\"accounts\":[{\"user\":\"$USER\",\"pass\":\"$PASS\"}],\"udp\":true}"
            else
                SETTINGS="{\"auth\":\"noauth\",\"udp\":true}"
            fi
            ;;
        http)
            SETTINGS="{}"
            ;;
        dokodemo-door)
            local ADDR=$(simple_input "Target Address" "")
            local TPORT=$(simple_input "Target Port" "")
            SETTINGS="{\"address\":\"$ADDR\",\"port\":$TPORT,\"network\":\"tcp,udp\"}"
            ;;
    esac
    echo -e "  ${UI_GREEN}✔${UI_NC} Client configured"

    # Create
    echo ""
    echo -e "  ${UI_DIM}Creating inbound...${UI_NC}"
    backup_xray_config

    # Write temp files for Python to read
    echo "$TAG" > /tmp/inbound_tag
    echo "$PORT" > /tmp/inbound_port
    echo "$LISTEN" > /tmp/inbound_listen
    echo "$PROTOCOL" > /tmp/inbound_protocol
    echo "$TRANSPORT" > /tmp/inbound_transport
    echo "$SECURITY" > /tmp/inbound_security
    echo "$SETTINGS" > /tmp/inbound_settings
    echo "$TRANSPORT_SETTINGS" > /tmp/inbound_transport_settings
    echo "$SECURITY_SETTINGS" > /tmp/inbound_security_settings

    local RESULT=$(python3 << 'PYEOF'
import json
import sys
import os

# Read config path from environment
config_path = os.environ.get('XRAY_CONFIG', '/var/lib/pasarguard/xray_config.json')

# Read values from temp files
def read_file(path):
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except:
        return ""

tag = read_file('/tmp/inbound_tag')
port = int(read_file('/tmp/inbound_port') or '0')
listen_addr = read_file('/tmp/inbound_listen') or '0.0.0.0'
protocol = read_file('/tmp/inbound_protocol')
transport = read_file('/tmp/inbound_transport')
security = read_file('/tmp/inbound_security')

# Parse JSON settings
def parse_json(path):
    try:
        content = read_file(path)
        if content:
            return json.loads(content)
    except:
        pass
    return {}

settings = parse_json('/tmp/inbound_settings')
transport_settings = parse_json('/tmp/inbound_transport_settings')
security_settings = parse_json('/tmp/inbound_security_settings')

# Build stream settings
stream_settings = {
    "network": transport,
    "security": security
}

# Add transport settings with correct key
transport_key_map = {
    "ws": "wsSettings",
    "h2": "httpSettings",
    "kcp": "kcpSettings",
    "tcp": "tcpSettings",
    "grpc": "grpcSettings",
    "xhttp": "xhttpSettings",
    "httpupgrade": "httpupgradeSettings",
    "quic": "quicSettings"
}
transport_key = transport_key_map.get(transport, f"{transport}Settings")
stream_settings[transport_key] = transport_settings

# Add security settings
if security == "reality":
    stream_settings["realitySettings"] = security_settings
elif security == "tls":
    stream_settings["tlsSettings"] = security_settings

# Build sniffing with Python True
sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"]
}

# Build inbound
new_inbound = {
    "tag": tag,
    "listen": listen_addr,
    "port": port,
    "protocol": protocol,
    "settings": settings,
    "streamSettings": stream_settings,
    "sniffing": sniffing
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    # Check port conflict
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print(f"CONFLICT:{ib.get('tag')}")
            sys.exit(1)
    
    config['inbounds'].append(new_inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print("SUCCESS")
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
PYEOF
)

    # Cleanup temp files
    rm -f /tmp/inbound_tag /tmp/inbound_port /tmp/inbound_listen /tmp/inbound_protocol \
          /tmp/inbound_transport /tmp/inbound_security /tmp/inbound_settings \
          /tmp/inbound_transport_settings /tmp/inbound_security_settings 2>/dev/null

    echo ""
    if [[ "$RESULT" == "SUCCESS" ]]; then
        echo -e "  ${UI_GREEN}╔════════════════════════════════════════╗${UI_NC}"
        echo -e "  ${UI_GREEN}║     ✔ INBOUND CREATED!                 ║${UI_NC}"
        echo -e "  ${UI_GREEN}╚════════════════════════════════════════╝${UI_NC}"
        echo ""
        echo -e "  Tag:       ${UI_CYAN}$TAG${UI_NC}"
        echo -e "  Protocol:  ${UI_CYAN}$PROTOCOL${UI_NC}"
        echo -e "  Transport: ${UI_CYAN}$TRANSPORT${UI_NC}"
        echo -e "  Security:  ${UI_CYAN}$SECURITY${UI_NC}"
        echo -e "  Port:      ${UI_CYAN}$PORT${UI_NC}"
        
        [ -f /tmp/last_uuid ] && echo -e "  UUID:      ${UI_CYAN}$(cat /tmp/last_uuid)${UI_NC}"
        [ -f /tmp/last_pass ] && echo -e "  Password:  ${UI_CYAN}$(cat /tmp/last_pass)${UI_NC}"
        [ -f /tmp/reality_pub ] && echo -e "  PublicKey: ${UI_CYAN}$(cat /tmp/reality_pub)${UI_NC}"
        [ -f /tmp/reality_sid ] && echo -e "  ShortID:   ${UI_CYAN}$(cat /tmp/reality_sid)${UI_NC}"
        
        rm -f /tmp/last_uuid /tmp/last_pass /tmp/last_email /tmp/reality_pub /tmp/reality_sid 2>/dev/null
        
        echo ""
        simple_confirm "Restart Panel?" "y" && restart_service "panel"
    elif [[ "$RESULT" == CONFLICT:* ]]; then
        local EXISTING=$(echo "$RESULT" | cut -d: -f2)
        echo -e "  ${UI_RED}✘ Port $PORT used by '$EXISTING'${UI_NC}"
    else
        echo -e "  ${UI_RED}✘ Failed: $RESULT${UI_NC}"
    fi

    pause
}

# ============ QUICK REALITY PRESET ============

quick_reality_preset() {
    clear
    check_inbound_requirements || return

    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}QUICK REALITY SETUP${UI_NC}                 ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""
    echo "  Preset:"
    echo "    1) VLESS + TCP + Vision ${UI_DIM}(Best)${UI_NC}"
    echo "    2) VLESS + gRPC"
    echo "    3) VLESS + H2"
    echo ""
    read -p "  Select [1]: " PRESET
    [ -z "$PRESET" ] && PRESET="1"

    local TRANSPORT="tcp"
    local FLOW="xtls-rprx-vision"
    case $PRESET in 
        2) TRANSPORT="grpc"; FLOW="" ;; 
        3) TRANSPORT="h2"; FLOW="" ;; 
    esac

    echo ""
    local TAG=$(simple_input "Tag" "REALITY_$(date +%s)")
    local PORT=$(input_port "")

    echo ""
    echo "  SNI: 1) google 2) microsoft 3) apple 4) cloudflare 5) custom"
    read -p "  Select [1]: " SNI_OPT
    local DEST="www.google.com"
    case $SNI_OPT in
        2) DEST="www.microsoft.com" ;;
        3) DEST="www.apple.com" ;;
        4) DEST="www.cloudflare.com" ;;
        5) DEST=$(simple_input "Domain" "") ;;
    esac

    echo ""
    echo -e "  ${UI_DIM}Generating keys...${UI_NC}"
    local KEYS=$(gen_x25519_keys)
    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    local SID=$(gen_short_id)
    local UUID=$(gen_uuid)

    if [[ "$PRIV" == "ERROR" ]] || [[ -z "$PRIV" ]]; then
        echo -e "  ${UI_RED}✘ Key generation failed!${UI_NC}"
        pause
        return
    fi
    echo -e "  ${UI_GREEN}✔ Keys generated${UI_NC}"

    backup_xray_config

    # Write to temp files
    echo "$TAG" > /tmp/r_tag
    echo "$PORT" > /tmp/r_port
    echo "$TRANSPORT" > /tmp/r_transport
    echo "$FLOW" > /tmp/r_flow
    echo "$DEST" > /tmp/r_dest
    echo "$PRIV" > /tmp/r_priv
    echo "$SID" > /tmp/r_sid
    echo "$UUID" > /tmp/r_uuid

    local RESULT=$(python3 << 'PYEOF'
import json
import sys
import os

config_path = os.environ.get('XRAY_CONFIG', '/var/lib/pasarguard/xray_config.json')

def read_file(path):
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except:
        return ""

tag = read_file('/tmp/r_tag')
port = int(read_file('/tmp/r_port') or '0')
transport = read_file('/tmp/r_transport')
flow = read_file('/tmp/r_flow')
dest = read_file('/tmp/r_dest')
priv = read_file('/tmp/r_priv')
sid = read_file('/tmp/r_sid')
uuid = read_file('/tmp/r_uuid')

# Build client
client = {"id": uuid, "email": f"user_{tag}"}
if flow:
    client["flow"] = flow

# Build stream settings
stream = {
    "network": transport,
    "security": "reality",
    "realitySettings": {
        "show": False,
        "dest": f"{dest}:443",
        "xver": 0,
        "serverNames": [dest],
        "privateKey": priv,
        "shortIds": [sid],
        "fingerprint": "chrome"
    }
}

# Add transport-specific settings
if transport == "grpc":
    stream["grpcSettings"] = {"serviceName": "grpc"}
elif transport == "h2":
    stream["httpSettings"] = {"path": "/"}
else:
    stream["tcpSettings"] = {"header": {"type": "none"}}

# Build inbound
inbound = {
    "tag": tag,
    "listen": "0.0.0.0",
    "port": port,
    "protocol": "vless",
    "settings": {"clients": [client], "decryption": "none"},
    "streamSettings": stream,
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print("CONFLICT")
            sys.exit(1)
    
    config['inbounds'].append(inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print("OK")
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
PYEOF
)

    # Cleanup
    rm -f /tmp/r_tag /tmp/r_port /tmp/r_transport /tmp/r_flow /tmp/r_dest /tmp/r_priv /tmp/r_sid /tmp/r_uuid 2>/dev/null

    echo ""
    if [[ "$RESULT" == "OK" ]]; then
        echo -e "  ${UI_GREEN}╔════════════════════════════════════════╗${UI_NC}"
        echo -e "  ${UI_GREEN}║     ✔ REALITY CREATED!                 ║${UI_NC}"
        echo -e "  ${UI_GREEN}╚════════════════════════════════════════╝${UI_NC}"
        echo ""
        echo -e "  Tag:        ${UI_CYAN}$TAG${UI_NC}"
        echo -e "  Port:       ${UI_CYAN}$PORT${UI_NC}"
        echo -e "  UUID:       ${UI_CYAN}$UUID${UI_NC}"
        echo -e "  SNI:        ${UI_CYAN}$DEST${UI_NC}"
        echo -e "  Public Key: ${UI_CYAN}$PUB${UI_NC}"
        echo -e "  Short ID:   ${UI_CYAN}$SID${UI_NC}"
        echo ""
        simple_confirm "Restart Panel?" "y" && restart_service "panel"
    else
        echo -e "  ${UI_RED}✘ Failed: $RESULT${UI_NC}"
    fi

    pause
}

# ============ QUICK CDN PRESET ============

quick_cdn_preset() {
    clear
    check_inbound_requirements || return

    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}QUICK CDN SETUP${UI_NC}                     ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""
    echo "  Preset:"
    echo "    1) VLESS + WS + NoTLS ${UI_DIM}(Port 80)${UI_NC}"
    echo "    2) VMess + WS + NoTLS"
    echo "    3) VLESS + WS + TLS ${UI_DIM}(Port 443)${UI_NC}"
    echo "    4) VMess + WS + TLS"
    echo ""
    read -p "  Select [1]: " PRESET
    [ -z "$PRESET" ] && PRESET="1"

    local PROTO="vless"
    local SECURITY="none"
    case $PRESET in 
        2) PROTO="vmess" ;; 
        3) SECURITY="tls" ;; 
        4) PROTO="vmess"; SECURITY="tls" ;; 
    esac

    echo ""
    local TAG=$(simple_input "Tag" "CDN_${PROTO^^}_$(date +%s)")
    local DEFAULT_PORT=80
    [ "$SECURITY" == "tls" ] && DEFAULT_PORT=443
    local PORT=$(input_port "$DEFAULT_PORT")
    local PATH=$(simple_input "Path" "/ws")
    local UUID=$(gen_uuid)

    local TLS_CERT=""
    local TLS_KEY=""
    
    if [ "$SECURITY" == "tls" ]; then
        local CERT_RESULT
        CERT_RESULT=$(select_tls_certificates)
        local STATUS=$?
        
        if [ $STATUS -eq 0 ] && [ -n "$CERT_RESULT" ]; then
            local FIRST=$(echo "$CERT_RESULT" | awk '{print $1}')
            local PATHS=$(find_cert_paths "$FIRST")
            if [ -n "$PATHS" ]; then
                TLS_CERT=$(echo "$PATHS" | cut -d'|' -f1)
                TLS_KEY=$(echo "$PATHS" | cut -d'|' -f2)
                echo -e "  ${UI_GREEN}✔ Using: $FIRST${UI_NC}"
            fi
        else
            echo -e "  ${UI_RED}✘ TLS needs certificate!${UI_NC}"
            pause
            return
        fi
    fi

    backup_xray_config

    # Write to temp files
    echo "$TAG" > /tmp/c_tag
    echo "$PORT" > /tmp/c_port
    echo "$PROTO" > /tmp/c_proto
    echo "$SECURITY" > /tmp/c_security
    echo "$PATH" > /tmp/c_path
    echo "$UUID" > /tmp/c_uuid
    echo "$TLS_CERT" > /tmp/c_cert
    echo "$TLS_KEY" > /tmp/c_key

    local RESULT=$(python3 << 'PYEOF'
import json
import sys
import os

config_path = os.environ.get('XRAY_CONFIG', '/var/lib/pasarguard/xray_config.json')

def read_file(path):
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except:
        return ""

tag = read_file('/tmp/c_tag')
port = int(read_file('/tmp/c_port') or '0')
proto = read_file('/tmp/c_proto')
security = read_file('/tmp/c_security')
ws_path = read_file('/tmp/c_path')
uuid = read_file('/tmp/c_uuid')
tls_cert = read_file('/tmp/c_cert')
tls_key = read_file('/tmp/c_key')

# Build client
if proto == "vmess":
    client = {"id": uuid, "email": f"user_{tag}", "alterId": 0}
    settings = {"clients": [client]}
else:
    client = {"id": uuid, "email": f"user_{tag}"}
    settings = {"clients": [client], "decryption": "none"}

# Build stream settings
stream = {
    "network": "ws",
    "security": security,
    "wsSettings": {"path": ws_path}
}

# Add TLS settings if needed
if security == "tls" and tls_cert and tls_key:
    stream["tlsSettings"] = {
        "certificates": [
            {"certificateFile": tls_cert, "keyFile": tls_key}
        ]
    }

# Build inbound
inbound = {
    "tag": tag,
    "listen": "0.0.0.0",
    "port": port,
    "protocol": proto,
    "settings": settings,
    "streamSettings": stream,
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print("CONFLICT")
            sys.exit(1)
    
    config['inbounds'].append(inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print("OK")
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
PYEOF
)

    # Cleanup
    rm -f /tmp/c_tag /tmp/c_port /tmp/c_proto /tmp/c_security /tmp/c_path /tmp/c_uuid /tmp/c_cert /tmp/c_key 2>/dev/null

    echo ""
    if [[ "$RESULT" == "OK" ]]; then
        echo -e "  ${UI_GREEN}╔════════════════════════════════════════╗${UI_NC}"
        echo -e "  ${UI_GREEN}║     ✔ CDN INBOUND CREATED!             ║${UI_NC}"
        echo -e "  ${UI_GREEN}╚════════════════════════════════════════╝${UI_NC}"
        echo ""
        echo -e "  Tag:      ${UI_CYAN}$TAG${UI_NC}"
        echo -e "  Port:     ${UI_CYAN}$PORT${UI_NC}"
        echo -e "  Path:     ${UI_CYAN}$PATH${UI_NC}"
        echo -e "  UUID:     ${UI_CYAN}$UUID${UI_NC}"
        echo ""
        simple_confirm "Restart Panel?" "y" && restart_service "panel"
    else
        echo -e "  ${UI_RED}✘ Failed: $RESULT${UI_NC}"
    fi

    pause
}