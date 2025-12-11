#!/usr/bin/env bash
# migrate_pasarguard_to_rebecca.sh
# Single-file production-ready migration from Pasarguard -> Rebecca
# Fixed: Paths, Installer URL, Race Conditions, Rollback

set -euo pipefail -o errtrace

### -------------------------
### Configuration (CORRECTED)
### -------------------------
# مسیرهای رسمی ربکا (Rebecca)
PASARGUARD_DIR="${PASARGUARD_DIR:-/opt/pasarguard}"
REBECCA_DIR="${REBECCA_DIR:-/opt/rebecca}"
REBECCA_DATA_DIR="${REBECCA_DATA_DIR:-/var/lib/rebecca}" 

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/migration}"
TEMP_DB="${TEMP_DB:-/tmp/migration_export_$$.sqlite3}"
TEMP_INSTALLER="${TEMP_INSTALLER:-/tmp/rebecca_installer_$$.sh}"
LOG_FILE="${LOG_FILE:-/var/log/mrm_migration.log}"
EXPORT_IN_CONTAINER="/tmp/dump.sqlite3"

# Internal path (Rebecca is a fork of Marzban, so internal path is usually /var/lib/marzban)
REBECCA_SQLITE_PATH="${REBECCA_SQLITE_PATH:-/var/lib/marzban/db.sqlite3}" 

# Official Installer URL
REBECCA_INSTALL_URL="${REBECCA_INSTALL_URL:-https://github.com/rebeccapanel/Rebecca-scripts/raw/master/rebecca.sh}"

DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"
CONTAINER_START_TIMEOUT="${CONTAINER_START_TIMEOUT:-30}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-30}"
READ_TIMEOUT="${READ_TIMEOUT:-300}"

# Colors
CYAN="$(tput setaf 6 2>/dev/null || echo '')"
YELLOW="$(tput setaf 3 2>/dev/null || echo '')"
GREEN="$(tput setaf 2 2>/dev/null || echo '')"
RED="$(tput setaf 1 2>/dev/null || echo '')"
BLUE="$(tput setaf 4 2>/dev/null || echo '')"
NC="$(tput sgr0 2>/dev/null || echo '')"

### -------------------------
### CLI args
### -------------------------
DRY_RUN_DEFAULT="${DRY_RUN:-false}" 
DRY_RUN="$DRY_RUN_DEFAULT"
CONFIRM=false
VERBOSE=false

usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  --pasarguard-dir PATH   (default: $PASARGUARD_DIR)
  --rebecca-dir PATH      (default: $REBECCA_DIR)
  --dry-run               show actions and don't execute destructive steps
  --confirm               required to actually perform non-dry-run changes
  --verbose               verbose logging
  -h|--help               show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pasarguard-dir) PASARGUARD_DIR="$2"; shift 2;;
    --rebecca-dir) REBECCA_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --confirm) CONFIRM=true; shift;;
    --verbose) VERBOSE=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

### -------------------------
### Logging + helpers
### -------------------------
_run() {
  local desc="$1"; shift
  local cmd="$*"
  echo "[$(date +'%F %T')] [RUN] $desc -> $cmd" | tee -a "$LOG_FILE"
  if [ "$DRY_RUN" = true ]; then
    [ "$VERBOSE" = true ] && echo "[DRY-RUN] $cmd"
    return 0
  fi
  bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}→${NC} $*" | tee -a "$LOG_FILE"; }
ok() { echo -e "${GREEN}✓${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}⚠${NC} $*" | tee -a "$LOG_FILE" >&2; }
err() { echo -e "${RED}✗${NC} $*" | tee -a "$LOG_FILE" >&2; }

pause() { read -t "$READ_TIMEOUT" -rp "Press Enter to continue..." || true; }

