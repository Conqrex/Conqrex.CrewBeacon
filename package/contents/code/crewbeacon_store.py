#!/usr/bin/env python3
"""Durable, narrow local store for CrewBeacon's normalized observer data."""

from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1


def database_path() -> Path:
    override = os.environ.get("CREWBEACON_DB_PATH")
    if override:
        return Path(override).expanduser()
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return data_home / "crewbeacon" / "crewbeacon.sqlite3"


def connect() -> sqlite3.Connection:
    path = database_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA busy_timeout = 3000")
    migrate(db)
    return db


def migrate(db: sqlite3.Connection) -> None:
    version = int(db.execute("PRAGMA user_version").fetchone()[0])
    if version > SCHEMA_VERSION:
        raise RuntimeError(f"database schema {version} is newer than supported {SCHEMA_VERSION}")
    if version < 1:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS hosts (
                source_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                endpoint TEXT,
                server_id TEXT,
                hostname TEXT,
                version TEXT,
                connection_state TEXT NOT NULL,
                last_seen_at TEXT,
                error TEXT,
                compatible INTEGER NOT NULL DEFAULT 1,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS repositories (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                remote_url TEXT,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspaces (
                key TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                external_id TEXT,
                repository_id TEXT,
                name TEXT,
                working_directory TEXT,
                branch TEXT,
                worktree TEXT,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sessions (
                key TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                host_id TEXT,
                external_id TEXT NOT NULL,
                repository_id TEXT,
                workspace_id TEXT,
                provider_id TEXT,
                model_id TEXT,
                state TEXT NOT NULL,
                started_at TEXT,
                last_activity_at TEXT,
                ended_at TEXT,
                attention_reason TEXT,
                payload_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS sessions_activity_idx
            ON sessions(last_activity_at DESC);

            CREATE TABLE IF NOT EXISTS usage_events (
                dedup_key TEXT PRIMARY KEY,
                captured_at TEXT NOT NULL,
                source_id TEXT NOT NULL,
                host_id TEXT,
                session_id TEXT NOT NULL,
                repository_id TEXT,
                workspace_id TEXT,
                provider_id TEXT,
                model_id TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER,
                context_used_tokens INTEGER,
                context_max_tokens INTEGER,
                reported_cost REAL,
                currency TEXT,
                provenance TEXT NOT NULL,
                quality TEXT NOT NULL,
                metric_kind TEXT NOT NULL CHECK(metric_kind IN ('event_delta', 'context_snapshot')),
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS usage_events_time_idx
            ON usage_events(captured_at);
            CREATE INDEX IF NOT EXISTS usage_events_repo_time_idx
            ON usage_events(repository_id, captured_at);

            CREATE TABLE IF NOT EXISTS attention_events (
                dedup_key TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                host_id TEXT,
                session_id TEXT NOT NULL,
                repository_id TEXT,
                provider_id TEXT,
                type TEXT NOT NULL,
                created_at TEXT NOT NULL,
                resolved_at TEXT,
                title TEXT,
                preview TEXT,
                source_event_id TEXT,
                notified_at TEXT
            );

            CREATE TABLE IF NOT EXISTS quota_snapshots (
                dedup_key TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL,
                captured_at TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );

            PRAGMA user_version = 1;
            """
        )
        db.commit()


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso_utc(value: datetime | None = None) -> str:
    return (value or now_utc()).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: Any, fallback: datetime | None = None) -> datetime:
    if not isinstance(value, str) or not value.strip():
        return fallback or now_utc()
    text = value.strip().replace("Z", "+00:00")
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def payload_arg(raw: str) -> dict[str, Any]:
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError("payload must be a JSON object")
    return parsed


def text(value: Any, default: str = "") -> str:
    return value.strip() if isinstance(value, str) and value.strip() else default


def metric(value: Any, *, integer: bool = True) -> int | float | None:
    if value is None or isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value) or value < 0:
        return None
    return int(value) if integer else float(value)


def upsert_repository(db: sqlite3.Connection, payload: dict[str, Any], stamp: str) -> None:
    repo_id = text(payload.get("repositoryId"))
    if not repo_id:
        return
    db.execute(
        """
        INSERT INTO repositories(id, name, remote_url, updated_at)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            remote_url = COALESCE(NULLIF(excluded.remote_url, ''), repositories.remote_url),
            updated_at = excluded.updated_at
        """,
        (
            repo_id,
            text(payload.get("repositoryName"), "Unknown repository"),
            text(payload.get("repositoryRemote")),
            stamp,
        ),
    )


def upsert_workspace(db: sqlite3.Connection, payload: dict[str, Any], stamp: str) -> None:
    source_id = text(payload.get("sourceId"), "unknown")
    workspace_id = text(payload.get("workspaceId"))
    if not workspace_id:
        return
    key = f"{source_id}:{workspace_id}"
    db.execute(
        """
        INSERT INTO workspaces(
            key, source_id, external_id, repository_id, name,
            working_directory, branch, worktree, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            repository_id = excluded.repository_id,
            name = excluded.name,
            working_directory = excluded.working_directory,
            branch = excluded.branch,
            worktree = excluded.worktree,
            updated_at = excluded.updated_at
        """,
        (
            key,
            source_id,
            workspace_id,
            text(payload.get("repositoryId")) or None,
            text(payload.get("workspaceName")) or None,
            text(payload.get("workingDirectory")) or None,
            text(payload.get("branch")) or None,
            text(payload.get("worktree")) or None,
            stamp,
        ),
    )


def safe_session_payload(session: dict[str, Any], stale: bool = False) -> dict[str, Any]:
    allowed = {
        "key", "id", "sourceId", "sourceName", "hostId", "hostName",
        "providerId", "providerLabel", "modelId", "title", "repositoryId",
        "repositoryName", "repositoryRemote", "repositoryQuality", "workspaceId",
        "workspaceName", "workingDirectory", "branch", "worktree", "state",
        "rawState", "startedAt", "lastActivityAt", "endedAt", "attentionReason",
        "attentionTimestamp", "usage", "capabilities", "deepLink",
        "sourceConnectionState",
    }
    result = {key: session[key] for key in allowed if key in session}
    result["stale"] = stale or bool(session.get("stale"))
    return result


def sync_snapshot(db: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    stamp = iso_utc()
    host = payload.get("host") if isinstance(payload.get("host"), dict) else {}
    source_id = text(host.get("id"), "unknown")
    db.execute(
        """
        INSERT INTO hosts(
            source_id, name, endpoint, server_id, hostname, version,
            connection_state, last_seen_at, error, compatible, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id) DO UPDATE SET
            name = excluded.name,
            endpoint = excluded.endpoint,
            server_id = excluded.server_id,
            hostname = excluded.hostname,
            version = excluded.version,
            connection_state = excluded.connection_state,
            last_seen_at = excluded.last_seen_at,
            error = excluded.error,
            compatible = excluded.compatible,
            updated_at = excluded.updated_at
        """,
        (
            source_id,
            text(host.get("name"), source_id),
            text(host.get("endpoint")) or None,
            text(host.get("serverId")) or None,
            text(host.get("hostname")) or None,
            text(host.get("version")) or None,
            text(host.get("connectionState"), "Unknown"),
            text(host.get("lastSeenAt")) or None,
            text(host.get("error")) or None,
            0 if host.get("compatible") is False else 1,
            stamp,
        ),
    )

    sessions = payload.get("sessions") if isinstance(payload.get("sessions"), list) else []
    for item in sessions:
        if not isinstance(item, dict) or not text(item.get("id")):
            continue
        item.setdefault("sourceId", source_id)
        upsert_repository(db, item, stamp)
        upsert_workspace(db, item, stamp)
        key = text(item.get("key"), f"{source_id}:{text(item.get('id'))}")
        safe = safe_session_payload(item)
        db.execute(
            """
            INSERT INTO sessions(
                key, source_id, host_id, external_id, repository_id, workspace_id,
                provider_id, model_id, state, started_at, last_activity_at, ended_at,
                attention_reason, payload_json, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                host_id = excluded.host_id,
                repository_id = excluded.repository_id,
                workspace_id = excluded.workspace_id,
                provider_id = excluded.provider_id,
                model_id = excluded.model_id,
                state = excluded.state,
                started_at = excluded.started_at,
                last_activity_at = excluded.last_activity_at,
                ended_at = excluded.ended_at,
                attention_reason = excluded.attention_reason,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """,
            (
                key,
                source_id,
                text(item.get("hostId")) or None,
                text(item.get("id")),
                text(item.get("repositoryId")) or None,
                text(item.get("workspaceId")) or None,
                text(item.get("providerId")) or None,
                text(item.get("modelId")) or None,
                text(item.get("state"), "Unknown"),
                text(item.get("startedAt")) or None,
                text(item.get("lastActivityAt")) or None,
                text(item.get("endedAt")) or None,
                text(item.get("attentionReason")) or None,
                json.dumps(safe, separators=(",", ":"), ensure_ascii=False),
                stamp,
            ),
        )
    db.commit()
    return {"ok": True, "sourceId": source_id, "sessions": len(sessions)}


def record_usage(db: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    dedup_key = text(payload.get("dedupKey"))
    session_id = text(payload.get("sessionId"))
    if not dedup_key or not session_id:
        raise ValueError("usage event requires dedupKey and sessionId")
    kind = text(payload.get("metricKind"))
    if kind not in {"event_delta", "context_snapshot"}:
        raise ValueError("metricKind must be event_delta or context_snapshot")
    captured = iso_utc(parse_timestamp(payload.get("capturedAt")))
    stamp = iso_utc()
    upsert_repository(db, payload, stamp)
    upsert_workspace(db, payload, stamp)
    cursor = db.execute(
        """
        INSERT OR IGNORE INTO usage_events(
            dedup_key, captured_at, source_id, host_id, session_id,
            repository_id, workspace_id, provider_id, model_id,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            reasoning_tokens, context_used_tokens, context_max_tokens,
            reported_cost, currency, provenance, quality, metric_kind, created_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            dedup_key,
            captured,
            text(payload.get("sourceId"), "unknown"),
            text(payload.get("hostId")) or None,
            session_id,
            text(payload.get("repositoryId")) or None,
            text(payload.get("workspaceId")) or None,
            text(payload.get("providerId")) or None,
            text(payload.get("modelId")) or None,
            metric(payload.get("inputTokens")),
            metric(payload.get("outputTokens")),
            metric(payload.get("cacheReadTokens")),
            metric(payload.get("cacheWriteTokens")),
            metric(payload.get("reasoningTokens")),
            metric(payload.get("contextUsedTokens")),
            metric(payload.get("contextMaxTokens")),
            metric(payload.get("reportedCost"), integer=False),
            text(payload.get("currency")) or None,
            text(payload.get("provenance"), "unknown"),
            text(payload.get("quality"), "partial"),
            kind,
            stamp,
        ),
    )
    db.commit()
    return {"ok": True, "inserted": cursor.rowcount == 1, "usage": usage_snapshot(db)}


def record_attention(db: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    dedup_key = text(payload.get("dedupKey"))
    session_id = text(payload.get("sessionId"))
    event_type = text(payload.get("type"))
    if not dedup_key or not session_id or not event_type:
        raise ValueError("attention event requires dedupKey, sessionId, and type")
    created = iso_utc(parse_timestamp(payload.get("createdAt")))
    cursor = db.execute(
        """
        INSERT OR IGNORE INTO attention_events(
            dedup_key, source_id, host_id, session_id, repository_id,
            provider_id, type, created_at, title, preview, source_event_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            dedup_key,
            text(payload.get("sourceId"), "unknown"),
            text(payload.get("hostId")) or None,
            session_id,
            text(payload.get("repositoryId")) or None,
            text(payload.get("providerId")) or None,
            event_type,
            created,
            text(payload.get("title")) or None,
            text(payload.get("preview")) or None,
            text(payload.get("sourceEventId")) or None,
        ),
    )
    inserted = cursor.rowcount == 1
    if inserted:
        db.execute(
            "UPDATE attention_events SET notified_at = ? WHERE dedup_key = ?",
            (iso_utc(), dedup_key),
        )
    db.commit()
    return {"ok": True, "inserted": inserted, "dedupKey": dedup_key}


def local_boundaries(reference: datetime | None = None) -> dict[str, tuple[str, str]]:
    local = (reference or now_utc()).astimezone()
    today = local.replace(hour=0, minute=0, second=0, microsecond=0)
    week = today - timedelta(days=today.weekday())
    month = today.replace(day=1)
    tomorrow = today + timedelta(days=1)
    next_week = week + timedelta(days=7)
    if month.month == 12:
        next_month = month.replace(year=month.year + 1, month=1)
    else:
        next_month = month.replace(month=month.month + 1)
    return {
        "today": (iso_utc(today), iso_utc(tomorrow)),
        "week": (iso_utc(week), iso_utc(next_week)),
        "month": (iso_utc(month), iso_utc(next_month)),
    }


def usage_rows(db: sqlite3.Connection, start: str, end: str) -> list[dict[str, Any]]:
    rows = db.execute(
        """
        SELECT
            COALESCE(u.repository_id, 'unattributed') AS repository_id,
            COALESCE(r.name, 'Unattributed') AS repository_name,
            SUM(COALESCE(u.input_tokens, 0) + COALESCE(u.output_tokens, 0)) AS total_tokens,
            SUM(COALESCE(u.input_tokens, 0)) AS input_tokens,
            SUM(COALESCE(u.output_tokens, 0)) AS output_tokens,
            SUM(COALESCE(u.cache_read_tokens, 0)) AS cache_read_tokens,
            SUM(COALESCE(u.cache_write_tokens, 0)) AS cache_write_tokens,
            SUM(COALESCE(u.reasoning_tokens, 0)) AS reasoning_tokens,
            SUM(COALESCE(u.reported_cost, 0)) AS reported_cost,
            COUNT(*) AS event_count
        FROM usage_events u
        LEFT JOIN repositories r ON r.id = u.repository_id
        WHERE u.metric_kind = 'event_delta'
          AND u.captured_at >= ? AND u.captured_at < ?
          AND (u.input_tokens IS NOT NULL OR u.output_tokens IS NOT NULL
               OR u.reported_cost IS NOT NULL)
        GROUP BY COALESCE(u.repository_id, 'unattributed'), COALESCE(r.name, 'Unattributed')
        ORDER BY total_tokens DESC, repository_name COLLATE NOCASE
        """,
        (start, end),
    ).fetchall()
    total = sum(int(row["total_tokens"] or 0) for row in rows)
    return [
        {
            "repositoryId": row["repository_id"],
            "repositoryName": row["repository_name"],
            "totalTokens": int(row["total_tokens"] or 0),
            "inputTokens": int(row["input_tokens"] or 0),
            "outputTokens": int(row["output_tokens"] or 0),
            "cacheReadTokens": int(row["cache_read_tokens"] or 0),
            "cacheWriteTokens": int(row["cache_write_tokens"] or 0),
            "reasoningTokens": int(row["reasoning_tokens"] or 0),
            "reportedCost": float(row["reported_cost"] or 0),
            "eventCount": int(row["event_count"]),
            "share": (int(row["total_tokens"] or 0) / total) if total else 0,
            "quality": "provider-reported",
        }
        for row in rows
    ]


def local_date_bounds(day: date) -> tuple[str, str]:
    start = datetime(day.year, day.month, day.day).astimezone()
    following = start + timedelta(days=1)
    return iso_utc(start), iso_utc(following)


def usage_calendar(
    db: sqlite3.Connection,
    reference: datetime | None = None,
    history_days: int = 371,
) -> dict[str, Any]:
    local_today = (reference or now_utc()).astimezone().date()
    first_day = local_today - timedelta(days=max(31, history_days) - 1)
    start, _ = local_date_bounds(first_day)
    _, end = local_date_bounds(local_today)
    rows = db.execute(
        """
        SELECT
            date(u.captured_at, 'localtime') AS local_date,
            SUM(COALESCE(u.input_tokens, 0) + COALESCE(u.output_tokens, 0)) AS total_tokens,
            SUM(COALESCE(u.input_tokens, 0)) AS input_tokens,
            SUM(COALESCE(u.output_tokens, 0)) AS output_tokens,
            SUM(COALESCE(u.cache_read_tokens, 0)) AS cache_read_tokens,
            SUM(COALESCE(u.cache_write_tokens, 0)) AS cache_write_tokens,
            SUM(COALESCE(u.reasoning_tokens, 0)) AS reasoning_tokens,
            SUM(COALESCE(u.reported_cost, 0)) AS reported_cost,
            COUNT(*) AS event_count,
            COUNT(DISTINCT COALESCE(u.repository_id, 'unattributed')) AS repository_count,
            COUNT(DISTINCT COALESCE(u.provider_id, 'unknown')) AS provider_count
        FROM usage_events u
        WHERE u.metric_kind = 'event_delta'
          AND u.captured_at >= ? AND u.captured_at < ?
          AND (u.input_tokens IS NOT NULL OR u.output_tokens IS NOT NULL
               OR u.reported_cost IS NOT NULL)
        GROUP BY date(u.captured_at, 'localtime')
        ORDER BY local_date
        """,
        (start, end),
    ).fetchall()
    days = [
        {
            "date": row["local_date"],
            "totalTokens": int(row["total_tokens"] or 0),
            "inputTokens": int(row["input_tokens"] or 0),
            "outputTokens": int(row["output_tokens"] or 0),
            "cacheReadTokens": int(row["cache_read_tokens"] or 0),
            "cacheWriteTokens": int(row["cache_write_tokens"] or 0),
            "reasoningTokens": int(row["reasoning_tokens"] or 0),
            "reportedCost": float(row["reported_cost"] or 0),
            "eventCount": int(row["event_count"] or 0),
            "repositoryCount": int(row["repository_count"] or 0),
            "providerCount": int(row["provider_count"] or 0),
        }
        for row in rows
        if row["local_date"]
    ]
    return {
        "startDate": first_day.isoformat(),
        "endDate": local_today.isoformat(),
        "maxTokens": max((item["totalTokens"] for item in days), default=0),
        "maxEvents": max((item["eventCount"] for item in days), default=0),
        "totalTokens": sum(item["totalTokens"] for item in days),
        "reportedCost": sum(item["reportedCost"] for item in days),
        "days": days,
    }


def usage_breakdown_rows(
    db: sqlite3.Connection,
    start: str,
    end: str,
    group: str,
) -> list[dict[str, Any]]:
    if group == "provider":
        select = "COALESCE(u.provider_id, 'unknown'), COALESCE(u.model_id, '')"
        labels = ("providerId", "modelId")
    elif group == "session":
        select = "u.session_id, COALESCE(u.provider_id, 'unknown')"
        labels = ("sessionId", "providerId")
    else:
        raise ValueError("unsupported usage breakdown")
    rows = db.execute(
        f"""
        SELECT {select},
            SUM(COALESCE(u.input_tokens, 0) + COALESCE(u.output_tokens, 0)) AS total_tokens,
            SUM(COALESCE(u.input_tokens, 0)) AS input_tokens,
            SUM(COALESCE(u.output_tokens, 0)) AS output_tokens,
            SUM(COALESCE(u.cache_read_tokens, 0)) AS cache_read_tokens,
            SUM(COALESCE(u.cache_write_tokens, 0)) AS cache_write_tokens,
            SUM(COALESCE(u.reasoning_tokens, 0)) AS reasoning_tokens,
            SUM(COALESCE(u.reported_cost, 0)) AS reported_cost,
            COUNT(*) AS event_count
        FROM usage_events u
        WHERE u.metric_kind = 'event_delta'
          AND u.captured_at >= ? AND u.captured_at < ?
          AND (u.input_tokens IS NOT NULL OR u.output_tokens IS NOT NULL
               OR u.reported_cost IS NOT NULL)
        GROUP BY {select}
        ORDER BY total_tokens DESC, event_count DESC
        """,
        (start, end),
    ).fetchall()
    total = sum(int(row["total_tokens"] or 0) for row in rows)
    result: list[dict[str, Any]] = []
    for row in rows:
        item = {
            labels[0]: row[0],
            labels[1]: row[1],
            "totalTokens": int(row["total_tokens"] or 0),
            "inputTokens": int(row["input_tokens"] or 0),
            "outputTokens": int(row["output_tokens"] or 0),
            "cacheReadTokens": int(row["cache_read_tokens"] or 0),
            "cacheWriteTokens": int(row["cache_write_tokens"] or 0),
            "reasoningTokens": int(row["reasoning_tokens"] or 0),
            "reportedCost": float(row["reported_cost"] or 0),
            "eventCount": int(row["event_count"] or 0),
            "share": (int(row["total_tokens"] or 0) / total) if total else 0,
        }
        result.append(item)
    return result


def usage_day_detail(db: sqlite3.Connection, day_value: str) -> dict[str, Any]:
    try:
        day = date.fromisoformat(day_value)
    except (TypeError, ValueError) as exc:
        raise ValueError("usage day must be YYYY-MM-DD") from exc
    start, end = local_date_bounds(day)
    repositories = usage_rows(db, start, end)
    providers = usage_breakdown_rows(db, start, end, "provider")
    sessions = usage_breakdown_rows(db, start, end, "session")
    events = [
        {
            "capturedAt": row["captured_at"],
            "sourceId": row["source_id"],
            "sessionId": row["session_id"],
            "repositoryId": row["repository_id"] or "unattributed",
            "repositoryName": row["repository_name"] or "Unattributed",
            "providerId": row["provider_id"] or "unknown",
            "modelId": row["model_id"] or "",
            "inputTokens": row["input_tokens"],
            "outputTokens": row["output_tokens"],
            "cacheReadTokens": row["cache_read_tokens"],
            "cacheWriteTokens": row["cache_write_tokens"],
            "reasoningTokens": row["reasoning_tokens"],
            "reportedCost": row["reported_cost"],
            "currency": row["currency"] or "",
            "quality": row["quality"],
        }
        for row in db.execute(
            """
            SELECT u.*, COALESCE(r.name, 'Unattributed') AS repository_name
            FROM usage_events u
            LEFT JOIN repositories r ON r.id = u.repository_id
            WHERE u.metric_kind = 'event_delta'
              AND u.captured_at >= ? AND u.captured_at < ?
              AND (u.input_tokens IS NOT NULL OR u.output_tokens IS NOT NULL
                   OR u.reported_cost IS NOT NULL)
            ORDER BY u.captured_at DESC
            LIMIT 200
            """,
            (start, end),
        )
    ]
    return {
        "ok": True,
        "date": day.isoformat(),
        "start": start,
        "end": end,
        "totalTokens": sum(row["totalTokens"] for row in repositories),
        "inputTokens": sum(row["inputTokens"] for row in repositories),
        "outputTokens": sum(row["outputTokens"] for row in repositories),
        "cacheReadTokens": sum(row["cacheReadTokens"] for row in repositories),
        "cacheWriteTokens": sum(row["cacheWriteTokens"] for row in repositories),
        "reasoningTokens": sum(row["reasoningTokens"] for row in repositories),
        "reportedCost": sum(row["reportedCost"] for row in repositories),
        "eventCount": sum(row["eventCount"] for row in repositories),
        "repositories": repositories,
        "providers": providers,
        "sessions": sessions,
        "events": events,
    }


def usage_snapshot(db: sqlite3.Connection, reference: datetime | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "generatedAt": iso_utc(reference),
        "ranges": {},
        "calendar": usage_calendar(db, reference),
    }
    for label, (start, end) in local_boundaries(reference).items():
        rows = usage_rows(db, start, end)
        result["ranges"][label] = {
            "start": start,
            "end": end,
            "totalTokens": sum(row["totalTokens"] for row in rows),
            "reportedCost": sum(row["reportedCost"] for row in rows),
            "repositories": rows,
        }
    return result


def stored_snapshot(db: sqlite3.Connection, retention_hours: int = 24) -> dict[str, Any]:
    cutoff = iso_utc(now_utc() - timedelta(hours=max(1, retention_hours)))
    sessions: list[dict[str, Any]] = []
    for row in db.execute(
        """
        SELECT payload_json FROM sessions
        WHERE COALESCE(last_activity_at, updated_at) >= ?
        ORDER BY COALESCE(last_activity_at, updated_at) DESC
        """,
        (cutoff,),
    ):
        try:
            payload = json.loads(row["payload_json"])
        except (TypeError, json.JSONDecodeError):
            continue
        if isinstance(payload, dict):
            payload["stale"] = True
            payload["sourceConnectionState"] = "Disconnected"
            sessions.append(payload)
    hosts = [dict(row) for row in db.execute("SELECT * FROM hosts ORDER BY name COLLATE NOCASE")]
    for host in hosts:
        host["connectionState"] = "Disconnected"
        host["sourceId"] = host.pop("source_id")
        host["serverId"] = host.pop("server_id")
        host["lastSeenAt"] = host.pop("last_seen_at")
        host["compatible"] = bool(host["compatible"])
    return {
        "ok": True,
        "schemaVersion": SCHEMA_VERSION,
        "sessions": sessions,
        "hosts": hosts,
        "usage": usage_snapshot(db),
    }


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, separators=(",", ":"), ensure_ascii=False))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init", "snapshot", "sync-snapshot", "record-usage", "record-attention", "usage-day"])
    parser.add_argument("payload", nargs="?", default="{}")
    parser.add_argument("--retention-hours", type=int, default=24)
    args = parser.parse_args(argv)

    try:
        with connect() as db:
            if args.command == "init":
                emit({"ok": True, "schemaVersion": SCHEMA_VERSION, "path": str(database_path())})
            elif args.command == "snapshot":
                emit(stored_snapshot(db, args.retention_hours))
            elif args.command == "sync-snapshot":
                emit(sync_snapshot(db, payload_arg(args.payload)))
            elif args.command == "record-usage":
                emit(record_usage(db, payload_arg(args.payload)))
            elif args.command == "record-attention":
                emit(record_attention(db, payload_arg(args.payload)))
            elif args.command == "usage-day":
                emit(usage_day_detail(db, text(payload_arg(args.payload).get("date"))))
    except (ValueError, RuntimeError, sqlite3.Error, json.JSONDecodeError) as error:
        emit({"ok": False, "error": str(error)})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
