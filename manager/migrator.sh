#!/usr/bin/env bash
#==============================================================================
# MRM Migration Tool - V9.3 (Production Ready - All Fixes Applied)
#==============================================================================

# Load Utils & UI
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh 2>/dev/null; fi
source /opt/mrm-manager/ui.sh 2>/dev/null

# Fallback colors if ui.sh not loaded
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[0;33m}"
BLUE="${BLUE:-\033[0;34m}"
NC="${NC:-\033[0m}"

# --- CONFIGURATION ---
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"
MIGRATION_TEMP=""

# Global variables for cross-function access
SRC=""
TGT=""
CURRENT_BACKUP=""

REBECCA_INSTALL_CMD="bash -c \"\$(curl -sL https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh)\" @ install --database mysql"

# --- HELPER FUNCTIONS ---

migration_init() {
    MIGRATION_TEMP=$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null) || MIGRATION_TEMP="/tmp/mrm-migration-$$"
    mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
    mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null
    touch "$MIGRATION_LOG" 2>/dev/null
    echo "=== Migration Started: $(date) ===" >> "$MIGRATION_LOG"
}

migration_cleanup() { 
    [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null
}

mlog()   { echo "[$(date +'%F %T')] $*" >> "$MIGRATION_LOG" 2>/dev/null; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; echo -e "${YELLOW}Press any key to continue...${NC}"; read -n 1 -s -r; echo ""; }

# Fallback ui_confirm if not defined
if ! type ui_confirm &>/dev/null; then
    ui_confirm() {
        local prompt="$1"
        local default="${2:-y}"
        read -p "$prompt [y/n] ($default): " answer
        answer="${answer:-$default}"
        [[ "$answer" =~ ^[Yy] ]]
    }
fi

# Fallback ui_header if not defined
if ! type ui_header &>/dev/null; then
    ui_header() {
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        echo -e "${GREEN}  $1${NC}"
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        echo ""
    }
fi

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
    [ -z "$cname" ] && cname=$(docker ps --format '{{.Names}}' | grep -iE "$(basename "$panel_dir").*($keywords)" | head -1)
    echo "$cname"
}

get_db_credentials() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    MIG_DB_USER=""; MIG_DB_PASS=""; MIG_DB_NAME=""
    
    [ ! -f "$env_file" ] && return 1
    
    local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    
    eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    try:
        scheme, rest = url.split('://', 1)
        if '+' in scheme: scheme = scheme.split('+', 1)[0]
        p = urlparse(scheme + '://' + rest)
        user = p.username or ""
        passwd = unquote(p.password or "")
        # Escape special characters for bash
        passwd = passwd.replace("'", "'\\''")
        dbname = (p.path or "").lstrip("/")
        print(f"MIG_DB_USER='{user}'")
        print(f"MIG_DB_PASS='{passwd}'")
        print(f"MIG_DB_NAME='{dbname}'")
    except Exception as e:
        print(f"# Error: {e}")
PYEOF
)"
}

