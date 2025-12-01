#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10
DATA_DIR="/var/lib/pasarguard"
ENV_FILE="/opt/pasarguard/.env"
NODE_ENV_FILE="/opt/pg-node/.env"
NODE_CERTS_DIR="/var/lib/pg-node/certs"

create_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CREATE FULL BACKUP                     ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    mkdir -p "$BACKUP_DIR"

    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"

    mkdir -p "$TEMP_PATH"

    echo -e "${YELLOW}Stopping services (few seconds)...${NC}"

    # Stop Services
    if [ -d "$PANEL_DIR" ]; then
        cd "$PANEL_DIR" && docker compose stop > /dev/null 2>&1
    fi
    if [ -d "$NODE_DIR" ]; then
        cd "$NODE_DIR" && docker compose stop > /dev/null 2>&1
    fi

    # Backup Panel Data
    echo -e "${BLUE}[1/4] Panel Data...${NC}"
    if [ -d "$DATA_DIR" ]; then
        cp -r "$DATA_DIR" "$TEMP_PATH/panel_data" 2>/dev/null
        echo -e "${GREEN}✔ Done${NC}"
    else
        echo -e "${YELLOW}! Not found${NC}"
    fi

    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "$TEMP_PATH/panel.env"
    fi

    # Backup Node Data
    echo -e "${BLUE}[2/4] Node Data...${NC}"
    if [ -f "$NODE_ENV_FILE" ]; then
        cp "$NODE_ENV_FILE" "$TEMP_PATH/node.env"
        echo -e "${GREEN}✔ Done${NC}"
    fi
    if [ -d "$NODE_CERTS_DIR" ]; then
        cp -r "$NODE_CERTS_DIR" "$TEMP_PATH/node_certs" 2>/dev/null
    fi

    # Restart Services
    echo -e "${BLUE}[3/4] Restarting services...${NC}"
    if [ -d "$PANEL_DIR" ]; then
        cd "$PANEL_DIR" && docker compose up -d > /dev/null 2>&1
    fi
    if [ -d "$NODE_DIR" ]; then
        cd "$NODE_DIR" && docker compose up -d > /dev/null 2>&1
    fi
    echo -e "${GREEN}✔ Services running${NC}"

    # Compress
    echo -e "${BLUE}[4/4] Compressing...${NC}"
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME" 2>/dev/null
    rm -rf "$TEMP_PATH"

    local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    
    if [ -f "$FINAL_FILE" ]; then
        local FILE_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
        echo ""
        echo -e "${GREEN}✔ Backup Complete!${NC}"
        echo -e "File: ${CYAN}$FINAL_FILE${NC}"
        echo -e "Size: ${CYAN}$FILE_SIZE${NC}"
    else
        echo -e "${RED}✘ Backup failed!${NC}"
    fi

    # Cleanup old backups
    local COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$COUNT" -gt "$MAX_BACKUPS" ]; then
        ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
        echo -e "${YELLOW}Old backups cleaned (keeping $MAX_BACKUPS)${NC}"
    fi

    pause
}

restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE BACKUP                         ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${RED}No backups found.${NC}"
        pause
        return
    fi

    echo ""
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        local fsize=$(du -h "$file" | cut -f1)
        local fdate=$(stat -c %y "$file" 2>/dev/null | cut -d'.' -f1)
        backups[$i]="$file"
        echo -e "${GREEN}$i)${NC} $fname ($fsize) - $fdate"
        ((i++))
    done

    echo ""
    read -p "Select backup (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    [ -z "${backups[$SEL]}" ] && { echo "Invalid."; pause; return; }

    local SELECTED="${backups[$SEL]}"

    echo ""
    echo -e "${RED}⚠ WARNING: This will OVERWRITE all current data!${NC}"
    read -p "Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo "Cancelled."; pause; return; }

    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"

    echo -e "${BLUE}Extracting...${NC}"
    if ! tar -xzf "$SELECTED" -C "$TEMP_DIR" 2>/dev/null; then
        echo -e "${RED}Failed to extract backup!${NC}"
        rm -rf "$TEMP_DIR"
        pause
        return
    fi

    local SOURCE_PATH="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    echo -e "${BLUE}Stopping services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose down > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose down > /dev/null 2>&1

    # Restore Panel
    if [ -d "$SOURCE_PATH/panel_data" ]; then
        rm -rf "$DATA_DIR"
        cp -r "$SOURCE_PATH/panel_data" "$DATA_DIR"
        echo -e "${GREEN}✔ Panel data restored${NC}"
    fi
    if [ -f "$SOURCE_PATH/panel.env" ]; then
        cp "$SOURCE_PATH/panel.env" "$ENV_FILE"
        echo -e "${GREEN}✔ Panel config restored${NC}"
    fi

    # Restore Node
    if [ -f "$SOURCE_PATH/node.env" ]; then
        mkdir -p "$(dirname $NODE_ENV_FILE)"
        cp "$SOURCE_PATH/node.env" "$NODE_ENV_FILE"
        echo -e "${GREEN}✔ Node config restored${NC}"
    fi
    if [ -d "$SOURCE_PATH/node_certs" ]; then
        mkdir -p "$NODE_CERTS_DIR"
        cp -r "$SOURCE_PATH/node_certs"/* "$NODE_CERTS_DIR/"
        echo -e "${GREEN}✔ Node certs restored${NC}"
    fi

    rm -rf "$TEMP_DIR"

    echo -e "${BLUE}Starting services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose up -d > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose up -d > /dev/null 2>&1

    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      BACKUP LIST                            ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        echo "No backups found."
        pause
        return
    fi

    printf "%-35s %-10s %-20s\n" "Filename" "Size" "Date"
    echo "--------------------------------------------------------------"

    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null); do
        local fname=$(basename "$file")
        local fsize=$(du -h "$file" | cut -f1)
        local fdate=$(stat -c %y "$file" 2>/dev/null | cut -d'.' -f1)
        printf "%-35s %-10s %-20s\n" "$fname" "$fsize" "$fdate"
    done

    echo ""
    echo "Total: $(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l) backups"
    pause
}

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      BACKUP & RESTORE                     ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Create Backup"
        echo "2) Restore Backup"
        echo "3) List Backups"
        echo "4) Back"
        echo -e "${BLUE}===========================================${NC}"
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