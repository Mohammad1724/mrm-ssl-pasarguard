#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V9.1 (Final: JWT DB Patch)
#==============================================================================

# Load Utils & UI
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
source /opt/mrm-manager/ui.sh

# --- CONFIGURATION ---
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""

REBECCA_INSTALL_CMD="bash -c \"\$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)\" @ install --database mysql"

# --- HELPER FUNCTIONS ---

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-migration-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null
    echo "=== Migration Started: $(date) ===" >> "$MIGRATION_LOG"
}

migration_cleanup() { [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null; }
mlog()   { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG"; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; echo -e "${YELLOW}Press any key to continue...${NC}"; read -n 1 -s -r; echo ""; }

detect_source_panel() {
    if [ -d "/opt/pasarguard" ] && [ -f "/opt/pasarguard/.env" ]; then echo "/opt/pasarguard"; return 0; fi
    if [ -d "/opt/marzban" ] && [ -f "/opt/marzban/.env" ]; then echo "/opt/marzban"; return 0; fi
    return 1
}

# --- DATABASE HELPERS ---

find_db_container() {
    local panel_dir="$1" type="$2"
    local keywords=""
    [ "$type" == "postgresql" ] && keywords="timescale|postgres|db"
    [ "$type" == "mysql" ] && keywords="mysql|mariadb|db"
    local cname=$(cd "$panel_dir" && docker compose ps --format '{{.Names}}' 2>/dev/null | grep -iE "$keywords" | head -1)
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename $panel_dir).*($keywords)" | head -1)
    echo "$cname"
}

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    MIG_DB_USER=""; MIG_DB_PASS=""; MIG_DB_NAME=""
    local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    try:
        scheme, rest = url.split('://', 1)
        if '+' in scheme: scheme = scheme.split('+', 1)[0]
        p = urlparse(scheme + '://' + rest)
        print(f'MIG_DB_USER="{p.username or ""}"')
        print(f'MIG_DB_PASS="{unquote(p.password or "")}"')
        print(f'MIG_DB_NAME="{(p.path or "").lstrip("/")}"')
    except: pass
PYEOF
)"
}

detect_db_type() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    local data_dir="/var/lib/$(basename "$panel_dir")"
    [ "$panel_dir" == "/opt/pasarguard" ] && data_dir="/var/lib/pasarguard"
    if [ -f "$env_file" ]; then
        local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        case "$db_url" in
            *postgresql*) echo "postgresql" ;;
            *mysql*) echo "mysql" ;;
            *sqlite*) echo "sqlite" ;;
            *) if [ -f "$data_dir/db.sqlite3" ]; then echo "sqlite"; else echo "unknown"; fi ;;
        esac
    else
        if [ -f "$data_dir/db.sqlite3" ]; then echo "sqlite"; else echo "unknown"; fi
    fi
}

install_rebecca_wizard() {
    clear; ui_header "INSTALLING REBECCA"
    if ! ui_confirm "Proceed?" "y"; then return 1; fi
    eval "$REBECCA_INSTALL_CMD"
    if [ -d "/opt/rebecca" ]; then
        mok "Rebecca Installation Verified."
        return 0
    else
        merr "Installation failed."
        return 1
    fi
}