detect_db_type() {
    local panel_dir="$1"
    local env_file="$panel_dir/.env"
    local data_dir="/var/lib/$(basename "$panel_dir")"
    [ "$panel_dir" == "/opt/pasarguard" ] && data_dir="/var/lib/pasarguard"
    if [ -f "$env_file" ]; then
        local db_url=$(grep "^SQLALCHEMY_DATABASE_URL" "$env_file" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
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
    clear
    ui_header "INSTALLING REBECCA"
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
    local SRC_DIR="$1"
    local DATA_DIR="/var/lib/$(basename "$SRC_DIR")"
    [ "$SRC_DIR" == "/opt/pasarguard" ] && DATA_DIR="/var/lib/pasarguard"
    minfo "Creating backup..."
    local ts=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP="$BACKUP_ROOT/backup_$ts"
    mkdir -p "$CURRENT_BACKUP"
    echo "$CURRENT_BACKUP" > "$BACKUP_ROOT/.last_backup"
    echo "$SRC_DIR" > "$BACKUP_ROOT/.last_source"
    tar --exclude='*/node_modules' --exclude='mysql' --exclude='postgres' -C "$(dirname "$SRC_DIR")" -czf "$CURRENT_BACKUP/config.tar.gz" "$(basename "$SRC_DIR")" 2>/dev/null
    tar --exclude='mysql' --exclude='postgres' -C "$(dirname "$DATA_DIR")" -czf "$CURRENT_BACKUP/data.tar.gz" "$(basename "$DATA_DIR")" 2>/dev/null
    local db_type=$(detect_db_type "$SRC_DIR")
    echo "$db_type" > "$CURRENT_BACKUP/db_type.txt"
    local out="$CURRENT_BACKUP/database.sql"
    case "$db_type" in
        sqlite) 
            if [ -f "$DATA_DIR/db.sqlite3" ]; then
                cp "$DATA_DIR/db.sqlite3" "$CURRENT_BACKUP/database.sqlite3"
                mok "SQLite exported"
            else
                merr "SQLite file not found"
            fi
            ;;
        postgresql)
            local cname=$(find_db_container "$SRC_DIR" "postgresql")
            get_db_credentials "$SRC_DIR"
            docker exec "$cname" pg_dump -U "${MIG_DB_USER:-pasarguard}" -d "${MIG_DB_NAME:-pasarguard}" --data-only --column-inserts --disable-dollar-quoting > "$out" 2>/dev/null
            [ -s "$out" ] && mok "Postgres exported" || merr "pg_dump failed"
            ;;
        mysql)
            local cname=$(find_db_container "$SRC_DIR" "mysql")
            get_db_credentials "$SRC_DIR"
            docker exec "$cname" mysqldump -u"${MIG_DB_USER:-root}" -p"${MIG_DB_PASS}" --single-transaction "${MIG_DB_NAME:-marzban}" > "$out" 2>/dev/null
            [ -s "$out" ] && mok "MySQL exported" || merr "mysqldump failed"
            ;;
    esac
}

