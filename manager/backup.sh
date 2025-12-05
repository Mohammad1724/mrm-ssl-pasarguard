#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10

# Paths to Backup
PATH_DATA="/var/lib/pasarguard"
PATH_DB="/var/lib/postgresql/pasarguard"
PATH_OPT="/opt/pasarguard"
PATH_NGINX="/etc/nginx"
PATH_LE="/etc/letsencrypt"
PATH_NODE_ENV="/opt/pg-node/.env"
PATH_NODE_CERTS="/var/lib/pg-node/certs"

create_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CREATE FULL SERVER BACKUP              ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo "This will backup Panel, Database, Nginx, SSL, and Configs."
    echo ""

    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="mrm_full_backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"

    mkdir -p "$TEMP_PATH"

    echo -e "${YELLOW}Stopping services to ensure data integrity...${NC}"
    
    # Stop Services
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose stop > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose stop > /dev/null 2>&1
    systemctl stop nginx > /dev/null 2>&1

    # 1. Panel Data (Config & Certs)
    echo -e "${BLUE}[1/6] Backing up Panel Data...${NC}"
    if [ -d "$PATH_DATA" ]; then
        mkdir -p "$TEMP_PATH/var_lib_pasarguard"
        cp -r "$PATH_DATA/." "$TEMP_PATH/var_lib_pasarguard/"
        echo -e "${GREEN}✔ Panel Data Saved${NC}"
    else
        echo -e "${RED}✘ Panel Data not found${NC}"
    fi

    # 2. Database (Postgres/Timescale)
    echo -e "${BLUE}[2/6] Backing up Database...${NC}"
    if [ -d "$PATH_DB" ]; then
        mkdir -p "$TEMP_PATH/var_lib_postgresql"
        cp -r "$PATH_DB/." "$TEMP_PATH/var_lib_postgresql/"
        echo -e "${GREEN}✔ Database Saved${NC}"
    else
        echo -e "${YELLOW}! Database folder not found (Maybe SQLite?)${NC}"
    fi

    # 3. Docker Configs (.env & yml)
    echo -e "${BLUE}[3/6] Backing up Docker Configs...${NC}"
    if [ -d "$PATH_OPT" ]; then
        mkdir -p "$TEMP_PATH/opt_pasarguard"
        cp -r "$PATH_OPT/." "$TEMP_PATH/opt_pasarguard/"
        echo -e "${GREEN}✔ Docker Configs Saved${NC}"
    fi

    # 4. Nginx & SSL
    echo -e "${BLUE}[4/6] Backing up Nginx & SSL...${NC}"
    if [ -d "$PATH_NGINX" ]; then
        mkdir -p "$TEMP_PATH/etc_nginx"
        cp -r "$PATH_NGINX/." "$TEMP_PATH/etc_nginx/"
    fi
    if [ -d "$PATH_LE" ]; then
        mkdir -p "$TEMP_PATH/etc_letsencrypt"
        cp -r "$PATH_LE/." "$TEMP_PATH/etc_letsencrypt/"
    fi
    echo -e "${GREEN}✔ Nginx & SSL Saved${NC}"

    # 5. Node Configs (If exists)
    echo -e "${BLUE}[5/6] Backing up Node Configs...${NC}"
    if [ -f "$PATH_NODE_ENV" ]; then
        mkdir -p "$TEMP_PATH/opt_pgnode"
        cp "$PATH_NODE_ENV" "$TEMP_PATH/opt_pgnode/.env"
    fi
    if [ -d "$PATH_NODE_CERTS" ]; then
        mkdir -p "$TEMP_PATH/var_lib_pgnode_certs"
        cp -r "$PATH_NODE_CERTS/." "$TEMP_PATH/var_lib_pgnode_certs/"
    fi
    echo -e "${GREEN}✔ Node Configs Checked${NC}"

    # Restart Services
    echo -e "${YELLOW}Restarting services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose up -d > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose up -d > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1

    # Compress
    echo -e "${BLUE}[6/6] Compressing...${NC}"
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$TEMP_PATH"

    local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    local SIZE=$(du -h "$FINAL_FILE" | cut -f1)

    echo ""
    echo -e "${GREEN}✔ BACKUP SUCCESSFUL!${NC}"
    echo -e "File: ${CYAN}$FINAL_FILE${NC}"
    echo -e "Size: ${CYAN}$SIZE${NC}"

    # Rotate
    ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null

    pause
}

restore_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      RESTORE FULL SERVER BACKUP             ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    if [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${RED}No backups found in $BACKUP_DIR${NC}"
        pause; return
    fi

    echo "Select backup to restore:"
    local i=1
    declare -a backups
    for file in $(ls -1t "$BACKUP_DIR"/*.tar.gz); do
        echo -e "${GREEN}$i)${NC} $(basename $file) ($(du -h $file | cut -f1))"
        backups[$i]="$file"
        ((i++))
    done

    read -p "Select: " SEL
    local FILE="${backups[$SEL]}"
    [ -z "$FILE" ] && return

    echo ""
    echo -e "${RED}⚠ WARNING: This will DELETE current data and RESTORE from backup.${NC}"
    read -p "Are you sure? (yes/no): " CONF
    [ "$CONF" != "yes" ] && return

    echo -e "${YELLOW}Stopping services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose down
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose down
    systemctl stop nginx

    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    tar -xzf "$FILE" -C "$TEMP_DIR"
    local ROOT="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    echo -e "${BLUE}Restoring files...${NC}"

    # Restore paths
    [ -d "$ROOT/var_lib_pasarguard" ] && rm -rf "$PATH_DATA"/* && cp -r "$ROOT/var_lib_pasarguard/." "$PATH_DATA/"
    [ -d "$ROOT/var_lib_postgresql" ] && rm -rf "$PATH_DB"/* && cp -r "$ROOT/var_lib_postgresql/." "$PATH_DB/"
    [ -d "$ROOT/opt_pasarguard" ] && cp -r "$ROOT/opt_pasarguard/." "$PATH_OPT/"
    [ -d "$ROOT/etc_nginx" ] && cp -r "$ROOT/etc_nginx/." "$PATH_NGINX/"
    [ -d "$ROOT/etc_letsencrypt" ] && cp -r "$ROOT/etc_letsencrypt/." "$PATH_LE/"
    
    # Restore Node
    if [ -d "$ROOT/opt_pgnode" ]; then
        mkdir -p "$(dirname $PATH_NODE_ENV)"
        cp "$ROOT/opt_pgnode/.env" "$PATH_NODE_ENV"
    fi
    if [ -d "$ROOT/var_lib_pgnode_certs" ]; then
        mkdir -p "$PATH_NODE_CERTS"
        cp -r "$ROOT/var_lib_pgnode_certs/." "$PATH_NODE_CERTS/"
    fi

    echo -e "${YELLOW}Restarting services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose up -d
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose up -d
    systemctl restart nginx

    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✔ Restore Complete!${NC}"
    pause
}

list_backups() {
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null
    pause
}

backup_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      BACKUP & RESTORE                     ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Create Full Backup"
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