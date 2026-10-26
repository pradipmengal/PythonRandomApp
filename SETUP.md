# Random Data Loader — Full Setup Guide

How this machine was built: **PostgreSQL 15.1 from source + PgBouncer + a FastAPI
producer app**, including the lifecycle script, network exposure, and the
problems hit along the way.

> Rebuilding on a fresh EC2 instance? Follow
> **[PROVISION.md](PROVISION.md)** instead. This file documents the existing
> reference machine.

> **Secrets are not in this file.** Real passwords live in
> `/home/ubuntu/random-data-app/.env` (mode 600, gitignored) and
> `/home/ubuntu/random-data-app/creds.txt` (mode 600, gitignored).
> This document uses `<password>` placeholders.

---

## 1. What the system does

A small web dashboard that inserts random JSON rows into PostgreSQL at a chosen
rate for a chosen duration ("a load"), shows live progress, keeps run history,
and can delete a load's rows or all data.

```
 Browser / API client                    psql / DB client
        │                                      │
        │ HTTP :8000 (public, no auth)         │ TCP :5432 (public, pg_hba scoped)
        ▼                                      ▼
 ┌──────────────────────┐             ┌─────────────────────────┐
 │ FastAPI + Uvicorn    │             │ PostgreSQL 15.1         │
 │ app/main.py          │             │ /usr/local/pgsql-15.1   │
 │                      │             └────────────▲────────────┘
 │ async psycopg3 pool  │                          │
 │ (1–8 connections)    │             ┌────────────┴────────────┐
 └──────────┬───────────┘             │ PgBouncer 1.25.1        │
            │ TCP :6432 (loopback)    │ transaction pooling     │
            └────────────────────────▶│ 0.0.0.0:6432 (public)   │
                                      └─────────────────────────┘
```

Database access paths:

| Path | Endpoint | Purpose |
|---|---|---|
| App → PgBouncer | `127.0.0.1:6432` | Normal application traffic |
| Direct PostgreSQL | `127.0.0.1:5432` | `init-db`, admin, `pg_dump` |
| Public PgBouncer | `<public-ip>:6432` | Remote clients (optional) |
| Public PostgreSQL | `<public-ip>:5432` | Remote clients, **restricted by `pg_hba.conf`** |

---

## 2. Host and software inventory

| Item | Value |
|---|---|
| OS | Ubuntu 26.04.1 LTS |
| Kernel | `7.0.0-1014-aws` |
| Cloud | AWS EC2 `t3.micro`, `ap-south-1b`, instance `i-0e67c95324f4dbb4a` |
| Security group | `launch-wizard-1` |
| CPU / RAM | 2 vCPU / 908 MiB |
| Swap | 1 GiB `/swapfile` (added because the kernel OOM-killed the agent) |
| Public IP | dynamic; assigned at launch, recorded in `creds.txt` |
| PostgreSQL | **15.1**, built from source, prefix `/usr/local/pgsql-15.1` |
| PgBouncer | **1.25.1** (Ubuntu package) |
| Python | 3.14.4 (`python3.14-venv`) |
| Web stack | FastAPI 0.161.1, Uvicorn 0.54.0, psycopg 3.3.6 + psycopg-pool 3.3.3 |
| App directory | `/home/ubuntu/random-data-app` |

Why native instead of containers: Docker was not available in this environment.
Why source for PostgreSQL: the requirement was exactly **15.1**, not whatever
the distro ships.

---

## 3. Part A — Build and run PostgreSQL 15.1

The source tree is still on disk at `/usr/local/src/postgresql-15.1`
(tarball: `postgresql-15.1.tar.bz2`). The exact build configuration is recorded
by `pg_config --configure`:

```text
'--prefix=/usr/local/pgsql-15.1' '--with-openssl' '--with-icu'
'--with-libxml' '--with-libxslt' '--with-zlib' '--with-readline'
'CFLAGS=-O2 -std=gnu17 -fpermissive'
```

### 3.1 Dependencies

```bash
sudo apt update
sudo apt install -y \
  build-essential pkg-config \
  libreadline-dev zlib1g-dev libssl-dev libicu-dev \
  libxml2-dev libxslt1-dev
```

