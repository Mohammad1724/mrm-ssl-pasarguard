#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 9.7 (Final Fix: PostgreSQL Multiline Cleanup)
#==============================================================================

#==============================================================================
# CONFIGURATION
#==============================================================================

PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""
CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#==============================================================================
# HELPERS
#==============================================================================

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-migration-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null || MIGRATION_LOG="/tmp/mrm_migration.log"
    echo "" >> "$MIGRATION_LOG"
    echo "=== Migration: $(date) ===" >> "$MIGRATION_LOG"
}

migration_cleanup() {
    [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null
}

mlog() { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG"; }
minfo() { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok() { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn() { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr() { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }

mpause() {
    echo ""
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo ""
}

#==============================================================================
# DATABASE DETECTION
#==============================================================================

detect_migration_db_type() {
    local panel_dir="$1" data_dir="$2"
    [ ! -d "$panel_dir" ] && { echo "not_found"; return 1; }
    
    local env_file="$panel_dir/.env"
    if [ -f "$env_file" ]; then
        local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')
        case "$db_url" in
            *timescale*|*postgresql+asyncpg*) echo "timescaledb"; return 0 ;;
            *postgresql*) echo "postgresql"; return 0 ;;
            *mysql+asyncmy*|*mysql*) echo "mysql"; return 0 ;;
            *mariadb*) echo "mariadb"; return 0 ;;
            *sqlite*) echo "sqlite"; return 0 ;;
        esac
    fi
    [ -f "$data_dir/db.sqlite3" ] && { echo "sqlite"; return 0; }
    echo "unknown"; return 1
}

get_migration_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    MIG_DB_USER=""; MIG_DB_PASS=""; MIG_DB_HOST=""; MIG_DB_PORT=""; MIG_DB_NAME=""
    [ ! -f "$env_file" ] && return 1
    
    local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')
    
    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    scheme, rest = url.split('://', 1)
    if '+' in scheme: scheme = scheme.split('+', 1)[0]
    url = scheme + '://' + rest
    p = urlparse(url)
    print(f'MIG_DB_USER="{p.username or ""}"')
    print(f'MIG_DB_PASS="{unquote(p.password or "")}"')
    print(f'MIG_DB_HOST="{p.hostname or "localhost"}"')
    print(f'MIG_DB_PORT="{p.port or ""}"')
    print(f'MIG_DB_NAME="{(p.path or "").lstrip("/") or "pasarguard"}"')
else:
    print('MIG_DB_USER=""'); print('MIG_DB_PASS=""'); print('MIG_DB_HOST="localhost"'); print('MIG_DB_PORT=""'); print('MIG_DB_NAME="pasarguard"')
PYEOF
)"
}

#==============================================================================
# CONTAINER MANAGEMENT
#==============================================================================

find_migration_pg_container() {
    local cname=""
    for svc in timescaledb db postgres postgresql database; do
        cname=$(cd "$PASARGUARD_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done
    cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(timescale|postgres|db)" | head -1)
    [ -n "$cname" ] && echo "$cname"
}

find_migration_mysql_container() {
    local cname=""
    for svc in mysql mariadb db database; do
        cname=$(cd "$REBECCA_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done
    cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb|db)" | head -1)
    [ -n "$cname" ] && echo "$cname"
}

is_migration_running() {
    [ -d "$1" ] && (cd "$1" && docker compose ps 2>/dev/null | grep -qE "Up|running")
}

start_migration_panel() {
    local dir="$1" name="$2"
    minfo "Starting $name..."
    [ ! -d "$dir" ] && { merr "$dir not found"; return 1; }
    (cd "$dir" && docker compose up -d) &>/dev/null
    local i=0
    while [ $i -lt $CONTAINER_TIMEOUT ]; do
        is_migration_running "$dir" && { mok "$name started"; sleep 3; return 0; }
        sleep 3; i=$((i+3))
    done
    merr "$name failed to start"; return 1
}

stop_migration_panel() {
    local dir="$1" name="$2"
    [ ! -d "$dir" ] && return 0
    minfo "Stopping $name..."
    (cd "$dir" && docker compose down) &>/dev/null
    sleep 2
    mok "$name stopped"
}

#==============================================================================
# BACKUP
#==============================================================================

create_migration_backup() {
    minfo "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_MIGRATION_BACKUP="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_MIGRATION_BACKUP"
    echo "$CURRENT_MIGRATION_BACKUP" > "$BACKUP_ROOT/.last_backup"

    if [ -d "$PASARGUARD_DIR" ]; then
        minfo "  Backing up config..."
        tar --exclude='*/node_modules' -C "$(dirname "$PASARGUARD_DIR")" \
            -czf "$CURRENT_MIGRATION_BACKUP/pasarguard_config.tar.gz" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        mok "  Config saved"
    fi

    if [ -d "$PASARGUARD_DATA" ]; then
        minfo "  Backing up data..."
        tar -C "$(dirname "$PASARGUARD_DATA")" \
            -czf "$CURRENT_MIGRATION_BACKUP/pasarguard_data.tar.gz" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        mok "  Data saved"
    fi

    local db_type=$(detect_migration_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$CURRENT_MIGRATION_BACKUP/db_type.txt"
    minfo "  Exporting database ($db_type)..."

    local export_success=false
    case "$db_type" in
        sqlite)
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                cp "$PASARGUARD_DATA/db.sqlite3" "$CURRENT_MIGRATION_BACKUP/database.sqlite3"
                mok "  SQLite exported"
                export_success=true
            fi
            ;;
        timescaledb|postgresql)
            export_migration_postgresql "$CURRENT_MIGRATION_BACKUP/database.sql" && export_success=true
            ;;
        mysql|mariadb)
            export_migration_mysql "$CURRENT_MIGRATION_BACKUP/database.sql" && export_success=true
            ;;
    esac

    cat > "$CURRENT_MIGRATION_BACKUP/info.txt" << EOF
