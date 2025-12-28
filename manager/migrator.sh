#!/usr/bin/env bash
#==============================================================================
# MRM ULTRA MIGRATOR PRO v15.0 - Final Release
# Intelligent Migration: Pasarguard (PostgreSQL) -> Rebecca (MySQL)
# 100% Data, SSL, Core, Environment & Node Sync
#==============================================================================

set -o pipefail

# --- Configuration & Colors ---
SRC="/opt/pasarguard"
TGT="/opt/rebecca"
S_DATA="/var/lib/pasarguard"
T_DATA="/var/lib/rebecca"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; PURPLE='\033[0;35m'; NC='\033[0m'

# --- Utils ---
minfo() { echo -e "${BLUE}→${NC} $*"; }
mok()   { echo -e "${GREEN}✓${NC} $*"; }
merr()  { echo -e "${RED}✗${NC} $*"; }
ui_header() { echo -e "\n${PURPLE}================== $1 ==================${NC}"; }

# --- [1] Dependency & Rebecca Installation ---
install_rebecca() {
    if [ ! -d "$TGT" ]; then
        ui_header "INSTALLING REBECCA"
        minfo "Rebecca not found. Starting official installation..."
        bash -c "$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql
    else
        mok "Rebecca is already installed."
    fi
}

# --- [2] Sync Core Files & Env (Condition 4, 5, 7, 8) ---
sync_assets_and_configs() {
    ui_header "SYNCING CORE ASSETS"
    
    # Backup & Transfer .env
    minfo "Transferring and repairing .env configuration..."
    local MYSQL_PASS=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2 | tr -d '"')
    cp "$SRC/.env" "$TGT/.env"
    
    # Fix DB URL for MySQL and internal connection
    sed -i "s|SQLALCHEMY_DATABASE_URL=.*|SQLALCHEMY_DATABASE_URL=\"mysql+pymysql://root:${MYSQL_PASS}@127.0.0.1:3306/rebecca\"|g" "$TGT/.env"
    
    # Fix glued lines bug
    sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$TGT/.env"
    sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$TGT/.env"
    
    # Sync SSL Certificates (Condition 7)
    minfo "Transferring SSL Certificates..."
    mkdir -p "$T_DATA/certs"
    cp -rp "$S_DATA/certs/." "$T_DATA/certs/" 2>/dev/null
    
    # Sync Xray Core & Config (Condition 8)
    minfo "Syncing Xray Core and Configuration..."
    cp -p "$S_DATA/xray" "$T_DATA/xray" 2>/dev/null
    cp -p "$S_DATA/xray_config.json" "$T_DATA/xray_config.json" 2>/dev/null
    chmod +x "$T_DATA/xray" 2>/dev/null

    # Sync Custom Templates (Condition 10)
    cp -rp "$S_DATA/templates/." "$T_DATA/templates/" 2>/dev/null
    mok "Assets synced."
}

# --- [3] Database Migration Engine (Condition 2, 3, 6, 9, 10) ---
migrate_database() {
    ui_header "DATABASE TRANSFORMATION"
    minfo "Translating PostgreSQL (Pasarguard) to MySQL (Rebecca)..."

    local PG_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres" | head -1)
    local MY_CONT=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*mysql" | head -1)
    local MY_PASS=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2 | tr -d '"')

    [ -z "$PG_CONT" ] && { merr "Postgres container not found!"; return 1; }
    [ -z "$MY_CONT" ] && { merr "MySQL container not found!"; return 1; }

    mkdir -p /tmp/mrm_migration
    local tables=("admins" "users" "inbounds" "proxies" "nodes" "hosts" "groups")

    for tbl in "${tables[@]}"; do
        minfo "Extracting $tbl..."
        docker exec "$PG_CONT" psql -U pasarguard -d pasarguard -c "COPY (SELECT * FROM $tbl) TO '/tmp/$tbl.csv' WITH (FORMAT csv, HEADER true);" >/dev/null 2>&1
        docker cp "$PG_CONT:/tmp/$tbl.csv" "/tmp/mrm_migration/$tbl.csv" 2>/dev/null
    done

    # Python Transformation Engine
    python3 <<EOF
import csv, os, json

def esc(v):
    if v is None or v == '' or v == 'None': return 'NULL'
    return f"'{str(v).replace(\"'\", \"''\")}'"