Toolchain present: gcc 15.2.0, GNU Make 4.4.1.

### 3.2 Compile and install

```bash
cd /usr/local/src
# tarball already present on this host (fetch from the URL below if rebuilding)
# https://ftp.postgresql.org/pub/source/v15.1/postgresql-15.1.tar.bz2
echo "64fdf23d734afad0dfe4077daca96ac51dcd697e68ae2d3d4ca6c45cb14e21ae  postgresql-15.1.tar.bz2" | sha256sum -c -
sudo tar xjf postgresql-15.1.tar.bz2
cd postgresql-15.1
./configure \
  --prefix=/usr/local/pgsql-15.1 \
  --with-openssl --with-icu --with-libxml --with-libxslt \
  --with-zlib --with-readline \
  CFLAGS="-O2 -std=gnu17 -fpermissive"
make -j"$(nproc)"
sudo make install
```

Core only — `contrib` was not installed (`share/extension` contains just
`plpgsql`). `initdb`, `pg_ctl`, `psql`, etc. live in
`/usr/local/pgsql-15.1/bin`.

### 3.3 PATH

```bash
# /etc/profile.d/postgresql-15.1.sh
export PATH=/usr/local/pgsql-15.1/bin:$PATH
```

### 3.4 Cluster initialisation

The `postgres` OS user (uid 999) owns the cluster:

```text
postgres:x:999:986:PostgreSQL administrator:/var/lib/postgresql:/bin/bash
```

If rebuilding from scratch: `sudo useradd -r -d /var/lib/postgresql -s /bin/bash postgres`.

Equivalent init command for this cluster (locale `C.UTF-8`, UTF-8, SCRAM on TCP,
peer on local socket):

```bash
sudo mkdir -p /var/lib/postgresql/15.1/data /var/log/postgresql
sudo chown -R postgres:postgres /var/lib/postgresql/15.1 /var/log/postgresql
sudo chmod 700 /var/lib/postgresql/15.1/data

sudo -u postgres /usr/local/pgsql-15.1/bin/initdb \
  -D /var/lib/postgresql/15.1/data \
  --encoding=UTF8 --locale=C.UTF-8 \
  --auth-local=peer --auth-host=scram-sha-256
```

### 3.5 systemd service

`/etc/systemd/system/postgresql-15.1.service`:

```ini
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
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now postgresql-15.1

# set the superuser password once, over the local peer socket
sudo -u postgres psql -c "ALTER ROLE postgres PASSWORD '<password>';"
```

> `postgresql.service` and `postgresql@.service` also exist because the
> `postgresql-common` package is installed (dependency of PgBouncer). They
> manage **no clusters** here (`pg_lsclusters` is empty); the real server is
> `postgresql-15.1`.

### 3.6 Effective PostgreSQL settings

| Setting | Value |
|---|---|
| `listen_addresses` | `0.0.0.0` (changed from `localhost` for public access) |
| `port` | `5432` |
| `max_connections` | `100` |
| `shared_buffers` | `32MB` |
| `work_mem` / `maintenance_work_mem` | `4MB` / `64MB` |
| `wal_level` | `replica` |
| `ssl` | **`off`** |
| `password_encryption` | `scram-sha-256` |
| `logging_collector` | `on` |
| `log_directory` | `/var/log/postgresql` |
| `log_filename` | `postgresql-15.1-%Y-%m-%d.log` |
| `unix_socket_directories` | `/tmp` (source-build default) |

Data dir: `/var/lib/postgresql/15.1/data` (mode 700, owner `postgres`).
Postgres log: `/var/log/postgresql/postgresql-15.1-YYYY-MM-DD.log`.

> `sudo -u postgres psql` run from `/home/ubuntu` prints
> `could not change directory to "/home/ubuntu": Permission denied` — harmless
> (`postgres` cannot read the home dir). `deploy.sh` avoids it with `cd /tmp`.

---

## 4. Part B — Roles, database, schema

### 4.1 Bootstrap

- Superuser `postgres` has a password (recorded in `creds.txt`); local socket
  auth is `peer`.
- Role `randomdata` owns database `randomdata`.
- `./deploy.sh init-db` creates them idempotently, running as the `postgres` OS
  user:

