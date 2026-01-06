#!/bin/bash

# ============================================
# INBOUND MANAGER - Create Functions
# ============================================

# ============ STREAM SETTINGS BUILDERS ============

build_tcp_settings() {
    local USE_HTTP=$1
    if [ "$USE_HTTP" == "y" ]; then
        local HOST=$(ui_input "HTTP Host" "www.google.com")
        local PATH=$(ui_input "HTTP Path" "/")
        echo "{\"header\":{\"type\":\"http\",\"request\":{\"path\":[\"$PATH\"],\"headers\":{\"Host\":[\"$HOST\"]}}}}"
    else
        echo "{\"header\":{\"type\":\"none\"}}"
    fi
}

build_ws_settings() {
    local PATH=$(ui_input "WS Path" "/ws")
    local HOST=$(ui_input "Host Header (optional)" "")
    if [ -n "$HOST" ]; then
        echo "{\"path\":\"$PATH\",\"headers\":{\"Host\":\"$HOST\"}}"
    else
        echo "{\"path\":\"$PATH\"}"
    fi
}

build_grpc_settings() {
    local SVC=$(ui_input "Service Name" "grpc")
    if ui_confirm "Enable Multi Mode?" "n"; then
        echo "{\"serviceName\":\"$SVC\",\"multiMode\":true}"
    else
        echo "{\"serviceName\":\"$SVC\"}"
    fi
}

build_xhttp_settings() {
    local PATH=$(ui_input "XHTTP Path" "/xhttp")
    echo ""
    echo "Mode: 1) auto  2) packet-up  3) stream-up  4) stream-one"
    local MODE_OPT=$(ui_input "Select" "1")
    local MODE="auto"
    case $MODE_OPT in
        2) MODE="packet-up" ;;
        3) MODE="stream-up" ;;
        4) MODE="stream-one" ;;
    esac
    echo "{\"path\":\"$PATH\",\"mode\":\"$MODE\"}"
}

build_httpupgrade_settings() {
    local PATH=$(ui_input "HTTPUpgrade Path" "/hu")
    local HOST=$(ui_input "Host (optional)" "")
    if [ -n "$HOST" ]; then
        echo "{\"path\":\"$PATH\",\"host\":\"$HOST\"}"
    else
        echo "{\"path\":\"$PATH\"}"
    fi
}

build_h2_settings() {
    local PATH=$(ui_input "H2 Path" "/h2")
    echo "{\"path\":\"$PATH\"}"
}

build_kcp_settings() {
    echo "Header: 1) none 2) srtp 3) utp 4) wechat-video 5) dtls 6) wireguard"
    local H_OPT=$(ui_input "Select" "1")
    local HEADER="none"
    case $H_OPT in
        2) HEADER="srtp" ;; 3) HEADER="utp" ;; 4) HEADER="wechat-video" ;;
        5) HEADER="dtls" ;; 6) HEADER="wireguard" ;;
    esac
    local SEED=$(ui_input "Seed/Password (optional)" "")
    if [ -n "$SEED" ]; then
        echo "{\"header\":{\"type\":\"$HEADER\"},\"seed\":\"$SEED\",\"mtu\":1350,\"tti\":50}"
    else
        echo "{\"header\":{\"type\":\"$HEADER\"},\"mtu\":1350,\"tti\":50}"
    fi
}

build_quic_settings() {
    echo "Header: 1) none 2) srtp 3) utp 4) wechat-video 5) dtls 6) wireguard"
    local H_OPT=$(ui_input "Select" "1")
    local HEADER="none"
    case $H_OPT in 2) HEADER="srtp" ;; 3) HEADER="utp" ;; 4) HEADER="wechat-video" ;; 5) HEADER="dtls" ;; 6) HEADER="wireguard" ;; esac
    echo "{\"security\":\"none\",\"header\":{\"type\":\"$HEADER\"}}"
}

# ============ SECURITY BUILDERS ============