Date: $(date)
Host: $(hostname)
Database: $db_type
Export: $export_success
EOF

    mok "Backup: $CURRENT_MIGRATION_BACKUP"
    [ "$export_success" = true ]
}

export_migration_postgresql() {
    local output_file="$1"
    get_migration_db_credentials "$PASARGUARD_DIR"
    local user="${MIG_DB_USER:-pasarguard}"
    local db="${MIG_DB_NAME:-pasarguard}"
    
    minfo "  User: $user, DB: $db"
    
    local cname=$(find_migration_pg_container)
    [ -z "$cname" ] && { merr "  PostgreSQL container not found!"; return 1; }
    minfo "  Container: $cname"

    local i=0
    while [ $i -lt 30 ]; do
        docker exec "$cname" pg_isready &>/dev/null && break
        sleep 2; i=$((i+2))
    done

    minfo "  Running pg_dump..."
    # Try with user (no password if trust/local)
    if docker exec "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            mok "  Exported: $size"
            return 0
        fi
    fi

    # Try with password
    if docker exec -e PGPASSWORD="$MIG_DB_PASS" "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            mok "  Exported: $size"
            return 0
        fi
    fi

    merr "  pg_dump failed"
    return 1
}

export_migration_mysql() {
    local output_file="$1"
    get_migration_db_credentials "$PASARGUARD_DIR"
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(mysql|mariadb|db)" | head -1)
    [ -z "$cname" ] && { merr "  MySQL container not found"; return 1; }
    
    if docker exec "$cname" mysqldump -u"${MIG_DB_USER:-root}" -p"$MIG_DB_PASS" --single-transaction "${MIG_DB_NAME:-pasarguard}" > "$output_file" 2>/dev/null; then
        [ -s "$output_file" ] && { mok "  Exported"; return 0; }
    fi
    merr "  mysqldump failed"; return 1
}

#==============================================================================
# CONVERSION (FIXED)
#==============================================================================

convert_migration_to_mysql() {
    local src="$1" dst="$2" type="$3"
    case "$type" in
        sqlite) convert_migration_sqlite "$src" "$dst" ;;
        postgresql|timescaledb) convert_migration_postgresql "$src" "$dst" ;;
        mysql|mariadb) cp "$src" "$dst"; mok "No conversion needed" ;;
        *) merr "Unknown: $type"; return 1 ;;
    esac
}

