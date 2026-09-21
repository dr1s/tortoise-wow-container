#!/usr/bin/env bash
# Initialise / update the Turtle WoW databases.
# Safe to re-run: subsequent runs apply missing migrations and refresh the realmlist.
set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
MARKER_DIR="${INIT_MARKER_DIR:-/var/lib/turtle-init}"
MARKER_FILE="${MARKER_DIR}/initialized"
SQL_ROOT="${SQL_DIR:-/opt/turtle/sql}"
MODULES_ROOT="${MODULES_DIR:-/opt/turtle/modules}"

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
DB_USER="${DB_USER:-mangos}"
DB_PASSWORD="${DB_PASSWORD:-mangos}"
DB_LOGIN="${DB_LOGIN:-tw_logon}"
DB_WORLD="${DB_WORLD:-tw_world}"
DB_CHAR="${DB_CHAR:-tw_char}"
DB_LOGS="${DB_LOGS:-tw_logs}"

REALM_NAME="${REALM_NAME:-TurtleWoW}"
REALM_ADDRESS="${REALM_ADDRESS:-127.0.0.1}"
WORLD_PORT="${WORLD_PORT:-8090}"
REALM_ID="${REALM_ID:-1}"

shopt -s nullglob

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------
validate_config() {
  if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
    echo "DB_ROOT_PASSWORD (or MYSQL_ROOT_PASSWORD) is required." >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Low-level helpers
# ------------------------------------------------------------------------------
mysql_root() {
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" --protocol=TCP "$@"
}

db_dir_to_db_name() {
  case "${1}" in
    world)             echo "${DB_WORLD}" ;;
    char|characters)   echo "${DB_CHAR}" ;;
    auth|login)        echo "${DB_LOGIN}" ;;
    logs)              echo "${DB_LOGS}" ;;
    *)                 echo "" ;;
  esac
}