```sql
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'pass')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')\gexec
```

```bash
cd /home/ubuntu/random-data-app
./deploy.sh init-db
```

### 4.2 ⚠️ Current role attribute: `randomdata` is SUPERUSER

`\du` shows:

```text
 randomdata | Superuser
```

`CREATE ROLE ... LOGIN` defaults to `NOSUPERUSER`, so this attribute came from
the original bootstrap (`createuser -s` / `CREATE ROLE ... SUPERUSER`), and
`init-db`'s `ALTER ROLE ... LOGIN PASSWORD` does not remove it. The app does
not need it; reduce it with:

```sql
ALTER ROLE randomdata NOSUPERUSER;
```

(Combined with the public port + weak password, this is the highest-risk item
on the box — see §11.)

### 4.3 Schema

Created automatically at app startup (`app/db.py` → `db.init()`):

```sql
CREATE TABLE IF NOT EXISTS random_events (
    id            bigserial PRIMARY KEY,
    run_id        uuid        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    payload       jsonb       NOT NULL,
    payload_bytes integer     NOT NULL
);
CREATE INDEX IF NOT EXISTS random_events_run_id_idx     ON random_events (run_id);
CREATE INDEX IF NOT EXISTS random_events_created_at_idx ON random_events (created_at DESC);

CREATE TABLE IF NOT EXISTS run_history (
    id               uuid PRIMARY KEY,
    status           text NOT NULL,            -- running|completed|stopped|failed|interrupted
    duration_seconds double precision NOT NULL,
    rate_per_second  integer NOT NULL,
    payload_bytes    integer NOT NULL,
    inserted         bigint NOT NULL DEFAULT 0,
    errors           bigint NOT NULL DEFAULT 0,
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    error            text
);
CREATE INDEX IF NOT EXISTS run_history_started_idx ON run_history (started_at DESC);
```

`run_history` is the source of truth for the dashboard; `random_events.run_id`
links rows to a load.

---

## 5. Part C — PgBouncer

Installed from Ubuntu packages:

```bash
sudo apt install -y pgbouncer      # 1.25.1
```

Runs as OS user `postgres` (package unit
`/usr/lib/systemd/system/pgbouncer.service`, `Type=notify`).

### 5.1 Authentication file

`/etc/pgbouncer/userlist.txt` (mode `640`, owner `postgres:postgres`):

```text
"randomdata" "<password>"
```

Plaintext is used so PgBouncer can derive SCRAM responses for both client and
server authentication. Keep it root/postgres-only.

### 5.2 Effective configuration

`/etc/pgbouncer/pgbouncer.ini` (comments removed):

```ini
[databases]
randomdata = host=127.0.0.1 port=5432 dbname=randomdata

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
unix_socket_dir = /var/run/postgresql
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = randomdata
stats_users = randomdata
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
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
log_connections = 0
log_disconnections = 0
verbose = 0
```

Key choices:

- **Transaction pooling** — a server connection is reused per transaction;
  many app clients share few backends.
- **`max_client_conn = 200`** — front-end limit.
- **`default_pool_size = 20` / `max_db_connections = 50`** — front of the
  100-connection Postgres limit.
- **`admin_users`/`stats_users = randomdata`** — the `pgbouncer` admin database
  is usable by that role. This is convenient **and** dangerous when 6432 is
  public.

### 5.3 systemd ordering / resilience

`/etc/systemd/system/pgbouncer.service.d/after-postgres.conf`:

```ini
[Unit]
After=postgresql-15.1.service
Wants=postgresql-15.1.service

[Service]
Restart=on-failure
RestartSec=2
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pgbouncer
```

### 5.4 The prepared-statement trap

With transaction pooling, a client's statements can land on different server
connections. Psycopg's automatic **named prepared statements** (`prepare_threshold`)
can then fail or leak across backends. The app therefore configures its pool
with:

```python
AsyncConnectionPool(
    conninfo=DATABASE_URL,
    min_size=1, max_size=8, open=False, timeout=10.0,
    kwargs={
        "row_factory": dict_row,
        "autocommit": True,
        "prepare_threshold": None,   # never use named prepared statements
    },
)
```