convert_migration_sqlite() {
    local src="$1" dst="$2"
    minfo "Converting SQLite → MySQL..."
    [ ! -f "$src" ] && { merr "Source not found"; return 1; }
    
    local dump="$MIGRATION_TEMP/sqlite_dump.sql"
    sqlite3 "$src" .dump > "$dump" 2>/dev/null || { merr "Dump failed"; return 1; }

    python3 << PYEOF
import re
with open("$dump", 'r', errors='replace') as f: c = f.read()
c = re.sub(r'BEGIN TRANSACTION;', 'START TRANSACTION;', c)
c = re.sub(r'PRAGMA.*?;\n?', '', c)
c = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', c, flags=re.I)
c = re.sub(r'\bINTEGER\b', 'INT', c, flags=re.I)
c = re.sub(r'\bREAL\b', 'DOUBLE', c, flags=re.I)
c = re.sub(r'\bBLOB\b', 'LONGBLOB', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_]\w*)"', r'\`\1\`', c)
with open("$dst", 'w') as f:
    f.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n\n" + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")
PYEOF
    [ -s "$dst" ] && { mok "Converted"; return 0; }
    merr "Conversion failed"; return 1
}

convert_migration_postgresql() {
    local src="$1" dst="$2"
    minfo "Converting PostgreSQL → MySQL..."
    [ ! -f "$src" ] && { merr "Source not found"; return 1; }

    python3 << PYEOF
import re
import sys

try:
    with open("$src", 'r', encoding='utf-8', errors='replace') as f:
        sql = f.read()

    # 1. Remove PostgreSQL specific blocks (Using DOTALL re.S)
    patterns = [
        r'CREATE SEQUENCE[^;]+;',
        r'ALTER SEQUENCE[^;]+;',
        r'ALTER TABLE\s+[\w`"]+\s+ALTER COLUMN\s+[\w`"]+\s+SET DEFAULT\s+nextval[^;]+;',
        r'CREATE TYPE[^;]+;',
        r'SELECT pg_catalog[^;]+;',
        r'SET\s+\w+[^;]+;',
        r'\\connect.*',
        r'COMMENT ON[^;]+;',
        r'CREATE EXTENSION[^;]+;',
        r'GRANT\s+[^;]+;',
        r'REVOKE\s+[^;]+;'
    ]
    
    for p in patterns:
        sql = re.sub(p, '', sql, flags=re.S|re.I)

    # 2. Clean up schemas
    sql = re.sub(r'public\.', '', sql)
    sql = re.sub(r'USING btree', '', sql, flags=re.I)

    # 3. Data Type Mapping
    types = [
        # Identity columns
        (r'\bGENERATED\s+BY\s+DEFAULT\s+AS\s+IDENTITY(\s*\(.*?\))?', 'AUTO_INCREMENT'),
        (r'\bGENERATED\s+ALWAYS\s+AS\s+IDENTITY(\s*\(.*?\))?', 'AUTO_INCREMENT'),
        # Standard types
        (r'\bSERIAL\b', 'INT AUTO_INCREMENT'),
        (r'\bBIGSERIAL\b', 'BIGINT AUTO_INCREMENT'),
        (r'\bSMALLSERIAL\b', 'SMALLINT AUTO_INCREMENT'),
        (r'\bBOOLEAN\b', 'TINYINT(1)'),
        (r'\bTIMESTAMP\s+WITH\s+TIME\s+ZONE\b', 'DATETIME'),
        (r'\bTIMESTAMP\s+WITHOUT\s+TIME\s+ZONE\b', 'DATETIME'),
        (r'\bTIMESTAMPTZ\b', 'DATETIME'),
        (r'\bJSONB\b', 'JSON'),
        (r'\bUUID\b', 'VARCHAR(36)'),
        (r'\bBYTEA\b', 'LONGBLOB'),
        (r'\bINET\b', 'VARCHAR(45)'),
        (r'\bCHARACTER\s+VARYING\b', 'VARCHAR'),
        (r'\bDOUBLE\s+PRECISION\b', 'DOUBLE')
    ]
    
    for p, r in types:
        sql = re.sub(p, r, sql, flags=re.I)

    # 4. Value corrections
    sql = re.sub(r"'t'::boolean", "'1'", sql, flags=re.I)
    sql = re.sub(r"'f'::boolean", "'0'", sql, flags=re.I)
    sql = re.sub(r'\btrue\b', '1', sql, flags=re.I)
    sql = re.sub(r'\bfalse\b', '0', sql, flags=re.I)
    sql = re.sub(r'::\w+(\[\])?', '', sql) 
    sql = re.sub(r"nextval\('[^']+'::regclass\)", 'NULL', sql, flags=re.I)

    # 5. Quotes
    sql = re.sub(r'"([a-zA-Z_][a-zA-Z0-9_]*)"', r'\`\1\`', sql)
    sql = re.sub(r'\n\s*\n\s*\n+', '\n\n', sql)

    header = "SET NAMES utf8mb4; SET FOREIGN_KEY_CHECKS=0; SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n\n"
    footer = "\n\nSET FOREIGN_KEY_CHECKS=1;"

    with open("$dst", 'w', encoding='utf-8') as f:
        f.write(header + sql + footer)
        
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYEOF
    [ -s "$dst" ] && { mok "Converted"; return 0; }
    merr "Conversion failed"; return 1
}

