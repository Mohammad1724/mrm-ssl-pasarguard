#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10

# --- CRITICAL PATHS (Check carefully) ---
# 1. Panel Data & Xray Config
PATH_DATA="/var/lib/pasarguard"
# 2. Database Data (TimescaleDB/Postgres)
PATH_DB="/var/lib/postgresql/pasarguard"
# 3. Docker Files (.env, docker-compose.yml)
PATH_OPT="/opt/pasarguard"
# 4. Nginx Configs (Sub Link Separation)
PATH_NGINX="/etc/nginx"
# 5. SSL Certificates (Certbot)
PATH_LE="/etc/letsencrypt"
# 6. Node Paths (If exists)
PATH_NODE_ENV="/opt/pg-node/.env"
PATH_NODE_CERTS="/var/lib/pg-node/certs"

create_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CREATE FULL SERVER BACKUP              ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo "This will backup ALL critical data (DB, SSL, Nginx, Panel)."
    echo ""

    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="mrm_full_backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"

    mkdir -p "$TEMP_PATH"

    echo -e "${YELLOW}Stopping services to ensure DB integrity...${NC}"
    
    # Stop Services (Crucial for DB)
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose stop > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose stop > /dev/null 2>&1
    systemctl stop nginx > /dev/null 2>&1

    echo -e "${BLUE}Backing up files (Preserving permissions)...${NC}"

    # 1. Panel Data
    if [ -d "$PATH_DATA" ]; then
        mkdir -p "$TEMP_PATH/var_lib_pasarguard"
        cp -a "$PATH_DATA/." "$TEMP_PATH/var_lib_pasarguard/"
        echo -e "${GREEN}✔ Panel Data Saved${NC}"
    fi

    # 2. Database (Postgres)
    if [ -d "$PATH_DB" ]; then
        mkdir -p "$TEMP_PATH/var_lib_postgresql"
        cp -a "$PATH_DB/." "$TEMP_PATH/var_lib_postgresql/"
        echo -e "${GREEN}✔ Database Saved${NC}"
    else
        echo -e "${YELLOW}! Database folder not found at $PATH_DB${NC}"
    fi

    # 3. Docker Configs
    if [ -d "$PATH_OPT" ]; then
        mkdir -p "$TEMP_PATH/opt_pasarguard"
        cp -a "$PATH_OPT/." "$TEMP_PATH/opt_pasarguard/"
        echo -e "${GREEN}✔ Docker Configs Saved${NC}"
    fi

    # 4. Nginx & SSL
    if [ -d "$PATH_NGINX" ]; then
        mkdir -p "$TEMP_PATH/etc_nginx"
        cp -a "$PATH_NGINX/." "$TEMP_PATH/etc_nginx/"
    fi
    if [ -d "$PATH_LE" ]; then
        mkdir -p "$TEMP_PATH/etc_letsencrypt"
        cp -a "$PATH_LE/." "$TEMP_PATH/etc_letsencrypt/"
    fi
    echo -e "${GREEN}✔ Nginx & SSL Saved${NC}"

    # 5. Node Configs
    if [ -f "$PATH_NODE_ENV" ]; then
        mkdir -p "$TEMP_PATH/opt_pgnode"
        cp -a "$PATH_NODE_ENV" "$TEMP_PATH/opt_pgnode/.env"
    fi
    if [ -d "$PATH_NODE_CERTS" ]; then
        mkdir -p "$TEMP_PATH/var_lib_pgnode_certs"
        cp -a "$PATH_NODE_CERTS/." "$TEMP_PATH/var_lib_pgnode_certs/"
    fi

    # Restart Services ASAP
    echo -e "${YELLOW}Restarting services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose up -d > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose up -d > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1

    # Compress
    echo -e "${BLUE}Compressing backup...${NC}"
    cd "$BACKUP_DIR"
    if tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"; then
        rm -rf "$TEMP_PATH"
        
        local FINAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
        local SIZE=$(du -h "$FINAL_FILE" | cut -f1)

        echo ""
        echo -e "${GREEN}✔ BACKUP SUCCESSFUL!${NC}"
        echo -e "File: ${CYAN}$FINAL_FILE${NC}"
        echo -e "Size: ${CYAN}$SIZE${NC}"
    else
        echo -e "${RED}✘ Compression Failed!${NC}"
    fi

    # Rotate (Delete old backups)
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
    echo -e "${RED}⚠ DANGER: This will DELETE current data and RESTORE from backup.${NC}"
    read -p "Are you sure? (yes/no): " CONF
    [ "$CONF" != "yes" ] && return

    # 1. Verify Archive
    echo -e "${BLUE}Verifying backup integrity...${NC}"
    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    
    if ! tar -xzf "$FILE" -C "$TEMP_DIR"; then
        echo -e "${RED}✘ Backup file is corrupted! Aborting restore.${NC}"
        rm -rf "$TEMP_DIR"
        pause; return
    fi
    
    local ROOT="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    # 2. Stop Services
    echo -e "${YELLOW}Stopping services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && docker compose down
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && docker compose down
    systemctl stop nginx

    echo -e "${BLUE}Restoring files...${NC}"

    # 3. Restore with Sync (Cleaner than rm && cp)
    # Panel Data
    if [ -d "$ROOT/var_lib_pasarguard" ]; then
        mkdir -p "$PATH_DATA"
        cp -a "$ROOT/var_lib_pasarguard/." "$PATH_DATA/"
    fi
    
    # Database (Crucial)
    if [ -d "$ROOT/var_lib_postgresql" ]; then
        mkdir -p "$PATH_DB"
        # Wipe old DB to prevent conflicts
        rm -rf "$PATH_DB:?/"* 
        cp -a "$ROOT/var_lib_postgresql/." "$PATH_DB/"
    fi

    # Docker Configs
    if [ -d "$ROOT/opt_pasarguard" ]; then
        mkdir -p "$PATH_OPT"
        cp -a "$ROOT/opt_pasarguard/." "$PATH_OPT/"
    fi

    # Nginx & SSL
    if [ -d "$ROOT/etc_nginx" ]; then
        rm -rf "$PATH_NGINX"
        cp -a "$ROOT/etc_nginx" "/etc/"
    fi
    if [ -d "$ROOT/etc_letsencrypt" ]; then
        rm -rf "$PATH_LE"
        cp -a "$ROOT/etc_letsencrypt" "/etc/"
    fi
    
    # Node
    if [ -d "$ROOT/opt_pgnode" ]; then
        mkdir -p "$(dirname $PATH_NODE_ENV)"
        cp -a "$ROOT/opt_pgnode/.env" "$PATH_NODE_ENV"
    fi
    if [ -d "$ROOT/var_lib_pgnode_certs" ]; then
        mkdir -p "$PATH_NODE_CERTS"
        cp -a "$ROOT/var_lib_pgnode_certs/." "$PATH_NODE_CERTS/"
    fi

    # 4. Restart
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