This was the fix for failures seen when routing the app through PgBouncer.

### 5.5 Admin console

```bash
psql "host=127.0.0.1 port=6432 user=randomdata dbname=pgbouncer" -c "SHOW POOLS;"
# remote (only when 6432 is publicly reachable):
psql "host=<public-ip> port=6432 user=randomdata dbname=pgbouncer" -c "SHOW POOLS;"
```

---

## 6. Part D — The application

### 6.1 Layout

| Path | Role |
|---|---|
| `app/main.py` | FastAPI routes, lifespan, request validation |
| `app/db.py` | async pool, schema, queries, delete helpers |
| `app/producer.py` | rate-paced background inserts, `RunManager` |
| `app/static/index.html` | single-file dashboard (vanilla JS/CSS) |
| `requirements.txt` | `fastapi`, `uvicorn`, `psycopg[binary,pool]` |
| `.env` / `.env.example` | runtime config |
| `deploy.sh` | start/stop/status/logs/creds/init-db/destroy |
| `README.md` | user-facing quick reference |
| `creds.txt` | generated credentials/endpoints (gitignored, 600) |

### 6.2 Python environment

```bash
sudo apt install -y python3.14-venv
cd /home/ubuntu/random-data-app
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

`requirements.txt`:

```text
fastapi==0.161.1
uvicorn==0.54.0
psycopg[binary,pool]==3.3.6
```

### 6.3 Configuration (`.env`)

```dotenv
APP_HOST=0.0.0.0
APP_PORT=8000

PG_HOST=127.0.0.1
PG_PORT=5432
PG_APP_DB=randomdata
PG_APP_USER=randomdata
PG_APP_PASSWORD=<password>

# app uses the pooler
DATABASE_URL=postgresql://randomdata:<password>@127.0.0.1:6432/randomdata
PGBOUNCER_HOST=127.0.0.1
PGBOUNCER_PORT=6432

# tuning (defaults shown)
# DB_POOL_MIN=1
# DB_POOL_MAX=8
# INSERT_BATCH_SIZE=250
# PROGRESS_PERSIST_SECONDS=2
```

`PG_*` and `DIRECT_DATABASE_URL` are the direct 5432 path used by admin tasks;
`DATABASE_URL` is what the app actually uses. `deploy.sh` sources `.env` and
exports it before launching Uvicorn — the app does not use `python-dotenv`.

### 6.4 Request / data flow

1. `POST /api/runs` validates duration (1 s – 1 h), rate (1 – 5000 rows/s) and
   payload size (16 B – 4 KB).
2. `RunManager.start()` creates a UUID, inserts a `run_history` row with status
   `running`, and starts an asyncio task.
3. The producer loop compares *expected rows so far* (`elapsed × rate`) with
   rows already inserted, builds a batch (max 250), and inserts it with one
   `executemany`. It sleeps 10 ms when no work is due.
4. Every 2 s it persists `inserted`/`errors` to `run_history`.
5. On completion it flushes the final partial remainder (up to one batch,
   which normally makes the target exact, e.g. 500/500).
6. `finished_at`, status and errors are written in a `finally` block.

Payloads are compact JSON (`id`, `r`, `v`, `t`) padded with random hex so the
encoded size is close to the requested byte count.

### 6.5 API

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/` | Dashboard |
| `GET` | `/healthz` | App + DB ping |
| `POST` | `/api/runs` | Start a load |
| `GET` | `/api/runs?limit=20` | Run history |
| `GET` | `/api/runs/{id}` | One run (memory or DB) |
| `POST` | `/api/runs/{id}/stop` | Stop a run |
| `DELETE` | `/api/runs/{id}` | Stop if needed, delete its rows + history |
| `GET` | `/api/stats` | Row count, table size, DB size |
| `GET` | `/api/rows?limit=20` | Newest payloads |
| `DELETE` | `/api/data` | Stop all runs, `TRUNCATE` rows + history, reset identity |
| `GET` | `/docs` | FastAPI Swagger UI |

Start a load:

```bash
curl -X POST http://127.0.0.1:8000/api/runs \
  -H 'Content-Type: application/json' \
  -d '{"duration_seconds":30,"rate_per_second":100,"payload_bytes":256}'
```

