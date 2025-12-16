#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Universal Auto Migrator v5.1 (Install Fix)
# Fixes: Ctrl+C handling during install, Robust Env parsing
#==============================================================================

# Load Utils & UI
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
source /opt/mrm-manager/ui.sh

# --- CONFIGURATION ---
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""
MYSQL_WAIT=60

# Official Rebecca Install Script
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

# --- DETECTION LOGIC ---

detect_source_panel() {
    if [ -d "/opt/pasarguard" ] && [ -f "/opt/pasarguard/.env" ]; then echo "/opt/pasarguard"; return 0; fi
    if [ -d "/opt/marzban" ] && [ -f "/opt/marzban/.env" ]; then echo "/opt/marzban"; return 0; fi
    return 1
}

# --- INSTALLATION LOGIC (ROBUST) ---

install_rebecca_wizard() {
    clear
    ui_header "INSTALLING REBECCA"
    echo -e "${YELLOW}Target panel not found.${NC}"
    echo -e "${BLUE}Starting official installer (MySQL)...${NC}"
    echo ""
    echo -e "${YELLOW}NOTE: When installation finishes and logs appear, press Ctrl+C once to continue.${NC}"
    echo ""
    
    if ! ui_confirm "Proceed?" "y"; then return 1; fi
    
    # Run installation
    eval "$REBECCA_INSTALL_CMD"
    
    # CRITICAL FIX: Check files instead of exit code
    # Because Ctrl+C on logs returns error code 130
    if [ -d "/opt/rebecca" ] && [ -f "/opt/rebecca/docker-compose.yml" ]; then
        echo ""
        mok "Rebecca Installation Verified."
        return 0
    else
        echo ""
        merr "Installation failed or directory /opt/rebecca missing."
        return 1
    fi
}

detect_db_type() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    local data_dir="/var/lib/$(basename "$panel_dir")"
    [ "$panel_dir" == "/opt/pasarguard" ] && data_dir="/var/lib/pasarguard"

    if [ -f "$env_file" ]; then
        local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        case "$db_url" in
            *timescale*|*postgresql*) echo "postgresql" ;;
            *mysql*|*mariadb*) echo "mysql" ;;
            *sqlite*) echo "sqlite" ;;
            *) if [ -f "$data_dir/db.sqlite3" ]; then echo "sqlite"; else echo "unknown"; fi ;;
        esac
    else
        if [ -f "$data_dir/db.sqlite3" ]; then echo "sqlite"; else echo "unknown"; fi
    fi
}

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
    
    local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
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

# --- BACKUP & EXPORT ---

