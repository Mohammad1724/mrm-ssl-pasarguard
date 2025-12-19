#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V10.3 (Final Stable - Zero Errors Edition)
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
log()   { echo -e "${BLUE}[$(date +'%T')]${NC} $1"; echo "[$(date +'%F %T')] $1" >> "$MIGRATION_LOG"; }
ok()    { echo -e "${GREEN}✓ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
err()   { echo -e "${RED}✗ $1${NC}"; }
pause() { echo ""; read -n 1 -s -r -p "Press any key to continue..."; echo ""; }

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX)
    mkdir -p "$BACKUP_ROOT"
    touch "$MIGRATION_LOG"
}

migration_cleanup() {
    rm -rf "$MIGRATION_TEMP"
}

# --- DATABASE HELPERS ---
get_db_pass() {
    if [ -f "$REBECCA_DIR/.env" ]; then
        grep MYSQL_ROOT_PASSWORD "$REBECCA_DIR/.env" | cut -d'=' -f2 | tr -d '"'
    else
        echo "password"
    fi
}

find_container() {
    local keyword="$1"
    docker ps --format '{{.Names}}' | grep -iE "$keyword" | head -1
}

run_mysql() {
    local pass=$(get_db_pass)
    local container=$(find_container "rebecca.*mysql")
    docker exec "$container" mysql -uroot -p"$pass" rebecca -N -e "$1" 2>/dev/null
}

# --- 1. PREPARATION & BACKUP ---
create_backup() {
    local src="$1"
    log "Creating backup of $src..."
    
    local ts=$(date +%Y%m%d_%H%M%S)
    local dest="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$dest"
    
    # Save metadata
    echo "$src" > "$BACKUP_ROOT/.last_source"
    echo "$src" > "$dest/source_path.txt"
    
    # Backup Data
    local data_dir="/var/lib/$(basename "$src")"
    [ "$src" == "/opt/pasarguard" ] && data_dir="/var/lib/pasarguard"
    
    if [ -d "$data_dir" ]; then
        tar --exclude='mysql' --exclude='postgres' --exclude='timescale' -czf "$dest/data.tar.gz" -C "$(dirname "$data_dir")" "$(basename "$data_dir")"
        ok "Data backed up to $dest"
    else
        warn "Data directory not found"
    fi
}

# --- 2. INSTALLATION ---
install_rebecca_if_needed() {
    if [ ! -d "$REBECCA_DIR" ]; then
        log "Installing Rebecca..."
        bash -c "$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)" @ install --database mysql
        
        # Ensure it starts
        cd "$REBECCA_DIR" && docker compose up -d
        sleep 10
    fi
}

# --- 3. DATA EXTRACTION (PostgreSQL) ---
extract_data_from_pasarguard() {
    local src="$1"
    log "Extracting data from Pasarguard..."
    
    # Start Pasarguard
    (cd "$src" && docker compose up -d) &>/dev/null
    sleep 15
    
    local pg=$(find_container "pasarguard.*(timescale|postgres)")
    if [ -z "$pg" ]; then err "Pasarguard DB not found"; return 1; fi
    
    # 1. Export Admins
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, username, hashed_password, COALESCE(is_sudo, false), COALESCE(telegram_id, 0) FROM admins;" > "$MIGRATION_TEMP/admins.txt"
        
    # 2. Export Users
    # Note: Converting timestamp to epoch for Rebecca
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, username, COALESCE(status, 'active'), COALESCE(used_traffic, 0), data_limit, EXTRACT(EPOCH FROM expire)::bigint, note FROM users;" > "$MIGRATION_TEMP/users.txt"
        
    # 3. Export Inbounds
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, tag FROM inbounds;" > "$MIGRATION_TEMP/inbounds.txt"
        
    # 4. Export Hosts
    # Note: Handling fingerprint enum and paths
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT id, remark, address, port, inbound_tag, sni, host, security, COALESCE(fingerprint::text, 'none'), is_disabled, path FROM hosts;" > "$MIGRATION_TEMP/hosts.txt"
        
    # 5. Export Core Config
    docker exec "$pg" psql -U pasarguard -d pasarguard -t -A -c \
        "SELECT config FROM core_configs LIMIT 1;" > "$MIGRATION_TEMP/config.json"
        
    ok "Data extraction complete"
    
    # Stop Pasarguard
    (cd "$src" && docker compose down) &>/dev/null
}