build_reality_settings() {
    echo ""
    ui_info "Reality Settings"

    local DEST=$(ui_input "SNI Domain" "www.google.com")
    local CLEAN_DEST=$(echo "$DEST" | sed 's/^www\.//')

    ui_spinner_start "Generating X25519 Keys..."
    local KEYS=$(gen_x25519_keys)
    ui_spinner_stop

    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')

    if [[ "$PRIV" == "ERROR" ]] || [[ -z "$PRIV" ]]; then
        ui_error "Failed to generate keys!"
        PRIV=$(ui_input "Enter Private Key manually" "")
        PUB=$(ui_input "Enter Public Key manually" "")
    fi

    local SID=$(gen_short_id)

    # Save for display later
    echo "$PUB" > /tmp/reality_pub
    echo "$SID" > /tmp/reality_sid

    echo "Fingerprint: 1) chrome 2) firefox 3) safari 4) ios 5) android 6) random"
    local FP_OPT=$(ui_input "Select" "1")
    local FP="chrome"
    case $FP_OPT in 2) FP="firefox" ;; 3) FP="safari" ;; 4) FP="ios" ;; 5) FP="android" ;; 6) FP="random" ;; esac

    cat << EOF
{
    "show": false,
    "dest": "$DEST:443",
    "xver": 0,
    "serverNames": ["$DEST", "www.$CLEAN_DEST"],
    "privateKey": "$PRIV",
    "shortIds": ["$SID"],
    "fingerprint": "$FP"
}
EOF
}

build_tls_settings() {
    echo ""
    ui_info "TLS Settings"

    local CERTS_JSON="[]"
    local CERTS_ARRAY=()

    local AVAILABLE=$(get_available_certs)
    if [ -n "$AVAILABLE" ]; then
        echo "Available certificates: $AVAILABLE"
    fi

    echo "Enter domains (empty to finish):"
    while true; do
        local DOMAIN=$(ui_input "Domain" "")
        [ -z "$DOMAIN" ] && break

        local PATHS=$(find_cert_paths "$DOMAIN")
        if [ -n "$PATHS" ]; then
            local CERT=$(echo "$PATHS" | cut -d'|' -f1)
            local KEY=$(echo "$PATHS" | cut -d'|' -f2)
            CERTS_ARRAY+=("{\"certificateFile\":\"$CERT\",\"keyFile\":\"$KEY\"}")
            ui_success "Added: $DOMAIN"
        else
            ui_error "Certificate not found for $DOMAIN"
            local CERT=$(ui_input "Cert file path" "")
            local KEY=$(ui_input "Key file path" "")
            if [ -f "$CERT" ] && [ -f "$KEY" ]; then
                CERTS_ARRAY+=("{\"certificateFile\":\"$CERT\",\"keyFile\":\"$KEY\"}")
                ui_success "Added manually"
            fi
        fi
    done

    if [ ${#CERTS_ARRAY[@]} -gt 0 ]; then
        CERTS_JSON=$(printf '%s\n' "${CERTS_ARRAY[@]}" | jq -s '.')
    fi

    echo "{\"certificates\":$CERTS_JSON,\"alpn\":[\"h2\",\"http/1.1\"]}"
}

# ============ CLIENT BUILDERS ============

build_vless_client() {
    local FLOW=$1
    local UUID=$(gen_uuid)
    local EMAIL="user_$(date +%s)"

    EMAIL=$(ui_input "Email" "$EMAIL")
    UUID=$(ui_input "UUID" "$UUID")

    echo "$UUID" > /tmp/last_uuid
    echo "$EMAIL" > /tmp/last_email

    if [ -n "$FLOW" ]; then
        echo "{\"id\":\"$UUID\",\"email\":\"$EMAIL\",\"flow\":\"$FLOW\"}"
    else
        echo "{\"id\":\"$UUID\",\"email\":\"$EMAIL\"}"
    fi
}

build_vmess_client() {
    local UUID=$(gen_uuid)
    local EMAIL="user_$(date +%s)"

    EMAIL=$(ui_input "Email" "$EMAIL")
    UUID=$(ui_input "UUID" "$UUID")

    echo "$UUID" > /tmp/last_uuid
    echo "{\"id\":\"$UUID\",\"email\":\"$EMAIL\",\"alterId\":0}"
}

build_trojan_client() {
    local PASS=$(gen_password)
    local EMAIL="user_$(date +%s)"

    EMAIL=$(ui_input "Email" "$EMAIL")
    PASS=$(ui_input "Password" "$PASS")

    echo "$PASS" > /tmp/last_pass
    echo "{\"password\":\"$PASS\",\"email\":\"$EMAIL\"}"
}

build_ss_settings() {
    echo "Method: 1) 2022-blake3-aes-128-gcm 2) aes-256-gcm 3) chacha20-poly1305"
    local M_OPT=$(ui_input "Select" "1")
    local METHOD="2022-blake3-aes-128-gcm"
    case $M_OPT in 2) METHOD="aes-256-gcm" ;; 3) METHOD="chacha20-poly1305" ;; esac

    local PASS=$(gen_ss_password)
    PASS=$(ui_input "Password" "$PASS")

    echo "$PASS" > /tmp/last_pass
    echo "{\"method\":\"$METHOD\",\"password\":\"$PASS\",\"network\":\"tcp,udp\"}"
}

