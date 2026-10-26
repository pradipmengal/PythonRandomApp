#!/usr/bin/env bash
#
# deploy.sh - lifecycle manager for the random-data loader.
#
#   ./deploy.sh start      create venv, install deps, start the app
#   ./deploy.sh stop       stop the app
#   ./deploy.sh restart    stop + start
#   ./deploy.sh status     show app + database status
#   ./deploy.sh logs [-f]  show (or follow) the app log
#   ./deploy.sh init-db    create the Postgres role + database
#   ./deploy.sh destroy    remove app files (--drop-db also drops the database)
#
set -Eeuo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

RUN_DIR="$APP_DIR/.run"
LOG_DIR="$APP_DIR/logs"
PID_FILE="$RUN_DIR/app.pid"
LOG_FILE="$LOG_DIR/app.log"
VENV_DIR="$APP_DIR/.venv"
REQ_FILE="$APP_DIR/requirements.txt"
DEPS_STAMP="$VENV_DIR/.requirements.sha256"

# ---------------------------------------------------------------------------
# Configuration (environment overrides, then .env)
# ---------------------------------------------------------------------------
if [[ -f "$APP_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$APP_DIR/.env"
  set +a
fi

APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-8000}"
PG_APP_USER="${PG_APP_USER:-randomdata}"
PG_APP_PASSWORD="${PG_APP_PASSWORD:-randomdata}"
PG_APP_DB="${PG_APP_DB:-randomdata}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
DATABASE_URL="${DATABASE_URL:-postgresql://${PG_APP_USER}:${PG_APP_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_APP_DB}}"
DIRECT_URL="${DIRECT_DATABASE_URL:-postgresql://${PG_APP_USER}:${PG_APP_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_APP_DB}}"
PGBOUNCER_HOST="${PGBOUNCER_HOST:-127.0.0.1}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
PGBOUNCER_URL="${PGBOUNCER_DATABASE_URL:-postgresql://${PG_APP_USER}:${PG_APP_PASSWORD}@${PGBOUNCER_HOST}:${PGBOUNCER_PORT}/${PG_APP_DB}}"
APP_DB_ENDPOINT="$(printf '%s' "$DATABASE_URL" | sed -E 's#^[^:]+://([^@]*@)?([^/]+)/.*#\2#')"

export APP_HOST APP_PORT PG_APP_USER PG_APP_PASSWORD PG_APP_DB PG_HOST PG_PORT \
  DATABASE_URL DIRECT_URL PGBOUNCER_HOST PGBOUNCER_PORT PGBOUNCER_URL APP_DB_ENDPOINT

HEALTH_HOST="$APP_HOST"
if [[ "$HEALTH_HOST" == "0.0.0.0" || "$HEALTH_HOST" == "::" ]]; then
  HEALTH_HOST="127.0.0.1"
fi
BASE_URL="http://${HEALTH_HOST}:${APP_PORT}"

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

usage() {
  cat <<EOF
Usage: ./deploy.sh <command> [options]

Commands:
  start               create venv, install deps, start the app
  stop                stop the app
  restart             stop + start
  status              show app and database status
  logs [-f]           show app log (-f to follow)
  creds               write all connection details to creds.txt (chmod 600)
  init-db             create the Postgres role and database (needs sudo)
  destroy [options]   stop and delete .venv, .run and logs
                        --yes       do not ask for confirmation
                        --drop-db   also drop the database and role (needs sudo)

Configuration (environment or .env):
  APP_HOST=${APP_HOST}
  APP_PORT=${APP_PORT}
  Database=${PG_APP_USER}@${PG_HOST}:${PG_PORT}/${PG_APP_DB}
  URL=${BASE_URL}
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

current_pid() { cat "$PID_FILE" 2>/dev/null || true; }

ensure_venv() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    info "Creating Python virtualenv in .venv"
    python3 -m venv "$VENV_DIR" 2>/dev/null \
      || die "Could not create venv. Install it with: sudo apt install python3.14-venv"
  fi
  local want have
  want="$(sha256sum "$REQ_FILE" | awk '{print $1}')"
  have="$(cat "$DEPS_STAMP" 2>/dev/null || true)"
  if [[ "$want" != "$have" ]]; then
    info "Installing Python dependencies"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    "$VENV_DIR/bin/pip" install --quiet -r "$REQ_FILE" \
      || die "Dependency installation failed"
    printf '%s\n' "$want" > "$DEPS_STAMP"
  fi
}

conn_ok() {
  [[ -n "${1:-}" && -x "$VENV_DIR/bin/python" ]] || return 1
  PGCONN="$1" "$VENV_DIR/bin/python" - <<'PY' >/dev/null 2>&1
import os
import psycopg

with psycopg.connect(os.environ["PGCONN"], connect_timeout=3) as conn:
    conn.execute("SELECT 1")
PY
}

# App path (through PgBouncer, per DATABASE_URL)
db_reachable() { conn_ok "$DATABASE_URL"; }
# Direct Postgres path (admin / bootstrap)
direct_reachable() { conn_ok "$DIRECT_URL"; }
# PgBouncer listening and accepting the app's credentials
pgbouncer_reachable() { conn_ok "$PGBOUNCER_URL"; }

health_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$BASE_URL/healthz" >/dev/null 2>&1
  else
    "$VENV_DIR/bin/python" - "$BASE_URL/healthz" <<'PY' >/dev/null 2>&1
import sys
import urllib.request
urllib.request.urlopen(sys.argv[1], timeout=2)
PY
  fi
}

port_in_use() {
  "$VENV_DIR/bin/python" - "$HEALTH_HOST" "$APP_PORT" <<'PY'
import socket
import sys

sock = socket.socket()
sock.settimeout(0.3)
sys.exit(0 if sock.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)
PY
}

init_db() {
  command -v psql >/dev/null 2>&1 \
    || die "psql not found. Is PostgreSQL installed and on PATH?"
  sudo -n true 2>/dev/null \
    || die "init-db needs passwordless sudo to run psql as the 'postgres' OS user."

  info "Ensuring role '$PG_APP_USER' and database '$PG_APP_DB'"
  (
    cd /tmp
    sudo -u postgres psql -X -q -tA -v ON_ERROR_STOP=1 -d postgres \
      -v role="$PG_APP_USER" -v pass="$PG_APP_PASSWORD" -v db="$PG_APP_DB" <<'SQL'
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE',
  :'role', :'pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format(
  'ALTER ROLE %I WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE',
  :'role', :'pass')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')\gexec
SQL
  )
  info "Database ready"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
  if is_running; then
    info "Already running (pid $(current_pid)) at $BASE_URL"
    return 0
  fi

  ensure_venv

  if ! db_reachable; then
    if direct_reachable; then
      die "Postgres is reachable directly, but PgBouncer (${PGBOUNCER_HOST}:${PGBOUNCER_PORT}) is not. Start it: sudo systemctl start pgbouncer"
    fi
    warn "Cannot reach Postgres directly with the configured credentials."
    if command -v psql >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      init_db
    fi
    db_reachable || die "Postgres is unreachable. Start it (sudo systemctl start postgresql-15.1) or adjust .env."
  fi

  if port_in_use; then
    die "Port ${APP_PORT} is already in use by another process."
  fi

  mkdir -p "$RUN_DIR" "$LOG_DIR"
  info "Starting app on ${APP_HOST}:${APP_PORT}"
  nohup "$VENV_DIR/bin/uvicorn" app.main:app \
    --host "$APP_HOST" --port "$APP_PORT" --no-access-log >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  local i
  for i in $(seq 1 60); do
    if ! is_running; then
      warn "App exited during startup. Last log lines:"
      tail -n 30 "$LOG_FILE" >&2 || true
      rm -f "$PID_FILE"
      exit 1
    fi
    if health_ok; then
      info "App is up: ${C_OK}${BASE_URL}${C_OFF}"
      dim "App DB:    ${APP_DB_ENDPOINT} (DATABASE_URL)"
      dim "Postgres:  ${PG_APP_USER}@${PG_HOST}:${PG_PORT}/${PG_APP_DB} (direct)"
      dim "Logs:     $LOG_FILE"
      return 0
    fi
    sleep 0.5
  done

  die "App did not become healthy within 30s. Check: ./deploy.sh logs"
}

cmd_stop() {
  if ! is_running; then
    rm -f "$PID_FILE"
    info "App is not running"
    return 0
  fi

  local pid
  pid="$(current_pid)"
  info "Stopping app (pid $pid)"
  kill -TERM "$pid" 2>/dev/null || true

  local i
  for i in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done

  if kill -0 "$pid" 2>/dev/null; then
    warn "App did not stop gracefully; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  info "Stopped"
}

cmd_status() {
  if is_running; then
    printf 'app:      %srunning%s (pid %s)\n' "$C_OK" "$C_OFF" "$(current_pid)"
    printf 'url:      %s\n' "$BASE_URL"
    if health_ok; then
      printf 'health:   %sok%s\n' "$C_OK" "$C_OFF"
    else
      printf 'health:   %snot responding%s\n' "$C_ERR" "$C_OFF"
    fi
  else
    printf 'app:      %sstopped%s\n' "$C_WARN" "$C_OFF"
  fi

  if direct_reachable; then
    printf 'postgres:  %sconnected%s (%s@%s:%s/%s)\n' \
      "$C_OK" "$C_OFF" "$PG_APP_USER" "$PG_HOST" "$PG_PORT" "$PG_APP_DB"
  else
    printf 'postgres:  %snot reachable%s (%s@%s:%s/%s)\n' \
      "$C_ERR" "$C_OFF" "$PG_APP_USER" "$PG_HOST" "$PG_PORT" "$PG_APP_DB"
  fi

  if pgbouncer_reachable; then
    printf 'pgbouncer: %sconnected%s (%s:%s)\n' \
      "$C_OK" "$C_OFF" "$PGBOUNCER_HOST" "$PGBOUNCER_PORT"
  else
    printf 'pgbouncer: %snot reachable%s (%s:%s)\n' \
      "$C_ERR" "$C_OFF" "$PGBOUNCER_HOST" "$PGBOUNCER_PORT"
  fi

  printf 'app db:    %s (DATABASE_URL)\n' "$APP_DB_ENDPOINT"
}

cmd_logs() {
  [[ -f "$LOG_FILE" ]] || die "No log file yet at $LOG_FILE"
  if [[ "${1:-}" == "-f" ]]; then
    tail -n 100 -f "$LOG_FILE"
  else
    tail -n 100 "$LOG_FILE"
  fi
}

