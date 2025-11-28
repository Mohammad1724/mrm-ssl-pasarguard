#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Token file location
TOKEN_FILE="/var/lib/pasarguard/node_token.conf"

generate_node_token() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      GENERATE NODE CONNECTION TOKEN         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo "This will create a token that you can use on node servers"
    echo "to automatically connect them to this panel."
    echo ""
    
    # Get panel info
    read -p "Panel Domain or IP: " PANEL_HOST
    [ -z "$PANEL_HOST" ] && { echo -e "${RED}Cancelled.${NC}"; pause; return; }
    
    read -p "Panel Port [443]: " PANEL_PORT
    [ -z "$PANEL_PORT" ] && PANEL_PORT="443"
    
    read -p "Use SSL? (y/n) [y]: " USE_SSL
    [ -z "$USE_SSL" ] && USE_SSL="y"
    
    local PROTOCOL="wss"
    [ "$USE_SSL" != "y" ] && PROTOCOL="ws"
    
    # Generate random token
    local TOKEN=$(openssl rand -hex 32)
    local TIMESTAMP=$(date +%s)
    
    # Create token data
    local TOKEN_DATA="${PROTOCOL}|${PANEL_HOST}|${PANEL_PORT}|${TOKEN}|${TIMESTAMP}"
    local ENCODED_TOKEN=$(echo "$TOKEN_DATA" | base64 -w 0)
    
    # Save token info
    mkdir -p "$(dirname $TOKEN_FILE)"
    cat > "$TOKEN_FILE" <<EOF
# Node Connection Token - Generated $(date)
TOKEN=$TOKEN
PANEL_HOST=$PANEL_HOST
PANEL_PORT=$PANEL_PORT
PROTOCOL=$PROTOCOL
GENERATED=$TIMESTAMP
EOF
    chmod 600 "$TOKEN_FILE"
    
    echo ""
    echo -e "${GREEN}✔ Token Generated Successfully!${NC}"
    echo ""
    echo -e "${YELLOW}=== CONNECTION TOKEN ===${NC}"
    echo ""
    echo -e "${CYAN}$ENCODED_TOKEN${NC}"
    echo ""
    echo -e "${YELLOW}=== INSTRUCTIONS ===${NC}"
    echo "1. Copy the token above"
    echo "2. On your NODE server, run:"
    echo ""
    echo -e "${GREEN}   bash <(curl -s YOUR_REPO_URL/node-connect.sh)${NC}"
    echo ""
    echo "3. Paste the token when asked"
    echo ""
    
    # Copy to clipboard if possible
    if command -v xclip &> /dev/null; then
        echo "$ENCODED_TOKEN" | xclip -selection clipboard
        echo -e "${GREEN}(Token copied to clipboard)${NC}"
    fi
    
    pause
}

show_current_token() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CURRENT NODE TOKEN                     ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    if [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${RED}No token generated yet!${NC}"
        echo "Use 'Generate Token' option first."
        pause
        return
    fi
    
    source "$TOKEN_FILE"
    
    echo -e "Panel Host:     ${CYAN}$PANEL_HOST${NC}"
    echo -e "Panel Port:     ${CYAN}$PANEL_PORT${NC}"
    echo -e "Protocol:       ${CYAN}$PROTOCOL${NC}"
    echo -e "Generated:      ${CYAN}$(date -d @$GENERATED 2>/dev/null || echo $GENERATED)${NC}"
    echo ""
    
    # Regenerate encoded token for display
    local TOKEN_DATA="${PROTOCOL}|${PANEL_HOST}|${PANEL_PORT}|${TOKEN}|${GENERATED}"
    local ENCODED_TOKEN=$(echo "$TOKEN_DATA" | base64 -w 0)
    
    echo -e "${YELLOW}Token:${NC}"
    echo -e "${CYAN}$ENCODED_TOKEN${NC}"
    echo ""
    
    pause
}

revoke_token() {
    clear
    echo -e "${RED}=== REVOKE NODE TOKEN ===${NC}"
    echo ""
    
    if [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${YELLOW}No token exists.${NC}"
        pause
        return
    fi
    
    read -p "Are you sure you want to revoke the current token? (yes/no): " CONFIRM
    
    if [ "$CONFIRM" == "yes" ]; then
        rm -f "$TOKEN_FILE"
        echo -e "${GREEN}✔ Token revoked successfully.${NC}"
        echo "Connected nodes may lose connection."
    else
        echo "Cancelled."
    fi
    
    pause
}

list_connected_nodes() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CONNECTED NODES                        ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    # Check panel database for nodes
    local DB_FILE="/var/lib/pasarguard/db.sqlite3"
    
    if [ ! -f "$DB_FILE" ]; then
        echo -e "${RED}Database not found!${NC}"
        pause
        return
    fi
    
    echo -e "${BLUE}Registered Nodes:${NC}"
    echo ""
    printf "%-5s %-20s %-15s %-10s\n" "ID" "Name" "Address" "Status"
    echo "--------------------------------------------------------------"
    
    # Try to query nodes table
    sqlite3 "$DB_FILE" "SELECT id, name, address, status FROM nodes;" 2>/dev/null | while IFS='|' read -r id name address status; do
        local status_color="${RED}"
        [ "$status" == "connected" ] || [ "$status" == "active" ] && status_color="${GREEN}"
        printf "%-5s %-20s %-15s " "$id" "$name" "$address"
        echo -e "${status_color}${status}${NC}"
    done
    
    # If no nodes found
    local NODE_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
    if [ "$NODE_COUNT" == "0" ] || [ -z "$NODE_COUNT" ]; then
        echo -e "${YELLOW}No nodes registered yet.${NC}"
    fi
    
    echo ""
    pause
}

