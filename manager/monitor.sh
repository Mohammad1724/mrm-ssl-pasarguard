#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
CONFIG_FILE="/var/lib/pasarguard/config.json"

ensure_config_exists() {
    if [ -f "$CONFIG_FILE" ]; then return 0; fi
    echo -e "${YELLOW}Config file missing. Trying to fetch from container...${NC}"
    
    # FIXED: Better container detection
    local CONTAINER=$(docker ps --format '{{.Names}}' | grep -i "pasarguard" | head -1)
    if [ -n "$CONTAINER" ]; then
        mkdir -p "$(dirname $CONFIG_FILE)"
        docker cp $CONTAINER:/var/lib/pasarguard/config.json "$CONFIG_FILE" > /dev/null 2>&1
        if [ $? -eq 0 ]; then return 0; fi
        docker cp $CONTAINER:/etc/xray/config.json "$CONFIG_FILE" > /dev/null 2>&1
        if [ $? -eq 0 ]; then return 0; fi
    fi
    echo -e "${RED}Error: config.json not found anywhere.${NC}"
    return 1
}

# (Other display functions remain the same as original)
show_service_status() {
    clear
    echo -e "${CYAN}=== SERVICE STATUS ===${NC}"
    echo -ne "Panel:  "
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pasarguard" && echo -e "${GREEN}Running${NC}" || echo -e "${RED}Stopped${NC}"
    echo -ne "Nginx:  "
    systemctl is-active --quiet nginx 2>/dev/null && echo -e "${GREEN}Running${NC}" || echo -e "${RED}Stopped${NC}"
    pause
}
# ... (Keep show_system_resources, show_network_info, show_ssl_status, show_panel_stats, live_monitor same as before) ...

# FIXED: Safer Live Log Watcher
live_log_watcher() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      LIVE TRAFFIC WATCHER (Sniffer)         ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    if ! ensure_config_exists; then pause; return; fi

    echo "1) Watch in Terminal"
    echo "2) Back"
    read -p "Select: " L_OPT
    if [ "$L_OPT" != "1" ]; then return; fi

    echo -e "${YELLOW}To see destinations, we set log level to INFO.${NC}"
    read -p "Enable INFO logs? (y/n): " EN_LOG

    if [ "$EN_LOG" == "y" ]; then
        cp "$CONFIG_FILE" /tmp/config_backup.json
        sed -i 's/"loglevel": "warning"/"loglevel": "info"/' "$CONFIG_FILE"
        restart_service "panel"
        echo -e "${GREEN}✔ Log level set to INFO.${NC}"
        echo -e "${YELLOW}Waiting for traffic... (Press Ctrl+C to stop)${NC}"

        # TRAP: Ensure config is restored even if script crashes
        restore_log() {
            echo -e "\n${YELLOW}Restoring Log Level...${NC}"
            sed -i 's/"loglevel": "info"/"loglevel": "warning"/' "$CONFIG_FILE"
            restart_service "panel"
            exit
        }
        trap restore_log SIGINT SIGTERM

        local CONTAINER=$(docker ps --format '{{.Names}}' | grep -i "pasarguard" | head -1)
        docker logs -f --tail 10 "$CONTAINER" | grep --line-buffered "common/log: access" | grep --line-buffered "accepted"
        
        # If loop breaks naturally
        restore_log
    fi
}

monitor_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      MONITORING & STATUS                  ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Service Status"
        echo "2) Live Traffic Watcher"
        echo "3) Back"
        read -p "Select: " OPT
        case $OPT in
            1) show_service_status ;;
            2) live_log_watcher ;;
            3) return ;;
            *) ;;
        esac
    done
}