convert_to_mysql() {
    local src="$1" dst="$2" type="$3"
    minfo "Converting $type → MySQL..."
    if [ "$type" == "sqlite" ] && [[ "$src" == *.sqlite3 ]]; then
        if ! command -v sqlite3 &>/dev/null; then
            merr "sqlite3 not installed. Installing..."
            apt-get update && apt-get install -y sqlite3
        fi
        sqlite3 "$src" .dump > "$MIGRATION_TEMP/sqlite.sql"
        src="$MIGRATION_TEMP/sqlite.sql"
    fi
    
    python3 - "$src" "$dst" << 'PYEOF'
import re, sys

src, dst = sys.argv[1], sys.argv[2]

try:
    with open(src, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
except Exception as e:
    print(f"Error reading file: {e}")
    sys.exit(1)

out = []
header = "SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\nSET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n\n"

for line in lines:
    l = line.strip()
    if l.startswith(('PRAGMA', 'BEGIN TRANSACTION', 'COMMIT', 'SET', '\\', '--')): 
        continue
    if re.match(r'^SELECT\s+(pg_catalog|setval)', l, re.I): 
        continue
    
    line = re.sub(r'\bINTEGER PRIMARY KEY AUTOINCREMENT\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bINTEGER PRIMARY KEY\b', 'INT AUTO_INCREMENT PRIMARY KEY', line, flags=re.I)
    line = re.sub(r'\bBOOLEAN\b', 'TINYINT(1)', line, flags=re.I)
    line = line.replace("'t'", "1").replace("'f'", "0")
    line = re.sub(r"'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?\+00'", r"'\1'", line)
    line = line.replace('/var/lib/pasarguard', '/var/lib/rebecca')
    line = line.replace('/opt/pasarguard', '/opt/rebecca')
    
    if re.match(r'^\s*INSERT\s+INTO\b', line, re.I):
        line = re.sub(r'^\s*INSERT\s+INTO', 'REPLACE INTO', line, flags=re.I)
        # Fix table name quoting
        line = re.sub(r'public\."?(\w+)"?', r'`\1`', line)
        # Don't double-escape backslashes
    
    out.append(line)

try:
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(header + "".join(out) + "\nSET FOREIGN_KEY_CHECKS=1;\n")
    print("Conversion successful")
except Exception as e:
    print(f"Error writing file: {e}")
    sys.exit(1)
PYEOF

    [ -s "$dst" ] && mok "Converted" || { merr "Conversion failed"; return 1; }
}

# --- SMART ENV READER ---
read_var() {
    local key="$1"
    local file="$2"
    [ ! -f "$file" ] && return
    grep -E "^\s*${key}\s*=" "$file" | head -1 | sed -E "s/^\s*${key}\s*=\s*//g" | sed -E 's/^"//;s/"$//;s/^\x27//;s/\x27$//'
}

# --- CLEAN ENV CONSTRUCTION ---
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

# --- FIXED: Pre-process SQL to handle JWT NULL values ---
preprocess_sql_fix_jwt() {
    local input_sql="$1"
    local output_sql="$2"
    local jwt_secret="$3"
    local sub_secret="$4"
    local admin_secret="$5"
    local vmess_mask="$6"
    local vless_mask="$7"

    minfo "Pre-processing SQL (Removing problematic JWT inserts)..."

    python3 - "$input_sql" "$output_sql" "$jwt_secret" "$sub_secret" "$admin_secret" "$vmess_mask" "$vless_mask" << 'PYEOF'
import re
import sys

if len(sys.argv) < 8:
    print("Error: Not enough arguments")
    sys.exit(1)

sql_file = sys.argv[1]
output_file = sys.argv[2]
jwt_secret = sys.argv[3]
sub_secret = sys.argv[4]
admin_secret = sys.argv[5]
vmess_mask = sys.argv[6]
vless_mask = sys.argv[7]

try:
    with open(sql_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
except Exception as e:
    print(f"Error reading SQL file: {e}")
    sys.exit(1)

# Split into lines for processing
lines = content.split('\n')
new_lines = []
in_jwt_statement = False
brace_count = 0

for i, line in enumerate(lines):
    line_lower = line.lower().strip()
    
    # Detect start of JWT insert/replace (various formats)
    if re.search(r'(insert|replace)\s+(into\s+)?[`"\']?jwt[`"\']?\s*[\(]', line_lower):
        in_jwt_statement = True
        brace_count = line.count('(') - line.count(')')
        new_lines.append('-- [MRM-FIX] JWT INSERT REMOVED (had NULL values)')
        if ';' in line and brace_count <= 0:
            in_jwt_statement = False
        continue
    
    # If we're inside a multi-line JWT statement
    if in_jwt_statement:
        brace_count += line.count('(') - line.count(')')
        if ';' in line:
            in_jwt_statement = False
            brace_count = 0
        continue
    
    new_lines.append(line)

content = '\n'.join(new_lines)

# Add fresh JWT handling at the end
jwt_section = f"""

-- ============================================
-- [MRM Migration Tool V9.3] Fresh JWT Record
-- ============================================

-- Create jwt table if not exists (safety)
CREATE TABLE IF NOT EXISTS `jwt` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `secret_key` VARCHAR(255) NOT NULL,
    `subscription_secret_key` VARCHAR(255),
    `admin_secret_key` VARCHAR(255),
    `vmess_mask` VARCHAR(64),
    `vless_mask` VARCHAR(64)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Clear any existing (potentially corrupt) JWT data
DELETE FROM `jwt`;

-- Insert fresh valid JWT record
INSERT INTO `jwt` (`secret_key`, `subscription_secret_key`, `admin_secret_key`, `vmess_mask`, `vless_mask`) 
VALUES ('{jwt_secret}', '{sub_secret}', '{admin_secret}', '{vmess_mask}', '{vless_mask}');

-- ============================================

"""

content = content + jwt_section

try:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(content)
    print("OK")
except Exception as e:
    print(f"Error writing output file: {e}")
    sys.exit(1)
PYEOF

    local result=$?
    if [ $result -eq 0 ] && [ -f "$output_sql" ] && [ -s "$output_sql" ]; then
        mok "SQL pre-processed successfully"
        return 0
    else
        mwarn "Could not pre-process SQL (exit code: $result)"
        return 1
    fi
}

# --- MAIN IMPORT FUNCTION (FULLY FIXED) ---
import_and_sanitize() {
    local SQL="$1" 
    local TGT_DIR="$2"
    
    minfo "Starting data import..."
    
    # Get credentials
    get_db_credentials "$TGT_DIR"
    local user="${MIG_DB_USER:-root}"
    local pass="${MIG_DB_PASS}"
    [ -z "$pass" ] && pass=$(grep "MYSQL_ROOT_PASSWORD" "$TGT_DIR/.env" | cut -d'=' -f2- | tr -d '"')

    # Find MySQL container
    local cname=$(find_db_container "$TGT_DIR" "mysql")
    if [ -z "$cname" ]; then
        merr "Target MySQL container not found"
        return 1
    fi
    minfo "Using MySQL container: $cname"

    # Wait for MySQL to be ready
    minfo "Waiting for MySQL to be ready..."
    local max_wait=30
    local waited=0
    while ! docker exec "$cname" mysqladmin ping -u"$user" -p"$pass" --silent 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ $waited -ge $max_wait ]; then
            merr "MySQL not ready after ${max_wait}s"
            return 1
        fi
    done
    mok "MySQL is ready"

    # Determine database name
    local db="rebecca"
    local db_exists=$(docker exec "$cname" mysql -u"$user" -p"$pass" -N -e "SHOW DATABASES LIKE 'rebecca';" 2>/dev/null)
    if [ -z "$db_exists" ]; then
        db_exists=$(docker exec "$cname" mysql -u"$user" -p"$pass" -N -e "SHOW DATABASES LIKE 'marzban';" 2>/dev/null)
        [ -n "$db_exists" ] && db="marzban"
    fi

    # Create database if needed
    docker exec "$cname" mysql -u"$user" -p"$pass" -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
    minfo "Using database: $db"

    # Generate fresh secrets
    local JWT_SECRET=$(openssl rand -hex 64)
    local SUB_SECRET=$(openssl rand -hex 64)
    local ADMIN_SECRET=$(openssl rand -hex 64)
    local VMESS_MASK=$(openssl rand -hex 16)
    local VLESS_MASK=$(openssl rand -hex 16)

    # Pre-process SQL to fix JWT issues
    local FIXED_SQL="${SQL}.fixed"
    if preprocess_sql_fix_jwt "$SQL" "$FIXED_SQL" "$JWT_SECRET" "$SUB_SECRET" "$ADMIN_SECRET" "$VMESS_MASK" "$VLESS_MASK"; then
        SQL="$FIXED_SQL"
    else
        mwarn "Continuing with original SQL file..."
    fi

    # Import SQL
    minfo "Importing SQL to database..."
    local import_error=""
    import_error=$(docker exec -i "$cname" mysql --binary-mode=1 -u"$user" -p"$pass" "$db" < "$SQL" 2>&1)
    local import_result=$?
    
    if [ $import_result -ne 0 ]; then
        merr "SQL import had errors:"
        echo "$import_error" | head -20
        mwarn "Attempting to continue..."
    else
        mok "SQL imported successfully"
    fi

    # Helper function for running SQL
    run_sql() { 
        docker exec "$cname" mysql -u"$user" -p"$pass" "$db" -N -e "$1" 2>/dev/null
    }

    # Add missing columns
    minfo "Adding missing columns to admins table..."
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS is_sudo TINYINT(1) DEFAULT 0;" 2>/dev/null
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS is_disabled TINYINT(1) DEFAULT 0;" 2>/dev/null
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS permissions JSON;" 2>/dev/null
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS data_limit BIGINT DEFAULT 0;" 2>/dev/null
    run_sql "ALTER TABLE admins ADD COLUMN IF NOT EXISTS users_limit INT DEFAULT 0;" 2>/dev/null

    # Sanitize data
    minfo "Sanitizing data..."
    run_sql "UPDATE admins SET permissions='[]' WHERE permissions IS NULL;"
    run_sql "UPDATE admins SET data_limit=0 WHERE data_limit IS NULL;"
    run_sql "UPDATE admins SET users_limit=0 WHERE users_limit IS NULL;"
    run_sql "UPDATE admins SET is_sudo=1 WHERE is_sudo IS NULL;"
    run_sql "UPDATE admins SET is_disabled=0 WHERE is_disabled IS NULL;"
    run_sql "UPDATE nodes SET server_ca = REPLACE(server_ca, '/var/lib/pasarguard', '/var/lib/rebecca') WHERE server_ca IS NOT NULL;"
    run_sql "UPDATE core_configs SET config = REPLACE(config, '/var/lib/pasarguard', '/var/lib/rebecca') WHERE config IS NOT NULL;"

    # Final JWT verification
    minfo "Verifying JWT table..."
    local jwt_count=$(run_sql "SELECT COUNT(*) FROM jwt;" 2>/dev/null | tr -d '[:space:]')
    
    if [ -z "$jwt_count" ] || [ "$jwt_count" == "0" ] || [ "$jwt_count" == "NULL" ]; then
        mwarn "JWT table empty or missing, creating fresh record..."
        run_sql "CREATE TABLE IF NOT EXISTS jwt (id INT AUTO_INCREMENT PRIMARY KEY, secret_key VARCHAR(255) NOT NULL, subscription_secret_key VARCHAR(255), admin_secret_key VARCHAR(255), vmess_mask VARCHAR(64), vless_mask VARCHAR(64)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
        run_sql "INSERT INTO jwt (secret_key, subscription_secret_key, admin_secret_key, vmess_mask, vless_mask) VALUES ('${JWT_SECRET}', '${SUB_SECRET}', '${ADMIN_SECRET}', '${VMESS_MASK}', '${VLESS_MASK}');"
    else
        minfo "JWT table has $jwt_count record(s), checking for NULL values..."
        run_sql "UPDATE jwt SET secret_key='${JWT_SECRET}' WHERE secret_key IS NULL OR secret_key='';"
        run_sql "UPDATE jwt SET subscription_secret_key='${SUB_SECRET}' WHERE subscription_secret_key IS NULL OR subscription_secret_key='';"
        run_sql "UPDATE jwt SET admin_secret_key='${ADMIN_SECRET}' WHERE admin_secret_key IS NULL OR admin_secret_key='';"
        run_sql "UPDATE jwt SET vmess_mask='${VMESS_MASK}' WHERE vmess_mask IS NULL OR vmess_mask='';"
        run_sql "UPDATE jwt SET vless_mask='${VLESS_MASK}' WHERE vless_mask IS NULL OR vless_mask='';"
    fi
    
    # Verify JWT is valid now
    local jwt_check=$(run_sql "SELECT secret_key FROM jwt LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$jwt_check" ] && [ "$jwt_check" != "NULL" ]; then
        mok "JWT table verified successfully"
    else
        merr "JWT table still has issues!"
        return 1
    fi

    mok "Data import and sanitization complete"
    return 0
}

create_rescue_admin() {
    echo ""
    echo -e "${YELLOW}Create new SuperAdmin? (Recommended)${NC}"
    if ui_confirm "Create?" "y"; then
        # Use global TGT variable
        local panel_name=$(basename "$TGT")
        local cname=$(docker ps --format '{{.Names}}' | grep -iE "${panel_name}.*(panel|rebecca|marzban)" | grep -v mysql | grep -v db | head -1)
        
        if [ -z "$cname" ]; then
            cname=$(docker ps --format '{{.Names}}' | grep -iE "rebecca" | grep -v mysql | grep -v db | head -1)
        fi
        
        if [ -n "$cname" ]; then
            minfo "Using container: $cname"
            docker exec -it "$cname" rebecca-cli admin create 2>/dev/null || \
            docker exec -it "$cname" marzban-cli admin create 2>/dev/null || \
            mwarn "Could not create admin via CLI. Please create manually."
        else
            mwarn "Panel container not found. Please create admin manually."
        fi
    fi
}

do_full_migration() {
    migration_init
    clear
    ui_header "UNIVERSAL MIGRATION V9.3"
    
    echo -e "${YELLOW}This tool will migrate from Pasarguard/Marzban to Rebecca${NC}"
    echo ""
    
    # Detect source
    SRC=$(detect_source_panel)
    if [ -z "$SRC" ]; then
        merr "No source panel found (Pasarguard/Marzban)"
        mpause
        return 1
    fi
    
    # Detect/install target
    if [ -d "/opt/rebecca" ]; then
        TGT="/opt/rebecca"
    elif [ -d "/opt/marzban" ] && [ "$SRC" != "/opt/marzban" ]; then
        TGT="/opt/marzban"
    else
        minfo "Rebecca not installed. Installing..."
        if ! install_rebecca_wizard; then
            mpause
            return 1
        fi
        TGT="/opt/rebecca"
    fi
    
    echo -e "Source: ${RED}$(basename "$SRC")${NC} → ${GREEN}$(basename "$TGT")${NC}"
    echo ""
    
    if ! ui_confirm "Start Migration?" "y"; then
        return 0
    fi

    # Step 1: Backup
    minfo "Step 1/6: Creating backup..."
    create_backup "$SRC"
    
    if [ -z "$CURRENT_BACKUP" ]; then
        merr "Backup failed"
        mpause
        return 1
    fi
    mok "Backup created: $CURRENT_BACKUP"

    # Step 2: Convert SQL
    minfo "Step 2/6: Converting database..."
    local db_type=$(cat "$CURRENT_BACKUP/db_type.txt" 2>/dev/null)
    local src_sql="$CURRENT_BACKUP/database.sql"
    [ "$db_type" == "sqlite" ] && src_sql="$CURRENT_BACKUP/database.sqlite3"
    
    local final_sql="$MIGRATION_TEMP/import.sql"
    if ! convert_to_mysql "$src_sql" "$final_sql" "$db_type"; then
        merr "Database conversion failed"
        mpause
        return 1
    fi

    # Step 3: Stop services
    minfo "Step 3/6: Stopping services..."
    docker ps -q --filter "name=pasarguard" 2>/dev/null | xargs -r docker stop 2>/dev/null
    docker ps -q --filter "name=marzban" 2>/dev/null | xargs -r docker stop 2>/dev/null
    (cd "$SRC" && docker compose down 2>/dev/null) &>/dev/null
    (cd "$TGT" && docker compose down 2>/dev/null) &>/dev/null
    sleep 3
    mok "Services stopped"

    # Step 4: Generate env
    minfo "Step 4/6: Configuring target..."
    generate_clean_env "$SRC" "$TGT"

    # Step 5: Start target and import
    minfo "Step 5/6: Starting target panel..."
    (cd "$TGT" && docker compose up -d --force-recreate) 
    
    minfo "Waiting for services to start..."
    sleep 25

    if ! import_and_sanitize "$final_sql" "$TGT"; then
        merr "Data import failed"
        mwarn "You may need to run rollback"
        mpause
        return 1
    fi

    # Step 6: Final restart
    minfo "Step 6/6: Final restart..."
    (cd "$TGT" && docker compose down && sleep 5 && docker compose up -d --force-recreate)
    sleep 15

    # Verify
    local panel_container=$(docker ps --format '{{.Names}}' | grep -iE "rebecca|marzban" | grep -v mysql | grep -v db | head -1)
    if [ -n "$panel_container" ]; then
        mok "Panel running: $panel_container"
    else
        mwarn "Panel container not detected"
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}     MIGRATION COMPLETED SUCCESSFULLY!    ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    
    create_rescue_admin
    migration_cleanup
    mpause
}

