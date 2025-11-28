#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Config file path
XRAY_CONFIG="/var/lib/pasarguard/config.json"

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

generate_short_id() {
    openssl rand -hex 8
}

generate_keys() {
    # Generate Reality keys using xray
    if command -v xray &> /dev/null; then
        xray x25519
    elif [ -f "/usr/local/bin/xray" ]; then
        /usr/local/bin/xray x25519
    else
        # Fallback: use docker
        docker exec pasarguard xray x25519 2>/dev/null
    fi
}

add_vless_reality() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      VLESS + Reality Inbound Wizard         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    # Get inputs
    read -p "Inbound Name (e.g., MAIN_REALITY): " IB_NAME
    [ -z "$IB_NAME" ] && IB_NAME="VLESS_REALITY_$(date +%s)"
    
    read -p "Port [443]: " IB_PORT
    [ -z "$IB_PORT" ] && IB_PORT="443"
    
    read -p "Dest Domain (e.g., www.google.com:443): " DEST_DOMAIN
    [ -z "$DEST_DOMAIN" ] && DEST_DOMAIN="www.google.com:443"
    
    read -p "Server Names (comma separated, e.g., www.google.com): " SERVER_NAMES
    [ -z "$SERVER_NAMES" ] && SERVER_NAMES="www.google.com"
    
    echo ""
    echo -e "${BLUE}Generating Keys...${NC}"
    
    # Generate keys
    local KEYS=$(generate_keys)
    local PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    local PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    local SHORT_ID=$(generate_short_id)
    local UUID=$(generate_uuid)
    
    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Failed to generate keys. Make sure Xray is installed.${NC}"
        pause
        return
    fi
    
    echo -e "${GREEN}✔ Keys Generated${NC}"
    echo ""
    
    # Create inbound JSON
    local INBOUND_JSON=$(cat <<EOF
{
    "tag": "$IB_NAME",
    "listen": "0.0.0.0",
    "port": $IB_PORT,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "$UUID",
                "flow": "xtls-rprx-vision"
            }
        ],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "dest": "$DEST_DOMAIN",
            "xver": 0,
            "serverNames": ["$(echo $SERVER_NAMES | sed 's/,/","/g')"],
            "privateKey": "$PRIVATE_KEY",
            "shortIds": ["$SHORT_ID"],
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

    # Backup config
    if [ -f "$XRAY_CONFIG" ]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%s)"
        echo -e "${GREEN}✔ Config backed up${NC}"
    fi
    
    # Add to config using Python (safe JSON manipulation)
    python3 << PYEOF
import json
import sys

config_path = "$XRAY_CONFIG"
new_inbound = $INBOUND_JSON

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    # Check if inbounds exists
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    # Check for duplicate port
    for ib in config['inbounds']:
        if ib.get('port') == new_inbound['port']:
            print(f"Warning: Port {new_inbound['port']} already in use by {ib.get('tag', 'unknown')}")
            sys.exit(1)
    
    # Add new inbound
    config['inbounds'].append(new_inbound)
    
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print("SUCCESS")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ Inbound Added Successfully!${NC}"
        echo ""
        echo -e "${YELLOW}=== CONNECTION INFO ===${NC}"
        echo -e "Protocol:   ${CYAN}VLESS + Reality${NC}"
        echo -e "Port:       ${CYAN}$IB_PORT${NC}"
        echo -e "UUID:       ${CYAN}$UUID${NC}"
        echo -e "Public Key: ${CYAN}$PUBLIC_KEY${NC}"
        echo -e "Short ID:   ${CYAN}$SHORT_ID${NC}"
        echo -e "SNI:        ${CYAN}$SERVER_NAMES${NC}"
        echo -e "Flow:       ${CYAN}xtls-rprx-vision${NC}"
        echo ""
        echo -e "${YELLOW}Save this info! You need it for client config.${NC}"
        
        # Restart panel
        read -p "Restart panel now? (y/n): " RESTART
        if [ "$RESTART" == "y" ]; then
            restart_service "panel"
        fi
    else
        echo -e "${RED}Failed to add inbound. Check config file.${NC}"
    fi
    
    pause
}

