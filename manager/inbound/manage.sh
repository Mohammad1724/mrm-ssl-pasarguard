#!/bin/bash

# ============================================
# INBOUND MANAGER - Manage Functions
# Version: 2.1 (Clean UI)
# ============================================

# ============ LIST INBOUNDS ============
list_inbounds() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}                    ${UI_YELLOW}INBOUNDS LIST${UI_NC}                                 ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "  ${UI_RED}✘ Config not found: $XRAY_CONFIG${UI_NC}"
        pause
        return
    fi

    python3 << 'PYEOF'
import json
import os

config_path = os.environ.get('XRAY_CONFIG', '')
if not config_path:
    config_path = "/var/lib/pasarguard/xray_config.json"

try:
    with open(config_path, 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if not inbounds:
        print("  No inbounds configured.")
    else:
        print(f"  {'#':<3} {'TAG':<22} {'PROTO':<10} {'PORT':<7} {'NET':<10} {'SEC':<8}")
        print("  " + "─" * 62)
        for i, ib in enumerate(inbounds, 1):
            tag = ib.get('tag', 'N/A')[:21]
            proto = ib.get('protocol', '?')
            port = ib.get('port', '?')
            stream = ib.get('streamSettings', {})
            network = stream.get('network', 'tcp')
            security = stream.get('security', 'none')
            print(f"  {i:<3} {tag:<22} {proto:<10} {port:<7} {network:<10} {security:<8}")
        print("  " + "─" * 62)
        print(f"  Total: {len(inbounds)} inbound(s)")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    pause
}

# ============ LIST INBOUNDS (NO PAUSE) ============
list_inbounds_silent() {
    inbound_init_paths

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "  ${UI_RED}✘ Config not found${UI_NC}"
        return 1
    fi

    python3 << 'PYEOF'
import json
import os

config_path = os.environ.get('XRAY_CONFIG', '')
if not config_path:
    config_path = "/var/lib/pasarguard/xray_config.json"

try:
    with open(config_path, 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if not inbounds:
        print("  No inbounds.")
    else:
        print(f"  {'#':<3} {'TAG':<22} {'PROTO':<8} {'PORT':<6}")
        print("  " + "─" * 42)
        for i, ib in enumerate(inbounds, 1):
            tag = ib.get('tag', 'N/A')[:21]
            proto = ib.get('protocol', '?')
            port = ib.get('port', '?')
            print(f"  {i:<3} {tag:<22} {proto:<8} {port:<6}")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
}

# ============ VIEW DETAILS ============
view_inbound_details() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}INBOUND DETAILS${UI_NC}                      ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    list_inbounds_silent

    echo ""
    read -p "  Inbound number (0=back): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && return

    echo ""
    python3 << PYEOF
import json

try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)

    inbounds = config.get('inbounds', [])
    if 0 <= idx < len(inbounds):
        ib = inbounds[idx]
        print("  " + "═" * 50)
        print(json.dumps(ib, indent=2, ensure_ascii=False))
        print("  " + "═" * 50)
    else:
        print("  Invalid number")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    pause
}