quick_node_setup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      QUICK NODE SETUP (On This Server)      ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo "This will install and configure a node on THIS server."
    echo "Use this if you want to run panel and node on same machine."
    echo ""
    
    read -p "Continue? (y/n): " CONT
    [ "$CONT" != "y" ] && return
    
    # Check if node already exists
    if [ -d "$NODE_DIR" ]; then
        echo -e "${YELLOW}Node directory already exists at $NODE_DIR${NC}"
        read -p "Reconfigure? (y/n): " RECONF
        [ "$RECONF" != "y" ] && { pause; return; }
    fi
    
    echo ""
    echo -e "${BLUE}[1/4] Creating node directory...${NC}"
    mkdir -p "$NODE_DIR"
    mkdir -p "$NODE_DEF_CERTS"
    
    echo -e "${BLUE}[2/4] Getting panel connection info...${NC}"
    
    read -p "Panel Address (localhost or domain): " P_ADDR
    [ -z "$P_ADDR" ] && P_ADDR="localhost"
    
    read -p "Panel Port [443]: " P_PORT
    [ -z "$P_PORT" ] && P_PORT="443"
    
    echo -e "${BLUE}[3/4] Creating node configuration...${NC}"
    
    cat > "$NODE_ENV" <<EOF
# Node Configuration - Generated $(date)
SERVICE_PROTOCOL=wss
SERVICE_HOST=$P_ADDR
SERVICE_PORT=$P_PORT
INSECURE=true
EOF
    
    echo -e "${BLUE}[4/4] Setting up Docker Compose...${NC}"
    
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  pg-node:
    image: pasarguard/node:latest
    container_name: pg-node
    restart: always
    network_mode: host
    env_file:
      - .env
    volumes:
      - $NODE_DEF_CERTS:/var/lib/pg-node/certs:ro
EOF
    
    echo ""
    echo -e "${GREEN}✔ Node configuration created!${NC}"
    echo ""
    echo -e "${YELLOW}To start the node, run:${NC}"
    echo -e "${CYAN}cd $NODE_DIR && docker compose up -d${NC}"
    echo ""
    
    read -p "Start node now? (y/n): " START_NOW
    if [ "$START_NOW" == "y" ]; then
        cd "$NODE_DIR"
        docker compose pull
        docker compose up -d
        echo -e "${GREEN}✔ Node started!${NC}"
    fi
    
    pause
}

generate_node_install_script() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      GENERATE NODE INSTALL COMMAND          ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Panel Domain/IP: " PANEL_HOST
    [ -z "$PANEL_HOST" ] && { echo "Cancelled."; pause; return; }
    
    read -p "Panel Port [443]: " PANEL_PORT
    [ -z "$PANEL_PORT" ] && PANEL_PORT="443"
    
    read -p "Use SSL? (y/n) [y]: " USE_SSL
    [ -z "$USE_SSL" ] && USE_SSL="y"
    
    local PROTOCOL="wss"
    local INSECURE="false"
    if [ "$USE_SSL" != "y" ]; then
        PROTOCOL="ws"
        INSECURE="true"
    fi
    
    echo ""
    echo -e "${GREEN}✔ Run this command on your NODE server:${NC}"
    echo ""
    echo -e "${CYAN}bash <(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main/node-install.sh) $PROTOCOL $PANEL_HOST $PANEL_PORT $INSECURE${NC}"
    echo ""
    echo -e "${YELLOW}Or manually create /opt/pg-node/.env with:${NC}"
    echo ""
    echo "SERVICE_PROTOCOL=$PROTOCOL"
    echo "SERVICE_HOST=$PANEL_HOST"
    echo "SERVICE_PORT=$PANEL_PORT"
    [ "$INSECURE" == "true" ] && echo "INSECURE=true"
    echo ""
    
    pause
}

nodelink_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      NODE CONNECTION MANAGER              ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Generate Node Token"
        echo "2) Show Current Token"
        echo "3) Revoke Token"
        echo "4) List Connected Nodes"
        echo "5) Quick Node Setup (This Server)"
        echo "6) Generate Node Install Command"
        echo "7) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) generate_node_token ;;
            2) show_current_token ;;
            3) revoke_token ;;
            4) list_connected_nodes ;;
            5) quick_node_setup ;;
            6) generate_node_install_script ;;
            7) return ;;
            *) ;;
        esac
    done
}