cat > /usr/local/bin/mrm-migrate << 'ENDSCRIPT'
#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - Pasarguard → Rebecca
# Version: 9.6 (Fixed backup_dir capture bug)
#==============================================================================

set -o pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================

PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA="${REBECCA_DATA:-/var/lib/rebecca}"
REBECCA_INSTALL_URL="https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"
TEMP_DIR=""
CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

#==============================================================================
# HELPERS
#==============================================================================

create_temp_dir() {
    TEMP_DIR=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || TEMP_DIR="/tmp/mrm-migration-$$"
    mkdir -p "$TEMP_DIR"
}

cleanup_temp() {
    [[ "$TEMP_DIR" == /tmp/* ]] && rm -rf "$TEMP_DIR" 2>/dev/null
}

init_migration() {
    create_temp_dir
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/mrm_migration.log"
    mkdir -p "$BACKUP_ROOT" 2>/dev/null
    echo -e "\n=== Migration: $(date) ===" >> "$LOG_FILE"
}

log()  { echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"; }
info() { echo -e "${BLUE}→${NC} $*"; log "INFO: $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; log "OK: $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; log "WARN: $*"; }
err()  { echo -e "${RED}✗${NC} $*"; log "ERROR: $*"; }

safe_pause() {
    echo -e "\n${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
}

#==============================================================================
# DEPENDENCIES
#==============================================================================

check_dependencies() {
    info "Checking dependencies..."
    local missing=()
    for cmd in docker curl tar gzip python3 sqlite3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -gt 0 ] && { err "Missing: ${missing[*]}"; return 1; }
    docker info &>/dev/null || { err "Docker not running"; return 1; }
    ok "Dependencies OK"
}

#==============================================================================
# DB DETECTION
#==============================================================================

detect_db_type() {
    local panel_dir="$1" data_dir="$2"
    [ ! -d "$panel_dir" ] && { echo "not_found"; return 1; }
    local env_file="$panel_dir/.env"
    if [ -f "$env_file" ]; then
        local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"'"'" | tr -d ' ')
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

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT=""; DB_NAME=""
    [ ! -f "$env_file" ] && return 1
    local db_url=$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d ' ')
    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    scheme, rest = url.split('://', 1)
    if '+' in scheme: scheme = scheme.split('+', 1)[0]
    url = scheme + '://' + rest
    p = urlparse(url)
    print(f'DB_USER="{p.username or ""}"')
    print(f'DB_PASS="{unquote(p.password or "")}"')
    print(f'DB_HOST="{p.hostname or "localhost"}"')
    print(f'DB_PORT="{p.port or ""}"')
    print(f'DB_NAME="{(p.path or "").lstrip("/") or "pasarguard"}"')
else:
    print('DB_USER=""'); print('DB_PASS=""'); print('DB_HOST="localhost"'); print('DB_PORT=""'); print('DB_NAME="pasarguard"')
PYEOF
)"
}

#==============================================================================
# CONTAINER MANAGEMENT
#==============================================================================

find_pg_container() {
    local cname=""
    for svc in timescaledb db postgres postgresql database; do
        cname=$(cd "$PASARGUARD_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done
    cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(timescale|postgres|db)" | head -1)
    [ -n "$cname" ] && echo "$cname"
}

find_mysql_container() {
    local cname=""
    for svc in mysql mariadb db database; do
        cname=$(cd "$REBECCA_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1)
        [ -n "$cname" ] && { echo "$cname"; return 0; }
    done
    cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb|db)" | head -1)
    [ -n "$cname" ] && echo "$cname"
}

is_running() {
    [ -d "$1" ] && (cd "$1" && docker compose ps 2>/dev/null | grep -qE "Up|running")
}

start_panel() {
    local dir="$1" name="$2"
    info "Starting $name..."
    [ ! -d "$dir" ] && { err "$dir not found"; return 1; }
    (cd "$dir" && docker compose up -d) &>/dev/null
    local i=0
    while [ $i -lt $CONTAINER_TIMEOUT ]; do
        is_running "$dir" && { ok "$name started"; sleep 3; return 0; }
        sleep 3; i=$((i+3))
    done
    err "$name failed to start"; return 1
}

stop_panel() {
    local dir="$1" name="$2"
    [ ! -d "$dir" ] && return 0
    info "Stopping $name..."
    (cd "$dir" && docker compose down) &>/dev/null
    sleep 2
    ok "$name stopped"
}

#==============================================================================
# BACKUP - FIXED
#==============================================================================

create_backup() {
    info "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$backup_dir"
    
    # Save path for later retrieval
    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup"

    if [ -d "$PASARGUARD_DIR" ]; then
        info "  Config..."
        tar --exclude='*/node_modules' -C "$(dirname "$PASARGUARD_DIR")" \
            -czf "$backup_dir/pasarguard_config.tar.gz" "$(basename "$PASARGUARD_DIR")" 2>/dev/null
        ok "  Config saved"
    fi

    if [ -d "$PASARGUARD_DATA" ]; then
        info "  Data..."
        tar -C "$(dirname "$PASARGUARD_DATA")" \
            -czf "$backup_dir/pasarguard_data.tar.gz" "$(basename "$PASARGUARD_DATA")" 2>/dev/null
        ok "  Data saved"
    fi

    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo "$db_type" > "$backup_dir/db_type.txt"
    info "  Database ($db_type)..."

    local export_success=false
    case "$db_type" in
        sqlite)
            if [ -f "$PASARGUARD_DATA/db.sqlite3" ]; then
                cp "$PASARGUARD_DATA/db.sqlite3" "$backup_dir/database.sqlite3"
                ok "  SQLite exported"
                export_success=true
            fi
            ;;
        timescaledb|postgresql)
            if export_postgresql "$backup_dir/database.sql"; then
                export_success=true
            fi
            ;;
        mysql|mariadb)
            if export_mysql "$backup_dir/database.sql"; then
                export_success=true
            fi
            ;;
    esac

    cat > "$backup_dir/info.txt" << EOF