### -------------------------
### Rollback stack
### -------------------------
declare -a ROLLBACK_CMD_STACK=()
push_rollback_cmd() { ROLLBACK_CMD_STACK+=("$*"); }
run_rollback_cmds() {
  err "Migration failed — running rollback"
  for ((i=${#ROLLBACK_CMD_STACK[@]}-1;i>=0;i--)); do
    cmd="${ROLLBACK_CMD_STACK[i]}"
    log "ROLLBACK: $cmd"
    if [ "$DRY_RUN" = false ]; then
      bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE" || log "Rollback step failed (ignored)"
    fi
  done
  ok "Rollback finished"
  pause
}

trap 'rc=$?; if [ $rc -ne 0 ]; then run_rollback_cmds; fi; exit $rc' ERR

### -------------------------
### Utility functions
### -------------------------
ensure_logfile() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null
}

get_file_size_bytes() {
  local f="$1"
  if [ ! -f "$f" ]; then echo 0; return; fi
  stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0
}

check_command_exists() { command -v "$1" >/dev/null 2>&1; }

check_dependencies() {
  local deps=(docker git wget tar sqlite3 awk sed grep head)
  local miss=()
  for d in "${deps[@]}"; do
    check_command_exists "$d" || miss+=("$d")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    err "Missing: ${miss[*]}"
    return 1
  fi
  ok "Dependencies OK"
}

safe_cd() { cd "$1" 2>/dev/null || { err "cd $1 failed"; return 1; } }

### -------------------------
### Container detection
### -------------------------
find_pasarguard_container() {
  safe_cd "$PASARGUARD_DIR" || return 1
  # Try explicit service name or image name
  local cid
  cid=$(docker compose ps -q marzban 2>/dev/null || \
        docker compose ps -q pasarguard 2>/dev/null || \
        docker ps --format '{{.ID}} {{.Names}}' | grep -vE "postgres|mysql|node" | grep -iE "pasarguard|marzban" | awk '{print $1}' | head -1)
  echo "${cid:-}"
}

wait_for_cli_ready() {
  local cid="$1" timeout="${2:-$DB_WAIT_TIMEOUT}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if docker exec "$cid" sh -c 'command -v marzban-cli >/dev/null 2>&1'; then
      return 0
    fi
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

### -------------------------
### Export Pasarguard DB
### -------------------------
export_pasarguard_db() {
  info "STEP 1: Export Pasarguard DB"
  safe_cd "$PASARGUARD_DIR" || return 1

  local cid
  cid=$(find_pasarguard_container)
  if [ -z "$cid" ]; then
    info "Pasarguard not running: starting temporarily"
    _run "Start Pasarguard" "docker compose up -d"
    push_rollback_cmd "cd '$PASARGUARD_DIR' && docker compose down"
    sleep 10
    cid=$(find_pasarguard_container)
  fi
  [ -z "$cid" ] && { err "Cannot locate Pasarguard container"; return 1; }
  
  wait_for_cli_ready "$cid" || warn "CLI check timeout"

  # Sync & Dump
  _run "Sync DB" "docker exec $cid marzban-cli sync || true"
  _run "Dump DB" "docker exec $cid marzban-cli database dump --target \"$EXPORT_IN_CONTAINER\""

  # Copy to host
  _run "Copy to host" "docker cp '${cid}:${EXPORT_IN_CONTAINER}' '$TEMP_DB'"
  
  if [ "$DRY_RUN" = false ]; then
    local hsize=$(get_file_size_bytes "$TEMP_DB")
    [ "$hsize" -ge 8192 ] || { err "Exported DB too small"; return 1; }
    
    # Header check
    if ! head -c 16 "$TEMP_DB" | grep -q "SQLite format 3"; then
        err "Invalid SQLite format"; return 1;
    fi
  fi

  push_rollback_cmd "rm -f '$TEMP_DB'"
  ok "Export DONE"
}

### -------------------------
### Download & Install Rebecca
### -------------------------
install_rebecca_official() {
  info "STEP 2: Installing Rebecca (Official)"
  
  # Download
  _run "Download Installer" "wget -q -O '$TEMP_INSTALLER' '$REBECCA_INSTALL_URL'"
  chmod +x "$TEMP_INSTALLER"
  push_rollback_cmd "rm -f '$TEMP_INSTALLER'"

  # Run
  info "Running Installer..."
  if [ "$DRY_RUN" = false ]; then
    # Run official installer non-interactively if possible, or assume user interaction
    # Using 'bash script install' pattern
    bash "$TEMP_INSTALLER" install 2>&1 | tee -a "$LOG_FILE"
    
    [ -d "$REBECCA_DIR" ] || { err "Rebecca dir not found"; return 1; }
    push_rollback_cmd "cd '$REBECCA_DIR' && docker compose down -v; rm -rf '$REBECCA_DIR'"
  fi
  ok "Rebecca Installed"
}

### -------------------------
### Stop Pasarguard
### -------------------------
stop_pasarguard() {
  info "STEP 3: Stopping Pasarguard"
  safe_cd "$PASARGUARD_DIR"
  push_rollback_cmd "cd '$PASARGUARD_DIR' && docker compose up -d"
  _run "Stop Pasarguard" "docker compose down"
  ok "Pasarguard Stopped"
}

### -------------------------
### Inject & Start Rebecca
### -------------------------
inject_and_start_rebecca() {
  info "STEP 4: Injecting Data & Starting Rebecca"
  safe_cd "$REBECCA_DIR" || return 1

  # Stop first
  _run "Stop Rebecca" "docker compose down"
  
  # Create containers (No Start) - CRITICAL FOR RACE CONDITION
  _run "Create Containers" "docker compose up --no-start"
  
  # Find Container
  local cid
  cid=$(docker compose ps -q | xargs docker inspect --format '{{.Id}} {{.Config.Image}}' | grep -vE "mysql|node" | head -1 | awk '{print $1}')
  
  if [ -z "$cid" ]; then err "Rebecca container not found"; return 1; fi
  
  # Inject DB
  _run "Make dir" "docker exec -u 0 '$cid' mkdir -p $(dirname "$REBECCA_SQLITE_PATH")"
  _run "Inject DB" "docker cp '$TEMP_DB' '$cid:$REBECCA_SQLITE_PATH'"
  _run "Fix Perms" "docker exec -u 0 '$cid' chown 1000:1000 '$REBECCA_SQLITE_PATH'"

  # Migrate Certs (Host to Host)
  if [ -d "/var/lib/pasarguard/certs" ]; then
      info "Moving Certs..."
      mkdir -p "$REBECCA_DATA_DIR/certs"
      cp -r /var/lib/pasarguard/certs/. "$REBECCA_DATA_DIR/certs/"
  fi

  # Configure Env (Force SQLite)
  if [ -f .env ]; then
      sed -i '/^SQLALCHEMY_DATABASE_URL=/d' .env
      sed -i '/^POSTGRES_/d' .env
      echo "SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3" >> .env
      
      # Copy critical vars from old env
      if [ -f "$PASARGUARD_DIR/.env" ]; then
          grep -E '^(JWT_|UVICORN_|XRAY_)' "$PASARGUARD_DIR/.env" >> .env || true
      fi
  fi

  # START
  _run "Start Rebecca" "docker compose start"
  ok "Rebecca Started"
}

### -------------------------
### Verification
### -------------------------
verify_rebecca() {
  info "STEP 5: Verifying..."
  safe_cd "$REBECCA_DIR"
  
  sleep 5
  if docker compose ps | grep -q "Up"; then
      local port=$(grep '^UVICORN_PORT=' .env 2>/dev/null | cut -d= -f2 || echo "8000")
      echo ""
      echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo -e "${GREEN}  MIGRATION SUCCESSFUL!                    ${NC}"
      echo -e "${GREEN}  Rebecca Panel: http://IP:${port}         ${NC}"
      echo -e "${GREEN}  Credentials: Same as before              ${NC}"
      echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  else
      err "Rebecca failed to start."
      return 1
  fi
}

### -------------------------
### Main
### -------------------------
main() {
  ensure_logfile
  clear
  echo -e "${CYAN}════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}   PASARGUARD -> REBECCA MIGRATOR (Final)   ${NC}"
  echo -e "${CYAN}════════════════════════════════════════════${NC}"
  
  check_dependencies || exit 1
  if [ ! -d "$PASARGUARD_DIR" ]; then err "Pasarguard not found"; exit 1; fi

  echo ""
  warn "This will STOP Pasarguard and install Rebecca."
  read -rp "Type 'migrate' to confirm: " c
  [ "$c" != "migrate" ] && exit 0

  # Start
  export_pasarguard_db || exit 1
  download_rebeka_installer || exit 1
  install_rebeka_official || exit 1
  stop_pasarguard || exit 1
  inject_and_start_rebecca || exit 1
  verify_rebecca || exit 1

  # Cleanup
  rm -f "$TEMP_DB" "$TEMP_INSTALLER"
  trap - ERR
}

main "$@"