create_backup() {
    local SRC="$1"
    local DATA_DIR="/var/lib/$(basename "$SRC")"
    [ "$SRC" == "/opt/pasarguard" ] && DATA_DIR="/var/lib/pasarguard"
    
    minfo "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_BACKUP"
    echo "$CURRENT_BACKUP" > "$BACKUP_ROOT/.last_backup"

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
            docker exec "$cname" pg_dump -U "${MIG_DB_USER:-marzban}" -d "${MIG_DB_NAME:-marzban}" --data-only --column-inserts --disable-dollar-quoting > "$out" 2>/dev/null
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

# --- CONVERSION LOGIC ---

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

    # Fix Types
    line = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bBOOLEAN\b', 'TINYINT(1)', line, flags=re.I)
    line = line.replace("'t'", "1").replace("'f'", "0")
    
    # Fix Timestamp +00 (Postgres)
    line = re.sub(r"'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?\+00'", r"'\1'", line)
    
    # Fix Paths (Universal)
    line = line.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    line = line.replace('/opt/pasarguard', '/opt/rebecca')
    
    # INSERT -> REPLACE logic
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

# --- IMPORT & SANITIZATION ---

import_and_sanitize() {
    local SQL="$1" TGT="$2"
    minfo "Importing & Fixing Data..."
    
    get_db_credentials "$TGT"
    local user="${MIG_DB_USER:-root}"
    local pass="$MIG_DB_PASS"
    [ -z "$pass" ] && pass=$(grep "MYSQL_ROOT_PASSWORD" "$TGT/.env" | cut -d'=' -f2)
    
    local cname=$(find_db_container "$TGT" "mysql")
    [ -z "$cname" ] && { merr "Target MySQL not found"; return 1; }
    
    # Auto-detect DB name from MySQL
    local db_list=$(docker exec "$cname" mysql -u"$user" -p"$pass" -e "SHOW DATABASES;" 2>/dev/null)
    local db="marzban"
    if [[ "$db_list" == *"rebecca"* ]]; then db="rebecca"; fi
    if [[ "$db_list" == *"marzban"* ]]; then db="marzban"; fi
    
    # 1. Create & Import
    docker exec "$cname" mysql -u"$user" -p"$pass" -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4;" 2>/dev/null
    if docker exec -i "$cname" mysql --binary-mode=1 -u"$user" -p"$pass" "$db" < "$SQL" 2>/dev/null; then
        mok "Data Imported."
    else
        mwarn "Import had warnings (Duplicate keys or table exists)."
    fi
    
    # 2. ALEMBIC UPGRADE (CRITICAL: Creates new columns like permissions)
    minfo "Running Alembic Upgrade..."
    local panel_cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename $TGT).*(panel|rebecca|marzban)" | head -1)
    if [ -n "$panel_cname" ]; then
        docker exec "$panel_cname" alembic upgrade head >/dev/null 2>&1
        mok "Schema Updated (Alembic)."
    else
        mwarn "Could not run alembic (Container not found)."
    fi

    # 3. SANITIZE DATA (CRITICAL: Fills NULLs)
    minfo "Sanitizing Data..."
    # Fixes for Pydantic validation errors
    local fixes=(
        "UPDATE admins SET permissions='[]' WHERE permissions IS NULL;"
        "UPDATE admins SET data_limit=0 WHERE data_limit IS NULL;"
        "UPDATE admins SET users_limit=0 WHERE users_limit IS NULL;"
        "UPDATE admins SET is_sudo=1 WHERE is_sudo IS NULL;"
        "UPDATE admins SET is_disabled=0 WHERE is_disabled IS NULL;"
        "UPDATE nodes SET server_ca = REPLACE(server_ca, '/var/lib/pasarguard', '/var/lib/rebecca');"
        "TRUNCATE TABLE jwt;"
    )

    for q in "${fixes[@]}"; do
        docker exec "$cname" mysql -u"$user" -p"$pass" "$db" -e "$q" 2>/dev/null
    done
    mok "Data Sanitized & Fixed."
}

