#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

node tests/test-paseo.mjs
node tests/test-domain.mjs
bash tests/test-quota-normalizers.sh
python3 -m unittest discover -s tests -p 'test_*.py'
bash -n install.sh package/contents/code/usage.sh package/contents/code/activity-hook.sh
python3 -c 'from pathlib import Path; [compile(p.read_text(), str(p), "exec") for p in [Path("package/contents/code/crewbeacon_store.py"), Path("package/contents/code/crewbeacon_paseo_relay.py")]]'
jq empty package/metadata.json
xmllint --noout package/contents/config/main.xml
qmllint package/contents/ui/*.qml package/contents/config/config.qml

forbidden_name='Agent''Dock'
if rg -n -i "$forbidden_name" .; then
    echo "legacy forbidden product name found" >&2
    exit 1
fi

echo "CrewBeacon validation: PASS"
