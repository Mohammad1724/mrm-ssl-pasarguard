#!/bin/bash

# ============================================
# INBOUND MANAGER - Tools
# Version: 2.1 (Clean UI)
# ============================================

# ============ GENERATE SHARE LINK ============
generate_share_link() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}GENERATE SHARE LINK${UI_NC}                 ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    list_inbounds_silent

    echo ""
    read -p "  Inbound number (0=back): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && return

    echo ""
    read -p "  Server Address/IP: " SERVER
    [[ -z "$SERVER" ]] && { echo -e "  ${UI_RED}✘ Server required${UI_NC}"; pause; return; }

    echo ""
    python3 << PYEOF
import json
import base64
import urllib.parse

def vless_link(server, port, uuid, params):
    q = urllib.parse.urlencode(params)
    tag = params.get('tag', 'vless').replace(' ', '_')
    return f"vless://{uuid}@{server}:{port}?{q}#{tag}"

def vmess_link(server, port, uuid, params):
    cfg = {
        "v": "2",
        "ps": params.get('tag', 'vmess'),
        "add": server,
        "port": str(port),
        "id": uuid,
        "aid": "0",
        "net": params.get('type', 'tcp'),
        "type": "none",
        "host": params.get('host', ''),
        "path": params.get('path', ''),
        "tls": "tls" if params.get('security') == 'tls' else ""
    }
    return f"vmess://{base64.b64encode(json.dumps(cfg).encode()).decode()}"

def trojan_link(server, port, password, params):
    q = urllib.parse.urlencode(params)
    tag = params.get('tag', 'trojan').replace(' ', '_')
    return f"trojan://{password}@{server}:{port}?{q}#{tag}"

def ss_link(server, port, method, password, tag):
    creds = base64.b64encode(f"{method}:{password}".encode()).decode()
    return f"ss://{creds}@{server}:{port}#{tag}"

try:
    idx = int("$NUM") - 1
    server = "$SERVER"

    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if not (0 <= idx < len(inbounds)):
        print("  Invalid number")
        exit(1)

    ib = inbounds[idx]
    proto = ib.get('protocol')
    port = ib.get('port')
    tag = ib.get('tag', 'config')
    stream = ib.get('streamSettings', {})
    settings = ib.get('settings', {})
    network = stream.get('network', 'tcp')
    security = stream.get('security', 'none')
    clients = settings.get('clients', [])

    print("")
    print("  " + "═" * 60)

    if proto == 'vless':
        for c in clients:
            uuid = c.get('id')
            flow = c.get('flow', '')
            email = c.get('email', 'user')
            
            params = {'type': network, 'security': security, 'tag': f"{tag}_{email}"}
            if flow:
                params['flow'] = flow
            
            if security == 'reality':
                r = stream.get('realitySettings', {})
                params['sni'] = r.get('serverNames', [''])[0]
                params['pbk'] = r.get('publicKey', '')
                params['sid'] = r.get('shortIds', [''])[0]
                params['fp'] = r.get('fingerprint', 'chrome')
            elif security == 'tls':
                t = stream.get('tlsSettings', {})
                params['sni'] = t.get('serverName', server)
            
            if network == 'ws':
                w = stream.get('wsSettings', {})
                params['path'] = w.get('path', '/')
                if 'headers' in w and 'Host' in w['headers']:
                    params['host'] = w['headers']['Host']
            elif network == 'grpc':
                g = stream.get('grpcSettings', {})
                params['serviceName'] = g.get('serviceName', '')
                params['mode'] = 'gun'
            elif network == 'xhttp':
                x = stream.get('xhttpSettings', {})
                params['path'] = x.get('path', '/')
            elif network == 'httpupgrade':
                h = stream.get('httpupgradeSettings', {})
                params['path'] = h.get('path', '/')
            
            link = vless_link(server, port, uuid, params)
            print(f"")
            print(f"  {email}:")
            print(f"  {link}")

    elif proto == 'vmess':
        for c in clients:
            uuid = c.get('id')
            email = c.get('email', 'user')
            
            params = {'type': network, 'security': security, 'tag': f"{tag}_{email}"}
            if network == 'ws':
                w = stream.get('wsSettings', {})
                params['path'] = w.get('path', '/')
            
            link = vmess_link(server, port, uuid, params)
            print(f"")
            print(f"  {email}:")
            print(f"  {link}")

    elif proto == 'trojan':
        for c in clients:
            password = c.get('password')
            email = c.get('email', 'user')
            
            params = {'type': network, 'security': security, 'tag': f"{tag}_{email}"}
            if security == 'tls':
                t = stream.get('tlsSettings', {})
                params['sni'] = t.get('serverName', server)
            
            link = trojan_link(server, port, password, params)
            print(f"")
            print(f"  {email}:")
            print(f"  {link}")

    elif proto == 'shadowsocks':
        method = settings.get('method', 'aes-256-gcm')
        password = settings.get('password', '')
        link = ss_link(server, port, method, password, tag)
        print(f"")
        print(f"  {tag}:")
        print(f"  {link}")

    else:
        print(f"  Protocol '{proto}' doesn't support share links")

    print("")
    print("  " + "═" * 60)

except Exception as e:
    print(f"  Error: {e}")
    import traceback
    traceback.print_exc()
PYEOF

    echo ""
    pause
}

