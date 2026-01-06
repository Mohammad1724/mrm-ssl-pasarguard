#!/bin/bash

# ============================================
# INBOUND MANAGER - Manage Functions
# ============================================

list_inbounds() {
    ui_header "INBOUNDS LIST" 70

    [ ! -f "$XRAY_CONFIG" ] && { ui_error "Config not found"; pause; return; }

    python3 << 'PYEOF'
import json
import os

config_path = os.environ.get('XRAY_CONFIG', '')
if not config_path:
    print("Config path not set")
    exit(1)

try:
    with open(config_path, 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if not inbounds:
        print("No inbounds configured.")
        exit(0)

    print(f"\n{'#':<3} {'TAG':<25} {'PROTO':<10} {'PORT':<7} {'NET':<12} {'SEC':<8}")
    print("─" * 68)

    for i, ib in enumerate(inbounds, 1):
        tag = ib.get('tag', 'N/A')[:24]
        proto = ib.get('protocol', '?')
        port = ib.get('port', '?')
        stream = ib.get('streamSettings', {})
        network = stream.get('network', 'tcp')
        security = stream.get('security', 'none')
        print(f"{i:<3} {tag:<25} {proto:<10} {port:<7} {network:<12} {security:<8}")

    print("─" * 68)
    print(f"Total: {len(inbounds)} inbound(s)")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    echo ""
    pause
}

view_inbound_details() {
    ui_header "INBOUND DETAILS" 55

    export XRAY_CONFIG
    list_inbounds

    local NUM=$(ui_input "Inbound number (0=cancel)" "0")
    [ "$NUM" == "0" ] && return

    python3 << PYEOF
import json
import os

try:
    idx = int("$NUM") - 1
    config_path = "$XRAY_CONFIG"

    with open(config_path, 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if 0 <= idx < len(inbounds):
        print("\n" + "=" * 60)
        print(json.dumps(inbounds[idx], indent=2, ensure_ascii=False))
        print("=" * 60)
    else:
        print("Invalid number")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    pause
}

edit_inbound() {
    ui_header "EDIT INBOUND" 55

    export XRAY_CONFIG
    list_inbounds

    local NUM=$(ui_input "Inbound number (0=cancel)" "0")
    [ "$NUM" == "0" ] && return

    echo ""
    echo "1) Change Port"
    echo "2) Change Tag"
    echo "3) Add Client"
    echo "4) Remove Client"
    echo "5) Change Path"
    echo "6) Toggle Sniffing"
    echo "0) Cancel"
    echo ""

    local EDIT_OPT=$(ui_input "Select" "0")

    backup_xray_config

    case $EDIT_OPT in
        1)
            local NEW_PORT=$(ui_input "New Port" "")
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        for i, ib in enumerate(config['inbounds']):
            if i != idx and ib.get('port') == $NEW_PORT:
                print(f"CONFLICT: Port used by {ib.get('tag')}")
                exit(1)
        config['inbounds'][idx]['port'] = $NEW_PORT
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print("OK")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            ;;
        2)
            local NEW_TAG=$(ui_input "New Tag" "")
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        config['inbounds'][idx]['tag'] = "$NEW_TAG"
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print("OK")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            ;;
        3)
            local UUID=$(gen_uuid)
            local EMAIL=$(ui_input "Email" "user_$(date +%s)")
            UUID=$(ui_input "UUID" "$UUID")

            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        ib = config['inbounds'][idx]
        proto = ib.get('protocol', '')
        if proto in ['vless', 'vmess']:
            new_client = {"id": "$UUID", "email": "$EMAIL"}
            if proto == 'vmess':
                new_client['alterId'] = 0
            ib.setdefault('settings', {}).setdefault('clients', []).append(new_client)
        elif proto == 'trojan':
            ib.setdefault('settings', {}).setdefault('clients', []).append({"password": "$UUID", "email": "$EMAIL"})
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print("Client added!")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            ;;
        4)
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        clients = config['inbounds'][idx].get('settings', {}).get('clients', [])
        if not clients:
            print("No clients")
            exit(0)
        print("\nClients:")
        for i, c in enumerate(clients, 1):
            print(f"  {i}) {c.get('email', 'N/A')}")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            local C_NUM=$(ui_input "Client number to remove" "")
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    cidx = int("$C_NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        clients = config['inbounds'][idx].get('settings', {}).get('clients', [])
        if 0 <= cidx < len(clients):
            removed = clients.pop(cidx)
            with open("$XRAY_CONFIG", 'w') as f:
                json.dump(config, f, indent=2)
            print(f"Removed: {removed.get('email', 'N/A')}")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            ;;
        5)
            local NEW_PATH=$(ui_input "New Path" "")
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        stream = config['inbounds'][idx].get('streamSettings', {})
        network = stream.get('network', 'tcp')
        key = f"{network}Settings"
        if network == 'ws': key = 'wsSettings'
        elif network == 'h2': key = 'httpSettings'
        if key in stream:
            stream[key]['path'] = "$NEW_PATH"
        else:
            stream[key] = {'path': "$NEW_PATH"}
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print("OK")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            ;;
        6)
            if ui_confirm "Enable Sniffing?" "y"; then
                local ENABLED="true"
            else
                local ENABLED="false"
            fi
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        config['inbounds'][idx]['sniffing'] = {"enabled": $ENABLED, "destOverride": ["http", "tls", "quic"]}
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print("OK")
except Exception as e:
    print(f"Error: {e}")
PYEOF
            ;;
        0) return ;;
    esac

    if ui_confirm "Restart Panel?" "y"; then
        restart_service "panel"
    fi
    pause
}

clone_inbound() {
    ui_header "CLONE INBOUND" 55

    export XRAY_CONFIG
    list_inbounds

    local NUM=$(ui_input "Inbound number (0=cancel)" "0")
    [ "$NUM" == "0" ] && return

    local NEW_TAG=$(ui_input "New Tag" "")
    local NEW_PORT=$(input_port "")

    backup_xray_config

    python3 << PYEOF
import json
import copy

try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if 0 <= idx < len(inbounds):
        for ib in inbounds:
            if ib.get('port') == $NEW_PORT:
                print(f"CONFLICT")
                exit(1)

        new_ib = copy.deepcopy(inbounds[idx])
        new_ib['tag'] = "$NEW_TAG"
        new_ib['port'] = $NEW_PORT
        config['inbounds'].append(new_ib)

        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print("Cloned!")
    else:
        print("Invalid number")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if ui_confirm "Restart Panel?" "y"; then
        restart_service "panel"
    fi
    pause
}

delete_inbound() {
    ui_header "DELETE INBOUND" 55

    export XRAY_CONFIG
    list_inbounds

    local NUM=$(ui_input "Inbound number (0=cancel)" "0")
    [ "$NUM" == "0" ] && return

    if ! ui_confirm "Are you sure?" "n"; then
        return
    fi

    backup_xray_config

    python3 << PYEOF
import json

try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if 0 <= idx < len(inbounds):
        removed = inbounds.pop(idx)
        config['inbounds'] = inbounds
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print(f"Deleted: {removed.get('tag')}")
    else:
        print("Invalid number")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if ui_confirm "Restart Panel?" "y"; then
        restart_service "panel"
    fi
    pause
}