The app also has **no authentication**, and the delete endpoints are
destructive — see §11.

### 6.6 Dashboard

Single page: form (duration, rate, payload size, estimated row count), live
progress/rate/errors, **Stop run**, recent rows, **Delete all data**, and run
history with per-run **Delete** buttons. Polling resumes an active run after a
page reload; runs left `running` by a dead process are marked `interrupted` on
startup.

---

## 7. Part E — `deploy.sh`

```text
./deploy.sh start        create venv if needed, install deps, start uvicorn
./deploy.sh stop         SIGTERM, then SIGKILL after ~15 s
./deploy.sh restart
./deploy.sh status       app + health + direct Postgres + PgBouncer + app DB
./deploy.sh logs [-f]
./deploy.sh creds        write creds.txt (600, all endpoints, detects public binds)
./deploy.sh init-db      create/update role + database (needs sudo)
./deploy.sh destroy [--yes] [--drop-db]
```

Implementation notes:

- `ensure_venv()` hashes `requirements.txt` and reinstalls only when it changes.
- `start` refuses to launch if `DATABASE_URL` is unreachable; if direct Postgres
  works but PgBouncer does not, it tells you to start `pgbouncer`.
- It checks the port is free, starts Uvicorn with `nohup ... --no-access-log`,
  writes `.run/app.pid`, and waits up to 30 s for `/healthz`.
- `destroy` removes `.venv`, `.run`, `logs`; `--drop-db` also terminates
  sessions and drops the database/role.
- `creds` reads the public IP from EC2 IMDSv2, checks `ss` to see whether 5432
  and 6432 are bound publicly, and writes `creds.txt` with the right public
  URLs.

The app is **not** a systemd unit, so it does **not** survive a reboot by
itself. After boot: `cd /home/ubuntu/random-data-app && ./deploy.sh start`.
(Adding a unit is suggested in §11.)

---

## 8. Part F — Network exposure

### 8.1 Current listeners

```text
0.0.0.0:22     sshd
0.0.0.0:8000   uvicorn        (public, unauthenticated)
0.0.0.0:5432   postgres       (public, pg_hba-restricted)
0.0.0.0:6432   pgbouncer      (public, password-auth)
127.0.0.1:5432 postgres       (same socket, loopback included)
```

**How it was exposed, in order:** the app was bound to `0.0.0.0:8000` first;
then PgBouncer's `listen_addr` changed from `127.0.0.1` to `0.0.0.0` (restart +
external TCP check); finally PostgreSQL's `listen_addresses` changed from
`localhost` to `0.0.0.0`, with a `pg_hba.conf` rule that only admits the
`randomdata` database/user. The security group already allowed these ports, so
no AWS-side change was needed.

### 8.2 `pg_hba.conf` (active)

```text
local   all          all                        peer
host    all          all    127.0.0.1/32        scram-sha-256
host    all          all    ::1/128             scram-sha-256
local   replication  all                        peer
host    replication  all    127.0.0.1/32        scram-sha-256
host    replication  all    ::1/128             scram-sha-256
host    randomdata   randomdata  0.0.0.0/0      scram-sha-256
```

Only database/user `randomdata` is reachable remotely. `postgres` (superuser)
is still local-only — verified: remote login as `postgres` returns
`no pg_hba.conf entry`.

### 8.3 Host firewall

- `ufw` is **inactive**
- iptables policy is `INPUT ACCEPT`

So reachability is governed by the EC2 security group. External TCP checks
(portchecker.io) confirmed **5432, 6432 and 8000 open** from the internet.
No IAM role/credentials exist on the instance, so the security group cannot be
inspected or modified from here.

### 8.4 Public endpoints

```text
Dashboard : http://<public-ip>:8000
PgBouncer : postgresql://randomdata:<password>@<public-ip>:6432/randomdata
Postgres  : postgresql://randomdata:<password>@<public-ip>:5432/randomdata
```

> The public IPv4 is **dynamic** (EC2 stop/start changes it; it changed on
> 2026-10-26). Re-run `./deploy.sh creds` after any stop/start.

---

## 9. Part G — What was tested