Date: $(date)
Host: $(hostname)
Database: $db_type
Export: $export_success
EOF

    ok "Backup dir: $backup_dir"
    
    if [ "$export_success" = true ]; then
        return 0
    else
        return 1
    fi
}

export_postgresql() {
    local output_file="$1"
    
    get_db_credentials "$PASARGUARD_DIR"
    local user="${DB_USER:-pasarguard}"
    local db="${DB_NAME:-pasarguard}"
    
    info "  User: $user, DB: $db"

    local cname=$(find_pg_container)
    [ -z "$cname" ] && { err "  Container not found!"; return 1; }
    info "  Container: $cname"

    # Wait for ready
    local i=0
    while [ $i -lt 30 ]; do
        docker exec "$cname" pg_isready &>/dev/null && break
        sleep 2; i=$((i+2))
    done

    # Try dump with app user (PRIMARY for this setup)
    info "  Running pg_dump..."
    if docker exec "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Exported: $size"
            return 0
        fi
    fi

    # Try with password
    if docker exec -e PGPASSWORD="$DB_PASS" "$cname" pg_dump -U "$user" -d "$db" --no-owner --no-acl > "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            local size=$(du -h "$output_file" | cut -f1)
            ok "  Exported: $size"
            return 0
        fi
    fi

    err "  pg_dump failed"
    echo "  Try: docker exec $cname pg_dump -U $user -d $db > /tmp/dump.sql"
    return 1
}

export_mysql() {
    local output_file="$1"
    get_db_credentials "$PASARGUARD_DIR"
    local cname=$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(mysql|mariadb|db)" | head -1)
    [ -z "$cname" ] && { err "  MySQL container not found"; return 1; }
    
    if docker exec "$cname" mysqldump -u"${DB_USER:-root}" -p"$DB_PASS" --single-transaction "${DB_NAME:-pasarguard}" > "$output_file" 2>/dev/null; then
        [ -s "$output_file" ] && { ok "  Exported"; return 0; }
    fi
    err "  mysqldump failed"; return 1
}