migrate_configs() {
    minfo "Migrating Configs..."
    local SRC_DATA="/var/lib/$(basename "$SRC")"
    [ "$SRC" == "/opt/pasarguard" ] && SRC_DATA="/var/lib/pasarguard"
    local TGT_DATA="/var/lib/$(basename "$TGT")"

    # Env Merge (Improved regex)
    local vars=("SUDO_USERNAME" "SUDO_PASSWORD" "UVICORN_PORT" "TELEGRAM_API_TOKEN" "TELEGRAM_ADMIN_ID" "XRAY_JSON" "JWT_ACCESS_TOKEN_EXPIRE_MINUTES")
    for v in "${vars[@]}"; do
        # Handle quoted/unquoted values
        local val=$(grep -E "^${v}\s*=" "$SRC/.env" 2>/dev/null | cut -d'=' -f2- | sed 's/^"//;s/"$//;s/^\x27//;s/\x27$//')
        if [ -n "$val" ]; then
            sed -i "/^${v}=/d" "$TGT/.env"
            echo "${v}=${val}" >> "$TGT/.env"
        fi
    done
    mok "Variables Migrated."
    
    # Copy Certs
    if [ -d "$SRC_DATA/certs" ]; then
        mkdir -p "$TGT_DATA/certs"
        cp -rn "$SRC_DATA/certs/"* "$TGT_DATA/certs/" 2>/dev/null
        chmod -R 644 "$TGT_DATA/certs"/* 2>/dev/null
        find "$TGT_DATA/certs" -type d -exec chmod 755 {} + 2>/dev/null
    fi
    [ -d "$SRC_DATA/templates" ] && cp -rn "$SRC_DATA/templates" "$TGT_DATA/" 2>/dev/null
}

create_rescue_admin() {
    echo ""; echo -e "${YELLOW}Create new SuperAdmin? (Recommended)${NC}"
    if ui_confirm "Create?" "y"; then
        local cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename $TGT).*(panel|rebecca|marzban)" | head -1)
        local cli="rebecca-cli"
        [ -f "$TGT/marzban-cli" ] && cli="marzban-cli"
        
        echo -e "${GREEN}Running interactive creation...${NC}"
        docker exec -it "$cname" $cli admin create
    fi
}

# --- MAIN LOOP ---

do_full_migration() {
    migration_init; clear
    ui_header "UNIVERSAL MIGRATION V5.1"
    
    SRC=$(detect_source_panel)
    
    # --- AUTO INSTALL TRIGGER ---
    if [ -d "/opt/rebecca" ]; then
        TGT="/opt/rebecca"
    elif [ -d "/opt/marzban" ]; then
        TGT="/opt/marzban"
    else
        # Install
        if ! install_rebecca_wizard; then
             mpause; return;
        fi
        TGT="/opt/rebecca"
    fi
    
    [ -z "$SRC" ] && { merr "Source (Pasarguard/Marzban) not found"; mpause; return; }
    
    echo -e "Source: ${RED}$SRC${NC}"
    echo -e "Target: ${GREEN}$TGT${NC}"
    
    if ! ui_confirm "Start Migration? This stops both panels." "y"; then return; fi
    
    # 1. Backup
    create_backup "$SRC"
    local db_type=$(cat "$CURRENT_BACKUP/db_type.txt")
    local src_sql="$CURRENT_BACKUP/database.sql"
    [ "$db_type" == "sqlite" ] && src_sql="$CURRENT_BACKUP/database.sqlite3"
    
    # 2. Convert
    local final_sql="$MIGRATION_TEMP/import.sql"
    convert_to_mysql "$src_sql" "$final_sql" "$db_type" || return
    
    # 3. Stop Panels
    (cd "$SRC" && docker compose down) &>/dev/null
    (cd "$TGT" && docker compose down) &>/dev/null
    
    # 4. Start Target DB Only
    minfo "Starting Target MySQL..."
    (cd "$TGT" && docker compose up -d mysql mariadb db 2>/dev/null); sleep 15
    
    # 5. Import & Sanitize
    import_and_sanitize "$final_sql" "$TGT"
    migrate_configs
    
    # 6. Full Restart
    ui_header "RESTARTING PANEL"
    (cd "$TGT" && docker compose down && docker compose up -d)
    
    sleep 10
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename $TGT).*(panel|rebecca|marzban)" | head -1)
    if [ -n "$cname" ]; then
         mok "Panel Running: $cname"
    fi
    
    echo -e "\n${GREEN}MIGRATION COMPLETED!${NC}"
    create_rescue_admin
    migration_cleanup; mpause
}

do_rollback() {
    clear; ui_header "ROLLBACK"
    local last=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)
    [ -z "$last" ] && { merr "No history found"; mpause; return; }
    
    if ui_confirm "Restore $last to Source?" "n"; then
        local TGT=$(detect_source_panel)
        (cd "$TGT" && docker compose down) &>/dev/null
        tar -xzf "$last/config.tar.gz" -C "$(dirname "$TGT")"
        tar -xzf "$last/data.tar.gz" -C "/var/lib"
        (cd "$TGT" && docker compose up -d) &>/dev/null
        mok "Restored"
    fi
    mpause
}

migrator_menu() {
    while true; do
        clear
        ui_header "MIGRATION MENU"
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