# Random Data → Postgres

> Full build/architecture/wiring guide: **[SETUP.md](SETUP.md)**
>
> Fresh-EC2 rebuild runbook: **[PROVISION.md](PROVISION.md)**

A small web app that streams randomly generated, size-controlled JSON records
into PostgreSQL for a chosen duration and rate. Includes a live dashboard and a
`deploy.sh` that starts, stops and destroys the application.

```
Browser ──► FastAPI (Uvicorn) ──► asyncpg-like pool (psycopg 3) ──► PostgreSQL 15.1
              │
              └─ background producer tasks (rate-limited, batched inserts)
```

## Requirements

- Python 3.12+ with `venv` (`python3.14-venv` on this machine)
- PostgreSQL 15.1 reachable over TCP (already installed here as the
  `postgresql-15.1` systemd service on port `5432`; public access is limited
  by `pg_hba.conf` to the `randomdata` user/database)
- `sudo` (only for creating/dropping the app role and database)

## Quick start

```bash
cd ~/random-data-app
./deploy.sh init-db     # create the randomdata role + database (one time)
./deploy.sh start       # create venv, install deps, start the app
```

Open <http://127.0.0.1:8000>.

```bash
./deploy.sh status
./deploy.sh logs -f
./deploy.sh stop
./deploy.sh restart
```

## deploy.sh commands

| Command | What it does |
|---|---|
| `start` | Creates `.venv` if needed, installs dependencies, verifies the DB (auto-creates role/DB if missing), starts Uvicorn, waits for `/healthz` |
| `stop` | Sends `SIGTERM` to the app process (PID file in `.run/`), waits, then `SIGKILL` if needed |
| `restart` | `stop` then `start` |
| `status` | App PID/URL/health and database connectivity |
| `logs [-f]` | Last 100 log lines, optionally follow |
| `init-db` | Idempotently creates the Postgres role and database |
| `destroy` | Stops the app and deletes `.venv`, `.run`, `logs` (asks for confirmation) |
| `destroy --yes` | Same, without prompting |
| `destroy --yes --drop-db` | Also drops the database and role |

`destroy` leaves PostgreSQL itself untouched unless `--drop-db` is passed.

## How a load works

1. The form sends `POST /api/runs` with `duration_seconds`, `rate_per_second`
   and `payload_bytes`.
2. The server creates a `run_id`, records it in `run_history`, and starts an
   async producer task.
3. The producer paces inserts against the wall clock, writing batches of up to
   250 rows, so the requested rate is approximated without per-row overhead.
4. When the duration elapses (or **Stop** is clicked), the final counters are
   persisted and the run is marked `completed` / `stopped`.

Payloads are compact JSON documents padded with random hex so their encoded
size is close to the requested size (16 B – 4 KB).


## Connection pooling (PgBouncer)

The app connects to **PgBouncer on `127.0.0.1:6432`**, which forwards to
PostgreSQL on `127.0.0.1:5432` using transaction pooling.

PgBouncer listens on **all interfaces** (`listen_addr = 0.0.0.0`), so the pooler
is reachable at `<public-ip>:6432`.

PostgreSQL itself now also listens on all interfaces (`listen_addresses =
'0.0.0.0'`, port **5432**), but `pg_hba.conf` permits remote access only for
user/database **`randomdata`**; the `postgres` superuser remains local-only.
Both ports are plaintext TCP (TLS is off) and protected only by the password —
restrict them at the firewall/security group if you don't need remote access.

```bash
# Replace <password> with the value in creds.txt or .env; it is not repeated here.
# direct PostgreSQL
psql "postgresql://randomdata:<password>@<public-ip>:5432/randomdata"
# via PgBouncer (recommended)
psql "postgresql://randomdata:<password>@<public-ip>:6432/randomdata"
```

| Item | Value |
|---|---|
| Listen | `0.0.0.0:6432` (public) |
| Pool mode | `transaction` |
| Auth | `scram-sha-256` (credentials in `/etc/pgbouncer/userlist.txt`) |
| Config | `/etc/pgbouncer/pgbouncer.ini` |
| Service | `sudo systemctl status|restart pgbouncer` |
| Log | `/var/log/postgresql/pgbouncer.log` |
| Admin console | `psql -h 127.0.0.1 -p 6432 -U randomdata -d pgbouncer -c "SHOW POOLS;"` |

