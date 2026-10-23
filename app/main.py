"""FastAPI app: start time-boxed loads of random data into Postgres."""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import db
from .producer import RunManager

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

manager = RunManager()


@asynccontextmanager
async def lifespan(_: FastAPI):
    await db.init()
    await db.mark_interrupted()
    yield
    await manager.shutdown()
    await db.close()


app = FastAPI(title="Random Data Loader", version="1.0.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class RunRequest(BaseModel):
    duration_seconds: float = Field(
        default=10, gt=0, le=3600, description="How long to keep inserting (max 1 hour)"
    )
    rate_per_second: int = Field(
        default=50, ge=1, le=5000, description="Target insert rate in rows/second"
    )
    payload_bytes: int = Field(
        default=256, ge=16, le=4096, description="Approximate JSON payload size in bytes"
    )


def _serialize_row(row: dict[str, Any]) -> dict[str, Any]:
    started = row["started_at"]
    finished = row["finished_at"]
    end = finished or datetime.now(timezone.utc)
    elapsed = max(0.0, (end - started).total_seconds())
    inserted = int(row["inserted"])
    target = max(1, round(row["duration_seconds"] * row["rate_per_second"]))
    return {
        "run_id": str(row["id"]),
        "status": row["status"],
        "duration_seconds": row["duration_seconds"],
        "rate_per_second": row["rate_per_second"],
        "payload_bytes": row["payload_bytes"],
        "target": target,
        "inserted": inserted,
        "errors": int(row["errors"]),
        "elapsed_seconds": round(elapsed, 3),
        "actual_rate": round(inserted / elapsed, 2) if elapsed > 0 else 0.0,
        "progress": min(1.0, inserted / target) if target else 0.0,
        "started_at": started.isoformat(),
        "finished_at": finished.isoformat() if finished else None,
        "last_error": row["error"],
    }


@app.get("/", include_in_schema=False)
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    try:
        await db.ping()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"database unavailable: {exc}") from exc
    return {"status": "ok", "database": "ok"}


@app.post("/api/runs", status_code=201)
async def create_run(request: RunRequest) -> dict[str, Any]:
    state = await manager.start(
        request.duration_seconds, request.rate_per_second, request.payload_bytes
    )
    return state.to_dict()


@app.get("/api/runs")
async def list_runs(limit: int = Query(20, ge=1, le=100)) -> dict[str, Any]:
    rows = await db.list_runs(limit)
    return {"runs": [_serialize_row(row) for row in rows]}


@app.get("/api/runs/{run_id}")
async def get_run(run_id: UUID) -> dict[str, Any]:
    state = manager.get(run_id)
    if state is not None:
        return state.to_dict()
    row = await db.get_run(run_id)
    if row is None:
        raise HTTPException(status_code=404, detail="run not found")
    return _serialize_row(row)


@app.post("/api/runs/{run_id}/stop")
async def stop_run(run_id: UUID) -> dict[str, Any]:
    state = await manager.stop(run_id)
    if state is not None:
        return state.to_dict()
    row = await db.get_run(run_id)
    if row is None:
        raise HTTPException(status_code=404, detail="run not found")
    return _serialize_row(row)


@app.get("/api/stats")
async def get_stats() -> dict[str, Any]:
    return await db.stats()


@app.delete("/api/runs/{run_id}")
async def delete_run(run_id: UUID) -> dict[str, Any]:
    """Stop (if needed) and delete a run's rows plus its history entry."""
    state = manager.get(run_id)
    row = await db.get_run(run_id)
    if state is None and row is None:
        raise HTTPException(status_code=404, detail="run not found")
    if state is not None and state.status == "running":
        await manager.stop(run_id)
    events, runs = await db.delete_run_data(run_id)
    manager.discard(run_id)
    return {"run_id": str(run_id), "deleted_rows": events, "run_removed": runs > 0}


@app.delete("/api/data")
async def delete_all() -> dict[str, Any]:
    """Stop all active runs and delete every row plus the run history."""
    await manager.stop_all()
    deleted = await db.delete_all_data()
    manager.clear()
    return {"deleted_rows": deleted}


@app.get("/api/rows")
async def get_rows(limit: int = Query(20, ge=1, le=200)) -> dict[str, Any]:
    rows = await db.recent_rows(limit)
    return {
        "rows": [
            {
                "id": row["id"],
                "run_id": str(row["run_id"]),
                "created_at": row["created_at"].isoformat(),
                "payload_bytes": row["payload_bytes"],
                "payload": row["payload"],
            }
            for row in rows
        ]
    }
