"""Background producers that stream small random records into Postgres."""

from __future__ import annotations

import asyncio
import json
import os
import random
import secrets
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

from . import db

BATCH_MAX = max(1, int(os.getenv("INSERT_BATCH_SIZE", "250")))
PERSIST_EVERY = float(os.getenv("PROGRESS_PERSIST_SECONDS", "2"))

REGIONS = (
    "us-east-1",
    "us-west-2",
    "eu-west-1",
    "eu-central-1",
    "ap-south-1",
    "ap-southeast-2",
)
TAGS = ("alpha", "beta", "gamma", "delta", "epsilon", "zeta")


def make_payload(size: int) -> tuple[str, int]:
    """Return compact JSON text whose encoded size is close to ``size`` bytes."""
    doc: dict[str, Any] = {
        "id": secrets.token_hex(4),
        "r": random.choice(REGIONS),
        "v": round(random.uniform(0, 1000), 2),
        "t": random.choice(TAGS),
    }
    base = json.dumps(doc, separators=(",", ":"))
    if len(base) >= size:
        doc = {"id": secrets.token_hex(4)}
        base = json.dumps(doc, separators=(",", ":"))
    room = size - len(base) - len(',"pad":""')
    if room > 0:
        doc["pad"] = os.urandom((room + 1) // 2).hex()[:room]
    raw = json.dumps(doc, separators=(",", ":"))
    return raw, len(raw)


@dataclass
class RunState:
    run_id: UUID
    duration_seconds: float
    rate_per_second: int
    payload_bytes: int
    target: int
    status: str = "running"
    inserted: int = 0
    errors: int = 0
    started_wall: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    finished_at: datetime | None = None
    last_error: str | None = None
    stop_event: asyncio.Event = field(default_factory=asyncio.Event)
    task: asyncio.Task[Any] | None = field(default=None, repr=False)

    def elapsed(self) -> float:
        end = self.finished_at or datetime.now(timezone.utc)
        return max(0.0, (end - self.started_wall).total_seconds())

    def to_dict(self) -> dict[str, Any]:
        elapsed = self.elapsed()
        return {
            "run_id": str(self.run_id),
            "status": self.status,
            "duration_seconds": self.duration_seconds,
            "rate_per_second": self.rate_per_second,
            "payload_bytes": self.payload_bytes,
            "target": self.target,
            "inserted": self.inserted,
            "errors": self.errors,
            "elapsed_seconds": round(elapsed, 3),
            "actual_rate": round(self.inserted / elapsed, 2) if elapsed > 0 else 0.0,
            "progress": min(1.0, self.inserted / self.target) if self.target else 0.0,
            "started_at": self.started_wall.isoformat(),
            "finished_at": self.finished_at.isoformat() if self.finished_at else None,
            "last_error": self.last_error,
        }


async def _execute(state: RunState) -> None:
    """Write rows at the requested rate until the duration elapses or stop is set."""
    start = time.monotonic()
    last_persist = start
    try:
        while True:
            if state.stop_event.is_set():
                state.status = "stopped"
                break

            elapsed = time.monotonic() - start
            if elapsed >= state.duration_seconds:
                state.status = "completed"
                break

            expected = min(state.target, int(elapsed * state.rate_per_second))
            due = expected - state.inserted
            if due > 0:
                count = min(due, BATCH_MAX)
                batch = [make_payload(state.payload_bytes) for _ in range(count)]
                try:
                    await db.insert_payloads(state.run_id, batch)
                    state.inserted += count
                    state.last_error = None
                except Exception as exc:  # keep the run alive, surface the error
                    state.errors += count
                    state.last_error = f"{type(exc).__name__}: {exc}"
                    await asyncio.sleep(0.25)
            else:
                await asyncio.sleep(0.01)

            now = time.monotonic()
            if now - last_persist >= PERSIST_EVERY:
                last_persist = now
                try:
                    await db.update_progress(state.run_id, state.inserted, state.errors)
                except Exception:
                    pass
        # The loop exits on the clock, which can leave a partial final tick
        # (e.g. 499/500). Flush that small remainder in one batch.
        if state.status == "completed" and state.inserted < state.target:
            remaining = min(state.target - state.inserted, BATCH_MAX)
            batch = [make_payload(state.payload_bytes) for _ in range(remaining)]
            try:
                await db.insert_payloads(state.run_id, batch)
                state.inserted += remaining
            except Exception as exc:
                state.errors += remaining
                state.last_error = f"{type(exc).__name__}: {exc}"
    except asyncio.CancelledError:
        state.status = "stopped"
        raise
    except Exception as exc:
        state.status = "failed"
        state.last_error = f"{type(exc).__name__}: {exc}"
    finally:
        state.finished_at = datetime.now(timezone.utc)
        try:
            await db.finish_run(
                state.run_id, state.status, state.inserted, state.errors, state.last_error
            )
        except Exception:
            pass


class RunManager:
    """In-memory registry of active/recent runs."""

    def __init__(self) -> None:
        self._runs: dict[UUID, RunState] = {}

    def get(self, run_id: UUID) -> RunState | None:
        return self._runs.get(run_id)

    async def start(
        self, duration_seconds: float, rate_per_second: int, payload_bytes: int
    ) -> RunState:
        run_id = uuid4()
        state = RunState(
            run_id=run_id,
            duration_seconds=duration_seconds,
            rate_per_second=rate_per_second,
            payload_bytes=payload_bytes,
            target=max(1, round(duration_seconds * rate_per_second)),
        )
        await db.create_run(run_id, duration_seconds, rate_per_second, payload_bytes)
        state.task = asyncio.create_task(_execute(state), name=f"run-{run_id}")
        self._runs[run_id] = state
        self._prune()
        return state

    async def stop(self, run_id: UUID) -> RunState | None:
        state = self._runs.get(run_id)
        if state is None:
            return None
        state.stop_event.set()
        if state.task is not None and not state.task.done():
            try:
                await asyncio.wait_for(asyncio.shield(state.task), timeout=10)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass
        return state

    def discard(self, run_id: UUID) -> None:
        """Forget a run after its data/history has been deleted."""
        self._runs.pop(run_id, None)

    def clear(self) -> None:
        self._runs.clear()

    async def stop_all(self) -> None:
        await self.shutdown()

    async def shutdown(self) -> None:
        active = [s for s in self._runs.values() if s.status == "running"]
        for state in active:
            state.stop_event.set()
        tasks = [s.task for s in active if s.task is not None]
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    def _prune(self) -> None:
        if len(self._runs) <= 100:
            return
        for key, state in list(self._runs.items()):
            if len(self._runs) <= 100:
                break
            if state.status != "running":
                del self._runs[key]