# ============ EDIT INBOUND ============
edit_inbound() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}EDIT INBOUND${UI_NC}                         ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    list_inbounds_silent

    echo ""
    read -p "  Inbound number (0=back): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && return

    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}EDIT OPTIONS${UI_NC}                         ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╠══════════════════════════════════════════════╣${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   1) Change Port                            ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   2) Change Tag                             ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   3) Add Client                             ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   4) Remove Client                          ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   5) Change Path                            ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   6) Toggle Sniffing                        ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}   0) Back                                    ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}                                              ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""
    read -p "  Select: " EDIT_OPT

    [[ "$EDIT_OPT" == "0" || -z "$EDIT_OPT" ]] && return

    backup_xray_config

    case $EDIT_OPT in
        1)
            echo ""
            read -p "  New Port: " NEW_PORT
            [[ -z "$NEW_PORT" ]] && return
            
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        for i, ib in enumerate(config['inbounds']):
            if i != idx and ib.get('port') == $NEW_PORT:
                print(f"  CONFLICT: Port used by {ib.get('tag')}")
                exit(1)
        old_port = config['inbounds'][idx]['port']
        config['inbounds'][idx]['port'] = $NEW_PORT
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print(f"  ✔ Port changed: {old_port} → $NEW_PORT")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            ;;
        2)
            echo ""
            read -p "  New Tag: " NEW_TAG
            [[ -z "$NEW_TAG" ]] && return
            
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        old_tag = config['inbounds'][idx].get('tag', 'N/A')
        config['inbounds'][idx]['tag'] = "$NEW_TAG"
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print(f"  ✔ Tag changed: {old_tag} → $NEW_TAG")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            ;;
        3)
            echo ""
            local UUID=$(gen_uuid)
            read -p "  Email [user_$(date +%s)]: " EMAIL
            [ -z "$EMAIL" ] && EMAIL="user_$(date +%s)"
            read -p "  UUID [$UUID]: " C_UUID
            [ -n "$C_UUID" ] && UUID="$C_UUID"

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
            print(f"  ✔ Client added: $EMAIL")
        elif proto == 'trojan':
            ib.setdefault('settings', {}).setdefault('clients', []).append({"password": "$UUID", "email": "$EMAIL"})
            print(f"  ✔ Client added: $EMAIL")
        else:
            print(f"  ✘ Protocol {proto} doesn't support clients")
            exit(1)
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            ;;
        4)
            echo ""
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        clients = config['inbounds'][idx].get('settings', {}).get('clients', [])
        if not clients:
            print("  No clients found")
            exit(0)
        print("  Clients:")
        for i, c in enumerate(clients, 1):
            email = c.get('email', c.get('id', 'N/A')[:8])
            print(f"    {i}) {email}")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            echo ""
            read -p "  Client number to remove: " C_NUM
            [[ -z "$C_NUM" ]] && return
            
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
            print(f"  ✔ Removed: {removed.get('email', 'N/A')}")
        else:
            print("  Invalid client number")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            ;;
        5)
            echo ""
            read -p "  New Path: " NEW_PATH
            [[ -z "$NEW_PATH" ]] && return
            
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        stream = config['inbounds'][idx].get('streamSettings', {})
        network = stream.get('network', 'tcp')
        
        key_map = {'ws': 'wsSettings', 'h2': 'httpSettings', 'httpupgrade': 'httpupgradeSettings',
                   'xhttp': 'xhttpSettings', 'grpc': 'grpcSettings'}
        key = key_map.get(network, f"{network}Settings")
        
        if key in stream:
            if 'path' in stream[key]:
                stream[key]['path'] = "$NEW_PATH"
            elif 'serviceName' in stream[key]:
                stream[key]['serviceName'] = "$NEW_PATH"
        else:
            stream[key] = {'path': "$NEW_PATH"}
        
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print(f"  ✔ Path changed to: $NEW_PATH")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            ;;
        6)
            echo ""
            read -p "  Enable Sniffing? (y/n) [y]: " SNIFF
            [ -z "$SNIFF" ] && SNIFF="y"
            local ENABLED="true"
            [[ "$SNIFF" =~ ^[Nn]$ ]] && ENABLED="false"
            
            python3 << PYEOF
import json
try:
    idx = int("$NUM") - 1
    with open("$XRAY_CONFIG", 'r') as f:
        config = json.load(f)
    if 0 <= idx < len(config.get('inbounds', [])):
        config['inbounds'][idx]['sniffing'] = {
            "enabled": $ENABLED,
            "destOverride": ["http", "tls", "quic", "fakedns"]
        }
        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        status = "enabled" if $ENABLED else "disabled"
        print(f"  ✔ Sniffing {status}")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
            ;;
    esac

    echo ""
    simple_confirm "Restart Panel?" "y" && restart_service "panel"
    pause
}

# ============ CLONE INBOUND ============
clone_inbound() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}CLONE INBOUND${UI_NC}                        ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    list_inbounds_silent

    echo ""
    read -p "  Inbound number to clone (0=back): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && return

    echo ""
    read -p "  New Tag: " NEW_TAG
    [[ -z "$NEW_TAG" ]] && { echo -e "  ${UI_RED}✘ Tag required${UI_NC}"; pause; return; }
    
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
                print(f"  ✘ CONFLICT: Port used by {ib.get('tag')}")
                exit(1)

        new_ib = copy.deepcopy(inbounds[idx])
        new_ib['tag'] = "$NEW_TAG"
        new_ib['port'] = $NEW_PORT
        config['inbounds'].append(new_ib)

        with open("$XRAY_CONFIG", 'w') as f:
            json.dump(config, f, indent=2)
        print(f"  ✔ Cloned: {inbounds[idx].get('tag')} → $NEW_TAG")
    else:
        print("  Invalid number")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    simple_confirm "Restart Panel?" "y" && restart_service "panel"
    pause
}

# ============ DELETE INBOUND ============
delete_inbound() {
    clear
    echo ""
    echo -e "${UI_CYAN}╔══════════════════════════════════════════════╗${UI_NC}"
    echo -e "${UI_CYAN}║${UI_NC}         ${UI_YELLOW}DELETE INBOUND${UI_NC}                       ${UI_CYAN}║${UI_NC}"
    echo -e "${UI_CYAN}╚══════════════════════════════════════════════╝${UI_NC}"
    echo ""

    inbound_init_paths
    list_inbounds_silent

    echo ""
    read -p "  Inbound number to delete (0=back): " NUM
    [[ "$NUM" == "0" || -z "$NUM" ]] && return

    echo ""
    if ! simple_confirm "Are you sure?" "n"; then
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
        print(f"  ✔ Deleted: {removed.get('tag')}")
    else:
        print("  Invalid number")
except Exception as e:
    print(f"  Error: {e}")
PYEOF

    echo ""
    simple_confirm "Restart Panel?" "y" && restart_service "panel"
    pause
}