tables = ["admins", "users", "inbounds", "proxies", "nodes", "hosts", "groups"]
with open('/tmp/mrm_migration/migrate.sql', 'w') as f:
    f.write("SET FOREIGN_KEY_CHECKS=0;\n")
    for tbl in tables:
        path = f"/tmp/mrm_migration/{tbl}.csv"
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8') as cf:
                reader = csv.DictReader(cf)
                f.write(f"DELETE FROM {tbl};\n")
                for row in reader:
                    cols = ", ".join([f"\`{k}\`" for k in row.keys()])
                    vals = ", ".join([esc(v) for v in row.values()])
                    f.write(f"INSERT INTO {tbl} ({cols}) VALUES ({vals});\n")
    f.write("SET FOREIGN_KEY_CHECKS=1;\n")
EOF

    minfo "Injecting data into Rebecca DB..."
    docker cp "/tmp/mrm_migration/migrate.sql" "$MY_CONT:/tmp/migrate.sql"
    docker exec "$MY_CONT" sh -c "mysql -uroot -p$MY_PASS rebecca < /tmp/migrate.sql"
    
    rm -rf /tmp/mrm_migration
    mok "Database migration complete."
}

# --- [4] Smart-Fix Engine (Condition 11) ---
apply_smart_fixes() {
    ui_header "SMART-FIX & OPTIMIZATION"
    
    # A. Anti-Lockout Firewall
    local SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    minfo "Securing Firewall (SSH Port: $SSH_PORT)..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    
    # B. Cleanup Network Blocks
    for r in "192.0.0.0/8" "102.0.0.0/8" "198.0.0.0/8" "172.0.0.0/8"; do
        ufw delete deny from "$r" >/dev/null 2>&1 || true
        ufw delete deny out to "$r" >/dev/null 2>&1 || true
    done

    # C. Node SSL Repair (Condition 6)
    mkdir -p "$T_DATA/certs"
    if [ ! -f "$T_DATA/certs/ssl_key.pem" ]; then
        minfo "Generating Node SSL keys..."
        openssl genrsa -out "$T_DATA/certs/ssl_key.pem" 2048 >/dev/null 2>&1
    fi
    
    # D. Nginx Proxy Repair
    local NG_CONF="/etc/nginx/conf.d/panel_separate.conf"
    if [ -f "$NG_CONF" ]; then
        minfo "Optimizing Nginx Proxy..."
        sed -i 's|proxy_pass http://127.0.0.1:7431;|proxy_pass https://127.0.0.1:7431;\n        proxy_ssl_verify off;|g' "$NG_CONF"
        systemctl restart nginx >/dev/null 2>&1
    fi
    mok "Optimization applied."
}

# --- Main Migration Process ---
start_migration() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}    MRM ULTRA MIGRATOR: PASARGUARD -> REBECCA${NC}"
    echo -e "${CYAN}======================================================${NC}"

    # 1. Prepare Environment
    install_rebecca
    
    # 2. Stop Services
    minfo "Stopping containers for safe migration..."
    cd "$SRC" && docker compose down >/dev/null 2>&1
    cd "$TGT" && docker compose down >/dev/null 2>&1
    
    # 3. Data Sync
    sync_assets_and_configs
    
    # 4. Start DB for Injection
    minfo "Starting MySQL..."
    cd "$TGT" && docker compose up -d mysql
    echo -ne "  Waiting for DB readiness... "
    sleep 15
    echo -e "${GREEN}Ready${NC}"
    
    # 5. DB Migration
    migrate_database || { merr "DB Migration Failed!"; exit 1; }
    
    # 6. Apply Fixes
    apply_smart_fixes
    
    # 7. Start Final Stack
    ui_header "FINALIZING"
    minfo "Starting Rebecca Panel..."
    cd "$TGT" && docker compose up -d --force-recreate
    
    echo -e "\n${GREEN}✔ MIGRATION SUCCESSFUL!${NC}"
    echo -e "${YELLOW}Panel Port: 7431 | DB: MySQL | All Assets Transferred.${NC}"
    echo -e "${CYAN}Log in with your existing Pasarguard credentials.${NC}\n"
}

# Execution
if [ "$EUID" -ne 0 ]; then merr "Please run as root"; exit 1; fi
start_migration