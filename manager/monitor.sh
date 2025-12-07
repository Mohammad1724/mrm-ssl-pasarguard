#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

CONFIG_FILE="/var/lib/pasarguard/config.json"

get_panel_container() {
    docker ps --format '{{.Names}}' | grep -i "pasarguard" | grep -v "node" | head -1
}

ensure_config_exists() {
    if [ -f "$CONFIG_FILE" ]; then return 0; fi
    echo -e "${YELLOW}Config file missing. Trying to fetch from container...${NC}"
    
    local CONTAINER=$(get_panel_container)
    if [ -n "$CONTAINER" ]; then
        mkdir -p "$(dirname $CONFIG_FILE)"
        docker cp "$CONTAINER:/var/lib/pasarguard/config.json" "$CONFIG_FILE" > /dev/null 2>&1 && return 0
        docker cp "$CONTAINER:/etc/xray/config.json" "$CONFIG_FILE" > /dev/null 2>&1 && return 0
    fi
    echo -e "${RED}Error: config.json not found anywhere.${NC}"
    return 1
}

show_service_status() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      SERVICE STATUS                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -ne "Panel (Pasarguard):  "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "pasarguard"; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi

    echo -ne "Node Service:        "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE "pg-node|pasarguard-node"; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi

    echo -ne "Nginx (Fake Site):   "
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi

    echo -ne "Docker Engine:       "
    if systemctl is-active --quiet docker 2>/dev/null; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi

    echo ""
    pause
}

show_system_resources() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      SYSTEM RESOURCES                       ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}CPU Usage:${NC}"
    local CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo -e "  ${CPU_USAGE}%"
    echo ""

    echo -e "${BLUE}Memory Usage:${NC}"
    local MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    local MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    local MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo -e "  Used: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)"
    echo ""

    echo -e "${BLUE}Disk Usage:${NC}"
    local DISK_INFO=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')
    echo -e "  Used: $DISK_INFO"
    echo ""

    echo -e "${BLUE}System Uptime:${NC}"
    echo -e "  $(uptime -p)"
    echo ""

    pause
}

show_network_info() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      NETWORK INFORMATION                    ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}Server IP Addresses:${NC}"
    local IPV4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
    local IPV6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
    echo -e "  IPv4: ${CYAN}$IPV4${NC}"
    echo -e "  IPv6: ${CYAN}$IPV6${NC}"
    echo ""

    echo -e "${BLUE}Listening Ports (VPN Related):${NC}"
    ss -tlnp 2>/dev/null | grep -E ':443|:80|:8080|:2053|:2083|:2087|:2096' | while read line; do
        local PORT=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
        echo -e "  Port ${GREEN}$PORT${NC}"
    done
    echo ""

    echo -e "${BLUE}Active Connections:${NC}"
    local CONN_COUNT=$(ss -tn state established 2>/dev/null | wc -l)
    echo -e "  Total: ${CYAN}$((CONN_COUNT - 1))${NC} connections"
    echo ""

    pause
}

