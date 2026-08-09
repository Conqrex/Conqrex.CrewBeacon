#!/usr/bin/env python3
"""Read-only Paseo relay snapshots through the official Paseo CLI.

The pairing offer is read from a user-owned 0600 file and is passed to the CLI
through PASEO_HOST, never through Plasma configuration or the command line.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
from typing import Any
from urllib.parse import urlparse


STATE_MAP = {
    "initializing": "Connecting",
    "idle": "Idle",
    "running": "Working",
    "error": "Failed",
    "closed": "Completed",
}


class RelayError(RuntimeError):
    pass


def read_offer(path_value: str) -> tuple[str, dict[str, Any]]:
    path = Path(path_value).expanduser()
    try:
        info = path.stat()
    except OSError as exc:
        raise RelayError(f"Offer file is unavailable: {exc.strerror}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise RelayError("Offer path is not a regular file")
    if info.st_uid != os.getuid():
        raise RelayError("Offer file must be owned by the current user")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise RelayError("Offer file permissions must be 0600")
    try:
        offer = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise RelayError(f"Cannot read offer file: {exc.strerror}") from exc

    parsed = urlparse(offer)
    if parsed.scheme != "https" or parsed.netloc != "app.paseo.sh":
        raise RelayError("Only https://app.paseo.sh pairing offers are accepted")
    prefix = "offer="
    if not parsed.fragment.startswith(prefix):
        raise RelayError("Pairing URL has no offer fragment")
    encoded = parsed.fragment[len(prefix):]
    try:
        padding = "=" * (-len(encoded) % 4)
        payload = json.loads(base64.urlsafe_b64decode(encoded + padding))
    except (ValueError, json.JSONDecodeError) as exc:
        raise RelayError("Pairing offer is malformed") from exc
    if payload.get("v") != 2 or not payload.get("serverId"):
        raise RelayError("Unsupported Paseo pairing offer version")
    relay = payload.get("relay")
    if not isinstance(relay, dict) or not relay.get("endpoint"):
        raise RelayError("Pairing offer has no relay endpoint")
    return offer, payload


def cli_candidates() -> list[str]:
    values = [
        os.environ.get("CREWBEACON_PASEO_CLI", ""),
        "/opt/Paseo/resources/bin/paseo",
        "/usr/bin/paseo",
        "/usr/local/bin/paseo",
        shutil.which("paseo") or "",
    ]
    result: list[str] = []
    for value in values:
        if value and value not in result and os.path.isfile(value) and os.access(value, os.X_OK):
            result.append(value)
    return result


def find_cli() -> str:
    for candidate in cli_candidates():
        try:
            probe = subprocess.run(
                [candidate, "ls", "--help"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if probe.returncode == 0 and "--host" in probe.stdout:
            return candidate
    raise RelayError("No compatible Paseo CLI with offer-link support was found")


def safe_cli_error(stderr: str) -> str:
    text = " ".join((stderr or "").strip().split())
    marker = "https://app.paseo.sh/"
    if marker in text:
        text = text.split(marker, 1)[0] + "<offer redacted>"
    return (text[:240] or "Paseo CLI relay request failed")


def fetch_agents(cli: str, offer: str) -> list[dict[str, Any]]:
    environment = os.environ.copy()
    environment["PASEO_HOST"] = offer
    # A user shell may globally disable Node TLS verification. Never inherit
    # that weakening for the relay transport.
    environment["NODE_TLS_REJECT_UNAUTHORIZED"] = "1"
    try:
        result = subprocess.run(
            [cli, "ls", "--json", "--global"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=35,
            check=False,
            env=environment,
        )
    except subprocess.TimeoutExpired as exc:
        raise RelayError("Paseo relay request timed out") from exc
    if result.returncode != 0:
        raise RelayError(safe_cli_error(result.stderr))
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RelayError("Paseo CLI returned invalid JSON") from exc
    if not isinstance(payload, list):
        raise RelayError("Paseo CLI returned an unexpected agent snapshot")
    return [entry for entry in payload if isinstance(entry, dict)]


def provider_parts(value: Any) -> tuple[str, str]:
    raw = str(value or "unknown")
    provider, _, model = raw.partition("/")
    return provider or "unknown", model


def normalize_agent(entry: dict[str, Any], source_id: str, source_name: str,
                    server_id: str) -> dict[str, Any] | None:
    agent_id = str(entry.get("id") or "").strip()
    if not agent_id:
        return None
    raw_state = str(entry.get("status") or "").lower()
    state = STATE_MAP.get(raw_state, "Unknown")
    cwd = str(entry.get("cwd") or "").strip()
    repository_name = Path(cwd).name if cwd else "Unknown repository"
    provider, model = provider_parts(entry.get("provider"))
    return {
        "key": f"{source_id}:{agent_id}",
        "id": agent_id,
        "sourceId": source_id,
        "sourceName": source_name,
        "hostId": server_id,
        "hostName": source_name,
        "providerId": provider,
        "providerLabel": provider[:1].upper() + provider[1:],
        "modelId": model,
        "title": str(entry.get("name") or repository_name),
        "repositoryId": f"host:{server_id}:{cwd}",
        "repositoryName": repository_name,
        "repositoryRemote": "",
        "repositoryQuality": "relay-cli-path-fallback",
        "workspaceId": "",
        "workspaceName": repository_name,
        "workingDirectory": cwd,
        "branch": "",
        "worktree": "",
        "state": state,
        "rawState": raw_state,
        "startedAt": "",
        "lastActivityAt": "",
        "endedAt": "",
        "attentionReason": "Agent failed" if state == "Failed" else "",
        "attentionTimestamp": "",
        "usage": None,
        "capabilities": {
            "canListSessions": True,
            "canStreamSessionState": False,
            "canReadRepository": bool(cwd),
            "canReadBranch": False,
            "canReadContextUsage": False,
            "canReadTokenUsage": False,
            "canReadCost": False,
            "canOpenSession": False,
            "canSendMessage": False,
            "canApprovePermission": False,
            "providerStreaming": False,
            "providerSessionPersistence": False,
        },
        "deepLink": "",
        "stale": False,
        "sourceConnectionState": "Connected",
    }


def snapshot(args: argparse.Namespace) -> dict[str, Any]:
    offer, offer_payload = read_offer(args.offer_file)
    cli = find_cli()
    entries = fetch_agents(cli, offer)
    server_id = str(offer_payload["serverId"])
    relay = offer_payload["relay"]
    sessions = [
        normalized
        for entry in entries
        if (normalized := normalize_agent(entry, args.source_id, args.source_name, server_id))
    ]
    host = {
        "id": args.source_id,
        "name": args.source_name,
        "endpoint": f"relay://{relay['endpoint']}",
        "serverId": server_id,
        "hostname": args.source_name,
        "version": "CLI relay",
        "connectionState": "Connected",
        "lastSeenAt": "",
        "error": "",
        "compatible": True,
        "unknownMessages": 0,
        "transport": "relay",
    }
    return {"ok": True, "host": host, "sessions": sessions}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subcommands = result.add_subparsers(dest="command", required=True)
    command = subcommands.add_parser("snapshot")
    command.add_argument("--offer-file", required=True)
    command.add_argument("--source-id", required=True)
    command.add_argument("--source-name", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        output = snapshot(args)
    except RelayError as exc:
        output = {"ok": False, "error": str(exc), "host": None, "sessions": []}
    json.dump(output, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
