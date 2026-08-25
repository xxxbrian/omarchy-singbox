#!/usr/bin/env bash
set -euo pipefail

# The manifest is the contract with the shell: the id, the entry point, and
# the widget metadata all have to agree with what Panel.qml declares.
python3 - <<'PY'
import json

manifest = json.load(open("manifest.json"))

assert manifest["schemaVersion"] == 1, manifest["schemaVersion"]
assert manifest["id"] == "singbox.omarchy", manifest["id"]
assert manifest["kinds"] == ["bar-widget"], manifest["kinds"]
assert manifest["entryPoints"]["barWidget"] == "Panel.qml"
assert manifest["barWidget"]["allowMultiple"] is False
assert manifest["barWidget"]["category"] == "Network"
assert manifest["name"] == "sing-box"
assert manifest["barWidget"]["displayName"] == "sing-box"

# Discoverability: the aliases must cover the spellings and the use.
aliases = set(manifest["barWidget"]["aliases"])
for expected in ("sing-box", "singbox", "proxy", "vpn", "clash", "tun"):
    assert expected in aliases, expected

schema = {entry["key"]: entry for entry in manifest["barWidget"]["schema"]}
assert "refreshIntervalSec" in schema
assert schema["refreshIntervalSec"]["type"] == "integer"
assert schema["refreshIntervalSec"]["defaultValue"] == manifest["barWidget"]["defaults"]["refreshIntervalSec"]
# Service.qml clamps to the same window; a schema that allowed more would let
# the settings UI offer a value the panel silently overrides.
assert schema["refreshIntervalSec"]["min"] == 5
assert schema["refreshIntervalSec"]["max"] == 3600

panel = open("Panel.qml").read()
assert 'moduleName: "%s"' % manifest["id"] in panel
assert 'ipcTarget: "%s"' % manifest["id"] in panel

print("test_manifest: ok")
PY

# install.sh must keep its backups outside the plugins directory: Omarchy
# scans every subdirectory of it for a manifest, so a backup left alongside
# the install is a second plugin with the same id.
grep -Fq 'backup_home="$config_home/omarchy/plugin-backups"' install.sh
if grep -E 'backup_path="\$plugin_home' install.sh >/dev/null; then
  echo 'install.sh backs up into the plugins directory' >&2
  exit 1
fi
bash -n install.sh

printf 'test_install: ok\n'
