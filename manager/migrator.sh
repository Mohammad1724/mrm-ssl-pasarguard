#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.4 (Standalone - No Dependencies)
#==============================================================================

# --- CONFIGURATION ---
REBECCA_DIR="/opt/rebecca"
BACKUP_ROOT="/var/backups/mrm-migration"
MIGRATION_LOG="/var/log/mrm_migration.log"
MIGRATION_TEMP=""

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- UTILS ---
log()   { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
pause() { echo ""; read -n 1 -s -r -p "Press any key to continue..."; echo ""; }

migration_init() {
    MIGRATION_TEMP="/tmp/mrm_mig_$(date +%s)"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
}

migration_cleanup() {
    rm -rf "$MIGRATION_TEMP"
}

find_container() {
    local keyword="$1"
    docker ps --format '{{.Names}}' | grep -iE "$keyword" | head -1
}

get_db_pass() {
    grep MYSQL_ROOT_PASSWORD "$REBECCA_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"'
}

# --- 1. START SOURCE ---
start_source() {
    local src="$1"
    log "Starting source panel ($src)..."
    (cd "$src" && docker compose up -d)
    
    log "Waiting for Database..."
    sleep 15
    
    local pg=$(find_container "pasarguard.*(timescale|postgres)")
    if [ -z "$pg" ]; then 
        err "Database container not found!"
        return 1
    fi
    ok "Found database: $pg"
    echo "$pg" > "$MIGRATION_TEMP/pg_container"
}

# --- 2. EXPORT DATA ---
export_data() {
    local pg=$(cat "$MIGRATION_TEMP/pg_container")
    log "Exporting data from $pg..."
    
    # Export Admins
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, username, hashed_password, COALESCE(is_sudo, false), COALESCE(telegram_id, 0) FROM admins;" > "$MIGRATION_TEMP/admins.txt"
    
    # Export Users (Convert Time)
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, username, COALESCE(status, 'active'), COALESCE(used_traffic, 0), data_limit, EXTRACT(EPOCH FROM expire)::bigint, note FROM users;" > "$MIGRATION_TEMP/users.txt"
        
    # Export Inbounds
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, tag FROM inbounds;" > "$MIGRATION_TEMP/inbounds.txt"
        
    # Export Hosts
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, remark, address, port, inbound_tag, sni, host, security, COALESCE(fingerprint::text, 'none'), is_disabled, path FROM hosts;" > "$MIGRATION_TEMP/hosts.txt"
        
    # Export Config
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT config FROM core_configs LIMIT 1;" > "$MIGRATION_TEMP/config.json"
    
    # Validate exports
    if [ ! -s "$MIGRATION_TEMP/users.txt" ]; then
        err "No users exported! Check source database."
        return 1
    fi
    
    ok "Data exported successfully."
    
    # Stop Source
    log "Stopping source panel..."
    cd "$(cat $BACKUP_ROOT/.last_source)" && docker compose down
}

# --- 3. GENERATE SQL (PYTHON WITHOUT DEPENDENCIES) ---
generate_sql() {
    log "Generating SQL import file..."
    
    # Generate Secrets in Bash to pass to Python
    export JWT_KEY=$(openssl rand -hex 64)
    export SUB_KEY=$(openssl rand -hex 64)
    export ADM_KEY=$(openssl rand -hex 64)
    export VMESS=$(openssl rand -hex 16)
    export VLESS=$(openssl rand -hex 16)
    export TEMP_DIR="$MIGRATION_TEMP"

    python3 << 'EOF'
import os
import json
import sys

temp_dir = os.environ['TEMP_DIR']
sql_file = os.path.join(temp_dir, 'import.sql')

statements = []
statements.append("SET FOREIGN_KEY_CHECKS=0;")
statements.append("DELETE FROM users; DELETE FROM admins; DELETE FROM inbounds; DELETE FROM hosts;")
statements.append("DELETE FROM services; DELETE FROM service_hosts; DELETE FROM core_configs; DELETE FROM jwt;")

# 1. ADMINS
try:
    with open(os.path.join(temp_dir, 'admins.txt'), 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 3:
                role = 'sudo' if parts[3] == 't' else 'standard'
                tgid = parts[4] if parts[4] != '0' else 'NULL'
                pw = parts[2].replace("'", "''")
                stmt = f"INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ({parts[0]}, '{parts[1]}', '{pw}', '{role}', 'active', {tgid}, NOW());"
                statements.append(stmt)
except: pass

# 2. INBOUNDS
try:
    with open(os.path.join(temp_dir, 'inbounds.txt'), 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 2:
                stmt = f"INSERT INTO inbounds (id, tag, protocol) VALUES ({parts[0]}, '{parts[1]}', 'mixed');"
                statements.append(stmt)
except: pass

# 3. USERS
try:
    with open(os.path.join(temp_dir, 'users.txt'), 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 2:
                # Fix username
                user = parts[1].replace('@','').replace('.','_').replace('-','_')
                
                limit = parts[4] if parts[4] else 'NULL'
                expire = parts[5] if parts[5] else 'NULL'
                note = parts[6].replace("'", "''") if len(parts) > 6 else ''
                
                stmt = f"INSERT INTO users (id, username, status, used_traffic, data_limit, expire, admin_id, note, created_at) VALUES ({parts[0]}, '{user}', '{parts[2]}', {parts[3]}, {limit}, {expire}, 1, '{note}', NOW());"
                statements.append(stmt)
except: pass

# 4. HOSTS
try:
    with open(os.path.join(temp_dir, 'hosts.txt'), 'r') as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 11:
                # Replace paths
                addr = parts[2].replace('pasarguard', 'rebecca')
                path = parts[10].replace('pasarguard', 'rebecca')
                remark = parts[1].replace("'", "''")
                
                port = parts[3] if parts[3] else 'NULL'
                dis = 1 if parts[9] == 't' else 0
                fp = parts[8] if parts[8] else 'none'
                
                stmt = f"INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path) VALUES ({parts[0]}, '{remark}', '{addr}', {port}, '{parts[4]}', '{parts[5]}', '{parts[6]}', '{parts[7]}', '{fp}', {dis}, '{path}');"
                statements.append(stmt)
except: pass

# 5. CORE CONFIG
try:
    with open(os.path.join(temp_dir, 'config.json'), 'r') as f:
        config = f.read().strip()
        if config:
            config = config.replace('pasarguard', 'rebecca')
            # Fix JSON for API
            try:
                c_json = json.loads(config)
                if 'api' not in c_json:
                    c_json['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
                config = json.dumps(c_json)
            except: pass
            
            config_esc = config.replace("'", "''").replace("\\", "\\\\")
            statements.append(f"INSERT INTO core_configs (id, name, config, created_at) VALUES (1, 'default', '{config_esc}', NOW());")
except: pass

# 6. JWT
jwt = os.environ['JWT_KEY']
sub = os.environ['SUB_KEY']
adm = os.environ['ADM_KEY']
vm = os.environ['VMESS']
vl = os.environ['VLESS']
statements.append(f"INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) VALUES ('{jwt}', '{sub}', '{adm}', '{vm}', '{vl}');")

# 7. SERVICES
statements.append("INSERT INTO services (id, name, created_at) VALUES (1, 'Default Service', NOW());")
statements.append("INSERT INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")
statements.append("UPDATE users SET service_id = 1 WHERE service_id IS NULL;")
statements.append("SET FOREIGN_KEY_CHECKS=1;")

with open(sql_file, 'w') as f:
    f.write('\n'.join(statements))

print("SQL generated")
EOF

    if [ -f "$MIGRATION_TEMP/import.sql" ]; then
        ok "SQL file generated successfully."
    else
        err "Failed to generate SQL."
        return 1
    fi
}

# --- 4. EXECUTE MIGRATION ---
execute_migration() {
    log "Applying migration to Rebecca..."
    
    local db_pass=$(get_db_pass)
    local mysql_container=$(find_container "rebecca.*mysql")
    
    if [ -z "$mysql_container" ]; then
        err "Rebecca MySQL not running!"
        return 1
    fi
    
    # Copy SQL file
    docker cp "$MIGRATION_TEMP/import.sql" "$mysql_container:/tmp/import.sql"
    
    # Execute
    docker exec "$mysql_container" mysql -uroot -p"$db_pass" rebecca -e "SOURCE /tmp/import.sql"
    
    if [ $? -eq 0 ]; then
        ok "Database import successful."
    else
        err "Database import failed."
        return 1
    fi
    
    # Restart
    log "Restarting Rebecca..."
    cd "$REBECCA_DIR" && docker compose restart
    sleep 15
    
    # Verify
    log "--- Final Check ---"
    docker exec "$mysql_container" mysql -uroot -p"$db_pass" rebecca -e "SELECT 'Users' as T, COUNT(*) FROM users UNION SELECT 'Inbounds', COUNT(*) FROM inbounds UNION SELECT 'Config', COUNT(*) FROM core_configs;"
    
    echo ""
    log "Xray Logs:"
    docker logs rebecca-rebecca-1 2>&1 | grep -iE "xray|inbound" | tail -5
    
    ok "MIGRATION COMPLETE"
}

# --- MAIN MENU ---
do_migration() {
    clear
    ui_header "MRM MIGRATION V10.4"
    
    # Detect Source
    local src=""
    if [ -d "/opt/pasarguard" ]; then src="/opt/pasarguard"; 
    elif [ -d "/opt/marzban" ]; then src="/opt/marzban"; fi
    
    if [ -z "$src" ]; then err "Source not found"; pause; return; fi
    
    echo "$src" > "$BACKUP_ROOT/.last_source"
    
    # Detect Target
    if [ ! -d "$REBECCA_DIR" ]; then
        log "Rebecca not installed. Installing..."
        bash -c "$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql
    fi
    
    if ! ui_confirm "Start Migration from $(basename $src)?" "y"; then return; fi
    
    migration_init
    
    start_source "$src"
    export_data
    generate_sql
    execute_migration
    
    migration_cleanup
    pause
}

menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION TOOL V10.4"
        echo "1) Start Migration"
        echo "2) Rollback"
        echo "3) Exit"
        read -p "Select: " opt
        case "$opt" in
            1) do_migration ;;
            2) 
                local old=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
                if [ -n "$old" ]; then
                    cd "$REBECCA_DIR" && docker compose down
                    cd "$old" && docker compose up -d
                    ok "Rollback complete"
                else
                    err "No history"
                fi
                pause
                ;;
            3) exit 0 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$EUID" -ne 0 ]; then echo "Run as root"; exit 1; fi
    menu
fi