cmd_creds() {
  local out="$APP_DIR/creds.txt"
  local public_ip="" public_url token
  if [[ "$APP_HOST" == "0.0.0.0" ]]; then
    token="$(curl -fsS --max-time 2 -X PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      public_ip="$(curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    fi
  fi
  if [[ -n "$public_ip" ]]; then
    public_url="http://${public_ip}:${APP_PORT}"
  else
    public_url="$BASE_URL"
  fi

  local pgb_public_lines="" pgb_public_note="PostgreSQL and PgBouncer listen on localhost only."
  local pg_public_lines="" pg_public_note="PostgreSQL listens on localhost only."
  if ss -lntH "sport = :${PG_PORT}" 2>/dev/null | grep -qE '(0\.0\.0\.0|\*|\[::\]):'"${PG_PORT}"'[[:space:]]'; then
    pg_public_note="PostgreSQL is bound to all interfaces (public); pg_hba.conf allows only db/user '${PG_APP_DB}'/'${PG_APP_USER}' remotely (superuser stays local)."
    if [[ -n "$public_ip" ]]; then
      pg_public_lines="
  Public host       : ${public_ip}
  Public URL        : postgresql://${PG_APP_USER}:${PG_APP_PASSWORD}@${public_ip}:${PG_PORT}/${PG_APP_DB}
  Public note       : user '${PG_APP_USER}' only; user 'postgres' is rejected remotely"
    fi
  fi
  if ss -lntH "sport = :${PGBOUNCER_PORT}" 2>/dev/null | grep -qE '(0\.0\.0\.0|\*|\[::\]):'"${PGBOUNCER_PORT}"'[[:space:]]'; then
    pgb_public_note="PgBouncer is bound to all interfaces (public)."
    if [[ -n "$public_ip" ]]; then
      pgb_public_lines="
  Public host       : ${public_ip}
  Public URL        : postgresql://${PG_APP_USER}:${PG_APP_PASSWORD}@${public_ip}:${PGBOUNCER_PORT}/${PG_APP_DB}
  Public admin      : PGPASSWORD='${PG_APP_PASSWORD}' psql -h ${public_ip} -p ${PGBOUNCER_PORT} -U ${PG_APP_USER} -d pgbouncer"
    fi
  fi

  umask 077
  cat > "$out" <<EOF
# Random Data Loader - credentials and connection details
# Generated: $(date -u '+%Y-%m-%d %H:%M UTC')
# Keep this file private. It is chmod 600 and listed in .gitignore.

APPLICATION
  Local URL         : http://127.0.0.1:${APP_PORT}
  Public URL        : ${public_url}
  Health check      : ${BASE_URL}/healthz
  Listen address    : ${APP_HOST}:${APP_PORT}
  Manage            : cd ${APP_DIR} && ./deploy.sh start|stop|restart|status|logs|destroy

POSTGRESQL (direct)
  Host              : ${PG_HOST}
  Port              : ${PG_PORT}
  Database          : ${PG_APP_DB}
  User              : ${PG_APP_USER}
  Password          : ${PG_APP_PASSWORD}
  Connection URL    : ${DIRECT_URL}${pg_public_lines}
  Superuser         : postgres (local peer auth only; no TCP password)
  Service           : postgresql-15.1
  Data directory    : /var/lib/postgresql/15.1/data
  Log file          : /var/log/postgresql/postgresql-15.1-YYYY-MM-DD.log

PGBOUNCER
  Host              : ${PGBOUNCER_HOST}
  Port              : ${PGBOUNCER_PORT}
  Pool mode         : transaction
  Auth type         : scram-sha-256
  Database mapping  : ${PG_APP_DB} -> ${PG_HOST}:${PG_PORT}/${PG_APP_DB}
  User              : ${PG_APP_USER}
  Password          : ${PG_APP_PASSWORD}
  Connection URL    : ${PGBOUNCER_URL}${pgb_public_lines}
  Admin console     : PGPASSWORD='${PG_APP_PASSWORD}' psql -h ${PGBOUNCER_HOST} -p ${PGBOUNCER_PORT} -U ${PG_APP_USER} -d pgbouncer
  Show pools        : PGPASSWORD='${PG_APP_PASSWORD}' psql -h ${PGBOUNCER_HOST} -p ${PGBOUNCER_PORT} -U ${PG_APP_USER} -d pgbouncer -c "SHOW POOLS;"
  Config            : /etc/pgbouncer/pgbouncer.ini
  User list         : /etc/pgbouncer/userlist.txt
  Log file          : /var/log/postgresql/pgbouncer.log
  Service           : pgbouncer (sudo systemctl status|restart pgbouncer)

APP DATABASE CONFIG (.env)
  DATABASE_URL      : ${DATABASE_URL}
  (the app connects through PgBouncer)

NOTES
  - ${pg_public_note}
  - ${pgb_public_note}
  - Public database access on 5432 and 6432 is plaintext (TLS is off). Use a
    strong password, keep this file private, and restrict the ports at the
    firewall/security group when possible.
  - If you change credentials in .env, also update /etc/pgbouncer/userlist.txt,
    then run: ./deploy.sh destroy --yes --drop-db && ./deploy.sh start
  - Keep this file private (chmod 600).
EOF
  chmod 600 "$out"
  info "Wrote $out (chmod 600)"
}

cmd_destroy() {
  local assume_yes=0 drop_db=0 arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) assume_yes=1 ;;
      --drop-db) drop_db=1 ;;
      *) die "Unknown option for destroy: $arg" ;;
    esac
  done

  cmd_stop

  if [[ $assume_yes -eq 0 ]]; then
    printf 'This deletes .venv, .run and logs'
    if [[ $drop_db -eq 1 ]]; then
      printf ', plus database "%s" and role "%s"' "$PG_APP_DB" "$PG_APP_USER"
    fi
    printf '. Continue? [y/N] '
    local answer
    read -r answer || true
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      info "Aborted"
      return 0
    fi
  fi

  rm -rf "$VENV_DIR" "$RUN_DIR" "$LOG_DIR"
  info "Removed app files (.venv, .run, logs)"

  if [[ $drop_db -eq 1 ]]; then
    command -v psql >/dev/null 2>&1 || die "psql not found; cannot drop the database"
    sudo -n true 2>/dev/null || die "Dropping the database needs passwordless sudo"
    (
      cd /tmp
      sudo -u postgres psql -X -q -tA -v ON_ERROR_STOP=1 -d postgres \
        -v role="$PG_APP_USER" -v db="$PG_APP_DB" <<'SQL'
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = :'db' AND pid <> pg_backend_pid();
SELECT format('DROP DATABASE IF EXISTS %I', :'db')\gexec
SELECT format('DROP ROLE IF EXISTS %I', :'role')\gexec
SQL
    )
    info "Dropped database '$PG_APP_DB' and role '$PG_APP_USER'"
  fi

  info "Destroyed"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  start)         cmd_start ;;
  stop)          cmd_stop ;;
  restart)       cmd_stop; cmd_start ;;
  status)        cmd_status ;;
  logs)          cmd_logs "$@" ;;
  creds|credentials) cmd_creds ;;
  init-db|initdb) init_db ;;
  destroy)       cmd_destroy "$@" ;;
  help|-h|--help) usage ;;
  *)             usage; die "Unknown command: $COMMAND" ;;
esac
