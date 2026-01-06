#!/bin/bash

# ============================================
# INBOUND MANAGER - Tools
# ============================================

generate_share_link() {
    ui_header "SHARE LINK" 55

    export XRAY_CONFIG
    list_inbounds

    local NUM=$(ui_input "Inbound number (0=cancel)" "0")
    [ "$NUM" == "0" ] && return

    local SERVER=$(ui_input "Server Address/IP" "")

    python3 << PYEOF
import json
import base64
import urllib.parse

def vless_link(server, port, uuid, params):
    q = urllib.parse.urlencode(params)
    return f"vless://{uuid}@{server}:{port}?{q}#{params.get('tag', 'vless')}"

def vmess_link(server, port, uuid, params):
    cfg = {"v": "2", "ps": params.get('tag', 'vmess'), "add": server, "port": str(port),
           "id": uuid, "aid": "0", "net": params.get('type', 'tcp'), "type": "none",
           "host": params.get('host', ''), "path": params.get('path', ''),
           "tls": params.get('security', 'none')}
    return f"vmess://{base64.b64encode(json.dumps(cfg).encode()).decode()}"

def trojan_link(server, port, password, params):
    q = urllib.parse.urlencode(params)
    return f"trojan://{password}@{server}:{port}?{q}#{params.get('tag', 'trojan')}"

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
        print("Invalid")
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

    print("\n" + "=" * 60)

    if proto == 'vless':
        for c in clients:
            uuid = c.get('id')
            flow = c.get('flow', '')
            email = c.get('email', 'user')
            params = {'type': network, 'security': security, 'tag': f"{tag}_{email}"}
            if flow: params['flow'] = flow
            if security == 'reality':
                r = stream.get('realitySettings', {})
                params['sni'] = r.get('serverNames', [''])[0]
                params['pbk'] = r.get('publicKey', '')
                params['sid'] = r.get('shortIds', [''])[0]
                params['fp'] = r.get('fingerprint', 'chrome')
            if network == 'ws':
                w = stream.get('wsSettings', {})
                params['path'] = w.get('path', '/')
            print(f"\n{email}:\n{vless_link(server, port, uuid, params)}")

    elif proto == 'vmess':
        for c in clients:
            uuid = c.get('id')
            email = c.get('email', 'user')
            params = {'type': network, 'security': security, 'tag': f"{tag}_{email}"}
            if network == 'ws':
                params['path'] = stream.get('wsSettings', {}).get('path', '/')
            print(f"\n{email}:\n{vmess_link(server, port, uuid, params)}")

    elif proto == 'trojan':
        for c in clients:
            password = c.get('password')
            email = c.get('email', 'user')
            params = {'type': network, 'security': security, 'tag': f"{tag}_{email}"}
            print(f"\n{email}:\n{trojan_link(server, port, password, params)}")

    elif proto == 'shadowsocks':
        method = settings.get('method', 'aes-256-gcm')
        password = settings.get('password', '')
        print(f"\n{tag}:\n{ss_link(server, port, method, password, tag)}")

    print("\n" + "=" * 60)
except Exception as e:
    print(f"Error: {e}")
PYEOF

    pause
}

export_inbound() {
    ui_header "EXPORT INBOUND" 55

    export XRAY_CONFIG
    list_inbounds

    local NUM=$(ui_input "Inbound number (0=cancel)" "0")
    [ "$NUM" == "0" ] && return

    local EXPORT_FILE="$INBOUND_EXPORT_DIR/inbound_$(date +%Y%m%d_%H%M%S).json"

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
        print(f"Exported: $EXPORT_FILE")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    pause
}

import_inbound() {
    ui_header "IMPORT INBOUND" 55

    local IMPORT_FILE=$(ui_input "JSON file path" "")

    if [ ! -f "$IMPORT_FILE" ]; then
        ui_error "File not found!"
        pause; return
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
            print(f"CONFLICT: Port {port}")
            exit(1)
    config['inbounds'].append(new_inbound)
    with open("$XRAY_CONFIG", 'w') as f:
        json.dump(config, f, indent=2)
    print(f"Imported: {new_inbound.get('tag')}")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if ui_confirm "Restart Panel?" "y"; then
        restart_service "panel"
    fi
    pause
}

backup_all_inbounds() {
    ui_header "BACKUP INBOUNDS" 55

    local BACKUP_FILE="$INBOUND_BACKUP_DIR/all_inbounds_$(date +%Y%m%d_%H%M%S).json"

    python3 << PYEOF
import json
try:
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    inbounds = config.get('inbounds', [])
    with open("$BACKUP_FILE", 'w') as f:
        json.dump(inbounds, f, indent=2)
    print(f"Backed up {len(inbounds)} inbound(s) to: $BACKUP_FILE")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    pause
}

restore_inbounds() {
    ui_header "RESTORE INBOUNDS" 55

    echo "Available backups:"
    ls -la "$INBOUND_BACKUP_DIR"/*.json 2>/dev/null || echo "No backups found"
    echo ""

    local BACKUP_FILE=$(ui_input "Backup file path" "")

    if [ ! -f "$BACKUP_FILE" ]; then
        ui_error "File not found!"
        pause; return
    fi

    backup_xray_config

    python3 << PYEOF
import json
try:
    with open("$BACKUP_FILE", 'r') as f:
        inbounds = json.load(f)
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    config['inbounds'] = inbounds
    with open("$XRAY_CONFIG", 'w') as f:
        json.dump(config, f, indent=2)
    print(f"Restored {len(inbounds)} inbound(s)")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if ui_confirm "Restart Panel?" "y"; then
        restart_service "panel"
    fi
    pause
}