#==============================================================================
# CONVERSION
#==============================================================================

convert_to_mysql() {
    local src="$1" dst="$2" type="$3"
    case "$type" in
        sqlite) convert_sqlite "$src" "$dst" ;;
        postgresql|timescaledb) convert_postgresql "$src" "$dst" ;;
        mysql|mariadb) cp "$src" "$dst"; ok "No conversion needed" ;;
        *) err "Unknown: $type"; return 1 ;;
    esac
}

convert_sqlite() {
    local src="$1" dst="$2"
    info "Converting SQLite → MySQL..."
    [ ! -f "$src" ] && { err "Source not found"; return 1; }
    
    local dump="$TEMP_DIR/sqlite.sql"
    sqlite3 "$src" .dump > "$dump" 2>/dev/null || { err "Dump failed"; return 1; }

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
    f.write("SET NAMES utf8mb4; SET FOREIGN_KEY_CHECKS=0;\n" + c + "\nSET FOREIGN_KEY_CHECKS=1;\n")
PYEOF
    [ -s "$dst" ] && { ok "Converted"; return 0; }
    err "Conversion failed"; return 1
}

convert_postgresql() {
    local src="$1" dst="$2"
    info "Converting PostgreSQL → MySQL..."
    [ ! -f "$src" ] && { err "Source not found"; return 1; }

    python3 << PYEOF
import re
with open("$src", 'r', errors='replace') as f: c = f.read()

# Remove PG-specific
for p in [r'^SET\s+\w+.*?;$', r'^SELECT\s+pg_catalog\..*?;$', r'^\\\\.*$', r'^\\restrict.*$',
          r'^CREATE\s+EXTENSION.*?;$', r'^COMMENT\s+ON.*?;$', r'^ALTER\s+.*?OWNER.*?;$',
          r'^GRANT\s+.*?;$', r'^REVOKE\s+.*?;$', r'^CREATE\s+SCHEMA.*?;$',
          r'^CREATE\s+SEQUENCE.*?;$', r'^ALTER\s+SEQUENCE.*?;$', r'^SELECT\s+.*?setval.*?;$',
          r'^SELECT\s+create_hypertable.*?;$']:
    c = re.sub(p, '', c, flags=re.M|re.I)

# Remove CREATE TYPE
c = re.sub(r'CREATE TYPE\s+\w+\.?\w*\s+AS\s+ENUM\s*\([^)]+\);', '', c, flags=re.I|re.S)

# Type mappings
for p, r in [(r'\bSERIAL\b', 'INT AUTO_INCREMENT'), (r'\bBIGSERIAL\b', 'BIGINT AUTO_INCREMENT'),
             (r'\bBOOLEAN\b', 'TINYINT(1)'), (r'\bTIMESTAMP\s+WITH\s+TIME\s+ZONE\b', 'DATETIME'),
             (r'\bTIMESTAMPTZ\b', 'DATETIME'), (r'\bBYTEA\b', 'LONGBLOB'), (r'\bUUID\b', 'VARCHAR(36)'),
             (r'\bJSONB?\b', 'JSON'), (r'\bINET\b', 'VARCHAR(45)'), (r'\bDOUBLE\s+PRECISION\b', 'DOUBLE'),
             (r'\bCHARACTER\s+VARYING\b', 'VARCHAR'), (r'\bpublic\.', '')]:
    c = re.sub(p, r, c, flags=re.I)

# Booleans
c = re.sub(r"'t'::boolean", "'1'", c, flags=re.I)
c = re.sub(r"'f'::boolean", "'0'", c, flags=re.I)
c = re.sub(r'\btrue\b', "'1'", c, flags=re.I)
c = re.sub(r'\bfalse\b', "'0'", c, flags=re.I)
c = re.sub(r'::\w+(\[\])?', '', c)
c = re.sub(r"nextval\('[^']*'[^)]*\)", 'NULL', c, flags=re.I)
c = re.sub(r'"([a-zA-Z_]\w*)"', r'\`\1\`', c)
c = re.sub(r'\n\s*\n\s*\n+', '\n\n', c)

with open("$dst", 'w') as f:
    f.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\nSET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n\n" + c + "\n\nSET FOREIGN_KEY_CHECKS=1;\n")
PYEOF
    [ -s "$dst" ] && { ok "Converted"; return 0; }
    err "Conversion failed"; return 1
}

