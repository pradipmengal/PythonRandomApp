"""Postgres access layer: connection pool, schema, queries."""

from __future__ import annotations

import os
from typing import Any
from uuid import UUID

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

PG_APP_USER = os.getenv("PG_APP_USER", "randomdata")
PG_APP_PASSWORD = os.getenv("PG_APP_PASSWORD", "randomdata")
PG_HOST = os.getenv("PG_HOST", "127.0.0.1")
PG_PORT = os.getenv("PG_PORT", "5432")
PG_APP_DB = os.getenv("PG_APP_DB", "randomdata")

DATABASE_URL = os.getenv("DATABASE_URL") or (
    f"postgresql://{PG_APP_USER}:{PG_APP_PASSWORD}@{PG_HOST}:{PG_PORT}/{PG_APP_DB}"
)

SCHEMA: tuple[str, ...] = (
    """
    CREATE TABLE IF NOT EXISTS random_events (
        id            bigserial PRIMARY KEY,
        run_id        uuid        NOT NULL,
        created_at    timestamptz NOT NULL DEFAULT now(),
        payload       jsonb       NOT NULL,
        payload_bytes integer     NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS random_events_run_id_idx ON random_events (run_id)",
    "CREATE INDEX IF NOT EXISTS random_events_created_at_idx ON random_events (created_at DESC)",
    """
    CREATE TABLE IF NOT EXISTS run_history (
        id               uuid PRIMARY KEY,
        status           text NOT NULL,
        duration_seconds double precision NOT NULL,
        rate_per_second  integer NOT NULL,
        payload_bytes    integer NOT NULL,
        inserted         bigint NOT NULL DEFAULT 0,
        errors           bigint NOT NULL DEFAULT 0,
        started_at       timestamptz NOT NULL DEFAULT now(),
        finished_at      timestamptz,
        error            text
    )
    """,
    "CREATE INDEX IF NOT EXISTS run_history_started_idx ON run_history (started_at DESC)",
)

pool = AsyncConnectionPool(
    conninfo=DATABASE_URL,
    min_size=int(os.getenv("DB_POOL_MIN", "1")),
    max_size=int(os.getenv("DB_POOL_MAX", "8")),
    open=False,
    timeout=10.0,
    # PgBouncer runs in transaction pooling mode, where a server connection can
    # change between statements. Disable psycopg's automatic named prepared
    # statements so they can never leak across pooled backends.
    kwargs={"row_factory": dict_row, "autocommit": True, "prepare_threshold": None},
)


async def init() -> None:
    """Open the pool and create tables/indexes if needed."""
    await pool.open()
    await pool.wait(timeout=15)
    async with pool.connection() as conn:
        for statement in SCHEMA:
            await conn.execute(statement)


async def close() -> None:
    await pool.close()


async def ping() -> None:
    async with pool.connection() as conn:
        await conn.execute("SELECT 1")


# --------------------------------------------------------------------------
# Runs
# --------------------------------------------------------------------------


async def create_run(
    run_id: UUID, duration_seconds: float, rate_per_second: int, payload_bytes: int
) -> dict[str, Any]:
    async with pool.connection() as conn:
        cur = await conn.execute(
            """
            INSERT INTO run_history (id, status, duration_seconds, rate_per_second, payload_bytes)
            VALUES (%s, 'running', %s, %s, %s)
            RETURNING started_at
            """,
            (run_id, duration_seconds, rate_per_second, payload_bytes),
        )
        return await cur.fetchone()


async def update_progress(run_id: UUID, inserted: int, errors: int) -> None:
    async with pool.connection() as conn:
        await conn.execute(
            "UPDATE run_history SET inserted = %s, errors = %s WHERE id = %s",
            (inserted, errors, run_id),
        )


async def finish_run(
    run_id: UUID, status: str, inserted: int, errors: int, error: str | None
) -> None:
    async with pool.connection() as conn:
        await conn.execute(
            """
            UPDATE run_history
               SET status = %s,
                   inserted = %s,
                   errors = %s,
                   error = %s,
                   finished_at = now()
             WHERE id = %s
            """,
            (status, inserted, errors, error, run_id),
        )


async def get_run(run_id: UUID) -> dict[str, Any] | None:
    async with pool.connection() as conn:
        cur = await conn.execute(
            "SELECT * FROM run_history WHERE id = %s",
            (run_id,),
        )
        return await cur.fetchone()


async def list_runs(limit: int = 20) -> list[dict[str, Any]]:
    async with pool.connection() as conn:
        cur = await conn.execute(
            "SELECT * FROM run_history ORDER BY started_at DESC LIMIT %s",
            (limit,),
        )
        return list(await cur.fetchall())


async def mark_interrupted() -> int:
    """Mark runs left 'running' by a previous process as interrupted."""
    async with pool.connection() as conn:
        cur = await conn.execute(
            """
            UPDATE run_history
               SET status = 'interrupted', finished_at = now()
             WHERE status = 'running'
            RETURNING id
            """
        )
        return len(await cur.fetchall())


# --------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------


async def insert_payloads(run_id: UUID, batch: list[tuple[str, int]]) -> None:
    """Insert a batch of (json_text, byte_size) rows in one round trip."""
    params = [(run_id, payload, size) for payload, size in batch]
    async with pool.connection() as conn:
        async with conn.cursor() as cur:
            await cur.executemany(
                """
                INSERT INTO random_events (run_id, payload, payload_bytes)
                VALUES (%s, %s::jsonb, %s)
                """,
                params,
            )


async def recent_rows(limit: int = 20) -> list[dict[str, Any]]:
    async with pool.connection() as conn:
        cur = await conn.execute(
            """
            SELECT id, run_id, created_at, payload_bytes, left(payload::text, 240) AS payload
              FROM random_events
             ORDER BY id DESC
             LIMIT %s
            """,
            (limit,),
        )
        return list(await cur.fetchall())


async def stats() -> dict[str, Any]:
    async with pool.connection() as conn:
        cur = await conn.execute("SELECT count(*) AS total_rows FROM random_events")
        counts = await cur.fetchone() or {"total_rows": 0}
        cur = await conn.execute(
            """
            SELECT pg_total_relation_size('random_events') AS table_bytes,
                   pg_database_size(current_database())     AS db_bytes
            """
        )
        sizes = await cur.fetchone() or {"table_bytes": 0, "db_bytes": 0}
    return {
        "total_rows": int(counts["total_rows"]),
        "table_bytes": int(sizes["table_bytes"]),
        "db_bytes": int(sizes["db_bytes"]),
    }


async def delete_run_data(run_id: UUID) -> tuple[int, int]:
    """Delete every event of a run plus its history entry.

    Returns (deleted_events, deleted_history_rows).
    """
    async with pool.connection() as conn:
        cur = await conn.execute("DELETE FROM random_events WHERE run_id = %s", (run_id,))
        events = max(cur.rowcount, 0)
        cur = await conn.execute("DELETE FROM run_history WHERE id = %s", (run_id,))
        runs = max(cur.rowcount, 0)
    return events, runs


async def delete_all_data() -> int:
    """Truncate events and run history. Returns the number of events removed."""
    async with pool.connection() as conn:
        cur = await conn.execute("SELECT count(*) AS n FROM random_events")
        row = await cur.fetchone()
        total = int(row["n"]) if row else 0
        await conn.execute("TRUNCATE random_events, run_history RESTART IDENTITY")
    return total