add_vless_ws_tls() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      VLESS + WS + TLS Inbound Wizard        ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Inbound Name (e.g., VLESS_WS): " IB_NAME
    [ -z "$IB_NAME" ] && IB_NAME="VLESS_WS_$(date +%s)"
    
    read -p "Port [443]: " IB_PORT
    [ -z "$IB_PORT" ] && IB_PORT="443"
    
    read -p "Domain (e.g., example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Domain is required for TLS!${NC}"
        pause
        return
    fi
    
    read -p "WebSocket Path [/ws]: " WS_PATH
    [ -z "$WS_PATH" ] && WS_PATH="/ws"
    
    read -p "Fallback Port (e.g., 80 for fake site) [none]: " FALLBACK_PORT
    
    local UUID=$(generate_uuid)
    local CERT_PATH="/var/lib/pasarguard/certs/$DOMAIN"
    
    # Check if cert exists
    if [ ! -f "$CERT_PATH/fullchain.pem" ]; then
        echo -e "${YELLOW}Warning: Certificate not found at $CERT_PATH${NC}"
        echo -e "You may need to generate SSL first."
    fi
    
    # Build fallback section
    local FALLBACK_SECTION=""
    if [ -n "$FALLBACK_PORT" ]; then
        FALLBACK_SECTION='"fallbacks": [{"dest": '$FALLBACK_PORT'}],'
    fi
    
    local INBOUND_JSON=$(cat <<EOF
{
    "tag": "$IB_NAME",
    "listen": "0.0.0.0",
    "port": $IB_PORT,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "$UUID",
                "flow": ""
            }
        ],
        "decryption": "none",
        "fallbacks": $([ -n "$FALLBACK_PORT" ] && echo '[{"dest": '$FALLBACK_PORT'}]' || echo '[]')
    },
    "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {
            "path": "$WS_PATH",
            "headers": {}
        },
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "certificates": [
                {
                    "certificateFile": "$CERT_PATH/fullchain.pem",
                    "keyFile": "$CERT_PATH/privkey.pem"
                }
            ]
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }
}
EOF
)

    # Backup and add
    if [ -f "$XRAY_CONFIG" ]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%s)"
    fi
    
    python3 << PYEOF
import json
config_path = "$XRAY_CONFIG"
new_inbound = $INBOUND_JSON

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    config['inbounds'].append(new_inbound)
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("SUCCESS")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ Inbound Added Successfully!${NC}"
        echo ""
        echo -e "${YELLOW}=== CONNECTION INFO ===${NC}"
        echo -e "Protocol: ${CYAN}VLESS + WS + TLS${NC}"
        echo -e "Address:  ${CYAN}$DOMAIN${NC}"
        echo -e "Port:     ${CYAN}$IB_PORT${NC}"
        echo -e "UUID:     ${CYAN}$UUID${NC}"
        echo -e "Path:     ${CYAN}$WS_PATH${NC}"
        [ -n "$FALLBACK_PORT" ] && echo -e "Fallback: ${CYAN}Port $FALLBACK_PORT${NC}"
        
        read -p "Restart panel now? (y/n): " RESTART
        [ "$RESTART" == "y" ] && restart_service "panel"
    fi
    
    pause
}

add_trojan_ws() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      Trojan + WS + TLS Inbound Wizard       ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    read -p "Inbound Name: " IB_NAME
    [ -z "$IB_NAME" ] && IB_NAME="TROJAN_WS_$(date +%s)"
    
    read -p "Port [443]: " IB_PORT
    [ -z "$IB_PORT" ] && IB_PORT="443"
    
    read -p "Domain: " DOMAIN
    [ -z "$DOMAIN" ] && { echo -e "${RED}Domain required!${NC}"; pause; return; }
    
    read -p "WebSocket Path [/trojan]: " WS_PATH
    [ -z "$WS_PATH" ] && WS_PATH="/trojan"
    
    local PASSWORD=$(openssl rand -hex 16)
    local CERT_PATH="/var/lib/pasarguard/certs/$DOMAIN"
    
    local INBOUND_JSON=$(cat <<EOF
{
    "tag": "$IB_NAME",
    "listen": "0.0.0.0",
    "port": $IB_PORT,
    "protocol": "trojan",
    "settings": {
        "clients": [
            {
                "password": "$PASSWORD"
            }
        ]
    },
    "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {
            "path": "$WS_PATH"
        },
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "certificates": [
                {
                    "certificateFile": "$CERT_PATH/fullchain.pem",
                    "keyFile": "$CERT_PATH/privkey.pem"
                }
            ]
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }
}
EOF
)

    if [ -f "$XRAY_CONFIG" ]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.backup.$(date +%s)"
    fi
    
    python3 << PYEOF
