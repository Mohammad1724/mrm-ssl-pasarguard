#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

show_service_status() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      SERVICE STATUS                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    # Panel Status
    echo -ne "Panel (Pasarguard):  "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pasarguard"; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi
    
    # Node Status
    echo -ne "Node Service:        "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pg-node\|pasarguard-node"; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi
    
    # Nginx Status
    echo -ne "Nginx (Fake Site):   "
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi
    
    # Docker Status
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
    
    # CPU Usage
    echo -e "${BLUE}CPU Usage:${NC}"
    local CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local CPU_BAR=$(printf "%-${CPU_USAGE%%.*}s" | tr ' ' '█')
    echo -e "  ${CPU_USAGE}% ${GREEN}${CPU_BAR}${NC}"
    echo ""
    
    # RAM Usage
    echo -e "${BLUE}Memory Usage:${NC}"
    local MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    local MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    local MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo -e "  Used: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)"
    local MEM_BAR=$(printf "%-$((MEM_PERCENT / 2))s" | tr ' ' '█')
    echo -e "  ${GREEN}${MEM_BAR}${NC}"
    echo ""
    
    # Disk Usage
    echo -e "${BLUE}Disk Usage:${NC}"
    local DISK_INFO=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')
    local DISK_PERCENT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
    echo -e "  Used: $DISK_INFO"
    local DISK_BAR=$(printf "%-$((DISK_PERCENT / 2))s" | tr ' ' '█')
    if [ "$DISK_PERCENT" -gt 80 ]; then
        echo -e "  ${RED}${DISK_BAR}${NC}"
    else
        echo -e "  ${GREEN}${DISK_BAR}${NC}"
    fi
    echo ""
    
    # Uptime
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
    
    # Server IP
    echo -e "${BLUE}Server IP Addresses:${NC}"
    local IPV4=$(curl -s -4 ifconfig.me 2>/dev/null || echo "N/A")
    local IPV6=$(curl -s -6 ifconfig.me 2>/dev/null || echo "N/A")
    echo -e "  IPv4: ${CYAN}$IPV4${NC}"
    echo -e "  IPv6: ${CYAN}$IPV6${NC}"
    echo ""
    
    # Open Ports
    echo -e "${BLUE}Listening Ports (VPN Related):${NC}"
    ss -tlnp 2>/dev/null | grep -E ':443|:80|:8080|:2053|:2083|:2087|:2096' | while read line; do
        local PORT=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
        local PROC=$(echo "$line" | grep -oP '"\K[^"]+' | head -1)
        [ -z "$PROC" ] && PROC="unknown"
        echo -e "  Port ${GREEN}$PORT${NC} - $PROC"
    done
    echo ""
    
    # Active Connections
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
    printf "%-30s %-15s %-20s\n" "Domain" "Status" "Expires"
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
            echo -e "${days_left} days"
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

    # Check for SQLite (may not exist if using PostgreSQL/TimescaleDB)
    local DB_FILE="/var/lib/pasarguard/db.sqlite3"

    echo -e "${BLUE}User Statistics:${NC}"
    if [ -f "$DB_FILE" ]; then
        local TOTAL=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "?")
        local ACTIVE=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE status='active';" 2>/dev/null || echo "?")
        echo -e "  Total: ${CYAN}$TOTAL${NC}  |  Active: ${GREEN}$ACTIVE${NC}"
    else
        echo -e "  ${YELLOW}Using external database (PostgreSQL/TimescaleDB)${NC}"
        echo -e "  ${YELLOW}Check panel dashboard for user stats.${NC}"
    fi
    echo ""

    # Inbounds
    echo -e "${BLUE}Inbound Count:${NC}"
    local CONFIG="/var/lib/pasarguard/config.json"
    if [ -f "$CONFIG" ]; then
        local COUNT=$(python3 -c "import json; print(len(json.load(open('$CONFIG')).get('inbounds',[])))" 2>/dev/null || echo "?")
        echo -e "  ${CYAN}$COUNT${NC} inbounds configured"
    fi
    echo ""

    # Last Backup
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
        echo -e "${YELLOW}      LIVE MONITOR (Press Q to exit)        ${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo ""
        
        # Time
        echo -e "${BLUE}Current Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        # Quick Status
        echo -ne "Panel: "
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pasarguard" && echo -ne "${GREEN}●${NC} " || echo -ne "${RED}●${NC} "
        
        echo -ne "Node: "
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pg-node" && echo -ne "${GREEN}●${NC} " || echo -ne "${RED}●${NC} "
        
        echo -ne "Nginx: "
        systemctl is-active --quiet nginx && echo -e "${GREEN}●${NC}" || echo -e "${RED}●${NC}"
        echo ""
        
        # Resources
        local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
        local MEM=$(free | awk '/^Mem:/{printf "%.1f", $3/$2*100}')
        local DISK=$(df / | awk 'NR==2{print $5}')
        
        echo -e "CPU: ${CYAN}${CPU}%${NC}  |  RAM: ${CYAN}${MEM}%${NC}  |  Disk: ${CYAN}${DISK}${NC}"
        echo ""
        
        # Connections
        local CONNS=$(ss -tn state established 2>/dev/null | wc -l)
        echo -e "Active Connections: ${CYAN}$((CONNS - 1))${NC}"
        echo ""
        
        echo -e "${YELLOW}Refreshing every 3 seconds... Press Ctrl+C to exit${NC}"
        
        sleep 3
    done
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
        echo "6) Live Monitor"
        echo "7) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) show_service_status ;;
            2) show_system_resources ;;
            3) show_network_info ;;
            4) show_ssl_status ;;
            5) show_panel_stats ;;
            6) live_monitor ;;
            7) return ;;
            *) ;;
        esac
    done
}