do_rollback() {
    clear
    ui_header "ROLLBACK"
    
    local last=$(cat "$BACKUP_ROOT/.last_backup" 2>/dev/null)
    local src_path=$(cat "$BACKUP_ROOT/.last_source" 2>/dev/null)
    [ -z "$src_path" ] && src_path="/opt/pasarguard"
    
    if [ -z "$last" ] || [ ! -d "$last" ]; then
        merr "No backup found to restore"
        mpause
        return 1
    fi
    
    echo "Backup: $last"
    echo "Target: $src_path"
    echo ""
    
    if ui_confirm "Restore this backup?" "n"; then
        minfo "Stopping services..."
        if [ -d "/opt/rebecca" ]; then 
            (cd /opt/rebecca && docker compose down 2>/dev/null) &>/dev/null
        fi
        
        local PID=$(lsof -t -i:7431 2>/dev/null)
        [ -n "$PID" ] && kill -9 $PID 2>/dev/null
        
        minfo "Restoring files..."
        mkdir -p "$(dirname "$src_path")"
        tar -xzf "$last/config.tar.gz" -C "$(dirname "$src_path")" 2>/dev/null
        tar -xzf "$last/data.tar.gz" -C "/var/lib" 2>/dev/null
        
        minfo "Starting original panel..."
        (cd "$src_path" && docker compose up -d 2>/dev/null) &>/dev/null
        
        mok "Rollback Complete"
    fi
    mpause
}

view_logs() {
    clear
    ui_header "MIGRATION LOGS"
    if [ -f "$MIGRATION_LOG" ]; then
        tail -100 "$MIGRATION_LOG"
    else
        echo "No logs found"
    fi
    mpause
}

migrator_menu() {
    while true; do
        clear
        ui_header "MRM MIGRATION TOOL V9.3"
        echo ""
        echo "  1) Auto Migrate (Pasarguard/Marzban → Rebecca)"
        echo "  2) Rollback to Previous State"
        echo "  3) View Migration Logs"
        echo ""
        echo "  0) Exit"
        echo ""
        read -p "Select option: " opt
        case "$opt" in
            1) do_full_migration ;;
            2) do_rollback ;;
            3) view_logs ;;
            0|q|Q) return 0 ;;
            *) mwarn "Invalid option" ;;
        esac
    done
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)"
        exit 1
    fi
    
    # Check dependencies
    if ! command -v docker &>/dev/null; then
        echo "Docker is required but not installed"
        exit 1
    fi
    
    if ! command -v python3 &>/dev/null; then
        echo "Python3 is required but not installed"
        exit 1
    fi
    
    migrator_menu
fi