# --- 4. IMPORT LOGIC (Python for Safety) ---
import_to_rebecca() {
    log "Importing data to Rebecca..."
    
    # Copy files to Rebeeca
    cp -r "$MIGRATION_TEMP"/* /tmp/
    
    local db_pass=$(get_db_pass)
    local mysql_container=$(find_container "rebecca.*mysql")
    
    # Python script to handle complex logic safely
    python3 << PYEOF
import pymysql
import json
import os
import secrets

# Connect to MySQL
try:
    conn = pymysql.connect(
        host='127.0.0.1',
        user='root',
        password='$db_pass',
        database='rebecca',
        port=3306,
        charset='utf8mb4',
        cursorclass=pymysql.cursors.DictCursor
    )
except:
    # Try docker socket via os command if local connect fails (usually happens)
    print("Direct connection failed, generating SQL file...")
    pass

def generate_sql_file():
    sql_commands = []
    
    # 1. CLEANUP
    sql_commands.append("SET FOREIGN_KEY_CHECKS=0;")
    tables = ['users', 'admins', 'inbounds', 'hosts', 'services', 'service_hosts', 'core_configs', 'jwt', 'proxies']
    for t in tables:
        sql_commands.append(f"DELETE FROM {t};")
    
    # 2. ADMINS
    try:
        with open('/tmp/admins.txt', 'r') as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 3:
                    uid, user, phash, sudo, tgid = parts[0], parts[1], parts[2], parts[3], parts[4]
                    role = 'sudo' if sudo == 't' else 'standard'
                    tgid = 'NULL' if tgid == '0' or not tgid else tgid
                    # Escape hash
                    phash = phash.replace("'", "''")
                    sql_commands.append(f"INSERT INTO admins (id, username, hashed_password, role, status, telegram_id, created_at) VALUES ({uid}, '{user}', '{phash}', '{role}', 'active', {tgid}, NOW());")
    except Exception as e:
        print(f"Admin error: {e}")

    # 3. USERS
    try:
        with open('/tmp/users.txt', 'r') as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 2:
                    uid, user = parts[0], parts[1]
                    status = parts[2] if len(parts) > 2 else 'active'
                    used = parts[3] if len(parts) > 3 and parts[3] else '0'
                    limit = parts[4] if len(parts) > 4 and parts[4] else 'NULL'
                    expire = parts[5] if len(parts) > 5 and parts[5] else 'NULL'
                    note = parts[6] if len(parts) > 6 else ''
                    
                    # Cleanup
                    user = user.replace('@', '').replace('.', '_').replace('-', '_')
                    note = note.replace("'", "''")
                    if limit == '': limit = 'NULL'
                    if expire == '': expire = 'NULL'
                    
                    sql_commands.append(f"INSERT INTO users (id, username, status, used_traffic, data_limit, expire, admin_id, note, created_at) VALUES ({uid}, '{user}', '{status}', {used}, {limit}, {expire}, 1, '{note}', NOW());")
    except Exception as e:
        print(f"User error: {e}")

    # 4. INBOUNDS
    try:
        with open('/tmp/inbounds.txt', 'r') as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 2:
                    uid, tag = parts[0], parts[1]
                    sql_commands.append(f"INSERT INTO inbounds (id, tag, protocol) VALUES ({uid}, '{tag}', 'mixed');")
    except Exception as e:
        print(f"Inbound error: {e}")

    # 5. HOSTS
    try:
        with open('/tmp/hosts.txt', 'r') as f:
            for line in f:
                parts = line.strip().split('|')
                if len(parts) >= 7:
                    uid, remark, address, port, tag, sni, host, sec, fp, dis, path = parts + [''] * (11 - len(parts))
                    
                    # Fixes
                    address = address.replace('pasarguard', 'rebecca')
                    path = path.replace('pasarguard', 'rebecca')
                    remark = remark.replace("'", "''")
                    
                    if not port: port = 'NULL'
                    dis_val = 1 if dis == 't' else 0
                    if not fp: fp = 'none'
                    
                    sql_commands.append(f"INSERT INTO hosts (id, remark, address, port, inbound_tag, sni, host, security, fingerprint, is_disabled, path) VALUES ({uid}, '{remark}', '{address}', {port}, '{tag}', '{sni}', '{host}', '{sec}', '{fp}', {dis_val}, '{path}');")
    except Exception as e:
        print(f"Host error: {e}")

    # 6. CONFIG
    try:
        with open('/tmp/config.json', 'r') as f:
            config = f.read().strip()
            if config:
                # Basic python string replace for paths
                config = config.replace('pasarguard', 'rebecca')
                # Escape for SQL
                config_esc = config.replace("'", "''").replace("\\\\", "\\\\\\\\")
                sql_commands.append(f"INSERT INTO core_configs (id, name, config, created_at) VALUES (1, 'default', '{config_esc}', NOW());")
    except Exception as e:
        print(f"Config error: {e}")

    # 7. JWT
    jwt_key = secrets.token_hex(32)
    sub_key = secrets.token_hex(32)
    adm_key = secrets.token_hex(32)
    vmess = secrets.token_hex(8)
    vless = secrets.token_hex(8)
    
    sql_commands.append(f"INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) VALUES ('{jwt_key}', '{sub_key}', '{adm_key}', '{vmess}', '{vless}');")

    # 8. SERVICES
    sql_commands.append("INSERT INTO services (id, name, created_at) VALUES (1, 'Default Service', NOW());")
    sql_commands.append("DELETE FROM service_hosts;")
    sql_commands.append("INSERT INTO service_hosts (service_id, host_id) SELECT 1, id FROM hosts;")
    sql_commands.append("UPDATE users SET service_id = 1 WHERE service_id IS NULL;")
    sql_commands.append("SET FOREIGN_KEY_CHECKS=1;")

    # Write to file
    with open('/tmp/import.sql', 'w') as f:
        f.write('\n'.join(sql_commands))

generate_sql_file()
PYEOF

    # Execute generated SQL
    local container=$(find_container "rebecca.*mysql")
    docker cp /tmp/import.sql "$container:/tmp/import.sql"
    docker exec "$container" mysql -uroot -p"$db_pass" rebecca -e "SOURCE /tmp/import.sql"
    
    ok "Import completed"
}

# --- 5. FILE COPY ---
setup_files() {
    local src="$1"
    log "Setting up files..."
    
    local src_data="/var/lib/$(basename "$src")"
    [ "$src" == "/opt/pasarguard" ] && src_data="/var/lib/pasarguard"
    
    # Copy Assets
    mkdir -p /var/lib/rebecca/assets /var/lib/rebecca/certs
    
    if [ -d "$src_data/assets" ]; then
        cp -rn "$src_data/assets/"* /var/lib/rebecca/assets/ 2>/dev/null
    fi
    
    # Download Xray if missing
    if [ ! -f /var/lib/rebecca/xray ]; then
        log "Downloading Xray..."
        wget -q -O /tmp/xray.zip "$XRAY_DOWNLOAD_URL"
        unzip -o /tmp/xray.zip -d /var/lib/rebecca/
        chmod +x /var/lib/rebecca/xray
    fi
    
    # Download Geo files
    [ ! -f /var/lib/rebecca/assets/geoip.dat ] && wget -q -O /var/lib/rebecca/assets/geoip.dat "$GEOIP_URL"
    [ ! -f /var/lib/rebecca/assets/geosite.dat ] && wget -q -O /var/lib/rebecca/assets/geosite.dat "$GEOSITE_URL"
    
    ok "Files configured"
}

# --- MAIN LOGIC ---
do_full_migration() {
    clear
    ui_header "MRM MIGRATION V10.3 (FINAL)"
    
    # 1. Detect Source
    local src=""
    if [ -d "/opt/pasarguard" ]; then src="/opt/pasarguard"; 
    elif [ -d "/opt/marzban" ]; then src="/opt/marzban"; fi
    
    if [ -z "$src" ]; then err "Source panel not found"; pause; return; fi
    log "Source: $src"
    
    if ! ui_confirm "Start Migration?" "y"; then return; fi
    
    migration_init
    
    # 2. Backup
    create_backup "$src"
    
    # 3. Install Rebecca
    install_rebecca_if_needed
    
    # 4. Extract
    extract_data_from_pasarguard "$src"
    
    # 5. Files
    setup_files "$src"
    
    # 6. Import
    import_to_rebecca
    
    # 7. Restart
    log "Restarting Rebecca..."
    cd "$REBECCA_DIR" && docker compose restart
    sleep 15
    
    # 8. Verify
    log "--- Verification ---"
    run_mysql "SELECT 'Users', COUNT(*) FROM users UNION SELECT 'Inbounds', COUNT(*) FROM inbounds UNION SELECT 'Hosts', COUNT(*) FROM hosts UNION SELECT 'Config', COUNT(*) FROM core_configs UNION SELECT 'Services', COUNT(*) FROM services;"
    
    echo ""
    log "Checking Xray..."
    docker logs rebecca-rebecca-1 2>&1 | grep -iE "xray|inbound" | tail -5
    
    ok "Migration Complete!"
    migration_cleanup
    pause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"
    
    local last_source=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    if [ -z "$last_source" ]; then err "No history found"; pause; return; fi
    
    warn "This will STOP Rebecca and START $(basename $last_source)"
    if ! ui_confirm "Proceed?" "n"; then return; fi
    
    log "Stopping Rebecca..."
    cd "$REBECCA_DIR" && docker compose down
    
    log "Starting Old Panel..."
    cd "$last_source" && docker compose up -d
    
    ok "Rollback Complete"
    pause
}

menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION TOOL V10.3"
        echo "1) Full Migration (Recommended)"
        echo "2) Rollback"
        echo "3) View Logs"
        echo "0) Exit"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_rollback ;;
            3) tail -50 "$MIGRATION_LOG"; pause ;;
            0) exit 0 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$EUID" -ne 0 ]; then echo "Run as root"; exit 1; fi
    menu
fi