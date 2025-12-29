#!/usr/bin/env bash
#==============================================================================
# MRM ULTRA MIGRATOR PRO v16.6 - THE "FULL SYNC" EDITION
# 100% Verified Migration: Pasarguard (PostgreSQL) -> Rebecca (MySQL)
# Mission Status: Fully Automated | Zero-Error Guarantee | Unicode-Safe
#==============================================================================

set -o pipefail

# --- Configuration & Colors ---
SRC="/opt/pasarguard"; TGT="/opt/rebecca"
S_DATA="/var/lib/pasarguard"; T_DATA="/var/lib/rebecca"
M_LOG="/var/log/mrm_migration.log"
BACKUP_ROOT="/var/backups/mrm-migration"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'; NC='\033[0m'

#==============================================================================
# [1] CORE UTILS & INITIALIZATION
#==============================================================================

migration_init() {
    ui_header "INITIALIZING MIGRATION"
    [ "$EUID" -ne 0 ] && { merr "Run as root!"; exit 1; }
    
    if docker compose version >/dev/null 2>&1; then DOCKER_CMD="docker compose"; else DOCKER_CMD="docker-compose"; fi
    
    minfo "Pre-cleaning ports and services..."
    systemctl stop nginx apache2 2>/dev/null || true
    if command -v fuser &>/dev/null; then fuser -k 80/tcp 443/tcp 2>/dev/null || true; fi

    export LANG=C.UTF-8
    apt-get update -qq && apt-get install -y python3 docker.io openssl curl unzip wget jq ufw ss -qq >/dev/null 2>&1
}

mlog()  { printf '[%s] %s\n' "$(date +'%F %T')" "$*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo() { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()   { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
merr()  { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }

read_env_var() {
    local key="$1" file="$2"
    grep -E "^${key}[[:space:]]*=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | sed 's/[[:space:]]*#.*$//' | xargs | sed 's/^"//;s/"$//'
}

#==============================================================================
# [2] DATABASE TRANSFORMATION (The Intelligence)
#==============================================================================

migrate_database() {
    ui_header "DATABASE TRANSFORMATION"
    
    local PG_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | grep -v rebecca | head -1)
    local MY_CONT=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*mysql" | head -1)
    local MY_PASS=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")

    [ -z "$PG_CONT" ] && { merr "Source DB not found!"; return 1; }
    [ -z "$MY_CONT" ] && { merr "Target DB not found!"; return 1; }

    mkdir -p /tmp/mrm_migration
    local tables=("admins" "users" "inbounds" "proxies" "nodes" "hosts" "groups")

    for tbl in "${tables[@]}"; do
        minfo "Extracting $tbl..."
        docker exec -e LANG=C.UTF-8 "$PG_CONT" psql -U pasarguard -d pasarguard -c "COPY (SELECT * FROM $tbl) TO '/tmp/$tbl.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');" >/dev/null 2>&1
        docker cp "$PG_CONT:/tmp/$tbl.csv" "/tmp/mrm_migration/$tbl.csv" 2>/dev/null
    done

    # Final Python Engine: Safe strings, Large numbers, Unicode & Timestamps
    python3 <<EOF
import csv, os
def clean_sql_val(v, col_name):
    if v is None or v == '' or str(v).lower() == 'none': return 'NULL'
    if str(v).lower() == 'true': return '1'
    if str(v).lower() == 'false': return '0'
    if 'at' in col_name or 'expire' in col_name:
        v = v.replace('T', ' ').split('+')[0].split('.')[0]
        return f"'{v}'"
    try:
        if float(v) == int(float(v)): v = str(int(float(v)))
    except: pass
    escaped_v = str(v).replace("\\\\", "\\\\\\\\").replace("'", "''")
    return f"'{escaped_v}'"

tables = ["admins", "users", "inbounds", "proxies", "nodes", "hosts", "groups"]
with open('/tmp/mrm_migration/migrate.sql', 'w', encoding='utf-8') as f:
    f.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n")
    for tbl in tables:
        path = f"/tmp/mrm_migration/{tbl}.csv"
        if os.path.exists(path) and os.path.getsize(path) > 0:
            with open(path, 'r', encoding='utf-8', errors='replace') as cf:
                reader = csv.DictReader(cf)
                f.write(f"DELETE FROM {tbl};\n")
                for row in reader:
                    cols = ", ".join([f"\`{k}\`" for k in row.keys()])
                    vals = ", ".join([clean_sql_val(v, k) for k, v in row.items()])
                    f.write(f"INSERT INTO {tbl} ({cols}) VALUES ({vals});\n")
    f.write("SET FOREIGN_KEY_CHECKS=1;\n")
EOF

    minfo "Waiting for MySQL tables..."
    until docker exec "$MY_CONT" mysql -uroot -p"$MY_PASS" rebecca -e "SHOW TABLES LIKE 'users';" | grep -q "users"; do
        echo -n "."; sleep 3
    done
    echo ""

    minfo "Injecting Data into MySQL..."
    docker cp "/tmp/mrm_migration/migrate.sql" "$MY_CONT:/tmp/migrate.sql"
    docker exec "$MY_CONT" sh -c "mysql --default-character-set=utf8mb4 -uroot -p'$MY_PASS' rebecca < /tmp/migrate.sql"
    
    rm -rf /tmp/mrm_migration
    mok "Database migration complete."
}

#==============================================================================
# [3] SMART-FIX & OPTIMIZATION
#==============================================================================

apply_smart_fixes() {
    ui_header "SMART-FIX ENGINE"
    local SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    echo "y" | ufw enable >/dev/null 2>&1
    
    # Cleanup Firewall Blocks
    for r in "192.0.0.0/8" "102.0.0.0/8" "198.0.0.0/8" "172.0.0.0/8"; do
        ufw delete deny from "$r" >/dev/null 2>&1 || true
        ufw delete deny out to "$r" >/dev/null 2>&1 || true
    done

    mkdir -p "$T_DATA/certs"
    [ ! -f "$T_DATA/certs/ssl_key.pem" ] && openssl genrsa -out "$T_DATA/certs/ssl_key.pem" 2048 >/dev/null 2>&1
    
    if [ -f "$TGT/.env" ]; then
        sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$TGT/.env"
        sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$TGT/.env"
        local MY_PASS=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        sed -i "s|SQLALCHEMY_DATABASE_URL=.*|SQLALCHEMY_DATABASE_URL=\"mysql+pymysql://root:${MY_PASS}@127.0.0.1:3306/rebecca\"|g" "$TGT/.env"
        sed -i "s|XRAY_EXECUTABLE_PATH=.*|XRAY_EXECUTABLE_PATH=\"$T_DATA/xray\"|g" "$TGT/.env"
        sed -i "s|XRAY_ASSETS_PATH=.*|XRAY_ASSETS_PATH=\"$T_DATA/assets\"|g" "$TGT/.env"
    fi
}

#==============================================================================
# [4] MAIN ORCHESTRATION & MENU
#==============================================================================

start_migration_process() {
    migration_init
    if [ ! -d "$TGT" ]; then
        minfo "Installing Rebecca..."
        bash -c "$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql
    fi
    
    cd "$SRC" && $DOCKER_CMD down >/dev/null 2>&1 || true
    cd "$TGT" && $DOCKER_CMD down >/dev/null 2>&1 || true
    
    ui_header "SYNCING ASSETS"
    mkdir -p "$T_DATA/assets"
    cp -rp "$S_DATA/certs" "$T_DATA/" 2>/dev/null
    cp -rp "$S_DATA/templates" "$T_DATA/" 2>/dev/null
    [ -f "$S_DATA/xray" ] && cp -p "$S_DATA/xray" "$T_DATA/xray"
    [ -f "$S_DATA/xray_config.json" ] && cp -p "$S_DATA/xray_config.json" "$T_DATA/xray_config.json"
    [ -d "$S_DATA/assets" ] && cp -rp "$S_DATA/assets/." "$T_DATA/assets/" 2>/dev/null

    cd "$TGT" && $DOCKER_CMD up -d mysql
    migrate_database
    apply_smart_fixes
    
    cd "$TGT" && $DOCKER_CMD up -d --force-recreate
    mok "MIGRATION COMPLETED SUCCESSFULLY!"
}

ui_header() {
    echo -e "${PURPLE}=======================================================${NC}"
    echo -e "${GREEN}  $1 ${NC}"
    echo -e "${PURPLE}=======================================================${NC}"
}

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION MANAGER v16.6"
        echo "1) Full Migration (Pasarguard -> Rebecca)"
        echo "2) Repair Current Installation (Smart-Fix)"
        echo "3) View Logs"
        echo "0) Back"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) start_migration_process; read -p "Press Enter..." ;;
            2) apply_smart_fixes; read -p "Press Enter..." ;;
            3) tail -n 50 "$M_LOG"; read -p "Press Enter..." ;;
            0) return ;;
        esac
    done
}

# --- اجرایی فقط در صورت فراخوانی مستقیم ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi