#!/usr/bin/env bash
set -euo pipefail

ETC="${TURTLE_HOME:-/opt/turtle}/etc"
# Baked into the image at build time, separate from ETC so a CONFIG_PATH bind
# mount over ETC (see docker-compose.yml) can't hide the .dist templates.
ETC_DIST="${TURTLE_HOME:-/opt/turtle}/etc.dist"
DATA_DIR="${DATA_DIR:-/opt/turtle/data}"
LOGS_DIR="${LOGS_DIR:-/opt/turtle/logs}"
SQL_DIR="${SQL_DIR:-/opt/turtle/sql}"
MODULES_ROOT="${MODULES_DIR:-/opt/turtle/modules}"

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-mangos}"
DB_PASSWORD="${DB_PASSWORD:-mangos}"
DB_LOGIN="${DB_LOGIN:-tw_logon}"
DB_WORLD="${DB_WORLD:-tw_world}"
DB_CHAR="${DB_CHAR:-tw_char}"
DB_LOGS="${DB_LOGS:-tw_logs}"

WORLD_PORT="${WORLD_PORT:-8090}"
REALM_PORT="${REALM_PORT:-3724}"
REALM_ID="${REALM_ID:-1}"
BIND_IP="${BIND_IP:-0.0.0.0}"

LOG_SQL="${LOG_SQL:-0}"
AUTO_UPDATE="${DATABASE_AUTOUPDATE_ENABLED:-1}"

DB_INFO() {
  local db="$1"
  printf '%s;%s;%s;%s;%s' "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASSWORD}" "${db}"
}

set_conf() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
  else
    printf '\n%s = %s\n' "${key}" "${value}" >> "${file}"
  fi
}

ensure_conf() {
  local dist="$1" conf="$2"
  if [[ ! -f "${conf}" ]]; then
    if [[ ! -f "${dist}" ]]; then
      echo "Missing config template: ${dist}" >&2
      exit 1
    fi
    cp "${dist}" "${conf}"
  fi
}

mkdir -p "${ETC}"

ensure_conf "${ETC_DIST}/mangosd.conf.dist" "${ETC}/mangosd.conf"
ensure_conf "${ETC_DIST}/realmd.conf.dist" "${ETC}/realmd.conf"
if [[ -f "${ETC_DIST}/aiplayerbot.conf" ]]; then
  ensure_conf "${ETC_DIST}/aiplayerbot.conf" "${ETC}/aiplayerbot.conf"
fi

if [[ -f "${ETC_DIST}/ahbot.conf.dist" ]]; then
  ensure_conf "${ETC_DIST}/ahbot.conf.dist" "${ETC}/ahbot.conf"
fi

mkdir -p "${ETC}/modules"
for module_dir in "${MODULES_ROOT}"/*/; do
    [ -d "${module_dir}conf" ] || continue
    for dist_file in "${module_dir}conf/"*.conf.dist; do
        [ -f "${dist_file}" ] || continue
        BASENAME="$(basename "${dist_file}")"
        BASENAME="${BASENAME%.dist}"
        ensure_conf "${dist_file}" "${ETC}/modules/${BASENAME}"
    done
done


# mangosd
set_conf "${ETC}/mangosd.conf" "LoginDatabase.Info" "\"$(DB_INFO "${DB_LOGIN}")\""
set_conf "${ETC}/mangosd.conf" "WorldDatabase.Info" "\"$(DB_INFO "${DB_WORLD}")\""
set_conf "${ETC}/mangosd.conf" "CharacterDatabase.Info" "\"$(DB_INFO "${DB_CHAR}")\""
set_conf "${ETC}/mangosd.conf" "LogsDatabase.Info" "\"$(DB_INFO "${DB_LOGS}")\""
set_conf "${ETC}/mangosd.conf" "DataDir" "\"${DATA_DIR}\""
set_conf "${ETC}/mangosd.conf" "LogsDir" "\"${LOGS_DIR}\""
set_conf "${ETC}/mangosd.conf" "WorldServerPort" "${WORLD_PORT}"
set_conf "${ETC}/mangosd.conf" "BindIP" "\"${BIND_IP}\""
set_conf "${ETC}/mangosd.conf" "RealmID" "${REALM_ID}"
set_conf "${ETC}/mangosd.conf" "LogSQL" "${LOG_SQL}"
set_conf "${ETC}/mangosd.conf" "Database.AutoUpdate.Enabled" "${AUTO_UPDATE}"
set_conf "${ETC}/mangosd.conf" "Database.AutoUpdate.Path" "\"${SQL_DIR}/\""

# realmd (note: key name has no dots between LoginDatabase and Info)
set_conf "${ETC}/realmd.conf" "LoginDatabaseInfo" "\"$(DB_INFO "${DB_LOGIN}")\""
set_conf "${ETC}/realmd.conf" "RealmServerPort" "${REALM_PORT}"
set_conf "${ETC}/realmd.conf" "BindIP" "\"${BIND_IP}\""

echo "Configs rendered under ${ETC}"