#==============================================================================
# REBECCA FUNCTIONS
#==============================================================================

check_migration_rebecca() { [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]; }
check_migration_rebecca_mysql() { [ -f "$REBECCA_DIR/.env" ] && grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"; }

wait_migration_mysql() {
    minfo "Waiting for MySQL..."
    local i=0
    while [ $i -lt $MYSQL_WAIT ]; do
        local cname=$(find_migration_mysql_container)
        if [ -n "$cname" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
            docker exec "$cname" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null && { mok "MySQL ready"; return 0; }
        fi
        sleep 3; i=$((i+3))
    done
    mwarn "MySQL timeout"; return 1
}

import_migration_to_rebecca() {
    local sql="$1"
    minfo "Importing to Rebecca..."
    [ ! -f "$sql" ] && { merr "SQL not found"; return 1; }

    local db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'" || echo "marzban")
    local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
    local cname=$(find_migration_mysql_container)
    
    [ -z "$cname" ] && { merr "MySQL container not found"; return 1; }
    minfo "  Container: $cname, DB: $db"

    # Drop existing DB to prevent conflicts
    docker exec "$cname" mysql -uroot -p"$pass" -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db;" 2>/dev/null
    
    if docker exec -i "$cname" mysql -uroot -p"$pass" "$db" < "$sql" 2>/dev/null; then
        mok "Import successful"
        return 0
    fi
    merr "Import failed"; return 1
}

migrate_migration_configs() {
    minfo "Migrating configs..."
    [ ! -f "$PASARGUARD_DIR/.env" ] || [ ! -f "$REBECCA_DIR/.env" ] && return 0

    local vars=("SUDO_USERNAME" "SUDO_PASSWORD" "UVICORN_PORT" "TELEGRAM_API_TOKEN" "TELEGRAM_ADMIN_ID"
                "XRAY_SUBSCRIPTION_URL_PREFIX" "WEBHOOK_ADDRESS" "WEBHOOK_SECRET")
    local n=0
    for v in "${vars[@]}"; do
        local val=$(grep "^${v}=" "$PASARGUARD_DIR/.env" 2>/dev/null | sed 's/[^=]*=//')
        if [ -n "$val" ]; then
            sed -i "/^${v}=/d" "$REBECCA_DIR/.env" 2>/dev/null
            echo "${v}=${val}" >> "$REBECCA_DIR/.env"
            n=$((n+1))
        fi
    done
    mok "Migrated $n variables"

    [ -d "$PASARGUARD_DATA/certs" ] && { mkdir -p "$REBECCA_DATA/certs"; cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null; }
    [ -f "$PASARGUARD_DATA/xray_config.json" ] && { mkdir -p "$REBECCA_DATA"; cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null; }
    [ -d "$PASARGUARD_DATA/templates" ] && { mkdir -p "$REBECCA_DATA/templates"; cp -r "$PASARGUARD_DATA/templates/"* "$REBECCA_DATA/templates/" 2>/dev/null; }
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

do_full_migration() {
    migration_init
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   PASARGUARD → REBECCA MIGRATION v9.7         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    for cmd in docker python3 sqlite3; do
        command -v "$cmd" &>/dev/null || { merr "Missing: $cmd"; mpause; return 1; }
    done
    mok "Dependencies OK"

    [ ! -d "$PASARGUARD_DIR" ] && { merr "Pasarguard not found"; mpause; return 1; }
    mok "Pasarguard found"

    local db_type=$(detect_migration_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database: ${CYAN}$db_type${NC}"

    check_migration_rebecca || { merr "Rebecca not installed"; mpause; return 1; }
    mok "Rebecca found"
    check_migration_rebecca_mysql || { merr "Rebecca needs MySQL"; mpause; return 1; }
    mok "MySQL verified"

    echo ""
    read -p "Type 'migrate' to start: " confirm
    [ "$confirm" != "migrate" ] && { minfo "Cancelled"; return 0; }

    # Step 1: Backup
    echo -e "\n${CYAN}━━━ STEP 1: BACKUP ━━━${NC}"
    is_migration_running "$PASARGUARD_DIR" || start_migration_panel "$PASARGUARD_DIR" "Pasarguard"
    create_migration_backup || { merr "Backup failed"; mpause; migration_cleanup; return 1; }
    
    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)
    [ ! -d "$backup_dir" ] && { merr "Backup dir not found"; mpause; return 1; }

    # Step 2: Verify
    echo -e "\n${CYAN}━━━ STEP 2: VERIFY ━━━${NC}"
    local src=""
    case "$db_type" in
        sqlite) src="$backup_dir/database.sqlite3" ;;
        *) src="$backup_dir/database.sql" ;;
    esac
    [ ! -s "$src" ] && { merr "Source empty: $src"; mpause; return 1; }
    mok "Source: $(du -h "$src" | cut -f1)"

    # Step 3: Convert
    echo -e "\n${CYAN}━━━ STEP 3: CONVERT ━━━${NC}"
    local mysql_sql="$MIGRATION_TEMP/mysql_import.sql"
    convert_migration_to_mysql "$src" "$mysql_sql" "$db_type" || { mpause; return 1; }
    cp "$mysql_sql" "$backup_dir/mysql_converted.sql" 2>/dev/null

    # Step 4: Stop Pasarguard
    echo -e "\n${CYAN}━━━ STEP 4: STOP PASARGUARD ━━━${NC}"
    stop_migration_panel "$PASARGUARD_DIR" "Pasarguard"

    # Step 5: Migrate configs
    echo -e "\n${CYAN}━━━ STEP 5: CONFIGS ━━━${NC}"
    migrate_migration_configs

    # Step 6: Import
    echo -e "\n${CYAN}━━━ STEP 6: IMPORT ━━━${NC}"
    is_migration_running "$REBECCA_DIR" || start_migration_panel "$REBECCA_DIR" "Rebecca"
    wait_migration_mysql
    import_migration_to_rebecca "$mysql_sql"

    # Step 7: Restart
    echo -e "\n${CYAN}━━━ STEP 7: RESTART ━━━${NC}"
    (cd "$REBECCA_DIR" && docker compose restart) &>/dev/null
    sleep 3
    mok "Rebecca restarted"

    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Migration completed!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo "Backup: $backup_dir"
    
    migration_cleanup
    mpause
}

do_migration_rollback() {
    clear
    echo -e "${CYAN}=== ROLLBACK ===${NC}"
    [ ! -f "$BACKUP_ROOT/.last_backup" ] && { merr "No backup"; mpause; return 1; }
    local backup=$(cat "$BACKUP_ROOT/.last_backup")
    [ ! -d "$backup" ] && { merr "Backup missing"; mpause; return 1; }

    echo "Backup: $backup"
    read -p "Type 'rollback': " ans
    [ "$ans" != "rollback" ] && return 0

    migration_init
    stop_migration_panel "$REBECCA_DIR" "Rebecca"

    [ -f "$backup/pasarguard_config.tar.gz" ] && {
        rm -rf "$PASARGUARD_DIR"
        mkdir -p "$(dirname "$PASARGUARD_DIR")"
        tar -xzf "$backup/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")"
        mok "Config restored"
    }
    [ -f "$backup/pasarguard_data.tar.gz" ] && {
        rm -rf "$PASARGUARD_DATA"
        mkdir -p "$(dirname "$PASARGUARD_DATA")"
        tar -xzf "$backup/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")"
        mok "Data restored"
    }

    start_migration_panel "$PASARGUARD_DIR" "Pasarguard"
    echo -e "${GREEN}Rollback done${NC}"
    migration_cleanup
    mpause
}

migrator_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   MIGRATION TOOLS v9.7             ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
        echo ""
        echo " 1) Migrate Pasarguard → Rebecca"
        echo " 2) Rollback to Pasarguard"
        echo " 3) View Backups"
        echo " 4) View Log"
        echo " 0) Back"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_migration_rollback ;;
            3) clear; ls -lh "$BACKUP_ROOT" 2>/dev/null || echo "No backups"; mpause ;;
            4) clear; tail -50 "$MIGRATION_LOG" 2>/dev/null || echo "No log"; mpause ;;
            0) return ;;
            *) ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    migrator_menu
fi