create_backup() {
    local SRC="$1"
    local DATA_DIR="/var/lib/$(basename "$SRC")"
    [ "$SRC" == "/opt/pasarguard" ] && DATA_DIR="/var/lib/pasarguard"
    minfo "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_BACKUP"
    echo "$CURRENT_BACKUP" > "$BACKUP_ROOT/.last_backup"
    echo "$SRC" > "$BACKUP_ROOT/.last_source"
    tar --exclude='*/node_modules' --exclude='mysql' --exclude='postgres' -C "$(dirname "$SRC")" -czf "$CURRENT_BACKUP/config.tar.gz" "$(basename "$SRC")" 2>/dev/null
    tar --exclude='mysql' --exclude='postgres' -C "$(dirname "$DATA_DIR")" -czf "$CURRENT_BACKUP/data.tar.gz" "$(basename "$DATA_DIR")" 2>/dev/null
    local db_type=$(detect_db_type "$SRC")
    echo "$db_type" > "$CURRENT_BACKUP/db_type.txt"
    local out="$CURRENT_BACKUP/database.sql"
    case "$db_type" in
        sqlite) cp "$DATA_DIR/db.sqlite3" "$CURRENT_BACKUP/database.sqlite3"; mok "SQLite exported" ;;
        postgresql)
            local cname=$(find_db_container "$SRC" "postgresql")
            get_db_credentials "$SRC"
            docker exec "$cname" pg_dump -U "${MIG_DB_USER:-pasarguard}" -d "${MIG_DB_NAME:-pasarguard}" --data-only --column-inserts --disable-dollar-quoting > "$out" 2>/dev/null
            [ -s "$out" ] && mok "Postgres exported" || merr "pg_dump failed"
            ;;
        mysql)
            local cname=$(find_db_container "$SRC" "mysql")
            get_db_credentials "$SRC"
            docker exec "$cname" mysqldump -u"${MIG_DB_USER:-root}" -p"$MIG_DB_PASS" --single-transaction "${MIG_DB_NAME:-marzban}" > "$out" 2>/dev/null
            [ -s "$out" ] && mok "MySQL exported" || merr "mysqldump failed"
            ;;
    esac
}

convert_to_mysql() {
    local src="$1" dst="$2" type="$3"
    minfo "Converting $type → MySQL..."
    if [ "$type" == "sqlite" ] && [[ "$src" == *.sqlite3 ]]; then
        sqlite3 "$src" .dump > "$MIGRATION_TEMP/sqlite.sql"
        src="$MIGRATION_TEMP/sqlite.sql"
    fi
    python3 - "$src" "$dst" << 'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8', errors='replace') as f: lines = f.readlines()
out = []
header = "SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\nSET SQL_MODE='NO_AUTO_VALUE_ON_ZERO,NO_BACKSLASH_ESCAPES';\n\n"
for line in lines:
    l = line.strip()
    if l.startswith(('PRAGMA', 'BEGIN TRANSACTION', 'COMMIT', 'SET', '\\', '--')): continue
    if re.match(r'^SELECT\s+(pg_catalog|setval)', l, re.I): continue
    line = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bBOOLEAN\b', 'TINYINT(1)', line, flags=re.I)
    line = line.replace("'t'", "1").replace("'f'", "0")
    line = re.sub(r"'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?\+00'", r"'\1'", line)
    line = line.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    line = line.replace('/opt/pasarguard', '/opt/rebecca')
    if re.match(r'^\s*INSERT\s+INTO\b', line, re.I):
        line = re.sub(r'^\s*INSERT\s+INTO', 'REPLACE INTO', line, flags=re.I)
        line = re.sub(r'public\."?(\w+)"?', r'`\1`', line)
        line = re.sub(r'"?(\w+)"?', r'`\1`', line)
        line = line.replace('\\', '\\\\')
    out.append(line)
with open(dst, 'w', encoding='utf-8') as f:
    f.write(header + "".join(out) + "\nSET FOREIGN_KEY_CHECKS=1;\n")
PYEOF
    [ -s "$dst" ] && mok "Converted" || merr "Conversion failed"
}

# --- SMART ENV READER ---
read_var() {
    local key="$1"
    local file="$2"
    grep -E "^\s*${key}\s*=" "$file" | head -1 | sed -E "s/^\s*${key}\s*=\s*//g" | sed -E 's/^"//;s/"$//;s/^\x27//;s/\x27$//'
}