#==============================================================================
# REBECCA
#==============================================================================

check_rebecca() { [ -d "$REBECCA_DIR" ] && [ -f "$REBECCA_DIR/.env" ]; }
check_rebecca_mysql() { [ -f "$REBECCA_DIR/.env" ] && grep -qiE "mysql|mariadb" "$REBECCA_DIR/.env"; }

wait_mysql() {
    info "Waiting for MySQL..."
    local i=0
    while [ $i -lt $MYSQL_WAIT ]; do
        local cname=$(find_mysql_container)
        if [ -n "$cname" ]; then
            local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
            docker exec "$cname" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null && { ok "MySQL ready"; return 0; }
        fi
        sleep 3; i=$((i+3))
    done
    warn "MySQL timeout"; return 1
}

import_to_rebecca() {
    local sql="$1"
    info "Importing to Rebecca..."
    [ ! -f "$sql" ] && { err "SQL not found"; return 1; }

    local db=$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'" || echo "marzban")
    local pass=$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"'"'")
    local cname=$(find_mysql_container)
    
    [ -z "$cname" ] && { err "MySQL container not found"; return 1; }
    info "  Container: $cname, DB: $db"

    if docker exec -i "$cname" mysql -uroot -p"$pass" "$db" < "$sql" 2>/dev/null; then
        ok "Import successful"
        return 0
    fi
    err "Import failed"; return 1
}

migrate_configs() {
    info "Migrating configs..."
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
    ok "Migrated $n variables"

    [ -d "$PASARGUARD_DATA/certs" ] && { mkdir -p "$REBECCA_DATA/certs"; cp -r "$PASARGUARD_DATA/certs/"* "$REBECCA_DATA/certs/" 2>/dev/null; }
    [ -f "$PASARGUARD_DATA/xray_config.json" ] && cp "$PASARGUARD_DATA/xray_config.json" "$REBECCA_DATA/" 2>/dev/null
    [ -d "$PASARGUARD_DATA/templates" ] && { mkdir -p "$REBECCA_DATA/templates"; cp -r "$PASARGUARD_DATA/templates/"* "$REBECCA_DATA/templates/" 2>/dev/null; }
}

#==============================================================================
# MAIN MIGRATION
#==============================================================================

