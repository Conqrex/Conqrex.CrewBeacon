from __future__ import annotations

import importlib.util
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "package" / "contents" / "code" / "crewbeacon_store.py"
SPEC = importlib.util.spec_from_file_location("crewbeacon_store", MODULE_PATH)
assert SPEC and SPEC.loader
store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(store)


class StoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.old_db = os.environ.get("CREWBEACON_DB_PATH")
        os.environ["CREWBEACON_DB_PATH"] = str(Path(self.temp.name) / "crewbeacon.sqlite3")

    def tearDown(self) -> None:
        if self.old_db is None:
            os.environ.pop("CREWBEACON_DB_PATH", None)
        else:
            os.environ["CREWBEACON_DB_PATH"] = self.old_db

    def usage_event(self, key: str, captured: str, **overrides):
        payload = {
            "dedupKey": key,
            "capturedAt": captured,
            "sourceId": "server-01",
            "hostId": "srv_fixture",
            "sessionId": "agent-1",
            "repositoryId": "remote:github.com/conqrex/engine",
            "repositoryName": "Engine",
            "repositoryRemote": "github.com/conqrex/engine",
            "workspaceId": "wks-1",
            "workspaceName": "feature",
            "workingDirectory": "/srv/engine-feature",
            "branch": "feature",
            "providerId": "claude",
            "modelId": "opus",
            "inputTokens": 100,
            "outputTokens": 40,
            "cacheReadTokens": 60,
            "reportedCost": 0.02,
            "currency": "USD",
            "provenance": "paseo:0.2.x:turn_completed",
            "quality": "provider-reported",
            "metricKind": "event_delta",
        }
        payload.update(overrides)
        return payload

    def test_schema_migration_and_snapshot(self):
        with store.connect() as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], store.SCHEMA_VERSION)
            snapshot = store.stored_snapshot(db)
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertEqual(snapshot["sessions"], [])

    def test_usage_dedup_and_context_exclusion(self):
        with store.connect() as db:
            event = self.usage_event("turn-1", "2026-08-09T10:00:00Z")
            self.assertTrue(store.record_usage(db, event)["inserted"])
            self.assertFalse(store.record_usage(db, event)["inserted"])
            context = self.usage_event(
                "context-1",
                "2026-08-09T10:01:00Z",
                inputTokens=None,
                outputTokens=None,
                cacheReadTokens=None,
                reportedCost=None,
                contextUsedTokens=50000,
                contextMaxTokens=200000,
                metricKind="context_snapshot",
            )
            self.assertTrue(store.record_usage(db, context)["inserted"])
            fixed = datetime(2026, 8, 9, 12, 0, tzinfo=timezone.utc)
            snapshot = store.usage_snapshot(db, fixed)

        self.assertEqual(snapshot["ranges"]["today"]["totalTokens"], 140)
        self.assertEqual(snapshot["ranges"]["today"]["repositories"][0]["cacheReadTokens"], 60)

    def test_local_day_week_and_month_boundaries(self):
        # Europe/Istanbul local midnight for Aug 9 is Aug 8 21:00 UTC.
        fixed = datetime(2026, 8, 9, 12, 0, tzinfo=timezone.utc)
        with store.connect() as db:
            store.record_usage(db, self.usage_event("before-midnight", "2026-08-08T20:59:00Z"))
            store.record_usage(db, self.usage_event("after-midnight", "2026-08-08T21:01:00Z"))
            store.record_usage(db, self.usage_event("earlier-week", "2026-08-06T12:00:00Z"))
            snapshot = store.usage_snapshot(db, fixed)

        self.assertEqual(snapshot["ranges"]["today"]["totalTokens"], 140)
        self.assertEqual(snapshot["ranges"]["week"]["totalTokens"], 420)
        self.assertEqual(snapshot["ranges"]["month"]["totalTokens"], 420)

    def test_partial_cost_metric_is_preserved_without_fake_tokens(self):
        fixed = datetime(2026, 8, 9, 12, 0, tzinfo=timezone.utc)
        with store.connect() as db:
            payload = self.usage_event(
                "cost-only", "2026-08-09T10:00:00Z",
                inputTokens=None, outputTokens=None, cacheReadTokens=None, reportedCost=1.25
            )
            store.record_usage(db, payload)
            rows = store.usage_snapshot(db, fixed)["ranges"]["today"]["repositories"]
        self.assertEqual(rows[0]["totalTokens"], 0)
        self.assertEqual(rows[0]["reportedCost"], 1.25)

    def test_calendar_rollup_and_selected_day_detail(self):
        fixed = datetime(2026, 8, 9, 12, 0, tzinfo=timezone.utc)
        with store.connect() as db:
            store.record_usage(db, self.usage_event("day-a", "2026-08-08T21:01:00Z"))
            store.record_usage(db, self.usage_event(
                "day-b", "2026-08-09T08:30:00Z",
                sessionId="agent-2", providerId="codex", modelId="gpt-5.6",
                inputTokens=200, outputTokens=80, cacheReadTokens=120,
                cacheWriteTokens=25, reasoningTokens=15,
            ))
            store.record_usage(db, self.usage_event("previous-day", "2026-08-08T20:59:00Z"))
            calendar = store.usage_calendar(db, fixed)
            detail = store.usage_day_detail(db, "2026-08-09")

        days = {item["date"]: item for item in calendar["days"]}
        self.assertEqual(days["2026-08-09"]["totalTokens"], 420)
        self.assertEqual(days["2026-08-09"]["eventCount"], 2)
        self.assertEqual(detail["totalTokens"], 420)
        self.assertEqual(detail["inputTokens"], 300)
        self.assertEqual(detail["outputTokens"], 120)
        self.assertEqual(detail["cacheWriteTokens"], 25)
        self.assertEqual(detail["reasoningTokens"], 15)
        self.assertEqual(len(detail["providers"]), 2)
        self.assertEqual(len(detail["sessions"]), 2)
        self.assertEqual(len(detail["events"]), 2)

    def test_usage_day_rejects_invalid_date(self):
        with store.connect() as db:
            with self.assertRaisesRegex(ValueError, "YYYY-MM-DD"):
                store.usage_day_detail(db, "09/08/2026")

    def test_attention_dedup_survives_reopen(self):
        payload = {
            "dedupKey": "attention-1",
            "sourceId": "server-01",
            "hostId": "srv_fixture",
            "sessionId": "agent-1",
            "repositoryId": "remote:github.com/conqrex/engine",
            "providerId": "claude",
            "type": "WaitingForPermission",
            "createdAt": "2026-08-09T10:00:00Z",
            "title": "Engine",
            "preview": "Run tests?",
            "sourceEventId": "permission-1",
        }
        with store.connect() as db:
            self.assertTrue(store.record_attention(db, payload)["inserted"])
        with store.connect() as db:
            self.assertFalse(store.record_attention(db, payload)["inserted"])

    def test_session_snapshot_survives_disconnect(self):
        payload = {
            "host": {
                "id": "server-01", "name": "Conqrex Server", "endpoint": "ws://127.0.0.1:16767/ws",
                "serverId": "srv_fixture", "hostname": "server-01", "version": "0.2.5",
                "connectionState": "Connected", "lastSeenAt": store.iso_utc(), "compatible": True,
            },
            "sessions": [{
                "key": "server-01:agent-1", "id": "agent-1", "sourceId": "server-01",
                "sourceName": "Conqrex Server", "hostId": "srv_fixture", "hostName": "server-01",
                "providerId": "claude", "providerLabel": "Claude", "modelId": "opus",
                "title": "Feature", "repositoryId": "remote:github.com/conqrex/engine",
                "repositoryName": "Engine", "repositoryRemote": "github.com/conqrex/engine",
                "workspaceId": "wks-1", "workspaceName": "feature", "workingDirectory": "/srv/feature",
                "branch": "feature", "worktree": "/srv/feature", "state": "Working",
                "startedAt": store.iso_utc(), "lastActivityAt": store.iso_utc(),
                "attentionReason": "", "capabilities": {"canReadTokenUsage": True},
                "deepLink": "paseo:/h/srv_fixture/agent/agent-1", "stale": False,
            }],
        }
        with store.connect() as db:
            store.sync_snapshot(db, payload)
        with store.connect() as db:
            snapshot = store.stored_snapshot(db)

        self.assertEqual(len(snapshot["sessions"]), 1)
        self.assertTrue(snapshot["sessions"][0]["stale"])
        self.assertEqual(snapshot["sessions"][0]["state"], "Working")
        self.assertEqual(snapshot["hosts"][0]["connectionState"], "Disconnected")


if __name__ == "__main__":
    unittest.main()