import json
config_path = "$XRAY_CONFIG"
new_inbound = $INBOUND_JSON
try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    config['inbounds'].append(new_inbound)
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("SUCCESS")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ Trojan Inbound Added!${NC}"
        echo ""
        echo -e "Protocol: ${CYAN}Trojan + WS + TLS${NC}"
        echo -e "Address:  ${CYAN}$DOMAIN${NC}"
        echo -e "Port:     ${CYAN}$IB_PORT${NC}"
        echo -e "Password: ${CYAN}$PASSWORD${NC}"
        echo -e "Path:     ${CYAN}$WS_PATH${NC}"
        
        read -p "Restart panel now? (y/n): " RESTART
        [ "$RESTART" == "y" ] && restart_service "panel"
    fi
    
    pause
}

list_inbounds() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CURRENT INBOUNDS                       ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "${RED}Config file not found!${NC}"
        pause
        return
    fi
    
    python3 << 'PYEOF'
import json

try:
    with open("/var/lib/pasarguard/config.json", 'r') as f:
        config = json.load(f)
    
    inbounds = config.get('inbounds', [])
    
    if not inbounds:
        print("No inbounds found.")
    else:
        print(f"{'#':<3} {'Tag':<25} {'Protocol':<10} {'Port':<8} {'Security':<10}")
        print("-" * 60)
        for i, ib in enumerate(inbounds, 1):
            tag = ib.get('tag', 'N/A')[:24]
            proto = ib.get('protocol', 'N/A')
            port = ib.get('port', 'N/A')
            sec = ib.get('streamSettings', {}).get('security', 'none')
            print(f"{i:<3} {tag:<25} {proto:<10} {port:<8} {sec:<10}")

except Exception as e:
    print(f"Error: {e}")
PYEOF
    
    pause
}

delete_inbound() {
    clear
    echo -e "${RED}=== DELETE INBOUND ===${NC}"
    
    list_inbounds
    
    read -p "Enter inbound number to delete (or 0 to cancel): " DEL_NUM
    
    [ "$DEL_NUM" == "0" ] && return
    
    python3 << PYEOF
import json

try:
    with open("/var/lib/pasarguard/config.json", 'r') as f:
        config = json.load(f)
    
    idx = int("$DEL_NUM") - 1
    if 0 <= idx < len(config.get('inbounds', [])):
        deleted = config['inbounds'].pop(idx)
        with open("/var/lib/pasarguard/config.json", 'w') as f:
            json.dump(config, f, indent=2)
        print(f"Deleted: {deleted.get('tag', 'unknown')}")
    else:
        print("Invalid number")
except Exception as e:
    print(f"Error: {e}")
PYEOF
    
    read -p "Restart panel? (y/n): " R
    [ "$R" == "y" ] && restart_service "panel"
    pause
}

inbound_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      INBOUND WIZARD                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Add VLESS + Reality (Recommended)"
        echo "2) Add VLESS + WS + TLS"
        echo "3) Add Trojan + WS + TLS"
        echo "4) List All Inbounds"
        echo "5) Delete Inbound"
        echo "6) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) add_vless_reality ;;
            2) add_vless_ws_tls ;;
            3) add_trojan_ws ;;
            4) list_inbounds ;;
            5) delete_inbound ;;
            6) return ;;
            *) ;;
        esac
    done
}