do_migration() {
    init_migration
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   PASARGUARD → REBECCA MIGRATION v9.6         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    check_dependencies || { safe_pause; cleanup_temp; return 1; }
    [ ! -d "$PASARGUARD_DIR" ] && { err "Pasarguard not found"; safe_pause; return 1; }
    ok "Pasarguard found"

    local db_type=$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA")
    echo -e "Database: ${CYAN}$db_type${NC}"

    check_rebecca || { err "Rebecca not installed"; safe_pause; return 1; }
    ok "Rebecca found"
    check_rebecca_mysql || { err "Rebecca needs MySQL"; safe_pause; return 1; }
    ok "MySQL verified"

    echo ""
    read -p "Type 'migrate' to start: " ans
    [ "$ans" != "migrate" ] && { info "Cancelled"; return 0; }

    # Step 1: Backup
    echo -e "\n${CYAN}━━━ STEP 1: BACKUP ━━━${NC}"
    is_running "$PASARGUARD_DIR" || start_panel "$PASARGUARD_DIR" "Pasarguard"
    
    if ! create_backup; then
        err "Database export failed"
        safe_pause; cleanup_temp; return 1
    fi
    
    # Read backup dir from file (reliable method)
    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)
    [ ! -d "$backup_dir" ] && { err "Backup dir not found"; safe_pause; return 1; }

    # Step 2: Verify
    echo -e "\n${CYAN}━━━ STEP 2: VERIFY ━━━${NC}"
    local src=""
    case "$db_type" in
        sqlite) src="$backup_dir/database.sqlite3" ;;
        *) src="$backup_dir/database.sql" ;;
    esac
    [ ! -s "$src" ] && { err "Source empty: $src"; safe_pause; return 1; }
    ok "Source: $(du -h "$src" | cut -f1)"

    # Step 3: Convert
    echo -e "\n${CYAN}━━━ STEP 3: CONVERT ━━━${NC}"
    local mysql_sql="$TEMP_DIR/mysql_import.sql"
    convert_to_mysql "$src" "$mysql_sql" "$db_type" || { safe_pause; return 1; }
    cp "$mysql_sql" "$backup_dir/mysql_converted.sql" 2>/dev/null

    # Step 4: Stop Pasarguard
    echo -e "\n${CYAN}━━━ STEP 4: STOP PASARGUARD ━━━${NC}"
    stop_panel "$PASARGUARD_DIR" "Pasarguard"

    # Step 5: Migrate configs
    echo -e "\n${CYAN}━━━ STEP 5: CONFIGS ━━━${NC}"
    migrate_configs

    # Step 6: Import
    echo -e "\n${CYAN}━━━ STEP 6: IMPORT ━━━${NC}"
    is_running "$REBECCA_DIR" || start_panel "$REBECCA_DIR" "Rebecca"
    wait_mysql
    import_to_rebecca "$mysql_sql"

    # Step 7: Restart
    echo -e "\n${CYAN}━━━ STEP 7: RESTART ━━━${NC}"
    (cd "$REBECCA_DIR" && docker compose restart) &>/dev/null
    sleep 3
    ok "Rebecca restarted"

    echo -e "\n${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Migration completed!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "Backup: $backup_dir"
    
    cleanup_temp
    safe_pause
}

do_rollback() {
    clear
    echo -e "${CYAN}=== ROLLBACK ===${NC}"
    [ ! -f "$BACKUP_ROOT/.last_backup" ] && { err "No backup"; safe_pause; return 1; }
    local backup=$(cat "$BACKUP_ROOT/.last_backup")
    [ ! -d "$backup" ] && { err "Backup missing"; safe_pause; return 1; }

    echo "Backup: $backup"
    read -p "Type 'rollback': " ans
    [ "$ans" != "rollback" ] && return 0

    init_migration
    stop_panel "$REBECCA_DIR" "Rebecca"

    [ -f "$backup/pasarguard_config.tar.gz" ] && {
        rm -rf "$PASARGUARD_DIR"
        tar -xzf "$backup/pasarguard_config.tar.gz" -C "$(dirname "$PASARGUARD_DIR")"
        ok "Config restored"
    }
    [ -f "$backup/pasarguard_data.tar.gz" ] && {
        rm -rf "$PASARGUARD_DATA"
        tar -xzf "$backup/pasarguard_data.tar.gz" -C "$(dirname "$PASARGUARD_DATA")"
        ok "Data restored"
    }

    start_panel "$PASARGUARD_DIR" "Pasarguard"
    echo -e "${GREEN}Rollback done${NC}"
    cleanup_temp
    safe_pause
}

#==============================================================================
# MENU
#==============================================================================

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   MRM MIGRATION TOOL v9.6          ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
        echo ""
        echo " 1) Migrate Pasarguard → Rebecca"
        echo " 2) Rollback"
        echo " 3) View Backups"
        echo " 4) View Log"
        echo " 0) Exit"
        echo ""
        read -p "Select: " opt
        case "$opt" in
            1) do_migration ;;
            2) do_rollback ;;
            3) ls -lh "$BACKUP_ROOT" 2>/dev/null; safe_pause ;;
            4) tail -50 "$LOG_FILE" 2>/dev/null; safe_pause ;;
            0) exit 0 ;;
        esac
    done
}

main_menu
ENDSCRIPT

chmod +x /usr/local/bin/mrm-migrate
mrm-migrate