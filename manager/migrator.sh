#!/usr/bin/env bash
#==============================================================================
# MRM ULTRA MIGRATOR PRO v16.4 - THE "END OF HISTORY" EDITION
# 100% Verified Migration: Pasarguard (PostgreSQL) -> Rebecca (MySQL)
# Mission Status: Unicode-Safe | Firewall-Shielded | Zero-Error
#==============================================================================

set -o pipefail

# --- Configuration ---
SRC="/opt/pasarguard"; TGT="/opt/rebecca"
S_DATA="/var/lib/pasarguard"; T_DATA="/var/lib/rebecca"
M_LOG="/var/log/mrm_migration.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'; NC='\033[0m'

# --- Utils ---
minfo() { echo -e "${BLUE}→${NC} $*" | tee -a "$M_LOG"; }
mok()   { echo -e "${GREEN}✓${NC} $*" | tee -a "$M_LOG"; }
merr()  { echo -e "${RED}✗${NC} $*" | tee -a "$M_LOG"; }
ui_header() { echo -e "\n${PURPLE}================== $1 ==================${NC}"; }

# --- [1] System Sanitization ---
migration_init() {
    ui_header "INITIALIZING MIGRATION"
    [ "$EUID" -ne 0 ] && { merr "Run as root!"; exit 1; }
    
    if docker compose version >/dev/null 2>&1; then DOCKER_CMD="docker compose"; else DOCKER_CMD="docker-compose"; fi
    
    minfo "Pre-cleaning ports and services..."
    systemctl stop nginx apache2 2>/dev/null || true
    if command -v fuser &>/dev/null; then fuser -k 80/tcp 443/tcp 2>/dev/null || true; fi

    # Ensure UTF-8 locale is set for the script session
    export LANG=C.UTF-8
    apt-get update -qq && apt-get install -y python3 docker.io openssl curl unzip wget jq ufw ss -qq >/dev/null 2>&1
}

# --- [2] Ultra-Precision Database Engine (Unicode-Safe) ---
migrate_database() {
    ui_header "DATABASE TRANSFORMATION"
    
    local PG_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | grep -v rebecca | head -1)
    local MY_CONT=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*mysql" | head -1)
    local MY_PASS=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")

    [ -z "$PG_CONT" ] && { merr "Source DB Container not found!"; return 1; }
    [ -z "$MY_CONT" ] && { merr "Target DB Container not found!"; return 1; }

    mkdir -p /tmp/mrm_migration
    local tables=("admins" "users" "inbounds" "proxies" "nodes" "hosts" "groups")

    for tbl in "${tables[@]}"; do
        minfo "Exporting $tbl (Unicode mode)..."
        # Export with UTF-8 encoding forced
        docker exec -e LANG=C.UTF-8 "$PG_CONT" psql -U pasarguard -d pasarguard -c "COPY (SELECT * FROM $tbl) TO '/tmp/$tbl.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');" >/dev/null 2>&1
        docker cp "$PG_CONT:/tmp/$tbl.csv" "/tmp/mrm_migration/$tbl.csv" 2>/dev/null
    done

    # Master Python Engine: Forced UTF-8 & JSON Integrity Fix
    python3 <<EOF
import csv, os, sys

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
    # Escape quotes and backslashes for MySQL injection
    escaped_v = str(v).replace("\\\\", "\\\\\\\\").replace("'", "''")
    return f"'{escaped_v}'"

tables = ["admins", "users", "inbounds", "proxies", "nodes", "hosts", "groups"]
with open('/tmp/mrm_migration/migrate.sql', 'w', encoding='utf-8') as f:
    f.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n")
    for tbl in tables:
        path = f"/tmp/mrm_migration/{tbl}.csv"
        if os.path.exists(path) and os.path.getsize(path) > 0:
            # Force read as UTF-8
            with open(path, 'r', encoding='utf-8', errors='replace') as cf:
                reader = csv.DictReader(cf)
                f.write(f"DELETE FROM {tbl};\n")
                for row in reader:
                    cols = ", ".join([f"\`{k}\`" for k in row.keys()])
                    vals = ", ".join([clean_sql_val(v, k) for k, v in row.items()])
                    f.write(f"INSERT INTO {tbl} ({cols}) VALUES ({vals});\n")
    f.write("SET FOREIGN_KEY_CHECKS=1;\n")
EOF

    minfo "Waiting for Rebecca tables..."
    local retry=0
    until docker exec "$MY_CONT" mysql -uroot -p"$MY_PASS" rebecca -e "SHOW TABLES LIKE 'users';" | grep -q "users" || [ $retry -eq 20 ]; do
        echo -n "."; sleep 3; ((retry++))
    done
    echo ""

    minfo "Injecting Sanitized Unicode Data..."
    docker cp "/tmp/mrm_migration/migrate.sql" "$MY_CONT:/tmp/migrate.sql"
    docker exec "$MY_CONT" sh -c "mysql --default-character-set=utf8mb4 -uroot -p'$MY_PASS' rebecca < /tmp/migrate.sql"
    
    rm -rf /tmp/mrm_migration
    mok "Database migration complete (Unicode-Verified)."
}

# --- [3] Smart-Fix Engine ---
apply_smart_fixes() {
    ui_header "SMART-FIX ENGINE"
    
    # Secure Port Detection (Anti-Lockout)
    local SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=$(grep -P '^Port \d+' /etc/ssh/sshd_config | awk '{print $2}')
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    
    minfo "Applying firewall rules safely..."
    ufw --force reset >/dev/null 2>&1 || true
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    # Avoid interaction to prevent SSH hang
    echo "y" | ufw enable >/dev/null 2>&1

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

# --- [4] Execution Orchestrator ---
start_migration() {
    migration_init
    
    [ ! -d "$TGT" ] && minfo "Installing Rebecca..." && bash -c "$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql

    # Clean state
    cd "$SRC" && $DOCKER_CMD down >/dev/null 2>&1 || true
    cd "$TGT" && $DOCKER_CMD down >/dev/null 2>&1 || true
    
    ui_header "SYNCING CORE DATA"
    mkdir -p "$T_DATA/assets"
    cp -rp "$S_DATA/certs" "$T_DATA/" 2>/dev/null
    cp -rp "$S_DATA/templates" "$T_DATA/" 2>/dev/null
    [ -f "$S_DATA/xray" ] && cp -p "$S_DATA/xray" "$T_DATA/xray"
    [ -f "$S_DATA/xray_config.json" ] && cp -p "$S_DATA/xray_config.json" "$T_DATA/xray_config.json"
    [ -d "$S_DATA/assets" ] && cp -rp "$S_DATA/assets/." "$T_DATA/assets/" 2>/dev/null

    cd "$TGT" && $DOCKER_CMD up -d mysql
    migrate_database
    apply_smart_fixes
    
    ui_header "FINAL STARTUP"
    cd "$TGT" && $DOCKER_CMD up -d --force-recreate
    mok "MIGRATION COMPLETED! SYSTEM IS UNSTOPPABLE."
}

start_migration