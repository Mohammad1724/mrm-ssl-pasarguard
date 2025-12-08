#!/bin/bash

# ============================================
# INTERACTIVE UI LIBRARY (FIXED STATUS)
# ============================================

# Colors
UI_RED='\033[0;31m'
UI_GREEN='\033[0;32m'
UI_YELLOW='\033[1;33m'
UI_BLUE='\033[0;34m'
UI_CYAN='\033[0;36m'
UI_WHITE='\033[1;37m'
UI_NC='\033[0m'
UI_BOLD='\033[1m'
UI_DIM='\033[2m'

# Box drawing characters
UI_TL="╔"
UI_TR="╗"
UI_BL="╚"
UI_BR="╝"
UI_H="═"
UI_V="║"

# ============================================
# HEADER & BOX FUNCTIONS
# ============================================

ui_header() {
    local TITLE=$1
    local WIDTH=${2:-50}
    
    clear
    
    # Top border
    echo -ne "${UI_CYAN}${UI_TL}"
    for ((i=0; i<WIDTH-2; i++)); do echo -ne "${UI_H}"; done
    echo -e "${UI_TR}${UI_NC}"
    
    # Title
    local PADDING=$(( (WIDTH - 2 - ${#TITLE}) / 2 ))
    echo -ne "${UI_CYAN}${UI_V}${UI_NC}"
    for ((i=0; i<PADDING; i++)); do echo -ne " "; done
    echo -ne "${UI_YELLOW}${UI_BOLD}${TITLE}${UI_NC}"
    for ((i=0; i<WIDTH-2-PADDING-${#TITLE}; i++)); do echo -ne " "; done
    echo -e "${UI_CYAN}${UI_V}${UI_NC}"
    
    # Bottom border
    echo -ne "${UI_CYAN}${UI_BL}"
    for ((i=0; i<WIDTH-2; i++)); do echo -ne "${UI_H}"; done
    echo -e "${UI_BR}${UI_NC}"
    echo ""
}

ui_status_bar() {
    # Default Status (Red)
    local PANEL_STATUS="${UI_RED}●${UI_NC}"
    local NODE_STATUS="${UI_RED}●${UI_NC}"
    local NGINX_STATUS="${UI_RED}●${UI_NC}"
    
    # Check Panel (Pasarguard or Marzban)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE "pasarguard|marzban"; then
        PANEL_STATUS="${UI_GREEN}●${UI_NC}"
    fi

    # Check Node (More flexible check: looks for 'node' in any container name)
    # Also checks if it's NOT the exporter to avoid false positives if possible
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "node"; then
        NODE_STATUS="${UI_GREEN}●${UI_NC}"
    fi
    
    # Check Nginx (Service OR Container)
    if systemctl is-active --quiet nginx 2>/dev/null; then
        NGINX_STATUS="${UI_GREEN}●${UI_NC}"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "nginx"; then
        NGINX_STATUS="${UI_GREEN}●${UI_NC}"
    fi
    
    echo -e "${UI_DIM}┌──────────────────────────────────────────────┐${UI_NC}"
    echo -e "${UI_DIM}│${UI_NC} Panel: $PANEL_STATUS  Node: $NODE_STATUS  Nginx: $NGINX_STATUS          ${UI_DIM}│${UI_NC}"
    echo -e "${UI_DIM}└──────────────────────────────────────────────┘${UI_NC}"
    echo ""
}

# ============================================
# PROGRESS BAR
# ============================================

ui_progress() {
    local CURRENT=$1
    local TOTAL=$2
    local WIDTH=${3:-40}
    local LABEL=${4:-"Progress"}
    
    local PERCENT=$((CURRENT * 100 / TOTAL))
    local FILLED=$((CURRENT * WIDTH / TOTAL))
    local EMPTY=$((WIDTH - FILLED))
    
    echo -ne "\r${LABEL}: ["
    echo -ne "${UI_GREEN}"
    for ((i=0; i<FILLED; i++)); do echo -ne "█"; done
    echo -ne "${UI_DIM}"
    for ((i=0; i<EMPTY; i++)); do echo -ne "░"; done
    echo -ne "${UI_NC}] ${PERCENT}%"
}

ui_progress_done() {
    echo ""
}

# ============================================
# SPINNER
# ============================================

ui_spinner_start() {
    local MESSAGE=${1:-"Loading..."}
    (
        local SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            echo -ne "\r${UI_CYAN}${SPIN:$i:1}${UI_NC} $MESSAGE"
            i=$(( (i + 1) % 10 ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

ui_spinner_stop() {
    if [ -n "$SPINNER_PID" ]; then
        kill $SPINNER_PID 2>/dev/null
        wait $SPINNER_PID 2>/dev/null
        echo -ne "\r\033[K"
    fi
}

# ============================================
# INTERACTIVE MENU
# ============================================

ui_menu() {
    local TITLE=$1
    shift
    local OPTIONS=("$@")
    local SELECTED=0
    local COUNT=${#OPTIONS[@]}
    
    tput civis
    
    while true; do
        clear
        ui_header "$TITLE"
        ui_status_bar
        
        for i in "${!OPTIONS[@]}"; do
            if [ $i -eq $SELECTED ]; then
                echo -e "  ${UI_CYAN}▶${UI_NC} ${UI_WHITE}${UI_BOLD}${OPTIONS[$i]}${UI_NC}"
            else
                echo -e "    ${UI_DIM}${OPTIONS[$i]}${UI_NC}"
            fi
        done
        
        echo ""
        echo -e "${UI_DIM}Use ↑↓ arrows to navigate, Enter to select, q to quit${UI_NC}"
        
        read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 key
                case "$key" in
                    '[A') ((SELECTED--)); [ $SELECTED -lt 0 ] && SELECTED=$((COUNT - 1)) ;;
                    '[B') ((SELECTED++)); [ $SELECTED -ge $COUNT ] && SELECTED=0 ;;
                esac
                ;;
            '') tput cnorm; echo $SELECTED; return $SELECTED ;;
            'q'|'Q') tput cnorm; echo -1; return 255 ;;
        esac
    done
}

ui_confirm() {
    local MESSAGE=$1
    local DEFAULT=${2:-n}
    local PROMPT="[y/N]"
    [ "$DEFAULT" == "y" ] && PROMPT="[Y/n]"
    echo -ne "${UI_YELLOW}? ${UI_NC}${MESSAGE} ${UI_DIM}${PROMPT}${UI_NC} "
    read -r REPLY
    [ -z "$REPLY" ] && REPLY=$DEFAULT
    case "$REPLY" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

ui_input() {
    local LABEL=$1
    local DEFAULT=$2
    local RESULT=""
    if [ -n "$DEFAULT" ]; then
        echo -ne "${UI_CYAN}? ${UI_NC}${LABEL} ${UI_DIM}[$DEFAULT]${UI_NC}: "
    else
        echo -ne "${UI_CYAN}? ${UI_NC}${LABEL}: "
    fi
    read -r RESULT
    [ -z "$RESULT" ] && RESULT="$DEFAULT"
    echo "$RESULT"
}

ui_success() { echo -e "${UI_GREEN}✔ ${UI_NC}$1"; }
ui_error() { echo -e "${UI_RED}✘ ${UI_NC}$1"; }
ui_warning() { echo -e "${UI_YELLOW}⚠ ${UI_NC}$1"; }
ui_info() { echo -e "${UI_BLUE}ℹ ${UI_NC}$1"; }