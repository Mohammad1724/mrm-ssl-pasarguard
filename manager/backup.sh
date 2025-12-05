#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

BACKUP_DIR="/root/mrm-backups"
MAX_BACKUPS=10

# --- CONFIGURABLE PATHS ---
PATH_DATA="/var/lib/pasarguard"
PATH_DB="/var/lib/postgresql/pasarguard"
PATH_OPT="/opt/pasarguard"
PATH_LE="/etc/letsencrypt"
PATH_NODE_ENV="/opt/pg-node/.env"
PATH_NODE_CERTS="/var/lib/pg-node/certs"

# Detect Docker Compose Command
if command -v docker-compose &> /dev/null; then
    D_COMPOSE="docker-compose"
else
    D_COMPOSE="docker compose"
fi

create_backup() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CREATE FULL SERVER BACKUP              ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    
    # Check Disk Space (Need approx 2x DB size space)
    local FREE_SPACE=$(df -k /root | awk 'NR==2 {print $4}')
    if [ "$FREE_SPACE" -lt 512000 ]; then # 500MB min
        echo -e "${RED}Warning: Low disk space. Backup might fail.${NC}"
        read -p "Continue anyway? (y/n): " CONT
        [ "$CONT" != "y" ] && return
    fi

    mkdir -p "$BACKUP_DIR"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_NAME="mrm_full_backup_$TIMESTAMP"
    local TEMP_PATH="$BACKUP_DIR/$BACKUP_NAME"

    mkdir -p "$TEMP_PATH"

    echo -e "${YELLOW}Stopping services (Ensuring Data Integrity)...${NC}"
    
    # Stop Services
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE stop > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE stop > /dev/null 2>&1
    systemctl stop nginx > /dev/null 2>&1

    echo -e "${BLUE}Backing up data...${NC}"

    # 1. Panel Data
    if [ -d "$PATH_DATA" ]; then
        mkdir -p "$TEMP_PATH/var_lib_pasarguard"
        cp -a "$PATH_DATA/." "$TEMP_PATH/var_lib_pasarguard/"
    fi

    # 2. Database (Safe Copy)
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
    fi

    # 4. SSL Certificates
    if [ -d "$PATH_LE" ]; then
        mkdir -p "$TEMP_PATH/etc_letsencrypt"
        cp -a "$PATH_LE/." "$TEMP_PATH/etc_letsencrypt/"
        echo -e "${GREEN}✔ SSL Certificates Saved${NC}"
    fi

    # 5. Nginx Configs (ONLY User Configs, not System)
    mkdir -p "$TEMP_PATH/nginx_backup"
    [ -d "/etc/nginx/conf.d" ] && cp -a "/etc/nginx/conf.d" "$TEMP_PATH/nginx_backup/"
    [ -d "/etc/nginx/sites-available" ] && cp -a "/etc/nginx/sites-available" "$TEMP_PATH/nginx_backup/"
    [ -d "/etc/nginx/sites-enabled" ] && cp -a "/etc/nginx/sites-enabled" "$TEMP_PATH/nginx_backup/"
    echo -e "${GREEN}✔ Nginx Configs Saved${NC}"

    # 6. Node Configs
    if [ -f "$PATH_NODE_ENV" ]; then
        mkdir -p "$TEMP_PATH/opt_pgnode"
        cp -a "$PATH_NODE_ENV" "$TEMP_PATH/opt_pgnode/.env"
    fi
    if [ -d "$PATH_NODE_CERTS" ]; then
        mkdir -p "$TEMP_PATH/var_lib_pgnode_certs"
        cp -a "$PATH_NODE_CERTS/." "$TEMP_PATH/var_lib_pgnode_certs/"
    fi

    # Restart Services
    echo -e "${YELLOW}Restarting services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE up -d > /dev/null 2>&1
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE up -d > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1

    # Compress
    echo -e "${BLUE}Compressing archive...${NC}"
    cd "$BACKUP_DIR"
    if tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME" 2>/dev/null; then
        rm -rf "$TEMP_PATH"
        local SIZE=$(du -h "${BACKUP_NAME}.tar.gz" | cut -f1)
        echo ""
        echo -e "${GREEN}✔ BACKUP SUCCESSFUL!${NC}"
        echo -e "File: ${CYAN}$BACKUP_DIR/${BACKUP_NAME}.tar.gz${NC}"
        echo -e "Size: ${CYAN}$SIZE${NC}"
    else
        echo -e "${RED}✘ Compression Failed! Check disk space.${NC}"
    fi

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
    echo -e "${RED}⚠ DANGER: This will WIPE current data and RESTORE from backup.${NC}"
    read -p "Are you sure? (yes/no): " CONF
    [ "$CONF" != "yes" ] && return

    # 1. Verify Archive
    echo -e "${BLUE}Verifying backup integrity...${NC}"
    local TEMP_DIR="/tmp/mrm_restore_$$"
    mkdir -p "$TEMP_DIR"
    
    if ! tar -xzf "$FILE" -C "$TEMP_DIR"; then
        echo -e "${RED}✘ Backup file is corrupted! Aborting.${NC}"
        rm -rf "$TEMP_DIR"
        pause; return
    fi
    
    local ROOT="$TEMP_DIR/$(ls "$TEMP_DIR" | head -1)"

    # 2. Stop Services
    echo -e "${YELLOW}Stopping services...${NC}"
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE down
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE down
    systemctl stop nginx

    echo -e "${BLUE}Restoring files...${NC}"

    # 3. Restore Data (Using 'cp -a' for permissions)
    
    # Panel Data
    if [ -d "$ROOT/var_lib_pasarguard" ]; then
        mkdir -p "$PATH_DATA"
        cp -a "$ROOT/var_lib_pasarguard/." "$PATH_DATA/"
    fi
    
    # Database (Critical: Wipe old DB first)
    if [ -d "$ROOT/var_lib_postgresql" ]; then
        mkdir -p "$PATH_DB"
        rm -rf "${PATH_DB:?}/"*  # Safe delete
        cp -a "$ROOT/var_lib_postgresql/." "$PATH_DB/"
        echo -e "${GREEN}✔ Database Restored${NC}"
    fi

    # Docker Configs
    if [ -d "$ROOT/opt_pasarguard" ]; then
        mkdir -p "$PATH_OPT"
        cp -a "$ROOT/opt_pasarguard/." "$PATH_OPT/"
    fi

    # SSL Certificates
    if [ -d "$ROOT/etc_letsencrypt" ]; then
        rm -rf "$PATH_LE"
        cp -a "$ROOT/etc_letsencrypt" "/etc/"
        echo -e "${GREEN}✔ SSL Restored${NC}"
    fi

    # Nginx Configs (Surgical Restore)
    if [ -d "$ROOT/nginx_backup" ]; then
        [ -d "$ROOT/nginx_backup/conf.d" ] && cp -a "$ROOT/nginx_backup/conf.d/." "/etc/nginx/conf.d/"
        [ -d "$ROOT/nginx_backup/sites-available" ] && cp -a "$ROOT/nginx_backup/sites-available/." "/etc/nginx/sites-available/"
        [ -d "$ROOT/nginx_backup/sites-enabled" ] && cp -a "$ROOT/nginx_backup/sites-enabled/." "/etc/nginx/sites-enabled/"
        echo -e "${GREEN}✔ Nginx Configs Restored${NC}"
    fi
    
    # Node Restore
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
    [ -d "$PANEL_DIR" ] && cd "$PANEL_DIR" && $D_COMPOSE up -d
    [ -d "$NODE_DIR" ] && cd "$NODE_DIR" && $D_COMPOSE up -d
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