record_migration() {
  local target_db="${1}"
  local module="${2}"
  local f="${3}"
  local n h
  n="$(basename "${f}" .sql)"
  h="$(sha1sum "${f}" | awk '{ print toupper($1) }')"
  mysql_root -e "
    INSERT INTO \`${target_db}\`.migrations (Name, Module, Hash, AppliedAt)
    VALUES ('${n}','${module}','${h}',NOW())
    ON DUPLICATE KEY UPDATE Hash='${h}', AppliedAt=NOW();
  "
}

refresh_realmlist() {
  echo "Refreshing realmlist..."
  mysql_root <<SQL
INSERT INTO ${DB_LOGIN}.realmlist
  (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel, realmbuilds)
VALUES
  (${REALM_ID}, '${REALM_NAME}', '${REALM_ADDRESS}', ${WORLD_PORT}, 0, 0, 1, 0, '7272')
ON DUPLICATE KEY UPDATE
  name = VALUES(name),
  address = VALUES(address),
  port = VALUES(port),
  icon = VALUES(icon),
  realmflags = VALUES(realmflags),
  timezone = VALUES(timezone),
  allowedSecurityLevel = VALUES(allowedSecurityLevel),
  realmbuilds = VALUES(realmbuilds);
SQL
}

# ------------------------------------------------------------------------------
# Migration helpers
# ------------------------------------------------------------------------------
discover_sql_files() {
  local sql_dir="${1}"
  find "${sql_dir}" -type f -name "*.sql" -printf '%d %p\0' \
    | sort -z -k1,1nr -k2 \
    | cut -z -d' ' -f2-
}

apply_migrations() {
  local module="${1}"
  local target_db="${2}"
  local sql_dir="${3}"
  local label="${module:-core}"

  local files=()
  local f
  while IFS= read -r -d '' f; do
    [[ -n "${f}" ]] && files+=("${f}")
  done < <(discover_sql_files "${sql_dir}")

  if [[ "${#files[@]}" -eq 0 ]]; then
    return 0
  fi

  local applied_file
  applied_file="$(mktemp)"

  mysql_root -N -e "SELECT Name FROM \`${target_db}\`.migrations WHERE Module='${module}';" 2>/dev/null > "${applied_file}" || true

  local missing=()
  local n
  for f in "${files[@]}"; do
    n="$(basename "${f}" .sql)"
    if ! grep -qxF "${n}" "${applied_file}" 2>/dev/null; then
      missing+=("${f}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Applying ${#missing[@]} missing migration(s) for '${label}'..."
    for f in "${missing[@]}"; do
      echo "  -> $(basename "${f}")"
      mysql_root --force "${target_db}" < "${f}" || true
      record_migration "${target_db}" "${module}" "${f}"
    done
  fi

  echo "Refreshing migration hashes for '${label}'..."
  for f in "${files[@]}"; do
    record_migration "${target_db}" "${module}" "${f}"
  done

  rm -f "${applied_file}"
}

apply_module_migrations_all() {
  if [[ ! -d "${MODULES_ROOT}" ]]; then
    return 0
  fi

  local module_dir
  for module_dir in "${MODULES_ROOT}"/*/; do
    local module_name sql_dir
    module_name="$(basename "${module_dir}")"
    sql_dir="${module_dir}/data/sql"
    [[ -d "${sql_dir}" ]] || continue

    local db_dir
    for db_dir in "${sql_dir}"/*/; do
      local db_dir_name target_db
      db_dir_name="$(basename "${db_dir}")"
      target_db="$(db_dir_to_db_name "${db_dir_name}")"
      if [[ -z "${target_db}" ]]; then
        echo "WARNING: Unknown module SQL directory '${db_dir_name}' for module '${module_name}'; skipping." >&2
        continue
      fi
      apply_migrations "${module_name}" "${target_db}" "${db_dir}"
    done
  done
}

# ------------------------------------------------------------------------------
# Main-step functions
# ------------------------------------------------------------------------------
wait_for_db() {
  echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
  local i
  for i in $(seq 1 90); do
    if mysql_root -e "SELECT 1" &>/dev/null; then
      echo "MariaDB is ready."
      return 0
    fi
    if [[ "${i}" -eq 90 ]]; then
      echo "MariaDB did not become ready in time." >&2
      exit 1
    fi
    sleep 2
  done
}

create_databases() {
  if [[ ! -f "${SQL_ROOT}/create_databases.sql" ]]; then
    echo "Missing ${SQL_ROOT}/create_databases.sql" >&2
    exit 1
  fi

  echo "Creating databases and base schemas..."
  mysql_root < "${SQL_ROOT}/create_databases.sql"
}

ensure_character_inventory_copy() {
  local character_inventory_copy_sql="${SQL_ROOT}/character-inventory-copy.sql"
  if [[ ! -f "${character_inventory_copy_sql}" ]]; then
    echo "Missing ${character_inventory_copy_sql}" >&2
    exit 1
  fi
  echo "Ensuring character_inventory_copy exists..."
  mysql_root "${DB_CHAR}" < "${character_inventory_copy_sql}"
}

create_app_user() {
  echo "Creating application user '${DB_USER}' and grants..."
  mysql_root <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_LOGIN}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_WORLD}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_CHAR}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_LOGS}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

import_base_world() {
  echo "Importing world content from sql/base (this can take several minutes)..."
  local base_files=("${SQL_ROOT}"/base/*.sql)
  if [[ "${#base_files[@]}" -eq 0 ]]; then
    echo "No SQL files found under ${SQL_ROOT}/base" >&2
    exit 1
  fi

  local f
  for f in "${base_files[@]}"; do
    echo "  -> $(basename "${f}")"
    mysql_root "${DB_WORLD}" < "${f}"
  done
}

ensure_migrations_module_column() {
  local db
  for db in "${DB_WORLD}" "${DB_CHAR}" "${DB_LOGIN}"; do
    echo "Ensuring ${db}.migrations.Module exists..."
    mysql_root -e "
      ALTER TABLE \`${db}\`.migrations
      ADD COLUMN IF NOT EXISTS Module VARCHAR(255) NOT NULL DEFAULT '';
    "
  done
}

verify_schema() {
  local col_count
  col_count="$(mysql_root -N -e "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_WORLD}' AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';")"
  if [[ "${col_count}" != "1" ]]; then
    echo "WARNING: spell_template.script_name not found after migrations (got count=${col_count})." >&2
    return 0
  fi
}

write_marker() {
  mkdir -p "${MARKER_DIR}"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
}

# ------------------------------------------------------------------------------
# Main entry point
# ------------------------------------------------------------------------------
main() {
  validate_config
  wait_for_db

  if [[ -f "${MARKER_FILE}" ]]; then
    echo "Init marker found (${MARKER_FILE}); skipping first-run database setup."
    apply_migrations "" "${DB_WORLD}" "${SQL_ROOT}/database_updates"
    apply_module_migrations_all
    refresh_realmlist
    exit 0
  fi

  create_databases
  ensure_character_inventory_copy
  create_app_user
  import_base_world
  ensure_migrations_module_column
  apply_migrations "" "${DB_WORLD}" "${SQL_ROOT}/database_updates"
  verify_schema
  apply_module_migrations_all
  refresh_realmlist
  write_marker

  echo "Database init complete."
}

main "$@"
