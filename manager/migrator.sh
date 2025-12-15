#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# Pasarguard (PostgreSQL/TimescaleDB) → Rebecca (MySQL) Data Migration
# Version: 12.0 - Data-only, JSON-safe, schema-preserving
#==============================================================================

# تنظیم مسیرها (در صورت نیاز تغییر بده)
PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
PASARGUARD_DATA="${PASARGUARD_DATA:-/var/lib/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mrm-migration}"
MIGRATION_LOG="${MIGRATION_LOG:-/var/log/mrm_migration.log}"

MIGRATION_TEMP=""
CONTAINER_TIMEOUT=120
MYSQL_WAIT=60

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

mlog()   { echo "[$(date +'%F %T')] $*" >>"$MIGRATION_LOG"; }
minfo()  { echo -e "${BLUE}→${NC} $*"; mlog "INFO: $*"; }
mok()    { echo -e "${GREEN}✓${NC} $*"; mlog "OK: $*"; }
mwarn()  { echo -e "${YELLOW}⚠${NC} $*"; mlog "WARN: $*"; }
merr()   { echo -e "${RED}✗${NC} $*"; mlog "ERROR: $*"; }
mpause() { echo ""; echo -e "${YELLOW}Press any key to continue...${NC}"; read -n 1 -s -r; echo ""; }

migration_init() {
  MIGRATION_TEMP="$(mktemp -d /tmp/mrm-migration-XXXXXX 2>/dev/null || echo "/tmp/mrm-migration-$$")"
  mkdir -p "$MIGRATION_TEMP" "$BACKUP_ROOT"
  mkdir -p "$(dirname "$MIGRATION_LOG")" 2>/dev/null || MIGRATION_LOG="/tmp/mrm_migration.log"
  echo "" >>"$MIGRATION_LOG"
  echo "=== Migration: $(date) ===" >>"$MIGRATION_LOG"
}

