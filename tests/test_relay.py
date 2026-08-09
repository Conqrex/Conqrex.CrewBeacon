from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "package" / "contents" / "code" / "crewbeacon_paseo_relay.py"
)
SPEC = importlib.util.spec_from_file_location("crewbeacon_paseo_relay", MODULE_PATH)
relay = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(relay)


def offer_url() -> str:
    payload = {
        "v": 2,
        "serverId": "srv_fixture",
        "daemonPublicKeyB64": "public-key-fixture",
        "relay": {"endpoint": "relay.paseo.sh:443", "useTls": True},
    }
    encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"https://app.paseo.sh/#offer={encoded}"


class RelayTests(unittest.TestCase):
    def test_private_offer_file_is_decoded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "paseo.offer"
            path.write_text(offer_url(), encoding="utf-8")
            path.chmod(0o600)
            value, payload = relay.read_offer(str(path))
            self.assertEqual(value, offer_url())
            self.assertEqual(payload["serverId"], "srv_fixture")

    def test_world_readable_offer_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "paseo.offer"
            path.write_text(offer_url(), encoding="utf-8")
            path.chmod(0o644)
            with self.assertRaisesRegex(relay.RelayError, "0600"):
                relay.read_offer(str(path))

    def test_cli_agent_normalization_is_honest_about_capabilities(self):
        result = relay.normalize_agent(
            {
                "id": "agent-1",
                "name": "Implement the API",
                "provider": "codex/gpt-5.6-sol",
                "status": "running",
                "cwd": "/srv/project",
            },
            "remote",
            "Build server",
            "srv_fixture",
        )
        self.assertEqual(result["state"], "Working")
        self.assertEqual(result["repositoryName"], "project")
        self.assertFalse(result["capabilities"]["canReadTokenUsage"])
        self.assertFalse(result["capabilities"]["canStreamSessionState"])


if __name__ == "__main__":
    unittest.main()