`init-db` and admin tasks still use the direct Postgres port. Run
`./deploy.sh creds` to write `creds.txt` (chmod 600, gitignored) containing all
endpoints, credentials, and paths.

## Data model

```sql
CREATE TABLE random_events (
    id            bigserial PRIMARY KEY,
    run_id        uuid        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    payload       jsonb       NOT NULL,
    payload_bytes integer     NOT NULL
);

CREATE TABLE run_history (
    id               uuid PRIMARY KEY,
    status           text,              -- running | completed | stopped | failed | interrupted
    duration_seconds double precision,
    rate_per_second  integer,
    payload_bytes    integer,
    inserted         bigint,
    errors           bigint,
    started_at       timestamptz,
    finished_at      timestamptz,
    error            text
);
```

Indexes exist on `random_events(run_id)` and `random_events(created_at DESC)`.
Runs left `running` by a crash are marked `interrupted` at startup.

## API

| Method | Route | Description |
|---|---|---|
| `POST` | `/api/runs` | Start a load: `{"duration_seconds":10,"rate_per_second":50,"payload_bytes":256}` |
| `GET` | `/api/runs/{id}` | Live status, progress, counters |
| `POST` | `/api/runs/{id}/stop` | Stop early |
| `GET` | `/api/runs?limit=20` | Recent runs |
| `DELETE` | `/api/runs/{id}` | Stop (if needed) and delete a run's rows + history entry |
| `DELETE` | `/api/data` | Stop all runs and delete every row + all run history |
| `GET` | `/api/stats` | Row count, table size, database size |
| `GET` | `/api/rows?limit=20` | Newest rows |
| `GET` | `/healthz` | App + database health |

Example:

```bash
curl -X POST http://127.0.0.1:8000/api/runs \
  -H 'Content-Type: application/json' \
  -d '{"duration_seconds":5,"rate_per_second":100,"payload_bytes":128}'
```

Limits: duration ≤ 3600 s, rate ≤ 5000 rows/s, payload 16 B – 4 KB.

## Configuration

Environment variables (or a `.env` file next to `deploy.sh`; see
`.env.example`):

| Variable | Default | Meaning |
|---|---|---|
| `APP_HOST` | `127.0.0.1` | Bind address (`0.0.0.0` to expose) |
| `APP_PORT` | `8000` | HTTP port |
| `PG_HOST` / `PG_PORT` | `127.0.0.1` / `5432` | PostgreSQL address |
| `PG_APP_DB` | `randomdata` | Database name |
| `PG_APP_USER` | `randomdata` | Role name |
| `PG_APP_PASSWORD` | `randomdata` | Role password |
| `DATABASE_URL` | built from the above | Full connection string override |
| `DB_POOL_MIN` / `DB_POOL_MAX` | `1` / `8` | Connection pool bounds |
| `INSERT_BATCH_SIZE` | `250` | Rows per INSERT round trip |
| `PROGRESS_PERSIST_SECONDS` | `2` | How often run counters are written to `run_history` |

To change the password or database name: edit `.env`, then
`./deploy.sh destroy --yes --drop-db && ./deploy.sh start`.

## Operations

```bash
# Postgres service (managed outside this app)
sudo systemctl status postgresql-15.1
sudo systemctl restart postgresql-15.1
sudo tail -f /var/log/postgresql/postgresql-15.1-$(date +%F).log

# App
./deploy.sh status
./deploy.sh logs -f
tail -f logs/app.log
```

The app binds to localhost by default. To expose it, set `APP_HOST=0.0.0.0`
in `.env`, restart, and open the port in your firewall/security group. There is
no authentication — put it behind a reverse proxy if exposed.

## Troubleshooting

- **`Could not create venv`** → `sudo apt install python3.14-venv`
- **`Postgres is unreachable`** → `sudo systemctl start postgresql-15.1`; check
  `./deploy.sh status` and the credentials in `.env`
- **`Port 8000 already in use`** → `./deploy.sh status`, or change `APP_PORT`
- **App exited during startup** → `./deploy.sh logs`