migration_cleanup() {
  [[ "$MIGRATION_TEMP" == /tmp/* ]] && rm -rf "$MIGRATION_TEMP" 2>/dev/null || true
}

detect_db_type() {
  local panel_dir="$1" data_dir="$2"
  [ ! -d "$panel_dir" ] && { echo "not_found"; return 1; }
  local env_file="$panel_dir/.env"
  if [ -f "$env_file" ]; then
    local db_url
    db_url="$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')"
    case "$db_url" in
      *timescale*|*postgresql+asyncpg*) echo "timescaledb"; return 0 ;;
      *postgresql*) echo "postgresql"; return 0 ;;
      *mysql*|*mariadb*) echo "mysql"; return 0 ;;
      *sqlite*) echo "sqlite"; return 0 ;;
    esac
  fi
  [ -f "$data_dir/db.sqlite3" ] && { echo "sqlite"; return 0; }
  echo "unknown"; return 1
}

get_pg_credentials() {
  local panel_dir="$1" env_file="$panel_dir/.env"
  PG_USER=""; PG_PASS=""; PG_DB=""; PG_HOST="localhost"; PG_PORT=""
  [ ! -f "$env_file" ] && return 1

  local db_url
  db_url="$(grep -E "^SQLALCHEMY_DATABASE_URL" "$env_file" 2>/dev/null | head -1 | sed 's/[^=]*=//' | tr -d '"' | tr -d "'" | tr -d ' ')"

  eval "$(python3 << PYEOF
from urllib.parse import urlparse, unquote
url = "$db_url"
if '://' in url:
    scheme, rest = url.split('://', 1)
    if '+' in scheme: scheme = scheme.split('+', 1)[0]
    p = urlparse(scheme + '://' + rest)
    print(f'PG_USER="{p.username or ""}"')
    print(f'PG_PASS="{unquote(p.password or "")}"')
    print(f'PG_HOST="{p.hostname or "localhost"}"')
    print(f'PG_PORT="{p.port or ""}"')
    print(f'PG_DB="{(p.path or "").lstrip("/") or "pasarguard"}"')
else:
    print('PG_USER=""'); print('PG_PASS=""'); print('PG_HOST="localhost"'); print('PG_PORT=""'); print('PG_DB="pasarguard"')
PYEOF
)"
}

find_pg_container() {
  local cname=""
  for svc in timescaledb db postgres postgresql database; do
    cname="$(cd "$PASARGUARD_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1 || true)"
    [ -n "$cname" ] && { echo "$cname"; return 0; }
  done
  cname="$(docker ps --format '{{.Names}}' | grep -iE "pasarguard.*(timescale|postgres|db)" | head -1 || true)"
  [ -n "$cname" ] && echo "$cname"
}

find_mysql_container() {
  local cname=""
  for svc in mysql mariadb db database; do
    cname="$(cd "$REBECCA_DIR" && docker compose ps --format '{{.Names}}' "$svc" 2>/dev/null | head -1 || true)"
    [ -n "$cname" ] && { echo "$cname"; return 0; }
  done
  cname="$(docker ps --format '{{.Names}}' | grep -iE "rebecca.*(mysql|mariadb|db)" | head -1 || true)"
  [ -n "$cname" ] && echo "$cname"
}

is_stack_running() { [ -d "$1" ] && (cd "$1" && docker compose ps 2>/dev/null | grep -qE "Up|running"); }

start_stack() {
  local dir="$1" name="$2"
  minfo "Starting $name..."
  [ ! -d "$dir" ] && { merr "$dir not found"; return 1; }
  (cd "$dir" && docker compose up -d) &>/dev/null || true
  local i=0
  while [ $i -lt $CONTAINER_TIMEOUT ]; do
    is_stack_running "$dir" && { mok "$name started"; sleep 3; return 0; }
    sleep 3; i=$((i+3))
  done
  merr "$name failed to start"
  return 1
}

wait_mysql_ready() {
  local dir="$1"
  minfo "Waiting for MySQL..."
  local i=0 cname pass
  cname="$(find_mysql_container || true)"
  pass="$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' || true)"
  while [ $i -lt $MYSQL_WAIT ]; do
    cname="$(find_mysql_container || true)"
    if [ -n "$cname" ] && [ -n "$pass" ]; then
      if docker exec "$cname" mysql -uroot -p"$pass" -e "SELECT 1" &>/dev/null; then
        mok "MySQL ready"
        return 0
      fi
    fi
    sleep 3; i=$((i+3))
  done
  mwarn "MySQL not confirmed ready (timeout)"
  return 1
}

export_pg_data_only() {
  local outfile="$1"
  minfo "Exporting PostgreSQL data (data-only)..."
  get_pg_credentials "$PASARGUARD_DIR"
  local user="${PG_USER:-pasarguard}"
  local db="${PG_DB:-pasarguard}"

  minfo "  User: $user, DB: $db"

  local cname
  cname="$(find_pg_container || true)"
  [ -z "$cname" ] && { merr "  PostgreSQL container not found"; return 1; }
  minfo "  Container: $cname"

  local i=0
  while [ $i -lt 30 ]; do
    docker exec "$cname" pg_isready &>/dev/null && break
    sleep 2; i=$((i+2))
  done

  local PG_FLAGS="--no-owner --no-acl --data-only --column-inserts --no-comments --disable-dollar-quoting"

  minfo "  Running pg_dump..."
  if docker exec "$cname" pg_dump -U "$user" -d "$db" $PG_FLAGS >"$outfile" 2>/dev/null &&
     [ -s "$outfile" ]; then
    mok "  Exported: $(du -h "$outfile" | cut -f1)"
    return 0
  fi

  if docker exec -e PGPASSWORD="$PG_PASS" "$cname" pg_dump -U "$user" -d "$db" $PG_FLAGS >"$outfile" 2>/dev/null &&
     [ -s "$outfile" ]; then
    mok "  Exported: $(du -h "$outfile" | cut -f1)"
    return 0
  fi

  merr "  pg_dump failed"
  return 1
}

convert_pg_data_to_mysql() {
  local src="$1" dst="$2"
  minfo "Converting PostgreSQL data → MySQL (schema public., SET, ...)..."
  [ ! -f "$src" ] && { merr "Source SQL not found: $src"; return 1; }

  python3 - "$src" "$dst" << 'PYEOF'
import re
import sys

src_file = sys.argv[1]
dst_file = sys.argv[2]

with open(src_file, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

out_lines = []
skip_until_semicolon = False

for line in lines:
    stripped = line.strip()

    # Skip empty at top-level
    if not stripped and not out_lines:
        continue

    # Skip SET/SELECT config/etc (PostgreSQL client/session stuff)
    if re.match(r'^SET\b', stripped, re.I):
        continue
    if re.match(r'^SELECT\s+pg_catalog\.', stripped, re.I):
        continue
    if re.match(r'^SELECT\s+setval\b', stripped, re.I):
        continue

    # We expect only INSERTs & maybe COPY leftovers (but with --data-only + --column-inserts، تقریباً فقط INSERT داریم)
    # Handle INSERT lines: fix schema and quote table name
    if re.match(r'^\s*INSERT\s+INTO\b', line, re.I):
        # Remove schema "public." / `public`. / public. if present
        # Pattern: INSERT INTO [ public.|"public".|`public`. ]tablename
        def fix_insert(m):
            prefix = m.group(1)
            table = m.group(2)
            return f"{prefix}`{table}`"

        # اول public. را حذف می‌کنیم
        # سپس فقط نام جدول را کوت می‌کنیم
        line = re.sub(
            r'^(\s*INSERT\s+INTO\s+)(?:"public"\.|`public`\.|public\.)?"?([A-Za-z0-9_]+)"?',
            fix_insert,
            line,
            flags=re.I
        )
        out_lines.append(line)
        continue

    # سایر خطوط (ادامه‌ی VALUES و غیره) را دست‌نخورده عبور بده
    out_lines.append(line)

# در این حالت هیچ DDL یا دستورات PostgreSQL خاص نداشته‌ایم (data-only)
# پس فقط یک هدر MySQL برای ایمن کردن ایمپورت اضافه می‌کنیم
header = "SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n\n"
footer = "\n\nSET FOREIGN_KEY_CHECKS=1;\n"

with open(dst_file, 'w', encoding='utf-8') as f:
    f.write(header)
    f.writelines(out_lines)
    f.write(footer)

PYEOF

  [ -s "$dst" ] && { mok "Converted data SQL: $(du -h "$dst" | cut -f1)"; return 0; }
  merr "Conversion failed (empty output)"
  return 1
}

wait_mysql_ready_simple() {
  wait_mysql_ready "$REBECCA_DIR" || return 1
}

import_data_to_mysql() {
  local sql="$1"
  minfo "Importing data into Rebecca MySQL..."
  [ ! -f "$sql" ] && { merr "SQL file not found: $sql"; return 1; }

  local db pass cname
  db="$(grep -E "^MYSQL_DATABASE" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' || echo "rebecca")"
  pass="$(grep -E "^MYSQL_ROOT_PASSWORD" "$REBECCA_DIR/.env" 2>/dev/null | sed 's/[^=]*=//' | tr -d '"' || true)"
  cname="$(find_migration_mysql_container || true)"

  [ -z "$cname" ] && { merr "MySQL container not found"; return 1; }
  [ -z "$db" ] && db="rebecca"

  minfo "  Container: $cname, DB: $db"
  minfo "  SQL file: $(du -h "$sql" | cut -f1)"

  local err_file="$MIGRATION_TEMP/mysql_import.err"

  # توجه: بانک را دروپ نمی‌کنیم؛ فرض می‌کنیم اسکیمای ریبکا از قبل ایجاد شده
  # اگر می‌خواهی قبل از ایمپورت، جداول را خالی کنی، می‌توانی این بخش را فعال کنی
  # (در صورت نیاز، بعداً می‌توانیم یک مرحله TRUNCATE همه جداول اضافه کنیم)

  minfo "  Running MySQL import..."
  if docker exec -i "$cname" mysql --binary-mode=1 -uroot -p"$pass" "$db" <"$sql" 2>"$err_file"; then
    mok "Data import completed"
    return 0
  else
    merr "Import failed!"
    grep -v "Using a password" "$err_file" | head -20 || true
    mlog "MySQL Import Error: $(cat "$err_file" 2>/dev/null || echo "no err file")"
    local ln
    ln="$(grep -oP 'at line \K\d+' "$err_file" 2>/dev/null | head -1 || true)"
    if [ -n "$ln" ]; then
      echo ""
      mwarn "Problematic SQL around line $ln:"
      sed -n "$((ln>2?ln-2:1)),$((ln+3))p" "$sql" || true
    fi
    return 1
  fi
}

run_migration() {
  migration_init
  clear
  echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   PASARGUARD → REBECCA DATA MIGRATION v12.0   ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
  echo ""

  for cmd in docker python3; do
    command -v "$cmd" &>/dev/null || { merr "Missing dependency: $cmd"; mpause; migration_cleanup; return 1; }
  done
  mok "Dependencies OK"

  [ ! -d "$PASARGUARD_DIR" ] && { merr "Pasarguard directory not found: $PASARGUARD_DIR"; mpause; migration_cleanup; return 1; }
  mok "Pasarguard directory: $PASARGUARD_DIR"

  [ ! -d "$REBECCA_DIR" ] && { merr "Rebecca directory not found: $REBECCA_DIR"; mpause; migration_cleanup; return 1; }
  mok "Rebecca directory: $REBECCA_DIR"

  local db_type
  db_type="$(detect_db_type "$PASARGUARD_DIR" "$PASARGUARD_DATA" || echo unknown)"
  echo -e "Pasarguard DB Type: ${CYAN}$db_type${NC}"
  case "$db_type" in
    timescaledb|postgresql) ;;
    *) merr "This script currently supports PostgreSQL/TimescaleDB only (detected: $db_type)"; mpause; migration_cleanup; return 1 ;;
  esac

  echo ""
  echo -e "${YELLOW}IMPORTANT:${NC} This script only migrates data. Rebecca's MySQL schema must already exist."
  echo -e "Make sure Rebecca has been installed and started at least once before."
  echo ""
  read -p "Type 'migrate' to start: " confirm
  [ "$confirm" != "migrate" ] && { minfo "Cancelled."; migration_cleanup; return 0; }

  # 1) Start Pasarguard (if not running)
  is_migration_running "$PASARGUARD_DIR" || start_stack "$PASARGUARD_DIR" "Pasarguard"

  # 2) Export PG data
  local raw_sql="$MIGRATION_TEMP/pg_data.sql"
  export_pg_data_only "$raw_sql" || { mpause; migration_cleanup; return 1; }

  # 3) Convert for MySQL
  local mysql_sql="$MIGRATION_TEMP/mysql_import.sql"
  convert_pg_data_to_mysql "$raw_sql" "$mysql_sql" || { mpause; migration_cleanup; return 1; }

  # 4) Start Rebecca & wait MySQL
  start_stack "$REBECCA_DIR" "Rebecca" || { mpause; migration_cleanup; return 1; }
  wait_mysql_ready_simple || { mwarn "Continuing despite MySQL wait timeout"; }

  # 5) Import
  import_data_to_mysql "$mysql_sql" || { mpause; migration_cleanup; return 1; }

  echo -e "\n${GREEN}════════════════════════════════════════${NC}"
  echo -e "${GREEN}   Data migration finished (PG → MySQL) ${NC}"
  echo -e "${GREEN}════════════════════════════════════════${NC}"

  migration_cleanup
  mpause
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_migration
fi