# ============ ADVANCED CREATOR ============

create_advanced_inbound() {
    ui_header "CREATE INBOUND" 55

    check_inbound_requirements || return

    # Step 1: Protocol
    echo -e "${UI_YELLOW}Step 1: Protocol${UI_NC}"
    local PROTOCOL=$(select_protocol)
    ui_success "Selected: $PROTOCOL"

    # Step 2: Transport
    echo -e "\n${UI_YELLOW}Step 2: Transport${UI_NC}"
    local TRANSPORT=$(select_transport)
    ui_success "Selected: $TRANSPORT"

    # Step 3: Security
    echo -e "\n${UI_YELLOW}Step 3: Security${UI_NC}"
    local SECURITY=$(select_security "$TRANSPORT")
    ui_success "Selected: $SECURITY"

    # Validate
    if [[ "$SECURITY" == "reality" ]] && [[ ! "$TRANSPORT" =~ ^(tcp|grpc|h2)$ ]]; then
        ui_error "Reality only works with TCP, gRPC, or H2!"
        pause; return
    fi

    # Step 4: Basic Info
    echo -e "\n${UI_YELLOW}Step 4: Basic Info${UI_NC}"
    local DEFAULT_TAG="${PROTOCOL^^}_${TRANSPORT^^}_$(date +%s)"
    local TAG=$(ui_input "Tag" "$DEFAULT_TAG")
    local PORT=$(input_port "")
    local LISTEN=$(ui_input "Listen" "0.0.0.0")

    # Step 5: Transport Settings
    echo -e "\n${UI_YELLOW}Step 5: Transport Settings${UI_NC}"
    local TRANSPORT_SETTINGS="{}"
    case $TRANSPORT in
        tcp)
            if ui_confirm "Use HTTP Camouflage?" "n"; then
                TRANSPORT_SETTINGS=$(build_tcp_settings "y")
            else
                TRANSPORT_SETTINGS=$(build_tcp_settings "n")
            fi
            ;;
        ws) TRANSPORT_SETTINGS=$(build_ws_settings) ;;
        grpc) TRANSPORT_SETTINGS=$(build_grpc_settings) ;;
        xhttp) TRANSPORT_SETTINGS=$(build_xhttp_settings) ;;
        httpupgrade) TRANSPORT_SETTINGS=$(build_httpupgrade_settings) ;;
        h2) TRANSPORT_SETTINGS=$(build_h2_settings) ;;
        kcp) TRANSPORT_SETTINGS=$(build_kcp_settings) ;;
        quic) TRANSPORT_SETTINGS=$(build_quic_settings) ;;
    esac

    # Step 6: Security Settings
    echo -e "\n${UI_YELLOW}Step 6: Security Settings${UI_NC}"
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

    # Step 7: Client Settings
    echo -e "\n${UI_YELLOW}Step 7: Client Settings${UI_NC}"
    local SETTINGS=""

    case $PROTOCOL in
        vless)
            local CLIENT=$(build_vless_client "$FLOW")
            SETTINGS="{\"clients\":[$CLIENT],\"decryption\":\"none\"}"
            ;;
        vmess)
            local CLIENT=$(build_vmess_client)
            SETTINGS="{\"clients\":[$CLIENT]}"
            ;;
        trojan)
            local CLIENT=$(build_trojan_client)
            SETTINGS="{\"clients\":[$CLIENT]}"
            ;;
        shadowsocks)
            SETTINGS=$(build_ss_settings)
            ;;
        socks)
            if ui_confirm "Require Auth?" "n"; then
                local USER=$(ui_input "Username" "")
                local PASS=$(ui_input "Password" "")
                SETTINGS="{\"auth\":\"password\",\"accounts\":[{\"user\":\"$USER\",\"pass\":\"$PASS\"}],\"udp\":true}"
            else
                SETTINGS="{\"auth\":\"noauth\",\"udp\":true}"
            fi
            ;;
        http)
            if ui_confirm "Require Auth?" "n"; then
                local USER=$(ui_input "Username" "")
                local PASS=$(ui_input "Password" "")
                SETTINGS="{\"accounts\":[{\"user\":\"$USER\",\"pass\":\"$PASS\"}]}"
            else
                SETTINGS="{}"
            fi
            ;;
        dokodemo-door)
            local ADDR=$(ui_input "Target Address" "")
            local TPORT=$(ui_input "Target Port" "")
            local NET=$(ui_input "Network" "tcp,udp")
            SETTINGS="{\"address\":\"$ADDR\",\"port\":$TPORT,\"network\":\"$NET\"}"
            ;;
    esac

    # Sniffing
    local SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}'
    if ! ui_confirm "Enable Sniffing?" "y"; then
        SNIFFING='{"enabled":false}'
    fi

    # Create
    backup_xray_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
