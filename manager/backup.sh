#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Backup Settings
BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10

# Directories (Panel)
DATA_DIR="/var/lib/pasarguard"
ENV_FILE="/opt/pasarguard/.env"

# Directories (Node - Based on your docs)
NODE_ENV_FILE="/opt/pg-node/.env"
NODE_CERTS_DIR="/var/lib/pg-node/certs"

create_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CREATE FULL BACKUP (Panel + Node)      ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    mkdir -p "$BACKUP_DIR"
    
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="pasarguard_full_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    
    mkdir -p "$TEMP_PATH"
    
    echo -e "${YELLOW}Pausing services for data integrity...${NC}"
    
    # 1. Stop Services
    if [ -d "$PANEL_DIR" ]; then
        cd "$PANEL_DIR" && docker compose stop
    fi
    if [ -d "$NODE_DIR" ]; then
        cd "$NODE_DIR" && docker compose stop
    fi
    
    # 2. Backup Panel Data
    echo -e "${BLUE}[1/4] Backing up Panel Data...${NC}"
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$TEMP_PATH/panel_data"
        cp -r "$DATA_DIR"/* "$TEMP_PATH/panel_data/"
        echo -e "${GREEN}✔ Panel Data copied${NC}"
    fi
    
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "$TEMP_PATH/panel.env"
        echo -e "${GREEN}✔ Panel Config (.env) copied${NC}"
    fi
    
    # 3. Backup Node Data (Fix applied here)
    echo -e "${BLUE}[2/4] Backing up Node Data...${NC}"
    if [ -f "$NODE_ENV_FILE" ]; then
        cp "$NODE_ENV_FILE" "$TEMP_PATH/node.env"
        echo -e "${GREEN}✔ Node Config (.env) copied${NC}"
    fi
    
    if [ -d "$NODE_CERTS_DIR" ]; then
        mkdir -p "$TEMP_PATH/node_certs"
        cp -r "$NODE_CERTS_DIR"/* "$TEMP_PATH/node_certs/"
        echo -e "${GREEN}✔ Node Certificates copied${NC}"
    fi
    
    # 4. Restart Services
    echo -e "${BLUE}[3/4] Restarting Services...${NC}"
    if [ -d "$PANEL_DIR" ]; then
        cd "$PANEL_DIR" && docker compose up -d
    fi
    if [ -d "$NODE_DIR" ]; then
        cd "$NODE_DIR" && docker compose up -d
    fi
    
    # 5. Compress
    echo -e "${BLUE}[4/4] Creating Archive...${NC}"
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$TEMP_PATH"
    
    local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    local FILE_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
    
    echo -e "${GREEN}✔ Backup Complete!${NC}"
    echo -e "File: ${CYAN}$FINAL_FILE${NC}"
    echo -e "Size: ${CYAN}$FILE_SIZE${NC}"
    
    # Cleanup
    local BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
    fi
    
    pause
}

restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE BACKUP                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    if [ ! -d "$BACKUP_DIR" ]; then echo -e "${RED}No backups found.${NC}"; pause; return; fi
    
    # List backups
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        local fsize=$(du -h "$file" | cut -f1)
        backups[$i]="$file"
        echo -e "${GREEN}$i)${NC} $fname (${fsize})"
        ((i++))
    done
    
    if [ $i -eq 1 ]; then echo "No backups."; pause; return; fi
    
    echo ""
    read -p "Select backup (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    
    local SELECTED_FILE="${backups[$SEL]}"
    [ -z "$SELECTED_FILE" ] && return
    
    echo -e "${RED}WARNING: Overwriting ALL data! Services will restart.${NC}"
    read -p "Confirm? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && return
    
    # Restore Process
    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    tar -xzf "$SELECTED_FILE" -C "$TEMP_DIR"
    local SOURCE_PATH="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"
    
    # Stop
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose down
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose down
    
    # Restore Panel
    if [ -d "$SOURCE_PATH/panel_data" ]; then
        rm -rf "$DATA_DIR"/*
        cp -r "$SOURCE_PATH/panel_data"/* "$DATA_DIR/"
        echo -e "${GREEN}✔ Panel Data restored${NC}"
    fi
    if [ -f "$SOURCE_PATH/panel.env" ]; then
        cp "$SOURCE_PATH/panel.env" "$ENV_FILE"
        echo -e "${GREEN}✔ Panel Config restored${NC}"
    fi
    
    # Restore Node
    if [ -f "$SOURCE_PATH/node.env" ]; then
        cp "$SOURCE_PATH/node.env" "$NODE_ENV_FILE"
        echo -e "${GREEN}✔ Node Config restored${NC}"
    fi
    if [ -d "$SOURCE_PATH/node_certs" ]; then
        mkdir -p "$NODE_CERTS_DIR"
        cp -r "$SOURCE_PATH/node_certs"/* "$NODE_CERTS_DIR/"
        echo -e "${GREEN}✔ Node Certs restored${NC}"
    fi
    
    # Cleanup & Start
    rm -rf "$TEMP_DIR"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose up -d
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose up -d
    
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      BACKUP LIST                            ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | awk '{print $9, $5}'
    pause
}

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      BACKUP & RESTORE                     ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Create Full Backup (Panel + Node)"
        echo "2) Restore Backup"
        echo "3) List Backups"
        echo "4) Back"
        read -p "Select: " OPT
        case $OPT in
            1) create_backup ;;
            2) restore_backup ;;
            3) list_backups ;;
            4) return ;;
            *) ;;
        esac
    done
}