# ============ EXPORT INBOUND ============
export_inbound() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}EXPORT INBOUND${UI_NC}                       ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    list_inbounds_silent

    echo ""
    read -p "  Inbound number (0=back): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && return

    local EXPORT_FILE="$INBOUND_EXPORT_DIR/inbound_$(date +%Y%m%d_%H%M%S).json"
    mkdir -p "$INBOUND_EXPORT_DIR"

    python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    inbounds = config.get('inbounds', [])
    if 0 <= idx < len(inbounds):
        with open("$EXPORT_FILE", 'w') as f:
            json.dump(inbounds[idx], f, indent=2)
        print(f"  ✔ Exported: $EXPORT_FILE")
    else:
        print("  Invalid number")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    pause
}

# ============ IMPORT INBOUND ============
import_inbound() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}IMPORT INBOUND${UI_NC}                       ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths

    # Show available exports
    if [ -d "$INBOUND_EXPORT_DIR" ]; then
        local FILES=$(ls -1 "$INBOUND_EXPORT_DIR"/*.json 2>/dev/null)
        if [ -n "$FILES" ]; then
            echo "  Available exports:"
            echo ""
            ls -1 "$INBOUND_EXPORT_DIR"/*.json 2>/dev/null | while read f; do
                echo "    $(basename "$f")"
            done
            echo ""
        fi
    fi

    read -p "  JSON file path (0=back): " IMPORT_FILE
    [[ "$IMPORT_FILE" == "0" || -z "$IMPORT_FILE" ]] && return

    # Check if just filename given
    if [[ ! "$IMPORT_FILE" == /* ]] && [ -f "$INBOUND_EXPORT_DIR/$IMPORT_FILE" ]; then
        IMPORT_FILE="$INBOUND_EXPORT_DIR/$IMPORT_FILE"
    fi

    if [ ! -f "$IMPORT_FILE" ]; then
        echo -e "  ${UI_RED}✘ File not found: $IMPORT_FILE${UI_NC}"
        pause
        return
    fi

    backup_xray_config

    python3 << PYEOF
import json
try:
    with open("$IMPORT_FILE", 'r') as f:
        new_inbound = json.load(f)
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 'inbounds' not in config:
        config['inbounds'] = []
    
    port = new_inbound.get('port')
    for ib in config['inbounds']:
        if ib.get('port') == port:
            print(f"  ✘ CONFLICT: Port {port} already used by {ib.get('tag')}")
            exit(1)
    
    config['inbounds'].append(new_inbound)
    with open("$XRAY_CONFIG", 'w') as f:
        json.dump(config, f, indent=2)
    print(f"  ✔ Imported: {new_inbound.get('tag')}")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    simple_confirm "Restart Panel?" "y" && restart_service "panel"
    pause
}

# ============ BACKUP ALL INBOUNDS ============
backup_all_inbounds() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}BACKUP ALL INBOUNDS${UI_NC}                  ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    
    local BACKUP_FILE="$INBOUND_BACKUP_DIR/all_inbounds_$(date +%Y%m%d_%H%M%S).json"
    mkdir -p "$INBOUND_BACKUP_DIR"

    python3 << PYEOF
import json
try:
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    inbounds = config.get('inbounds', [])
    with open("$BACKUP_FILE", 'w') as f:
        json.dump(inbounds, f, indent=2)
    print(f"  ✔ Backed up {len(inbounds)} inbound(s)")
    print(f"  File: $BACKUP_FILE")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    pause
}

# ============ RESTORE INBOUNDS ============
restore_inbounds() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}RESTORE INBOUNDS${UI_NC}                     ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths

    # Show available backups
    if [ -d "$INBOUND_BACKUP_DIR" ]; then
        local FILES=$(ls -1t "$INBOUND_BACKUP_DIR"/all_inbounds_*.json 2>/dev/null | head -10)
        if [ -n "$FILES" ]; then
            echo "  Recent backups:"
            echo ""
            local i=1
            declare -a BACKUP_FILES
            while IFS= read -r f; do
                BACKUP_FILES+=("$f")
                local fname=$(basename "$f")
                local fsize=$(ls -lh "$f" | awk '{print $5}')
                printf "    %d) %s (%s)\n" "$i" "$fname" "$fsize"
                ((i++))
            done <<< "$FILES"
            echo ""
            echo "    0) Enter path manually"
            echo ""
            
            read -p "  Select backup: " SEL
            
            if [[ "$SEL" == "0" ]]; then
                read -p "  Backup file path: " BACKUP_FILE
            elif [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le ${#BACKUP_FILES[@]} ]; then
                BACKUP_FILE="${BACKUP_FILES[$((SEL-1))]}"
            else
                echo -e "  ${UI_RED}✘ Invalid selection${UI_NC}"
                pause
                return
            fi
        else
            read -p "  Backup file path: " BACKUP_FILE
        fi
    else
        read -p "  Backup file path: " BACKUP_FILE
    fi

    [[ -z "$BACKUP_FILE" ]] && return

    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "  ${UI_RED}✘ File not found: $BACKUP_FILE${UI_NC}"
        pause
        return
    fi

    echo ""
    echo -e "  ${UI_YELLOW}⚠ This will REPLACE all current inbounds!${UI_NC}"
    if ! simple_confirm "Continue?" "n"; then
        return
    fi

    backup_xray_config

    python3 << PYEOF
import json
try:
    with open("$BACKUP_FILE", 'r') as f:
        inbounds = json.load(f)
    
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    
    old_count = len(config.get('inbounds', []))
    config['inbounds'] = inbounds
    
    with open("$XRAY_CONFIG", 'w') as f:
        json.dump(config, f, indent=2)
    
    print(f"  ✔ Restored {len(inbounds)} inbound(s)")
    print(f"  (Previous: {old_count} inbounds)")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    simple_confirm "Restart Panel?" "y" && restart_service "panel"
    pause
}