tag = "$TAG"
port = $PORT
listen_addr = "$LISTEN"
protocol = "$PROTOCOL"
transport = "$TRANSPORT"
security = "$SECURITY"

settings = $SETTINGS
transport_settings = $TRANSPORT_SETTINGS
security_settings = $SECURITY_SETTINGS
sniffing = $SNIFFING

stream_settings = {"network": transport, "security": security}

transport_key = f"{transport}Settings"
if transport == "ws": transport_key = "wsSettings"
elif transport == "h2": transport_key = "httpSettings"
elif transport == "kcp": transport_key = "kcpSettings"

stream_settings[transport_key] = transport_settings

if security == "reality":
    stream_settings["realitySettings"] = security_settings
elif security == "tls":
    stream_settings["tlsSettings"] = security_settings

new_inbound = {
    "tag": tag, "listen": listen_addr, "port": port,
    "protocol": protocol, "settings": settings,
    "streamSettings": stream_settings, "sniffing": sniffing
}

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print(f"CONFLICT")
            sys.exit(1)
    config['inbounds'].append(new_inbound)
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("SUCCESS")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        echo ""
        ui_success "Inbound Created!"
        echo ""
        echo -e "Tag:       ${UI_CYAN}$TAG${UI_NC}"
        echo -e "Protocol:  ${UI_CYAN}$PROTOCOL${UI_NC}"
        echo -e "Transport: ${UI_CYAN}$TRANSPORT${UI_NC}"
        echo -e "Security:  ${UI_CYAN}$SECURITY${UI_NC}"
        echo -e "Port:      ${UI_CYAN}$PORT${UI_NC}"

        [ -f /tmp/last_uuid ] && echo -e "UUID:      ${UI_CYAN}$(cat /tmp/last_uuid)${UI_NC}"
        [ -f /tmp/last_pass ] && echo -e "Password:  ${UI_CYAN}$(cat /tmp/last_pass)${UI_NC}"
        [ -f /tmp/reality_pub ] && echo -e "PublicKey: ${UI_CYAN}$(cat /tmp/reality_pub)${UI_NC}"
        [ -f /tmp/reality_sid ] && echo -e "ShortID:   ${UI_CYAN}$(cat /tmp/reality_sid)${UI_NC}"

        rm -f /tmp/last_uuid /tmp/last_pass /tmp/last_email /tmp/reality_pub /tmp/reality_sid

        echo ""
        if ui_confirm "Restart Panel?" "y"; then
            restart_service "panel"
        fi
    fi

    pause
}

# ============ QUICK PRESETS ============

quick_reality_preset() {
    ui_header "QUICK REALITY" 55

    check_inbound_requirements || return

    echo "Preset: 1) VLESS+Reality+TCP+Vision  2) VLESS+Reality+gRPC  3) VLESS+Reality+H2"
    local PRESET=$(ui_input "Select" "1")

    local TRANSPORT="tcp"
    local FLOW="xtls-rprx-vision"
    case $PRESET in
        2) TRANSPORT="grpc"; FLOW="" ;;
        3) TRANSPORT="h2"; FLOW="" ;;
    esac

    local TAG=$(ui_input "Tag" "REALITY_$(date +%s)")
    local PORT=$(input_port "")

    echo "SNI: 1) google.com 2) microsoft.com 3) apple.com 4) cloudflare.com 5) Custom"
    local SNI_OPT=$(ui_input "Select" "1")
    local DEST="www.google.com"
    case $SNI_OPT in
        2) DEST="www.microsoft.com" ;;
        3) DEST="www.apple.com" ;;
        4) DEST="www.cloudflare.com" ;;
        5) DEST=$(ui_input "Domain" "") ;;
    esac

    ui_spinner_start "Generating keys..."
    local KEYS=$(gen_x25519_keys)
    ui_spinner_stop

    local PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    local SID=$(gen_short_id)
    local UUID=$(gen_uuid)

    if [[ "$PRIV" == "ERROR" ]] || [[ -z "$PRIV" ]]; then
        ui_error "Failed to generate keys!"
        pause; return
    fi

    backup_xray_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
