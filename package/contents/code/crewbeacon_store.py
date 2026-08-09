#!/usr/bin/env python3
"""Durable, narrow local store for CrewBeacon's normalized observer data."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import socket
import sqlite3
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SCHEMA_VERSION = 2
LOCAL_IMPORT_DEFAULT_DAYS = 7
LOCAL_IMPORT_MAX_BYTES = 128 * 1024 * 1024
TOKEN_COUNTER_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


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
    if version < 2:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS local_import_files (
                path TEXT PRIMARY KEY,
                provider_id TEXT NOT NULL,
                file_device INTEGER NOT NULL,
                file_inode INTEGER NOT NULL,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                file_size INTEGER NOT NULL DEFAULT 0,
                mtime_ns INTEGER NOT NULL DEFAULT 0,
                session_id TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                counters_json TEXT NOT NULL DEFAULT '{}',
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS local_import_files_updated_idx
            ON local_import_files(updated_at DESC);

            PRAGMA user_version = 2;
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


def insert_usage_event(db: sqlite3.Connection, payload: dict[str, Any]) -> bool:
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
    return cursor.rowcount == 1


def record_usage(db: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    inserted = insert_usage_event(db, payload)
    db.commit()
    return {"ok": True, "inserted": inserted, "usage": usage_snapshot(db)}


def normalize_git_remote(value: str) -> str:
    remote = value.strip()
    if not remote:
        return ""
    if "://" not in remote and ":" in remote:
        user_host, path = remote.split(":", 1)
        host = user_host.rsplit("@", 1)[-1]
        normalized = f"{host}/{path}"
    else:
        parsed = urlparse(remote if "://" in remote else f"ssh://{remote}")
        normalized = f"{parsed.hostname or ''}{parsed.path}"
    return normalized.strip("/").removesuffix(".git").lower()


def repository_metadata(cwd_value: Any) -> dict[str, str]:
    cwd = text(cwd_value)
    if not cwd:
        return {
            "workingDirectory": "", "repositoryId": "unattributed",
            "repositoryName": "Unattributed", "repositoryRemote": "",
        }
    path = Path(cwd).expanduser()
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    root = resolved
    remote = ""
    if resolved.is_dir():
        try:
            result = subprocess.run(
                ["git", "-C", str(resolved), "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=2, check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                root = Path(result.stdout.strip()).resolve()
                remote_result = subprocess.run(
                    ["git", "-C", str(root), "config", "--get", "remote.origin.url"],
                    capture_output=True, text=True, timeout=2, check=False,
                )
                if remote_result.returncode == 0:
                    remote = normalize_git_remote(remote_result.stdout)
        except (OSError, subprocess.SubprocessError):
            pass
    if remote:
        repository_id = f"remote:{remote}"
    else:
        digest = hashlib.sha256(str(root).encode("utf-8", "replace")).hexdigest()[:20]
        repository_id = f"local:{digest}"
    return {
        "workingDirectory": str(resolved),
        "repositoryId": repository_id,
        "repositoryName": root.name or resolved.name or "Local workspace",
        "repositoryRemote": remote,
    }


def refresh_repository_metadata(metadata: dict[str, Any], cwd_value: Any) -> None:
    cwd = text(cwd_value)
    if not cwd:
        return
    if text(metadata.get("workingDirectory")) == cwd and text(metadata.get("repositoryId")):
        return
    metadata.update(repository_metadata(cwd))


def safe_event_timestamp(value: Any, fallback: datetime) -> str:
    try:
        return iso_utc(parse_timestamp(value, fallback))
    except (TypeError, ValueError):
        return iso_utc(fallback)


def local_usage_payload(
    provider_id: str,
    metadata: dict[str, Any],
    session_id: str,
    captured_at: str,
    identity: str,
    values: dict[str, int | float | None],
) -> dict[str, Any]:
    return {
        "dedupKey": f"local:{provider_id}:{identity}",
        "capturedAt": captured_at,
        "sourceId": f"local-{provider_id}",
        "hostId": socket.gethostname() or "local",
        "sessionId": session_id,
        "repositoryId": text(metadata.get("repositoryId"), "unattributed"),
        "repositoryName": text(metadata.get("repositoryName"), "Unattributed"),
        "repositoryRemote": text(metadata.get("repositoryRemote")),
        "workingDirectory": text(metadata.get("workingDirectory")),
        "branch": text(metadata.get("branch")),
        "providerId": provider_id,
        "modelId": text(metadata.get("modelId")),
        "inputTokens": values.get("inputTokens"),
        "outputTokens": values.get("outputTokens"),
        "cacheReadTokens": values.get("cacheReadTokens"),
        "cacheWriteTokens": values.get("cacheWriteTokens"),
        "reasoningTokens": values.get("reasoningTokens"),
        "reportedCost": values.get("reportedCost"),
        "currency": text(values.get("currency")),
        "provenance": f"{provider_id}:local-jsonl",
        "quality": "provider-reported",
        "metricKind": "event_delta",
    }


def codex_log_event(
    row: dict[str, Any],
    metadata: dict[str, Any],
    counters: dict[str, int],
    fallback: datetime,
) -> dict[str, Any] | None:
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    row_type = text(row.get("type"))
    if row_type == "session_meta":
        session_id = text(payload.get("id")) or text(payload.get("session_id"))
        if session_id:
            metadata["sessionId"] = session_id
        metadata["surface"] = text(payload.get("source")) or text(payload.get("originator"))
        refresh_repository_metadata(metadata, payload.get("cwd"))
        return None
    if row_type == "turn_context":
        if text(payload.get("model")):
            metadata["modelId"] = text(payload.get("model"))
        refresh_repository_metadata(metadata, payload.get("cwd"))
        return None
    if row_type != "event_msg" or text(payload.get("type")) != "token_count":
        return None
    info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
    raw_total = info.get("total_token_usage") if isinstance(info.get("total_token_usage"), dict) else {}
    if not raw_total:
        return None
    current = {field: int(metric(raw_total.get(field)) or 0) for field in TOKEN_COUNTER_FIELDS}
    previous = {field: int(counters.get(field, 0)) for field in TOKEN_COUNTER_FIELDS}
    if counters:
        delta = {field: current[field] - previous[field] for field in TOKEN_COUNTER_FIELDS}
    else:
        delta = current.copy()
    if any(value < 0 for value in delta.values()):
        recent = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else {}
        delta = {field: int(metric(recent.get(field)) or 0) for field in TOKEN_COUNTER_FIELDS}
    counters.clear()
    counters.update(current)
    if not any(delta[field] > 0 for field in (
        "input_tokens", "output_tokens", "cached_input_tokens",
        "cache_write_input_tokens", "reasoning_output_tokens",
    )):
        return None
    session_id = text(metadata.get("sessionId")) or "unknown-codex-session"
    captured = safe_event_timestamp(row.get("timestamp"), fallback)
    fingerprint = hashlib.sha256(
        f"{session_id}\0{captured}\0{current['total_tokens']}\0{current['input_tokens']}".encode()
    ).hexdigest()[:24]
    return local_usage_payload("codex", metadata, session_id, captured, fingerprint, {
        "inputTokens": delta["input_tokens"],
        "outputTokens": delta["output_tokens"],
        "cacheReadTokens": delta["cached_input_tokens"],
        "cacheWriteTokens": delta["cache_write_input_tokens"],
        "reasoningTokens": delta["reasoning_output_tokens"],
        "reportedCost": None,
        "currency": "",
    })


def claude_log_event(
    row: dict[str, Any], metadata: dict[str, Any], fallback: datetime,
) -> dict[str, Any] | None:
    session_id = text(row.get("sessionId"))
    if session_id:
        metadata["sessionId"] = session_id
    if text(row.get("gitBranch")):
        metadata["branch"] = text(row.get("gitBranch"))
    refresh_repository_metadata(metadata, row.get("cwd"))
    if text(row.get("type")) != "assistant":
        return None
    message = row.get("message") if isinstance(row.get("message"), dict) else {}
    usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
    if not usage:
        return None
    if text(message.get("model")):
        metadata["modelId"] = text(message.get("model"))
    values = {
        "inputTokens": metric(usage.get("input_tokens")),
        "outputTokens": metric(usage.get("output_tokens")),
        "cacheReadTokens": metric(usage.get("cache_read_input_tokens")),
        "cacheWriteTokens": metric(usage.get("cache_creation_input_tokens")),
        "reasoningTokens": None,
        "reportedCost": None,
        "currency": "",
    }
    if all(values[key] is None for key in (
        "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
    )):
        return None
    session_id = text(metadata.get("sessionId")) or "unknown-claude-session"
    captured = safe_event_timestamp(row.get("timestamp"), fallback)
    request_id = text(row.get("requestId")) or text(message.get("id")) or text(row.get("uuid"))
    if not request_id:
        request_id = hashlib.sha256(
            f"{session_id}\0{captured}\0{json.dumps(values, sort_keys=True)}".encode()
        ).hexdigest()[:24]
    identity = hashlib.sha256(f"{session_id}\0{request_id}".encode()).hexdigest()[:24]
    return local_usage_payload("claude", metadata, session_id, captured, identity, values)


def local_log_roots(payload: dict[str, Any]) -> list[tuple[str, Path]]:
    codex_default = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "sessions"
    claude_default = Path.home() / ".claude" / "projects"
    return [
        ("codex", Path(text(payload.get("codexRoot"), str(codex_default))).expanduser()),
        ("claude", Path(text(payload.get("claudeRoot"), str(claude_default))).expanduser()),
    ]


def discover_local_logs(payload: dict[str, Any], reference: datetime) -> list[tuple[str, Path, os.stat_result]]:
    days = max(1, min(371, int(payload.get("historyDays") or LOCAL_IMPORT_DEFAULT_DAYS)))
    cutoff = reference.timestamp() - days * 86400
    found: list[tuple[str, Path, os.stat_result]] = []
    for provider_id, root in local_log_roots(payload):
        if not root.is_dir():
            continue
        try:
            paths = root.rglob("*.jsonl")
            for path in paths:
                try:
                    stat = path.stat()
                except OSError:
                    continue
                if stat.st_mtime >= cutoff and path.is_file():
                    found.append((provider_id, path.resolve(), stat))
        except OSError:
            continue
    found.sort(key=lambda item: item[2].st_mtime_ns, reverse=True)
    return found


def load_import_cursor(db: sqlite3.Connection, path: Path) -> sqlite3.Row | None:
    return db.execute("SELECT * FROM local_import_files WHERE path = ?", (str(path),)).fetchone()


def save_import_cursor(
    db: sqlite3.Connection,
    provider_id: str,
    path: Path,
    stat: os.stat_result,
    offset: int,
    metadata: dict[str, Any],
    counters: dict[str, int],
) -> None:
    db.execute(
        """
        INSERT INTO local_import_files(
            path, provider_id, file_device, file_inode, byte_offset, file_size,
            mtime_ns, session_id, metadata_json, counters_json, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            provider_id = excluded.provider_id,
            file_device = excluded.file_device,
            file_inode = excluded.file_inode,
            byte_offset = excluded.byte_offset,
            file_size = excluded.file_size,
            mtime_ns = excluded.mtime_ns,
            session_id = excluded.session_id,
            metadata_json = excluded.metadata_json,
            counters_json = excluded.counters_json,
            updated_at = excluded.updated_at
        """,
        (
            str(path), provider_id, stat.st_dev, stat.st_ino, offset, stat.st_size,
            stat.st_mtime_ns, text(metadata.get("sessionId")) or None,
            json.dumps(metadata, separators=(",", ":"), ensure_ascii=False),
            json.dumps(counters, separators=(",", ":")), iso_utc(),
        ),
    )


def import_local_usage(db: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    reference = now_utc()
    requested_bytes = int(payload.get("maxBytes") or LOCAL_IMPORT_MAX_BYTES)
    byte_budget = max(1024, min(512 * 1024 * 1024, requested_bytes))
    inserted = 0
    duplicates = 0
    parsed_lines = 0
    consumed_bytes = 0
    files_processed = 0
    files = discover_local_logs(payload, reference)

    for provider_id, path, stat in files:
        if consumed_bytes >= byte_budget:
            break
        cursor = load_import_cursor(db, path)
        reset = cursor is None or int(cursor["file_device"]) != stat.st_dev \
            or int(cursor["file_inode"]) != stat.st_ino or stat.st_size < int(cursor["byte_offset"])
        offset = 0 if reset else int(cursor["byte_offset"])
        if offset >= stat.st_size:
            continue
        try:
            metadata = {} if reset else json.loads(cursor["metadata_json"] or "{}")
            counters = {} if reset else json.loads(cursor["counters_json"] or "{}")
        except (TypeError, json.JSONDecodeError):
            metadata, counters, offset = {}, {}, 0
        metadata = metadata if isinstance(metadata, dict) else {}
        counters = counters if isinstance(counters, dict) else {}
        fallback = datetime.fromtimestamp(stat.st_mtime, timezone.utc)
        current_offset = offset
        try:
            with path.open("rb") as handle:
                handle.seek(offset)
                while consumed_bytes < byte_budget:
                    start = handle.tell()
                    raw = handle.readline()
                    if not raw:
                        break
                    has_newline = raw.endswith(b"\n")
                    try:
                        row = json.loads(raw)
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        if not has_newline:
                            handle.seek(start)
                            break
                        current_offset = handle.tell()
                        consumed_bytes += current_offset - start
                        continue
                    current_offset = handle.tell()
                    consumed_bytes += current_offset - start
                    parsed_lines += 1
                    if not isinstance(row, dict):
                        continue
                    event = codex_log_event(row, metadata, counters, fallback) \
                        if provider_id == "codex" else claude_log_event(row, metadata, fallback)
                    if event:
                        if insert_usage_event(db, event):
                            inserted += 1
                        else:
                            duplicates += 1
        except OSError:
            continue
        files_processed += 1
        try:
            latest_stat = path.stat()
        except OSError:
            latest_stat = stat
        save_import_cursor(db, provider_id, path, latest_stat, current_offset, metadata, counters)

    db.commit()
    return {
        "ok": True,
        "inserted": inserted,
        "duplicates": duplicates,
        "parsedLines": parsed_lines,
        "consumedBytes": consumed_bytes,
        "filesProcessed": files_processed,
        "filesDiscovered": len(files),
        "partial": consumed_bytes >= byte_budget,
        "usage": usage_snapshot(db),
    }


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
    parser.add_argument("command", choices=[
        "init", "snapshot", "sync-snapshot", "record-usage", "record-attention",
        "usage-day", "import-local-usage",
    ])
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
            elif args.command == "import-local-usage":
                emit(import_local_usage(db, payload_arg(args.payload)))
    except (ValueError, RuntimeError, sqlite3.Error, json.JSONDecodeError) as error:
        emit({"ok": False, "error": str(error)})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
