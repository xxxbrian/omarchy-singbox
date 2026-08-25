# Design

What the panel is and why. `AGENTS.md` holds the working agreements about the
code; this holds the ones about the surface. Where a rule has a reason, the
reason is the rule — it is what tells you whether a new case is covered.

## The premise

The config is the user's. The panel reads it, checks it, opens an editor on
it, and restarts the service — it never writes it, never generates it, and
never installs anything. Every capability the panel offers is either a read,
a Clash API call that changes the running core in place, or a `systemctl
--user` verb on a unit the user already owns. A panel that quietly rewrote a
proxy config would be one bad merge away from taking someone's network down.

This is also the conflict story: a user who already runs sing-box their own
way loses nothing by installing the panel, because the panel owns nothing.
Its only file is the optional override at `~/.config/omarchy-singbox/config`.

## Discovery over configuration

The panel finds the core rather than being told about it: the running
process's own command line names the config, its cgroup names the unit, and
the config names the API. Configuration (the override file) exists only for
what discovery cannot see. A panel that required setup to show a core that is
already running would be failing at its one job.

- The process wins over every fallback: the files on its command line are, by
  definition, the files in use.
- The user manager (`user@UID.service`) is never mistaken for the core's own
  unit — a shell-started core has no unit, and claiming the session as one
  would offer a restart button for the whole desktop.
- The panel itself holds no privileges — no pkexec, no sudo, ever. A
  system-scope unit is controlled through plain `systemctl`, whose own polkit
  path puts the question to the user through the desktop's agent: consent is
  given per action, on screen, never assumed. Only a core running outside
  systemd is watch-only — there is no unit a restart would act on.

## sing-box is not mihomo

The panel descends from omarchy-mihoro but three API differences shape it:

- **Modes are the config's, not the core's.** sing-box has no built-in
  Rule/Global/Direct; `mode-list` reports whatever `clash_mode` values the
  route rules use. The chips render that list, and with one entry the section
  hides — there is nothing to switch, and a control that lit up would be
  describing a mode not in effect anywhere.
- **No hot reload, no runtime TUN toggle.** A config change takes a restart.
  The config page owns that flow: `sing-box check` as the gate, restart as
  the apply, and the journal fetched when the start fails anyway — `check`
  passes dangling outbound references that only fail at run.
- **GLOBAL is not selectable.** `PUT /proxies/GLOBAL` is a 404, so there is
  no global-proxy dropdown; the proxies page selects within `Selector`
  groups, which is the only selection sing-box honours.

## Icons and colour

- Every colour comes from the active Omarchy theme through `qs.Commons.Color`
  or a `Style.*For` helper. No hex, no named display colours.
  `tests/test_panel_source.sh` enforces this.
- The semantics are fixed: `Color.accent` is download, connected, and the
  current selection; `Color.urgent` is upload, failure, and destruction.
- **Colour alone never carries state.** The selected proxy is a filled dot
  *and* a selected fill.
- The bar icon is a Canvas-drawn cube — bar slots are ~16px, where SVG
  rasterisation smears strokes and text glyphs size to their em box, not
  their ink.

## Labels

- Suffix a button or menu label with `...` when activating it opens a dialog,
  an editor, a page, a browser, or a terminal workflow instead of completing
  the action there and then. "Open in editor..." opens; "Check config"
  checks.
- Prefer the shorter label when both are honest, and never buy brevity with
  accuracy.

## The panel's shape

Three pages in one popup: status, proxies, configuration. Navigation is
explicit — a menu item or a back arrow — and every fresh open returns to page
one with the cursor cleared.

- Page one is the whole state at a glance in **one** notice line; a failure
  may take three, clamped by `maximumLineCount` against the real width.
- **A message from outside is shortened before it is shown, never by the
  clamp.** Journal lines and check errors quote URLs and payloads;
  `Model.noticeMessage` redacts URLs to their host and collapses quoted runs
  first — eliding first could stop halfway through a token.
- **What will not fit goes to an agent, on a button.** `Diagnose...` writes
  the whole failure to a `0600` file and points the user's default agent at
  it. Offered only for a failed check or start/restart, only once
  `omarchy-default-agent` names an agent, and never opened on its own.
- A refused or failed action reports on the page it happened on.

## Optimism and truth

- A control moves the instant it is clicked; the refresh that confirms it
  stops overriding once it lands. Waiting for systemd makes the panel feel
  broken.
- Optimism has a deadline: every optimistic overlay is dropped after a
  timeout whether or not the truth arrived.
- The running core wins over everything: the API's answers set the mode, the
  proxies, and the version the panel shows.

## Credentials

- The API secret rides an `Authorization` header, never a URL — URLs land in
  logs and process lists.
- The failure log is written `0600` through a temporary file renamed into
  place. The agent prompt carries paths, never the output: `--prompt` becomes
  argv, and the process list is world-readable.
- Proxy configs carry credentials in server entries; the diagnosis prompt
  says so and tells the agent not to print them.

## Verification

Run `make validate` after any QML or behaviour change.
`tests/test_panel_source.sh` pins the decisions above at the source level,
because Quickshell's `Process`, `Panel`, and the `qs.Ui` kit only exist
inside a running shell. When a decision here changes, change the test in the
same commit — a rule with nothing holding it is a rule that has already
drifted.
