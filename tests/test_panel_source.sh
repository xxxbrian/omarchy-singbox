#!/usr/bin/env bash
set -euo pipefail

# `set -e` is specified to ignore a command whose status is inverted with `!`,
# so a bare `! grep` would be a comment with a grep in it. This helper fails
# loudly when a forbidden pattern appears.
refute() {
  if grep "$@" >/dev/null 2>&1; then
    printf 'unexpected match: grep %s\n' "$*" >&2
    exit 1
  fi
}

# Quickshell's Process, Panel, and the qs.Ui kit only exist inside a running
# Omarchy shell, so the QML behaviour that matters is pinned here at the source
# level. Each check stands for a decision that is easy to undo by accident.

# ---- the panel never writes the user's config -----------------------------

# The whole premise: the config is the user's. The panel reads it, checks it,
# opens an editor on it, and restarts the service — nothing else. No process
# in the service writes to a config path.
refute -Eq 'tee|> *"\$1"|cat *>' SingboxConfig.js
grep -Fq 'parsed, never written' SingboxConfig.js
# jq is invoked read-only, without any in-place tricks.
grep -Fq "jq -s 'reduce" Model.js

# ---- discovery ------------------------------------------------------------

# The running process is the source of truth for the config path; fallbacks
# only speak for a stopped core.
grep -Fq 'if (specs.length === 0 && state.configFallback !== "")' Model.js
# The user manager is never mistaken for the core's own unit.
grep -Fq "grep -v '^user@'" Model.js
# The override wins so a user can always rescue a misread setup.
grep -Fq 'if (ov.endpoint !== "")' SingboxConfig.js

# ---- groups are the controls ----------------------------------------------

# sing-box style: every routing decision the config leaves open is a group
# selection, so the groups sit on page one and there is no mode switcher. The
# clash mode is read, never written — it exists for Clash dashboards, and a
# switch made there must not let the stats lie.
grep -Fq 'GroupsSection {' Panel.qml
refute -Fq 'setModeCommand' SingboxApi.js Service.qml
refute -Eq 'MODES *= *\[' Model.js
grep -Fq 'mode-list' SingboxApi.js
grep -Fq 'label: "Mode"' components/ConnectionSection.qml
grep -Fq 'visible: root.service.modeList.length > 1' components/ConnectionSection.qml

# ---- proxy selection ------------------------------------------------------

# Only Selector groups take a click; sing-box refuses the rest, and GLOBAL is
# excluded outright — PUT to it is a 404.
grep -Fq '"Selector"' SingboxApi.js
grep -Fq 'if (key === "GLOBAL"' SingboxApi.js
grep -Fq 'if (memberRow.selectable)' components/GroupsSection.qml
# Colour alone never carries state: the selected member is a filled dot and a
# selected fill.
grep -Fq '"●"' components/GroupsSection.qml

# ---- connection status ----------------------------------------------------

# Live speeds come from the streaming endpoint, not a poll loop, and the
# stream is torn down with the panel.
grep -Fq 'SingboxApi.trafficCommand' Service.qml
grep -Fq 'var wanted = panelOpen && apiBase !== "" && coreRunning && apiState === "ok"' Service.qml
# The connections poll is panel-scoped too — nothing polls a closed panel.
grep -Fq 'running: root.panelOpen' Service.qml
grep -Fq 'onTriggered: root.nowEpoch = Date.now() / 1000' Service.qml
grep -Fq 'Model.uptimeSeconds(root.service.probe, root.service.nowEpoch)' components/ConnectionSection.qml

# One source of truth for what the panel is looking at. It is `connection`,
# not `state`: QQuickItem owns that name, so `singbox.state` silently resolves
# to the item's own state string.
grep -Fq 'Model.connectionState(probe, apiState)' Service.qml
grep -Fq 'singbox.connection.label' Panel.qml
refute -Fq 'singbox.state' Panel.qml

# Download is accent, upload is urgent, in both the curves and the readouts.
grep -Fq 'metricColor: Color.accent' components/ConnectionSection.qml
grep -Fq 'metricColor: Color.urgent' components/ConnectionSection.qml

# ---- service control ------------------------------------------------------

# The scope that owns the unit is the scope that controls it. At system scope
# plain systemctl asks polkit and the desktop's agent asks the user — the
# panel itself never escalates: no pkexec, no sudo, anywhere.
grep -Fq 'function scopeArgs' Model.js
grep -Fq 'function serviceScope' Model.js
refute -Eq 'pkexec|sudo "|"sudo"' Model.js Service.qml Panel.qml
# A core running outside systemd has no unit to restart; it stays watch-only.
grep -Fq 'return state.unitLoaded ? "user" : ""' Model.js
# Optimism has a deadline: every optimistic overlay is dropped on a timer.
grep -Fq 'optimismTimer' Service.qml

# ---- check and restart ----------------------------------------------------

# `check` passes configs that still fail at start, so a failed start fetches
# the journal for the notice and the diagnosis.
grep -Fq 'journalProcess.command = Model.journalCommand' Service.qml
# The editor leaves the panel's process group or Quickshell reaps it.
grep -Fq 'setsid' Model.js

# ---- credentials ----------------------------------------------------------

# The API secret rides an Authorization header, never a URL.
grep -Fq 'Authorization: Bearer' SingboxApi.js
refute -Fq 'secret=' SingboxApi.js
# The failure log is written 0600 through a rename, and the agent prompt
# carries paths, not the output — argv is world-readable.
grep -Fq 'chmod 600' Model.js
grep -Fq 'mktemp' Model.js
# Notices redact URLs before eliding: truncation could leave the front of a
# token on screen.
grep -Fq 'collapseQuoted(redactUrls(' Model.js

# ---- colour discipline ----------------------------------------------------

# Every colour comes from the theme. No hex literals in any QML.
refute -Eq '"#[0-9a-fA-F]{3,8}"' Panel.qml Service.qml components/*.qml

# ---- labels ---------------------------------------------------------------

# Actions that open something else end in `...`; actions that finish here do
# not.
grep -Fq '"Open in editor..."' components/ConfigSection.qml
grep -Fq '"Diagnose..."' Panel.qml
grep -Fq '"Check config"' components/ConfigSection.qml
grep -Fq '"Restart to apply"' components/ConfigSection.qml

# ---- the popup ------------------------------------------------------------

# Every fresh open returns to page one.
grep -Fq 'onOpenedChanged: if (opened) {' Panel.qml
grep -Fq 'panelPage = 1' Panel.qml
# The notice is clamped by line count against the real width, not characters.
grep -Fq 'maximumLineCount: 3' Panel.qml

printf 'test_panel_source: ok\n'