show_ssl_status() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      SSL CERTIFICATES STATUS                ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    local CERT_DIR="/var/lib/pasarguard/certs"

    if [ ! -d "$CERT_DIR" ]; then
        echo -e "${RED}Certificate directory not found!${NC}"
        pause
        return
    fi

    echo -e "${BLUE}Installed Certificates:${NC}"
    echo ""
    printf "%-30s %-15s %-20s\n" "Domain" "Status" "Days Left"
    echo "----------------------------------------------------------------------"

    for domain_dir in "$CERT_DIR"/*/; do
        [ -d "$domain_dir" ] || continue
        local domain=$(basename "$domain_dir")
        local cert_file="$domain_dir/fullchain.pem"

        if [ -f "$cert_file" ]; then
            local expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
            local now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            local status="${GREEN}Valid${NC}"
            if [ "$days_left" -lt 0 ]; then
                status="${RED}Expired${NC}"
            elif [ "$days_left" -lt 7 ]; then
                status="${RED}Expiring!${NC}"
            elif [ "$days_left" -lt 30 ]; then
                status="${YELLOW}Warning${NC}"
            fi

            printf "%-30s " "$domain"
            echo -ne "$status"
            printf "%*s" $((15 - 5)) ""
            echo "$days_left days"
        else
            printf "%-30s ${RED}%-15s${NC} %-20s\n" "$domain" "No Cert" "-"
        fi
    done

    echo ""
    pause
}

show_panel_stats() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      PANEL STATISTICS                       ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    echo -e "${BLUE}Database:${NC}"
    echo -e "  ${YELLOW}Using external database (PostgreSQL/TimescaleDB)${NC}"
    echo -e "  ${YELLOW}Check panel dashboard for user stats.${NC}"
    echo ""

    ensure_config_exists > /dev/null 2>&1
    echo -e "${BLUE}Inbound Count:${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        local COUNT=$(python3 -c "import json; print(len(json.load(open('$CONFIG_FILE')).get('inbounds',[])))" 2>/dev/null || echo "?")
        echo -e "  ${CYAN}$COUNT${NC} inbounds configured"
    else
        echo -e "  ${RED}Config file not found${NC}"
    fi
    echo ""

    echo -e "${BLUE}Last Backup:${NC}"
    local LAST=$(ls -1t /root/mrm-backups/*.tar.gz 2>/dev/null | head -1)
    if [ -n "$LAST" ]; then
        echo -e "  ${CYAN}$(basename $LAST)${NC}"
    else
        echo -e "  ${YELLOW}No backups${NC}"
    fi
    echo ""

    pause
}

live_monitor() {
    while true; do
        clear
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${YELLOW}      LIVE MONITOR (Press Ctrl+C to exit)   ${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo ""

        echo -e "${BLUE}Current Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        echo -ne "Panel: "
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "pasarguard" && echo -ne "${GREEN}●${NC} " || echo -ne "${RED}●${NC} "

        echo -ne "Node: "
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE "pg-node" && echo -ne "${GREEN}●${NC} " || echo -ne "${RED}●${NC} "

        echo -ne "Nginx: "
        systemctl is-active --quiet nginx && echo -e "${GREEN}●${NC}" || echo -e "${RED}●${NC}"
        echo ""

        local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
        local MEM=$(free | awk '/^Mem:/{printf "%.1f", $3/$2*100}')
        local DISK=$(df / | awk 'NR==2{print $5}')

        echo -e "CPU: ${CYAN}${CPU}%${NC}  |  RAM: ${CYAN}${MEM}%${NC}  |  Disk: ${CYAN}${DISK}${NC}"
        echo ""

        local CONNS=$(ss -tn state established 2>/dev/null | wc -l)
        echo -e "Active Connections: ${CYAN}$((CONNS - 1))${NC}"
        echo ""

        echo -e "${YELLOW}Refreshing every 3 seconds...${NC}"
        sleep 3
    done
}

live_log_watcher() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      LIVE TRAFFIC WATCHER (Sniffer)         ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    if ! ensure_config_exists; then pause; return; fi

    echo "1) Watch in Terminal"
    echo "2) Send to Telegram"
    echo "3) Back"
    read -p "Select: " L_OPT

    if [ "$L_OPT" == "3" ] || [ "$L_OPT" != "1" ] && [ "$L_OPT" != "2" ]; then return; fi

    echo ""
    echo -e "${YELLOW}To see destinations, we set log level to INFO.${NC}"
    echo -e "${RED}WARNING: This will increase log size. Don't leave it on for long!${NC}"
    read -p "Enable INFO logs? (y/n): " EN_LOG

    if [ "$EN_LOG" != "y" ]; then return; fi

    # Backup config
    cp "$CONFIG_FILE" /tmp/config_backup_log.json
    sed -i 's/"loglevel": "warning"/"loglevel": "info"/' "$CONFIG_FILE"
    restart_service "panel"
    echo -e "${GREEN}✔ Log level set to INFO.${NC}"

    # Restore function
    restore_log_level() {
        echo -e "\n${YELLOW}Restoring Log Level to WARNING...${NC}"
        if [ -f "/tmp/config_backup_log.json" ]; then
            cp /tmp/config_backup_log.json "$CONFIG_FILE"
            rm -f /tmp/config_backup_log.json
        else
            sed -i 's/"loglevel": "info"/"loglevel": "warning"/' "$CONFIG_FILE"
        fi
        restart_service "panel"
        echo -e "${GREEN}✔ Log level restored.${NC}"
    }

    # Set trap for multiple signals
    trap restore_log_level SIGINT SIGTERM EXIT

    local CONTAINER=$(get_panel_container)
    if [ -z "$CONTAINER" ]; then
        echo -e "${RED}Panel container not found!${NC}"
        restore_log_level
        pause
        return
    fi

    echo -e "${YELLOW}Watching traffic... (Press Ctrl+C to stop)${NC}"
    echo ""

    if [ "$L_OPT" == "1" ]; then
        docker logs -f --tail 10 "$CONTAINER" 2>&1 | grep --line-buffered -E "accepted|common/log"
    elif [ "$L_OPT" == "2" ]; then
        read -p "Bot Token: " TG_TOKEN
        read -p "Chat ID: " TG_CHAT
        
        docker logs -f --tail 0 "$CONTAINER" 2>&1 | grep --line-buffered "accepted" | while read line; do
            DOMAIN=$(echo "$line" | grep -oP 'tcp:\K[^:]+' | head -1)
            if [ -n "$DOMAIN" ]; then
                curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
                    -d chat_id="$TG_CHAT" \
                    -d text="🌐 Visit: $DOMAIN" > /dev/null
            fi
        done
    fi

    # Remove trap before exiting normally
    trap - SIGINT SIGTERM EXIT
    restore_log_level
    pause
}

monitor_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      MONITORING & STATUS                  ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Service Status"
        echo "2) System Resources (CPU/RAM/Disk)"
        echo "3) Network Information"
        echo "4) SSL Certificates Status"
        echo "5) Panel Statistics"
        echo "6) Live Monitor (Dashboard)"
        echo "7) Live Traffic Watcher (Sniffer)"
        echo "8) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) show_service_status ;;
            2) show_system_resources ;;
            3) show_network_info ;;
            4) show_ssl_status ;;
            5) show_panel_stats ;;
            6) live_monitor ;;
            7) live_log_watcher ;;
            8) return ;;
            *) ;;
        esac
    done
}