# --- THE FIX: CLEAN ENV CONSTRUCTION ---
generate_clean_env() {
    local src="$1"
    local tgt="$2"
    local tgt_env="$tgt/.env"
    local src_env="$src/.env"
    
    minfo "Re-generating .env (Smart Builder)..."
    
    local DB_PASS=$(read_var "MYSQL_ROOT_PASSWORD" "$tgt_env")
    if [ -z "$DB_PASS" ]; then DB_PASS="password"; fi

    local UV_PORT=$(read_var "UVICORN_PORT" "$src_env")
    [ -z "$UV_PORT" ] && UV_PORT="7431"

    local SUDO_USER=$(read_var "SUDO_USERNAME" "$src_env")
    local SUDO_PASS=$(read_var "SUDO_PASSWORD" "$src_env")
    [ -z "$SUDO_USER" ] && SUDO_USER="admin"
    [ -z "$SUDO_PASS" ] && SUDO_PASS="admin"

    local TG_TOKEN=$(read_var "BACKUP_TELEGRAM_BOT_KEY" "$src_env")
    [ -z "$TG_TOKEN" ] && TG_TOKEN=$(read_var "TELEGRAM_API_TOKEN" "$src_env")

    local TG_ADMIN=$(read_var "BACKUP_TELEGRAM_CHAT_ID" "$src_env")
    [ -z "$TG_ADMIN" ] && TG_ADMIN=$(read_var "TELEGRAM_ADMIN_ID" "$src_env")

    local SSL_CERT=$(read_var "UVICORN_SSL_CERTFILE" "$src_env")
    local SSL_KEY=$(read_var "UVICORN_SSL_KEYFILE" "$src_env")
    SSL_CERT="${SSL_CERT/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    SSL_KEY="${SSL_KEY/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    SSL_CERT="${SSL_CERT/\/opt\/pasarguard/\/opt\/rebecca}"
    SSL_KEY="${SSL_KEY/\/opt\/pasarguard/\/opt\/rebecca}"

    local TPL_DIR=$(read_var "CUSTOM_TEMPLATES_DIRECTORY" "$src_env")
    TPL_DIR="${TPL_DIR/\/var\/lib\/pasarguard/\/var\/lib\/rebecca}"
    
    local TPL_PAGE=$(read_var "SUBSCRIPTION_PAGE_TEMPLATE" "$src_env")
    local XRAY_JSON=$(read_var "XRAY_JSON" "$src_env")
    local SUB_URL=$(read_var "SUB_CONF_URL" "$src_env")

    cat > "$tgt_env" <<EOF
SQLALCHEMY_DATABASE_URL="mysql+pymysql://root:${DB_PASS}@127.0.0.1:3306/rebecca"
MYSQL_ROOT_PASSWORD="${DB_PASS}"
MYSQL_DATABASE="rebecca"
MYSQL_USER="rebecca"
MYSQL_PASSWORD="${DB_PASS}"

UVICORN_HOST="0.0.0.0"
UVICORN_PORT="${UV_PORT}"
UVICORN_SSL_CERTFILE="${SSL_CERT}"
UVICORN_SSL_KEYFILE="${SSL_KEY}"

SUDO_USERNAME="${SUDO_USER}"
SUDO_PASSWORD="${SUDO_PASS}"

TELEGRAM_API_TOKEN="${TG_TOKEN}"
TELEGRAM_ADMIN_ID="${TG_ADMIN}"

XRAY_JSON="${XRAY_JSON}"
XRAY_SUBSCRIPTION_URL_PREFIX=""
XRAY_EXECUTABLE_PATH="/var/lib/rebecca/xray"
XRAY_ASSETS_PATH="/var/lib/rebecca/assets"

CUSTOM_TEMPLATES_DIRECTORY="${TPL_DIR}"
SUBSCRIPTION_PAGE_TEMPLATE="${TPL_PAGE}"
SUB_CONF_URL="${SUB_URL}"

JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440
SECRET_KEY="$(openssl rand -hex 32)"
JWT_ACCESS_TOKEN_SECRET="$(openssl rand -hex 32)"
JWT_REFRESH_TOKEN_SECRET="$(openssl rand -hex 32)"
EOF

    mok "Env file built successfully."
    
    local SRC_DATA="/var/lib/$(basename "$src")"
    [ "$src" == "/opt/pasarguard" ] && SRC_DATA="/var/lib/pasarguard"
    local TGT_DATA="/var/lib/$(basename "$tgt")"
    
    if [ -d "$SRC_DATA/certs" ]; then
        mkdir -p "$TGT_DATA/certs"
        cp -rn "$SRC_DATA/certs/"* "$TGT_DATA/certs/" 2>/dev/null
        chmod -R 644 "$TGT_DATA/certs"/* 2>/dev/null
        find "$TGT_DATA/certs" -type d -exec chmod 755 {} + 2>/dev/null
    fi
    if [ -d "$SRC_DATA/templates" ]; then
        mkdir -p "$TGT_DATA/templates"
        cp -rn "$SRC_DATA/templates/"* "$TGT_DATA/templates/" 2>/dev/null
    fi
}

import_and_sanitize() {
    local SQL="$1" TGT="$2"
    minfo "Importing Data..."
    get_db_credentials "$TGT"
    local user="${MIG_DB_USER:-root}"
    local pass="$MIG_DB_PASS"
    [ -z "$pass" ] && pass=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2 | tr -d '"')
    
    local cname=$(find_db_container "$TGT" "mysql")
    [ -z "$cname" ] && { merr "Target MySQL not found"; return 1; }
    
    local db_list=$(docker exec "$cname" mysql -u"$user" -p"$pass" -e "SHOW DATABASES;" 2>/dev/null)
    local db="marzban"
    if [[ "$db_list" == *"rebecca"* ]]; then db="rebecca"; fi
    
    docker exec "$cname" mysql -u"$user" -p"$pass" -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4;" 2>/dev/null
    docker exec -i "$cname" mysql --binary-mode=1 -u"$user" -p"$pass" "$db" < "$SQL" 2>/dev/null
    
    run_sql() { docker exec "$cname" mysql -u"$user" -p"$pass" "$db" -e "$1" 2>/dev/null; }
    
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS is_sudo TINYINT(1) DEFAULT 0;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS is_disabled TINYINT(1) DEFAULT 0;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS permissions JSON;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS data_limit BIGINT DEFAULT 0;"
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS users_limit INT DEFAULT 0;"
    
    minfo "Sanitizing Data..."
    run_sql "UPDATE admins SET permissions='[]' WHERE permissions IS NULL;"
    run_sql "UPDATE admins SET data_limit=0 WHERE data_limit IS NULL;"
    run_sql "UPDATE admins SET users_limit=0 WHERE users_limit IS NULL;"
    run_sql "UPDATE admins SET is_sudo=1 WHERE is_sudo IS NULL;"
    run_sql "UPDATE admins SET is_disabled=0 WHERE is_disabled IS NULL;"
    run_sql "UPDATE nodes SET server_ca = REPLACE(server_ca, '/var/lib/pasarguard', '/var/lib/rebecca');"
    run_sql "UPDATE core_configs SET config = REPLACE(config, '/var/lib/pasarguard', '/var/lib/rebecca');"
    
    # --- JWT FIX: PATCH DB INSTEAD OF TRUNCATE ---
    minfo "Patching JWT table (Fixing Null Secrets)..."
    local JWT_SECRET="$(openssl rand -hex 64)"
    local SUB_SECRET="$(openssl rand -hex 64)"
    local ADMIN_SECRET="$(openssl rand -hex 64)"
    local VMESS_MASK="$(openssl rand -hex 16)"
    local VLESS_MASK="$(openssl rand -hex 16)"

    # Fill NULL secrets
    run_sql "UPDATE jwt SET secret_key='${JWT_SECRET}' WHERE secret_key IS NULL;"
    
    # Insert fresh row if empty
    run_sql "INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) SELECT '${JWT_SECRET}', '${SUB_SECRET}', '${ADMIN_SECRET}', '${VMESS_MASK}', '${VLESS_MASK}' WHERE NOT EXISTS (SELECT 1 FROM jwt);"

    mok "Data Sanitized & Fixed."
}

create_rescue_admin() {
    echo ""; echo -e "${YELLOW}Create new SuperAdmin? (Recommended)${NC}"
    if ui_confirm "Create?" "y"; then
        local cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename $TGT).*(panel|rebecca|marzban)" | head -1)
        docker exec -it "$cname" rebecca-cli admin create
    fi
}

do_full_migration() {
    migration_init; clear
    ui_header "UNIVERSAL MIGRATION V9.1 (FINAL)"
    SRC=$(detect_source_panel)
    if [ -d "/opt/rebecca" ]; then
        TGT="/opt/rebecca"
    elif [ -d "/opt/marzban" ]; then
        TGT="/opt/marzban"
    else
        if ! install_rebecca_wizard; then mpause; return; fi
        TGT="/opt/rebecca"
    fi
    [ -z "$SRC" ] && { merr "Source not found"; mpause; return; }
    echo -e "Source: ${RED}$SRC${NC}"
    echo -e "Target: ${GREEN}$TGT${NC}"
    if ! ui_confirm "Start Migration?" "y"; then return; fi

    create_backup "$SRC"
    local db_type=$(cat "$CURRENT_BACKUP/db_type.txt")
    local src_sql="$CURRENT_BACKUP/database.sql"
    [ "$db_type" == "sqlite" ] && src_sql="$CURRENT_BACKUP/database.sqlite3"
    local final_sql="$MIGRATION_TEMP/import.sql"
    convert_to_mysql "$src_sql" "$final_sql" "$db_type" || return

    minfo "Stopping panels..."
    docker ps -q --filter "name=pasarguard" | xargs -r docker stop
    docker ps -q --filter "name=marzban" | xargs -r docker stop
    (cd "$SRC" && docker compose down) &>/dev/null
    (cd "$TGT" && docker compose down) &>/dev/null

    generate_clean_env "$SRC" "$TGT"

    minfo "Starting Target Panel..."
    (cd "$TGT" && docker compose up -d --force-recreate); sleep 20

    import_and_sanitize "$final_sql" "$TGT"

    ui_header "FINAL RESTART"
    (cd "$TGT" && docker compose down && docker compose up -d --force-recreate)

    sleep 10
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename $TGT).*(panel|rebecca|marzban)" | head -1)
    if [ -n "$cname" ]; then mok "Panel Running: $cname"; fi

    echo -e "\n${GREEN}MIGRATION COMPLETED!${NC}"
    create_rescue_admin
    migration_cleanup; mpause
}

do_rollback() {
    clear; ui_header "ROLLBACK"
    local last=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)
    local src_path=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    [ -z "$src_path" ] && src_path="/opt/pasarguard"
    [ -z "$last" ] && { merr "No history found"; mpause; return; }
    if ui_confirm "Restore $last to $src_path?" "n"; then
        if [ -d "/opt/rebecca" ]; then (cd /opt/rebecca && docker compose down) &>/dev/null; fi
        local PID=$(lsof -t -i:7431 2>/dev/null); [ ! -z "$PID" ] && kill -9 $PID
        mkdir -p "$(dirname "$src_path")"
        tar -xzf "$last/config.tar.gz" -C "$(dirname "$src_path")"
        tar -xzf "$last/data.tar.gz" -C "/var/lib"
        (cd "$src_path" && docker compose up -d) &>/dev/null
        mok "Rollback Complete."
    fi
    mpause
}

migrator_menu() {
    while true; do
        clear; ui_header "MIGRATION MENU"
        echo "1) Auto Migrate (Full Fix)"
        echo "2) Rollback"
        echo "3) Logs"
        echo "0) Back"
        read -p "Select: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_rollback ;;
            3) tail -50 "$MIGRATION_LOG"; mpause ;;
            0) return ;;
        esac
    done
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && migrator_menu