tag = "$TAG"
port = $PORT
transport = "$TRANSPORT"
flow = "$FLOW"
dest = "$DEST"
priv = "$PRIV"
sid = "$SID"
uuid = "$UUID"

client = {"id": uuid, "email": f"user_{tag}"}
if flow:
    client["flow"] = flow

stream = {
    "network": transport,
    "security": "reality",
    "realitySettings": {
        "show": False, "dest": f"{dest}:443", "xver": 0,
        "serverNames": [dest], "privateKey": priv,
        "shortIds": [sid], "fingerprint": "chrome"
    }
}

if transport == "grpc":
    stream["grpcSettings"] = {"serviceName": "grpc"}
elif transport == "h2":
    stream["httpSettings"] = {"path": "/"}
else:
    stream["tcpSettings"] = {"header": {"type": "none"}}

inbound = {
    "tag": tag, "listen": "0.0.0.0", "port": port,
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
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        ui_success "Reality Inbound Created!"
        echo ""
        echo -e "Tag:        ${UI_CYAN}$TAG${UI_NC}"
        echo -e "Port:       ${UI_CYAN}$PORT${UI_NC}"
        echo -e "UUID:       ${UI_CYAN}$UUID${UI_NC}"
        echo -e "SNI:        ${UI_CYAN}$DEST${UI_NC}"
        echo -e "Public Key: ${UI_CYAN}$PUB${UI_NC}"
        echo -e "Short ID:   ${UI_CYAN}$SID${UI_NC}"
        echo ""
        if ui_confirm "Restart Panel?" "y"; then
            restart_service "panel"
        fi
    fi
    pause
}

quick_cdn_preset() {
    ui_header "QUICK CDN" 55

    check_inbound_requirements || return

    echo "Preset: 1) VLESS+WS+NoTLS 2) VMess+WS+NoTLS 3) VLESS+WS+TLS 4) VMess+WS+TLS"
    local PRESET=$(ui_input "Select" "1")

    local PROTO="vless"
    local SECURITY="none"
    case $PRESET in
        2) PROTO="vmess" ;;
        3) SECURITY="tls" ;;
        4) PROTO="vmess"; SECURITY="tls" ;;
    esac

    local TAG=$(ui_input "Tag" "CDN_${PROTO^^}_$(date +%s)")
    local PORT=80
    [ "$SECURITY" == "tls" ] && PORT=443
    PORT=$(input_port "$PORT")
    local PATH=$(ui_input "Path" "/ws")
    local UUID=$(gen_uuid)

    local TLS_SETTINGS="{}"
    if [ "$SECURITY" == "tls" ]; then
        local DOMAIN=$(ui_input "Domain for TLS" "")
        local PATHS=$(find_cert_paths "$DOMAIN")
        if [ -n "$PATHS" ]; then
            local CERT=$(echo "$PATHS" | cut -d'|' -f1)
            local KEY=$(echo "$PATHS" | cut -d'|' -f2)
            TLS_SETTINGS="{\"certificates\":[{\"certificateFile\":\"$CERT\",\"keyFile\":\"$KEY\"}]}"
        else
            ui_error "Certificate not found!"
            pause; return
        fi
    fi

    backup_xray_config

    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
tag = "$TAG"
port = $PORT
proto = "$PROTO"
security = "$SECURITY"
path = "$PATH"
uuid = "$UUID"
tls_settings = $TLS_SETTINGS

if proto == "vmess":
    client = {"id": uuid, "email": f"user_{tag}", "alterId": 0}
    settings = {"clients": [client]}
else:
    client = {"id": uuid, "email": f"user_{tag}"}
    settings = {"clients": [client], "decryption": "none"}

stream = {"network": "ws", "security": security, "wsSettings": {"path": path}}
if security == "tls":
    stream["tlsSettings"] = tls_settings

inbound = {
    "tag": tag, "listen": "0.0.0.0", "port": port,
    "protocol": proto, "settings": settings,
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
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        ui_success "CDN Inbound Created!"
        echo -e "Tag:  ${UI_CYAN}$TAG${UI_NC}"
        echo -e "Port: ${UI_CYAN}$PORT${UI_NC}"
        echo -e "Path: ${UI_CYAN}$PATH${UI_NC}"
        echo -e "UUID: ${UI_CYAN}$UUID${UI_NC}"
        echo ""
        if ui_confirm "Restart Panel?" "y"; then
            restart_service "panel"
        fi
    fi
    pause
}