| Test | Result |
|---|---|
| First load test | 6,000 rows at ~1,994 rows/s, 0 errors |
| App through PgBouncer | healthy, schema created, inserts verified |
| Delete a completed 50-row run | exactly 50 rows + 1 history row removed |
| Delete a **running** run | stopped, 10 rows + history removed |
| Delete unknown UUID | HTTP 404 |
| Delete all | 9,030 rows → 0 rows / 0 history |
| Superuser remotely | blocked by `pg_hba.conf` |
| Wrong password (5432/6432) | `password authentication failed` |
| External port checks | 5432 open, 6432 open, 8000 open |
| Reboot | Postgres + PgBouncer auto-start; app must be started manually |

Data is transient test data; the table is often empty after delete-all tests.

---

## 10. Part H — Operations runbook

### Daily

```bash
cd /home/ubuntu/random-data-app
./deploy.sh status
./deploy.sh logs -f          # app log (no HTTP access entries)
./deploy.sh creds            # refresh endpoints after IP changes
```

### Restart order (after config changes)

```bash
sudo systemctl restart postgresql-15.1
sudo systemctl restart pgbouncer      # ordered after postgres by the drop-in
./deploy.sh restart                   # refresh psycopg pool
curl -fsS http://127.0.0.1:8000/healthz
```

Restarting Postgres while the app runs breaks pooled connections; the app
usually recovers on the next request, but restarting the app is cleaner.

### Logs

| Log | Path |
|---|---|
| App | `logs/app.log` (no HTTP access log — `--no-access-log`) |
| PgBouncer | `/var/log/postgresql/pgbouncer.log` |
| PostgreSQL | `/var/log/postgresql/postgresql-15.1-YYYY-MM-DD.log` |

No log rotation is configured for the app: `logs/app.log` grows until you
truncate it. PostgreSQL and PgBouncer are covered by
`/etc/logrotate.d/postgresql-common` (`/var/log/postgresql/*.log`, weekly,
10 rotations, `copytruncate`).

### Backup / restore

```bash
# direct connection, custom format
PGPASSWORD='<password>' pg_dump -h 127.0.0.1 -p 5432 -U randomdata \
  -d randomdata -Fc -f /var/backups/randomdata-$(date +%F).dump

# restore (drops/recreates objects)
PGPASSWORD='<password>' pg_restore -h 127.0.0.1 -p 5432 -U randomdata \
  -d randomdata --clean --if-exists /var/backups/randomdata-YYYY-MM-DD.dump
```

### Rotate the `randomdata` password

```bash
NEW='<strong-password>'

# 1. database
cd /tmp && sudo -u postgres psql -c "ALTER ROLE randomdata PASSWORD '$NEW';"

# 2. PgBouncer auth file (plaintext entry, mode 640)
sudo sed -i "s/^\"randomdata\".*/\"randomdata\" \"$NEW\"/" /etc/pgbouncer/userlist.txt
sudo systemctl reload pgbouncer

# 3. app config (both password and DATABASE_URL)
#    edit .env, then:
cd /home/ubuntu/random-data-app && ./deploy.sh restart && ./deploy.sh creds
```

### Enable TLS (not done)

PostgreSQL: generate `server.crt`/`server.key` under the data dir, set
`ssl = on`, `ssl_cert_file`, `ssl_key_file`, restart.

PgBouncer: set `client_tls_sslmode = require` (or `allow`) plus
`client_tls_cert_file` / `client_tls_key_file`, restart. Clients then use
`sslmode=require`. Do this before treating the public endpoints as safe.

---

## 11. Security posture and recommended fixes

The box is currently a publicly reachable database and an unauthenticated
destructive web app. In priority order:

1. **`randomdata` is SUPERUSER with a weak password, exposed on 5432/6432.**
   ```sql
   ALTER ROLE randomdata NOSUPERUSER;
   ```
   Then rotate the password (runbook above).
2. **No TLS** on either public database port. Enable it (above).
3. **Destructive API with no auth.** Anyone who finds
   `http://<public-ip>:8000` can `DELETE /api/data`. Add HTTP Basic auth (or
   restrict 8000 in the security group).
4. **PgBouncer admin console is public** (`admin_users = randomdata`). A
   stronger password is mandatory; alternatively use firewall rules so only
   your IP reaches 6432.
