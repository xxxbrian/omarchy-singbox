# Project working agreements

## The surface

`DESIGN.md` is the design standard — the read-only premise, discovery,
sing-box's API differences, icons, colour, labels, and what may show a
credential. Read it before touching a component, and change it in the same
commit as the behaviour it describes.

The three that come up most:

- The panel never writes the user's sing-box config and never escalates
  privileges. Any feature that needs either is out of scope by design.
- Colours come from `qs.Commons.Color` and the shared `Style` helpers. No
  hard-coded hex, RGB, or named display colours. Derive shades with
  `Qt.darker`, `Qt.lighter`, or `Qt.rgba` over a theme colour.
- Suffix button and menu labels with `...` when activating them opens a
  dialog, editor, terminal workflow, or secondary page instead of completing
  the action immediately.

## The code

- Logic lives in the plain-JS modules (`Model.js`, `SingboxApi.js`,
  `SingboxConfig.js`) so it can be tested with node, without a compositor.
  QML files orchestrate and render; they do not parse.
- Every external process the panel runs is declared in `Service.qml`, and
  every poll skips itself while its own process is still running — the
  watchdog reaps stragglers.
- API behaviour is verified against a real core, not assumed: sing-box's
  Clash API diverges from mihomo's (mode-list, no reload, GLOBAL not
  selectable), and each divergence found is recorded in `SingboxApi.js`'s
  header comment with the version it was tested on.

## Verification

- Run `make validate` after QML or behaviour changes. It runs the node
  tests, the source-level rule tests, qmllint, and the manifest validation.
- `./install.sh --no-restart` symlinks the checkout into the plugin
  directory; QML edits are read through the symlink on the next shell
  restart.
