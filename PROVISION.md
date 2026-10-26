# Fresh EC2 Provisioning Runbook

**PostgreSQL 15.1 (source build) + PgBouncer + FastAPI random-data loader**

This document is written for an **agentic AI or a human operator** rebuilding the
stack from zero on a fresh Ubuntu EC2 instance. It is intentionally
command-oriented: run the phases in order, stop at the first failed checkpoint,
and do not skip the verification steps.

Tested on:

| Item | Value |
|---|---|
| OS | Ubuntu 26.04.1 LTS |
| Instance | AWS EC2 `t3.micro` (2 vCPU, 908 MiB RAM) |
| Public IP | dynamic — assigned at launch |
| PostgreSQL | **15.1**, built from source |
| PgBouncer | 1.25.1 (Ubuntu package) |
| Python | 3.14 (FastAPI 0.161.1 / Uvicorn 0.54.0 / psycopg 3.3.6) |

> This is a **fresh-host** runbook. If the stack already exists and contains
> data, use `SETUP.md` for operations instead. Phases below are mostly
> idempotent, but `initdb` and `CREATE DATABASE` are not reversible.

---

## 0. Agent contract

1. Run commands **on the new EC2 instance** as the default `ubuntu` user with
   `sudo` (EC2's passwordless sudo). Do not run the whole runbook as root.
2. Use **one shell session** if possible. Every phase block begins by sourcing
   the saved variable file, so separate shells are also fine.
3. Never print, commit, or paste the generated passwords. They live in
   `$HOME/.randomdata-secrets` (mode 600) and the app's `.env` (mode 600).
4. Use `curl -fsS` and `set -Eeuo pipefail`; check exit codes.
5. If a checkpoint fails, **stop** and use §12 Troubleshooting. Do not continue
   to the next phase with a broken dependency.
6. The app is deliberately **not** a systemd service (same as the reference
   host). It is started with `./deploy.sh start`; see §11.5 for an optional
   unit.
7. Public database exposure is optional but defaults to **on** to match the
   reference deployment. Read §9 before exposing it.

### 0.1 Differences from the reference host

The reference host is a **legacy** deployment. Do not copy its credentials or
role attributes to a fresh host.

| Aspect | Reference host | This runbook |
|---|---|---|
| `randomdata` role | `SUPERUSER`, weak password | `NOSUPERUSER`, generated 48-char hex password |
| `postgres` superuser | local password set (and a hardcoded line in `creds.txt`) | peer auth only; no TCP password |
| Data | existing runs/events | empty database |
| App startup | manual `./deploy.sh start` | same by default; optional systemd unit in §11.5 |
| TLS | off | off by default; optional in §11.2 |
| Public ports | 8000, 5432, 6432 | same by default; controlled by `EXPOSE_*` |
| PgBouncer | transaction pooling, SCRAM | same |

If you need the old behavior for compatibility testing, create the role
manually instead of using §6 — but do not do that for a normal deployment.

---

## 1. Fixed inputs and variables

| Variable | Default | Meaning |
|---|---|---|
| `APP_DIR` | `/home/ubuntu/random-data-app` | application checkout |
| `APP_PORT` | `8000` | dashboard / API |
| `EXPOSE_APP` | `1` | bind app to `0.0.0.0` (public) |
| `EXPOSE_DB` | `1` | bind PostgreSQL and PgBouncer to `0.0.0.0` |
| `PG_VERSION` | `15.1` | required version |
| `PG_PREFIX` | `/usr/local/pgsql-15.1` | install prefix |
| `PGDATA` | `/var/lib/postgresql/15.1/data` | cluster directory |
| `PG_SERVICE` | `postgresql-15.1` | systemd unit name |
| `DB_NAME` / `DB_USER` | `randomdata` | app database and role |
| `PGBOUNCER_PORT` | `6432` | pooler |
| `DB_ALLOWED_CIDR` | `0.0.0.0/0` | SG source for 5432/6432 |
| `APP_ALLOWED_CIDR` | `0.0.0.0/0` | SG source for 8000 |
| `SG_NAME` | `launch-wizard-1` | EC2 security group name |
| `AWS_REGION` | `ap-south-1` | region containing the security group |
| `MAKE_JOBS` | `2` | keep low on a 908 MiB host |

### 1.1 Save variables and generate the password

```bash
set -Eeuo pipefail

export APP_DIR=/home/ubuntu/random-data-app
export APP_PORT=8000
export EXPOSE_APP=1          # 0 = dashboard on loopback only
export EXPOSE_DB=1           # 0 = PostgreSQL/PgBouncer on loopback only
export PG_VERSION=15.1
export PG_PREFIX=/usr/local/pgsql-15.1
export PGDATA=/var/lib/postgresql/15.1/data
export PG_LOG_DIR=/var/log/postgresql
export PG_SERVICE=postgresql-15.1
export DB_NAME=randomdata
export DB_USER=randomdata
export PGBOUNCER_PORT=6432
export APP_REPO=https://github.com/pradipmengal/PythonRandomApp.git
export APP_BRANCH=master
export DB_ALLOWED_CIDR=0.0.0.0/0
export APP_ALLOWED_CIDR=0.0.0.0/0
export SG_NAME=launch-wizard-1
export AWS_REGION=ap-south-1
export MAKE_JOBS=2
export SECRETS_FILE="$HOME/.randomdata-secrets"
export PROVISION_ENV="$HOME/.randomdata-provision.env"

cat > "$PROVISION_ENV" <<EOF
export APP_DIR=$APP_DIR
export APP_PORT=$APP_PORT
export EXPOSE_APP=$EXPOSE_APP
export EXPOSE_DB=$EXPOSE_DB
export PG_VERSION=$PG_VERSION
export PG_PREFIX=$PG_PREFIX
export PGDATA=$PGDATA
export PG_LOG_DIR=$PG_LOG_DIR
export PG_SERVICE=$PG_SERVICE
export DB_NAME=$DB_NAME
export DB_USER=$DB_USER
export PGBOUNCER_PORT=$PGBOUNCER_PORT
export APP_REPO=$APP_REPO
export APP_BRANCH=$APP_BRANCH
export DB_ALLOWED_CIDR=$DB_ALLOWED_CIDR
export APP_ALLOWED_CIDR=$APP_ALLOWED_CIDR
export SG_NAME=$SG_NAME
export AWS_REGION=$AWS_REGION
export MAKE_JOBS=$MAKE_JOBS
export SECRETS_FILE=$SECRETS_FILE
EOF
chmod 600 "$PROVISION_ENV"

# One strong password, reused for: DB role, PgBouncer userlist, .env.
# Hex only => safe in SQL, URLs and shell without escaping.
umask 077
if [[ ! -s "$SECRETS_FILE" ]]; then
  printf 'DB_PASSWORD=%s\n' "$(python3 -c 'import secrets; print(secrets.token_hex(24))')" \
    > "$SECRETS_FILE"
fi
chmod 600 "$SECRETS_FILE"
source "$SECRETS_FILE"
source "$PROVISION_ENV"
export PATH="$PG_PREFIX/bin:$PATH"

echo "Variables saved. Password length: ${#DB_PASSWORD} (value hidden)."
```

From this point on, **every phase starts with**:

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"
```

---

## 2. Phase 0 — Preflight

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

grep -q '^ID=ubuntu' /etc/os-release || echo "WARNING: tested on Ubuntu only"
[[ "$(id -un)" == "ubuntu" ]] || echo "WARNING: expected user 'ubuntu', got $(id -un)"

sudo -n true || { echo "ERROR: passwordless sudo is required"; exit 1; }

echo "--- resources ---"
nproc
free -h
df -h /
echo "--- ports ---"
ss -lntp | grep -E ':(5432|6432|8000)\b' || echo "target ports are free"

# Abort only if a foreign PostgreSQL is already using 5432 on a fresh host.
if [[ ! -f "$PGDATA/PG_VERSION" ]] && ss -lntH 'sport = :5432' | grep -q .; then
  echo "ERROR: port 5432 is already in use:"
  ss -lntp 'sport = :5432'
  exit 1
fi

sudo systemctl is-active --quiet postgresql-15.1 2>/dev/null \
  && echo "NOTE: an existing postgresql-15.1 service is present (re-run mode)" || true
```

Checkpoint:

- `free -h` shows ~908 MiB RAM.
- No unrelated process is listening on 5432, 6432, or 8000.
- `sudo -n true` succeeds.

---

## 3. Phase 1 — Swap and OS packages

The reference host is a 908 MiB `t3.micro`; the PostgreSQL build and the app can
trigger the OOM killer without swap. Create 1 GiB swap first.

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential pkg-config ca-certificates curl wget bzip2 \
  openssl git rsync sudo \
  libreadline-dev zlib1g-dev libssl-dev libicu-dev \
  libxml2-dev libxslt1-dev \
  python3-venv

# Ubuntu names the venv package after the installed Python (3.12, 3.14, ...).
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "python${PY_VER}-venv"

# --- swap ---
if ! sudo swapon --show | grep -qw '/swapfile'; then
  if [[ ! -f /swapfile ]]; then
    sudo fallocate -l 1G /swapfile \
      || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
  fi
  sudo swapon /swapfile
  grep -q '^/swapfile[[:space:]]' /etc/fstab \
    || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

echo "--- versions ---"
gcc --version | head -1
make --version | head -1
python3 --version
echo "--- swap ---"
swapon --show
```

Checkpoint:

```bash
gcc --version | head -1          # present
make --version | head -1         # present
swapon --show                    # /swapfile, 1G
python3 -c 'import venv; print("venv ok")'
```

---

## 4. Phase 2 — Build PostgreSQL 15.1 from source

### 4.1 Source and checksum

```text
URL:    https://ftp.postgresql.org/pub/source/v15.1/postgresql-15.1.tar.bz2
SHA256: 64fdf23d734afad0dfe4077daca96ac51dcd697e68ae2d3d4ca6c45cb14e21ae
```

### 4.2 Compile and install

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

cd /usr/local/src

[[ -f postgresql-15.1.tar.bz2 ]] \
  || sudo curl -fLO https://ftp.postgresql.org/pub/source/v15.1/postgresql-15.1.tar.bz2

echo "64fdf23d734afad0dfe4077daca96ac51dcd697e68ae2d3d4ca6c45cb14e21ae  postgresql-15.1.tar.bz2" \
  | sha256sum -c -

[[ -d postgresql-15.1 ]] || sudo tar xjf postgresql-15.1.tar.bz2
sudo chown -R "$(id -un):$(id -gn)" /usr/local/src/postgresql-15.1
cd /usr/local/src/postgresql-15.1

./configure \
  --prefix="$PG_PREFIX" \
  --with-openssl \
  --with-icu \
  --with-libxml \
  --with-libxslt \
  --with-zlib \
  --with-readline \
  CFLAGS="-O2 -std=gnu17 -fpermissive"

make -j"$MAKE_JOBS"
sudo make install

# Make the binaries available to login shells.
echo 'export PATH=/usr/local/pgsql-15.1/bin:$PATH' \
  | sudo tee /etc/profile.d/postgresql-15.1.sh >/dev/null
sudo chmod 644 /etc/profile.d/postgresql-15.1.sh
export PATH="$PG_PREFIX/bin:$PATH"

"$PG_PREFIX/bin/postgres" --version
"$PG_PREFIX/bin/pg_config" --configure
```

Checkpoint:

```bash
"$PG_PREFIX/bin/postgres" --version
# PostgreSQL 15.1

"$PG_PREFIX/bin/initdb" --version
# initdb (PostgreSQL) 15.1

"$PG_PREFIX/bin/pg_config" --configure
# should include --prefix=/usr/local/pgsql-15.1 and the flags above
```

If `make` is killed by the OOM killer, verify swap is active, then retry with
`make -j1`.

---

## 5. Phase 3 — Cluster, configuration, and systemd

### 5.1 OS user and directories

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

getent group postgres >/dev/null || sudo groupadd --system postgres
id postgres >/dev/null 2>&1 \
  || sudo useradd --system --gid postgres \
       --home-dir /var/lib/postgresql --shell /bin/bash postgres

sudo install -d -m 0755 -o postgres -g postgres /var/lib/postgresql
sudo install -d -m 0755 -o postgres -g postgres /var/lib/postgresql/15.1
sudo install -d -m 0700 -o postgres -g postgres "$PGDATA"
sudo install -d -m 1775 -o root -g postgres "$PG_LOG_DIR"

id postgres
ls -ld "$PGDATA" "$PG_LOG_DIR"
```

### 5.2 Initialize the cluster (only once)

```bash
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  (cd /tmp && sudo -u postgres "$PG_PREFIX/bin/initdb" \
    -D "$PGDATA" \
    --encoding=UTF8 \
    --locale=C.UTF-8 \
    --auth-local=peer \
    --auth-host=scram-sha-256)
else
  echo "Cluster already initialized; skipping initdb."
fi
```

Notes:

- Local socket directory is `/tmp` (source-build default).
- `postgres` superuser is reachable via **peer** auth from the `postgres` OS
  user. No superuser TCP password is set by this runbook.
- The app role gets a generated password in Phase 4.

### 5.3 PostgreSQL configuration

```bash
PG_LISTEN="localhost"
[[ "$EXPOSE_DB" == "1" ]] && PG_LISTEN="0.0.0.0"

if ! sudo grep -q '^# --- randomdata provisioning ---' "$PGDATA/postgresql.conf"; then
  sudo -u postgres tee -a "$PGDATA/postgresql.conf" >/dev/null <<EOF
# --- randomdata provisioning ---
listen_addresses = '$PG_LISTEN'
port = 5432
max_connections = 100
shared_buffers = 32MB
work_mem = 4MB
maintenance_work_mem = 64MB
password_encryption = scram-sha-256
logging_collector = on
log_directory = '$PG_LOG_DIR'
log_filename = 'postgresql-15.1-%Y-%m-%d.log'
log_line_prefix = '%m [%p] '
ssl = off
EOF
fi

# Remote access: only the application database/user, never the superuser.
if [[ "$EXPOSE_DB" == "1" ]] \
   && ! sudo grep -qE '^host[[:space:]]+randomdata[[:space:]]+randomdata[[:space:]]+0\.0\.0\.0/0' \
        "$PGDATA/pg_hba.conf"; then
  echo 'host randomdata randomdata 0.0.0.0/0 scram-sha-256' \
    | sudo -u postgres tee -a "$PGDATA/pg_hba.conf" >/dev/null
fi
```

`pg_hba.conf` should contain the initdb defaults plus, when public:

```text
local   all          all                        peer
host    all          all    127.0.0.1/32        scram-sha-256
host    all          all    ::1/128             scram-sha-256
local   replication  all                        peer
host    replication  all    127.0.0.1/32        scram-sha-256
host    replication  all    ::1/128             scram-sha-256
host    randomdata   randomdata  0.0.0.0/0      scram-sha-256
```

### 5.4 systemd unit

```bash
sudo tee /etc/systemd/system/postgresql-15.1.service >/dev/null <<'EOF'
[Unit]
Description=PostgreSQL 15.1 database server
Documentation=https://www.postgresql.org/docs/15/
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGDATA=/var/lib/postgresql/15.1/data
ExecStart=/usr/local/pgsql-15.1/bin/pg_ctl start -D ${PGDATA} -s -w -t 300
ExecStop=/usr/local/pgsql-15.1/bin/pg_ctl stop -D ${PGDATA} -s -m fast
ExecReload=/usr/local/pgsql-15.1/bin/pg_ctl reload -D ${PGDATA} -s
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "$PG_SERVICE"
```

Checkpoint:

```bash
sudo systemctl is-active "$PG_SERVICE"
sudo systemctl is-enabled "$PG_SERVICE"
"$PG_PREFIX/bin/pg_isready" -h 127.0.0.1 -p 5432

(cd /tmp && sudo -u postgres "$PG_PREFIX/bin/psql" -X -tAc 'select version();')
```

Expected: `active`, `enabled`, `accepting connections`, and
`PostgreSQL 15.1 ...`.

If it fails:

```bash
sudo systemctl --no-pager --full status "$PG_SERVICE"
sudo journalctl -u "$PG_SERVICE" -n 80 --no-pager
sudo tail -n 80 "$PG_LOG_DIR"/postgresql-15.1-*.log
```

---

## 6. Phase 4 — Application role and database

The application role is explicitly **NOSUPERUSER / NOCREATEDB / NOCREATEROLE**.
It owns the `randomdata` database, which is all the app needs.

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

(cd /tmp && sudo -u postgres "$PG_PREFIX/bin/psql" \
  -X -q -v ON_ERROR_STOP=1 -d postgres \
  -v role="$DB_USER" -v pass="$DB_PASSWORD" -v db="$DB_NAME" <<'SQL'
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
```

Checkpoint:

```bash
# role attributes: rolsuper/rolcreatedb/rolcreaterole must all be f
(cd /tmp && sudo -u postgres "$PG_PREFIX/bin/psql" -X -tAc \
  "select rolname, rolsuper, rolcreatedb, rolcreaterole
     from pg_roles where rolname = '$DB_USER';")

# database owner
(cd /tmp && sudo -u postgres "$PG_PREFIX/bin/psql" -X -tAc \
  "select datname, pg_get_userbyid(datdba)
     from pg_database where datname = '$DB_NAME';")

# password login over TCP
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=5432 user=$DB_USER dbname=$DB_NAME" \
  -tAc 'select current_user, current_database();'
```

Expected: `randomdata | f | f | f`, database owner `randomdata`, and
`randomdata|randomdata`.

> `deploy.sh init-db` performs the same idempotent role/database creation later.
> Running it is a good extra check, but this phase already created them.

---

## 7. Phase 5 — PgBouncer

### 7.1 Install and stop the default instance

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pgbouncer
sudo systemctl stop pgbouncer 2>/dev/null || true
pgbouncer -V
```

### 7.2 Auth file and configuration

```bash
sudo install -d -m 0755 -o postgres -g postgres /var/run/postgresql
sudo install -d -m 1775 -o root -g postgres "$PG_LOG_DIR"

# Plaintext entry: PgBouncer needs it to derive SCRAM responses for both
# client and server authentication.
printf '"%s" "%s"\n' "$DB_USER" "$DB_PASSWORD" \
  | sudo tee /etc/pgbouncer/userlist.txt >/dev/null
sudo chown postgres:postgres /etc/pgbouncer/userlist.txt
sudo chmod 640 /etc/pgbouncer/userlist.txt

PGB_LISTEN="127.0.0.1"
[[ "$EXPOSE_DB" == "1" ]] && PGB_LISTEN="0.0.0.0"

sudo tee /etc/pgbouncer/pgbouncer.ini >/dev/null <<EOF
[databases]
$DB_NAME = host=127.0.0.1 port=5432 dbname=$DB_NAME

[pgbouncer]
listen_addr = $PGB_LISTEN
listen_port = $PGBOUNCER_PORT
unix_socket_dir = /var/run/postgresql
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = $DB_USER
stats_users = $DB_USER
pool_mode = transaction
max_client_conn = 200
default_pool_size = 20
min_pool_size = 2
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 50
max_prepared_statements = 100
ignore_startup_parameters = extra_float_digits
server_reset_query = DISCARD ALL
logfile = $PG_LOG_DIR/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
log_connections = 0
log_disconnections = 0
verbose = 0
EOF
sudo chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
sudo chmod 640 /etc/pgbouncer/pgbouncer.ini
```

> `max_prepared_statements` requires PgBouncer **1.21+** (1.25.1 is what the
> reference host runs). On older packages remove that line; the app disables
> named prepared statements anyway (`prepare_threshold=None`).

### 7.3 Start after PostgreSQL

```bash
sudo install -d /etc/systemd/system/pgbouncer.service.d
sudo tee /etc/systemd/system/pgbouncer.service.d/after-postgres.conf >/dev/null <<'EOF'
[Unit]
After=postgresql-15.1.service
Wants=postgresql-15.1.service

[Service]
Restart=on-failure
RestartSec=2
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pgbouncer
```

Checkpoint:

```bash
sudo systemctl is-active pgbouncer

# Through the pooler
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=$PGBOUNCER_PORT user=$DB_USER dbname=$DB_NAME" \
  -tAc 'select current_user, current_database();'

# Admin console
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=$PGBOUNCER_PORT user=$DB_USER dbname=pgbouncer" \
  -c 'SHOW POOLS;'
```

Expected: `active`, `randomdata|randomdata`, and a `SHOW POOLS` table.

If authentication fails:

```bash
sudo systemctl --no-pager --full status pgbouncer
sudo journalctl -u pgbouncer -n 80 --no-pager
sudo grep -n '^logfile\|^pidfile\|^listen' /etc/pgbouncer/pgbouncer.ini
sudo tail -n 50 "$PG_LOG_DIR"/pgbouncer.log
```

Re-check that the password in `userlist.txt` exactly matches
`$DB_PASSWORD`, then `sudo systemctl reload pgbouncer`.

---

## 8. Phase 6 — Deploy the application

### 8.1 Get the code

The repository is public and the `master` branch contains the app and
`deploy.sh`:

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

if [[ ! -d "$APP_DIR/.git" ]]; then
  if [[ -d "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null || true)" ]]; then
    echo "ERROR: $APP_DIR exists and is not a git clone."
    echo "Move it aside or copy the app with the rsync alternative below."
    exit 1
  fi
  git clone --branch "$APP_BRANCH" "$APP_REPO" "$APP_DIR"
fi

cd "$APP_DIR"
chmod +x deploy.sh
git rev-parse --short HEAD
test -f app/main.py && test -f app/db.py && test -f app/producer.py \
  && test -f requirements.txt && test -x deploy.sh
echo "app files present"
```

> The GitHub repo contains the runtime app. `SETUP.md` / `PROVISION.md` may not
> be in the remote yet; copy them separately if you want the documentation on
> the new host. They are not required for the app to run.

If the repository is private or GitHub is unreachable, copy the app from an
existing checkout instead of `git clone`:

```bash
# Run on the OLD host, replacing NEW_HOST:
# rsync -av \
#   --exclude .git --exclude .venv --exclude .run --exclude logs \
#   --exclude .env --exclude creds.txt \
#   /home/ubuntu/random-data-app/ ubuntu@NEW_HOST:/home/ubuntu/random-data-app/
```

### 8.2 Python environment

```bash
cd "$APP_DIR"
[[ -x .venv/bin/python ]] || python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt
.venv/bin/python -c 'import fastapi, uvicorn, psycopg; print("python deps ok")'
```

### 8.3 Generate `.env`

This **overwrites** `.env` with the generated password. The password is hex, so
it is safe in the URL without percent-encoding.

```bash
APP_BIND="127.0.0.1"
[[ "$EXPOSE_APP" == "1" ]] && APP_BIND="0.0.0.0"

cd "$APP_DIR"
umask 077
cat > .env <<EOF
# App
APP_HOST=$APP_BIND
APP_PORT=$APP_PORT

# Direct database endpoint (admin/bootstrap; used by deploy.sh)
PG_HOST=127.0.0.1
PG_PORT=5432
PG_APP_DB=$DB_NAME
PG_APP_USER=$DB_USER
PG_APP_PASSWORD=$DB_PASSWORD

# App traffic goes through PgBouncer (transaction pooling)
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:$PGBOUNCER_PORT/$DB_NAME
PGBOUNCER_HOST=127.0.0.1
PGBOUNCER_PORT=$PGBOUNCER_PORT

# Tuning (defaults)
# DB_POOL_MIN=1
# DB_POOL_MAX=8
# INSERT_BATCH_SIZE=250
# PROGRESS_PERSIST_SECONDS=2
EOF
chmod 600 .env
ls -l .env
```

### 8.4 Initialize and start

```bash
cd "$APP_DIR"
./deploy.sh init-db
./deploy.sh start
./deploy.sh status
```

Checkpoint:

```bash
curl -fsS http://127.0.0.1:8000/healthz
# {"status":"ok","database":"ok"}
```

The app creates its tables on startup:

- `random_events` (`id`, `run_id`, `created_at`, `payload`, `payload_bytes`)
- `run_history` (run status, parameters, counters, timestamps)

### 8.5 Generate `creds.txt`

```bash
cd "$APP_DIR"
./deploy.sh creds
ls -l creds.txt
```

`creds.txt` is mode 600 and gitignored. **Known mismatch:** `deploy.sh` prints a
hardcoded line claiming a default superuser password. This runbook does **not**
set a superuser TCP password; local superuser access is **peer auth only**.
Edit that line if you want the file to be literal (the regex avoids spelling a
credential in this document):

```bash
sed -i 's|^Superuser         : postgres / .* (local only)$|Superuser         : postgres (peer auth only; no TCP password set)|' creds.txt
grep -n '^Superuser' creds.txt
```

---

## 9. Phase 7 — Public exposure and security group

Skip this phase if `EXPOSE_APP=0` and `EXPOSE_DB=0`.

### 9.1 Required AWS security-group rules

| Port | Protocol | Purpose | Source |
|---|---|---|---|
| 22 | TCP | SSH | your admin IP |
| 8000 | TCP | dashboard/API | `APP_ALLOWED_CIDR` |
| 5432 | TCP | direct PostgreSQL | `DB_ALLOWED_CIDR` |
| 6432 | TCP | PgBouncer | `DB_ALLOWED_CIDR` |

The reference host's group (`launch-wizard-1`) allows these from the internet.
That is convenient but risky: the dashboard has **no authentication**, and the
database ports are plaintext (TLS is off unless you do §11.2).

If AWS CLI credentials are available on the instance:

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"

AWS_REGION="${AWS_REGION:-ap-south-1}"
SG_ID="${SG_ID:-}"

if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
  if [[ -z "$SG_ID" ]]; then
    SG_ID="$(aws ec2 describe-security-groups \
      --region "$AWS_REGION" \
      --group-names "$SG_NAME" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  fi

  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    echo "Could not find security group '$SG_NAME'. Set SG_ID=sg-... and re-run."
  else
    add_rule() {
      aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port "$1" --cidr "$2" >/dev/null 2>&1 || true
    }
    [[ "$EXPOSE_APP" == "1" ]] && add_rule 8000 "$APP_ALLOWED_CIDR"
    if [[ "$EXPOSE_DB" == "1" ]]; then
      add_rule 5432 "$DB_ALLOWED_CIDR"
      add_rule 6432 "$DB_ALLOWED_CIDR"
    fi
    echo "Security group rules requested for $SG_ID"
  fi
else
  echo "No AWS CLI credentials. Add these inbound rules manually:"
  [[ "$EXPOSE_APP" == "1" ]] && echo "  TCP 8000 from $APP_ALLOWED_CIDR"
  if [[ "$EXPOSE_DB" == "1" ]]; then
    echo "  TCP 5432 from $DB_ALLOWED_CIDR"
    echo "  TCP 6432 from $DB_ALLOWED_CIDR"
  fi
fi
```

> Changing `0.0.0.0/0` to your workstation IP (`x.x.x.x/32`) is the single
> biggest security improvement. The runbook defaults to all sources only to
> match the reference box.

### 9.2 Host firewall

The reference host uses no host firewall; the AWS security group is the
control. If `ufw` is active on your AMI, allow the same ports:

```bash
sudo ufw status || true
if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
  [[ "$EXPOSE_APP" == "1" ]] && sudo ufw allow 8000/tcp
  if [[ "$EXPOSE_DB" == "1" ]]; then
    sudo ufw allow 5432/tcp
    sudo ufw allow 6432/tcp
  fi
fi
```

### 9.3 Get the public IP and verify externally

```bash
TOKEN="$(curl -fsS --max-time 3 -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
PUBLIC_IP="$(curl -fsS --max-time 3 \
  -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)"
echo "PUBLIC_IP=$PUBLIC_IP"

# Third-party port checker (requires internet).
curl -sS --max-time 30 -X POST https://portchecker.io/api/query \
  -H 'Content-Type: application/json' \
  -d "{\"host\":\"$PUBLIC_IP\",\"ports\":[8000,5432,6432]}"; echo
```

Expected when all exposure is enabled:

```json
{"error":false,"check":[{"port":8000,"status":true},
                        {"port":5432,"status":true},
                        {"port":6432,"status":true}]}
```

If a port is closed:

1. Confirm the process listens on all interfaces:
   `ss -lntp | grep -E ':(8000|5432|6432)\b'`
2. Confirm the security-group rule (§9.1).
3. Confirm `EXPOSE_APP`/`EXPOSE_DB` and the config in
   `postgresql.conf` / `pgbouncer.ini`.
4. Remember the public IPv4 is **dynamic**: after an EC2 stop/start, re-run
   `./deploy.sh creds`.

---

## 10. Phase 8 — Verification and load test

### 10.1 Core checks

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"
cd "$APP_DIR"

./deploy.sh status
curl -fsS http://127.0.0.1:8000/healthz; echo

# Direct PostgreSQL (5432)
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=5432 user=$DB_USER dbname=$DB_NAME" \
  -tAc 'select current_user, current_database(), version();'

# Through PgBouncer (6432)
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=$PGBOUNCER_PORT user=$DB_USER dbname=$DB_NAME" \
  -tAc 'select 1;'

# PgBouncer pool state
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=$PGBOUNCER_PORT user=$DB_USER dbname=pgbouncer" \
  -c 'SHOW POOLS;'
```

### 10.2 Insert a small load

```bash
RESP="$(curl -fsS -X POST http://127.0.0.1:8000/api/runs \
  -H 'Content-Type: application/json' \
  -d '{"duration_seconds":5,"rate_per_second":100,"payload_bytes":256}')"
echo "$RESP" | python3 -m json.tool

RUN_ID="$(printf '%s' "$RESP" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"
echo "RUN_ID=$RUN_ID"

sleep 6
curl -fsS "http://127.0.0.1:8000/api/runs/$RUN_ID" | python3 -m json.tool

PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=5432 user=$DB_USER dbname=$DB_NAME" \
  -tAc "select count(*) from random_events where run_id = '$RUN_ID';"
```

Expected: status `completed`, `inserted` 500, and count `500` (the producer
paces to `duration × rate` and flushes the final remainder). If the count is
lower, check `errors`, the app log, and whether the app is still running.

### 10.3 Test per-run delete, then clean up

```bash
curl -fsS -X DELETE "http://127.0.0.1:8000/api/runs/$RUN_ID" \
  | python3 -m json.tool

PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=5432 user=$DB_USER dbname=$DB_NAME" \
  -tAc "select
          (select count(*) from random_events where run_id = '$RUN_ID'),
          (select count(*) from run_history where id = '$RUN_ID');"
```

Expected: `0|0`.

Do **not** call `DELETE /api/data` on a host whose data you want to keep — it
stops all runs and truncates both tables.

### 10.4 Log check

```bash
grep -iE 'error|traceback|exception' "$APP_DIR/logs/app.log" | tail -n 30 || true
sudo tail -n 30 "$PG_LOG_DIR"/pgbouncer.log
```

---

## 11. Phase 9 — Optional hardening

The baseline above already uses a generated password and a non-superuser app
role. The reference box additionally has these weaknesses; fix them as needed.

```bash
set -Eeuo pipefail
source "$HOME/.randomdata-provision.env"
source "$SECRETS_FILE"
export PATH="$PG_PREFIX/bin:$PATH"
```

### 11.1 Restrict database ports

Use `DB_ALLOWED_CIDR=<your-ip>/32` and re-run §9.1, or edit the security group
in the AWS console. This is more important than TLS.

### 11.2 TLS for public PostgreSQL and PgBouncer

TLS is **off** by default, matching the reference host. If 5432/6432 are
internet-facing, enable it.

PostgreSQL server certificate (self-signed):

```bash
(cd /tmp && sudo -u postgres openssl req -new -x509 -days 365 -nodes -text \
  -out "$PGDATA/server.crt" \
  -keyout "$PGDATA/server.key" \
  -subj "/CN=$(hostname)")
sudo chown postgres:postgres "$PGDATA/server.crt" "$PGDATA/server.key"
sudo chmod 600 "$PGDATA/server.key"

(cd /tmp && sudo -u postgres "$PG_PREFIX/bin/psql" -X \
  -c "ALTER SYSTEM SET ssl = 'on';")
sudo systemctl restart "$PG_SERVICE"
```

Verify a TLS connection:

```bash
PGPASSWORD="$DB_PASSWORD" "$PG_PREFIX/bin/psql" \
  "host=127.0.0.1 port=5432 user=$DB_USER dbname=$DB_NAME sslmode=require" \
  -tAc 'select ssl from pg_stat_ssl where pid = pg_backend_pid();'
# t
```

PgBouncer client TLS (all clients, including the app, must then use TLS):

```bash
sudo openssl req -new -x509 -days 365 -nodes -text \
  -out /etc/pgbouncer/server.crt \
  -keyout /etc/pgbouncer/server.key \
  -subj "/CN=$(hostname)"
sudo chown postgres:postgres /etc/pgbouncer/server.crt /etc/pgbouncer/server.key
sudo chmod 600 /etc/pgbouncer/server.key

if ! sudo grep -q '^client_tls_sslmode' /etc/pgbouncer/pgbouncer.ini; then
  sudo tee -a /etc/pgbouncer/pgbouncer.ini >/dev/null <<'EOF'
client_tls_sslmode = require
client_tls_cert_file = /etc/pgbouncer/server.crt
client_tls_key_file = /etc/pgbouncer/server.key
EOF
fi
sudo systemctl restart pgbouncer

# Tell the app to use TLS through the pooler.
cd "$APP_DIR"
python3 - <<'PY'
from pathlib import Path
p = Path(".env")
s = p.read_text()
if "sslmode=require" not in s:
    lines = []
    for line in s.splitlines():
        if line.startswith("DATABASE_URL="):
            line += "?sslmode=require"
        lines.append(line)
    p.write_text("\n".join(lines) + "\n")
PY
./deploy.sh restart
./deploy.sh status
```

Notes:

- `sslmode=require` encrypts but does not verify a self-signed certificate. For
  verification, use a real CA and `sslmode=verify-full`.
- `creds.txt` URLs do not automatically gain `?sslmode=require`; edit or
  document it.
- Enabling PgBouncer client TLS while a client pins `sslmode=disable` will break
  it; use `require` (or `verify-full` with a real CA).

### 11.3 Add authentication to the app

The app has no login. Either:

- restrict TCP 8000 to trusted IPs at the security group, or
- put an authenticating reverse proxy (nginx/Caddy) in front and bind the app
  to `127.0.0.1` (`EXPOSE_APP=0`), or
- add HTTP Basic auth middleware to `app/main.py`.

At minimum, do not expose `DELETE /api/data` to the internet without auth.

### 11.4 Log rotation

PostgreSQL and PgBouncer logs are covered by
`/etc/logrotate.d/postgresql-common` (weekly, 10 copies, `copytruncate`).
The app log is not:

```bash
sudo tee /etc/logrotate.d/random-data-app >/dev/null <<'EOF'
/home/ubuntu/random-data-app/logs/app.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
```

### 11.5 Optional app auto-start

The reference host starts the app manually with `./deploy.sh start`. If you
want boot start, use a systemd unit **instead of** `deploy.sh start/stop` (do
not mix the two management paths):

```bash
sudo tee /etc/systemd/system/random-data-app.service >/dev/null <<'EOF'
[Unit]
Description=Random Data Loader
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/random-data-app
EnvironmentFile=/home/ubuntu/random-data-app/.env
ExecStart=/home/ubuntu/random-data-app/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-access-log
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# Stop the nohup-managed instance before handing control to systemd.
cd "$APP_DIR" && ./deploy.sh stop || true

sudo systemctl daemon-reload
sudo systemctl enable --now random-data-app
```

If you use this unit, manage the app with `systemctl`, not `./deploy.sh` (the
PID file under `.run/` is not used by systemd).

### 11.6 Backups

```bash
BACKUP_DIR="$HOME/backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
umask 077
PGPASSWORD="$DB_PASSWORD" pg_dump \
  -h 127.0.0.1 -p 5432 -U "$DB_USER" -d "$DB_NAME" \
  -Fc -f "$BACKUP_DIR/randomdata-$(date +%F).dump"
```

Restore:

```bash
PGPASSWORD="$DB_PASSWORD" pg_restore \
  -h 127.0.0.1 -p 5432 -U "$DB_USER" -d "$DB_NAME" \
  --clean --if-exists "$HOME/backups/randomdata-YYYY-MM-DD.dump"
```

---

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `make` killed, `dmesg` shows OOM | swap not active or `MAKE_JOBS` too high; `swapon --show`, retry `make -j1` |
| `initdb: could not change directory` | harmless warning from `sudo -u postgres` in a non-readable cwd; run from `/tmp` |
| Postgres won't start | `journalctl -u postgresql-15.1 -n 80`, check `$PGDATA` ownership/mode, port 5432, config syntax |
| `psql: no pg_hba.conf entry` from remote | add the `host randomdata randomdata ...` rule, then `systemctl reload postgresql-15.1`; confirm SG |
| `password authentication failed` via 6432 | `userlist.txt` must contain the exact current password; `systemctl reload pgbouncer` |
| `prepared statement ... does not exist` | transaction pooling + named prepares; keep `prepare_threshold=None` in `app/db.py` |
| PgBouncer won't start | `journalctl -u pgbouncer`, check `listen_addr`, `pidfile`, `unix_socket_dir`, `/etc/pgbouncer/userlist.txt` perms |
| App start says PgBouncer unreachable | `systemctl status pgbouncer`, test with `psql -p 6432`; check `.env` `DATABASE_URL` |
| App unhealthy after DB/PgBouncer restart | stale pooled connections; `./deploy.sh restart` |
| App gone after reboot | expected: it is not a service; `./deploy.sh start` (or install §11.5) |
| Public ports closed | EC2 security group, host firewall, or process bound to `127.0.0.1` (`ss -lntp`) |
| Public DB/API stopped working after stop/start | public IPv4 changed; `./deploy.sh creds`, update clients |
| `port 8000 already in use` | another uvicorn/process; `ss -lntp 'sport = :8000'`, stop it |
| `deploy.sh init-db` fails | it needs passwordless sudo and `psql` on `PATH`; run `sudo -n true` and `export PATH=$PG_PREFIX/bin:$PATH` |
| TLS enabled and app unhealthy | PgBouncer cert/key permissions, or a client pinned to `sslmode=disable`; check `journalctl -u pgbouncer` |
| `SHOW POOLS` denied | user not in `admin_users`; use `$DB_USER` or update `pgbouncer.ini` |

Useful diagnostics:

```bash
sudo systemctl status postgresql-15.1 pgbouncer --no-pager
sudo journalctl -u postgresql-15.1 -u pgbouncer -n 100 --no-pager
ss -lntp | grep -E ':(5432|6432|8000)\b'
sudo tail -n 50 /var/log/postgresql/postgresql-15.1-*.log
sudo tail -n 50 /var/log/postgresql/pgbouncer.log
tail -n 50 /home/ubuntu/random-data-app/logs/app.log
free -h
df -h /
```

---

## 13. Phase 10 — Teardown

> Destructive. This deletes the database and role.

```bash
cd /home/ubuntu/random-data-app

# If you installed the optional unit in §11.5, stop it first.
sudo systemctl disable --now random-data-app 2>/dev/null || true

./deploy.sh destroy --yes --drop-db
sudo systemctl disable --now pgbouncer postgresql-15.1
```

Optional full removal of the build and data (only on a disposable host):

```bash
sudo rm -rf /usr/local/pgsql-15.1
sudo rm -rf /usr/local/src/postgresql-15.1 /usr/local/src/postgresql-15.1.tar.bz2
sudo rm -rf /var/lib/postgresql/15.1 /var/log/postgresql
sudo rm -rf /etc/pgbouncer /etc/systemd/system/pgbouncer.service.d
sudo rm -f /etc/systemd/system/postgresql-15.1.service /etc/profile.d/postgresql-15.1.sh
sudo systemctl daemon-reload
sudo apt-get remove --purge -y pgbouncer
```

Also remove the security-group rules added in §9 and terminate the instance.

---

## 14. Acceptance checklist

- [ ] `postgres --version` reports **PostgreSQL 15.1**
- [ ] `systemctl is-active postgresql-15.1` = `active`
- [ ] `systemctl is-enabled postgresql-15.1` = `enabled`
- [ ] `systemctl is-active pgbouncer` = `active`
- [ ] `systemctl is-enabled pgbouncer` = `enabled`
- [ ] Role `randomdata` has `rolsuper = f`, `rolcreatedb = f`, `rolcreaterole = f`
- [ ] Database `randomdata` is owned by `randomdata`
- [ ] Direct 5432 password login works
- [ ] PgBouncer 6432 login works and `SHOW POOLS` works
- [ ] `curl /healthz` returns `{"status":"ok","database":"ok"}`
- [ ] A 5 s / 100 rows/s load inserts ~500 rows with 0 errors
- [ ] `DELETE /api/runs/{id}` removes that run's rows and history
- [ ] `README.md` is present (and the docs were copied, if you want them locally)
- [ ] `.env` and `creds.txt` are mode 600
- [ ] Generated password is not committed (`git status` clean of secrets)
- [ ] If public: 8000/5432/6432 are open only from the intended CIDR
- [ ] If public DB: TLS is enabled (§11.2) or the risk is accepted

---

## 15. Appendix

### 15.1 Versions and paths

| Item | Value |
|---|---|
| PostgreSQL prefix | `/usr/local/pgsql-15.1` |
| Data directory | `/var/lib/postgresql/15.1/data` |
| Postgres logs | `/var/log/postgresql/postgresql-15.1-YYYY-MM-DD.log` |
| PgBouncer config | `/etc/pgbouncer/pgbouncer.ini` |
| PgBouncer auth | `/etc/pgbouncer/userlist.txt` (640 postgres:postgres) |
| Postgres unit | `/etc/systemd/system/postgresql-15.1.service` |
| PgBouncer drop-in | `/etc/systemd/system/pgbouncer.service.d/after-postgres.conf` |
| App | `/home/ubuntu/random-data-app` |
| App env | `/home/ubuntu/random-data-app/.env` (600) |
| Generated credentials | `/home/ubuntu/random-data-app/creds.txt` (600) |
| Generated password store | `$HOME/.randomdata-secrets` (600) of the provisioning user |

### 15.2 App runtime map

```text
Browser / API client ── :8000 ──► FastAPI/Uvicorn (PID file .run/app.pid)
                                      │ async psycopg pool 1–8
                                      ▼
                                PgBouncer :6432 (transaction)
                                      │
                                      ▼
                                PostgreSQL 15.1 :5432
                                      └── randomdata
                                          ├── random_events
                                          └── run_history
```

### 15.3 Why these choices

- **Source build**: the requirement is exactly 15.1, not the distro package.
- **PgBouncer transaction pooling**: many short app connections share a small
  number of Postgres backends; the app disables named prepared statements
  (`prepare_threshold=None`) because transaction pooling can switch backends
  between statements.
- **Separate app role**: `randomdata` owns its database but is not a superuser.
- **Direct 5432 + pooler 6432**: admin work uses 5432; app traffic uses 6432.
- **`pg_hba` scoped remote rule**: even with 5432 public, the `postgres`
  superuser is rejected remotely; only `randomdata`/`randomdata` is allowed.
- **`creds.txt` mode 600**: it contains the generated password.

### 15.4 Reference documents

- `SETUP.md` — explanatory architecture and current-box build details
- `README.md` — day-to-day quick reference
- `PROVISION.md` — this fresh-host runbook