5. **Restrict the security group** to your IP for 5432/6432/8000 (SSH too, if
   possible). This is the single most effective control.
6. **No app auto-start** after reboot. Suggested unit (not installed):
   ```ini
   # /etc/systemd/system/random-data-app.service
   [Unit]
   Description=Random Data Loader
   After=network.target pgbouncer.service

   [Service]
   User=ubuntu
   WorkingDirectory=/home/ubuntu/random-data-app
   ExecStart=/home/ubuntu/random-data-app/.venv/bin/uvicorn app.main:app \
     --host 0.0.0.0 --port 8000 --no-access-log
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   ```
7. **No access logs** for HTTP; remove `--no-access-log` if you need auditing.

---

## 12. Troubleshooting notes (real issues hit)

| Symptom | Cause / fix |
|---|---|
| `prepared statement "..." does not exist` / protocol errors via pooler | transaction pooling + named prepares → `prepare_threshold=None` |
| Agent/session killed, `Killed` in dmesg | 908 MB RAM exhausted → 1 GB swapfile added |
| `python3 -m venv` fails | install `python3.14-venv` |
| `could not change directory to "/home/ubuntu"` | harmless; run `sudo -u postgres` commands from `/tmp` |
| App errors after Postgres/PgBouncer restart | stale pooled connections → `./deploy.sh restart` |
| App down after reboot | it is not a service → `./deploy.sh start` |
| Public DB/API unreachable after stop/start | public IPv4 changed → re-run `./deploy.sh creds` |
| `connection refused` on a port | check `ss -lntp`, `systemctl status`, then security group |
| Table size does not shrink after deleting a run | `DELETE` leaves dead tuples; `VACUUM` reclaims, `VACUUM FULL` shrinks files; delete-all uses `TRUNCATE` |

---

## 13. File map

```text
/home/ubuntu/random-data-app/
├── app/
│   ├── main.py              FastAPI app + routes + lifespan
│   ├── db.py                async pool, schema, queries, deletes
│   ├── producer.py          rate-paced producer + RunManager
│   └── static/index.html    dashboard (HTML/CSS/JS)
├── .env                     runtime config (600, gitignored)
├── .env.example             documented template
├── requirements.txt         pinned Python deps
├── deploy.sh                lifecycle + creds generator
├── README.md                quick reference
├── SETUP.md                 this document
├── creds.txt                generated credentials/endpoints (600, gitignored)
├── logs/app.log             uvicorn log
├── .run/app.pid             pid file
└── .venv/                   virtualenv

/etc/systemd/system/postgresql-15.1.service
/etc/systemd/system/pgbouncer.service.d/after-postgres.conf
/etc/pgbouncer/pgbouncer.ini
/etc/pgbouncer/userlist.txt                  (640 postgres:postgres)
/usr/local/pgsql-15.1/                       binaries + libs
/usr/local/src/postgresql-15.1/              build tree
/usr/local/src/postgresql-15.1.tar.bz2       source tarball
/var/lib/postgresql/15.1/data/               cluster (700 postgres)
/var/log/postgresql/                         postgres + pgbouncer logs
/swapfile                                    1 GiB swap (in /etc/fstab)
```

---

## 14. Appendix — useful commands

```bash
# versions
postgres --version && pgbouncer -V && .venv/bin/python --version
pg_config --configure

# postgres / pgbouncer state
sudo systemctl status postgresql-15.1 pgbouncer
sudo -u postgres psql -c '\l' -c '\du'
psql "host=127.0.0.1 port=6432 user=randomdata dbname=pgbouncer" -c 'SHOW POOLS;'

# listeners
ss -lntp | grep -E ':(5432|6432|8000)\b'

# external reachability (third party)
curl -s -X POST https://portchecker.io/api/query \
  -H 'Content-Type: application/json' \
  -d '{"host":"<public-ip>","ports":[5432,6432,8000]}'

# direct DB smoke test
PGPASSWORD='<password>' psql \
  "host=<public-ip> port=5432 user=randomdata dbname=randomdata" \
  -c 'select count(*) from random_events;'

# current public IP (IMDSv2)
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4
```
