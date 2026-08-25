# sing-box for Omarchy

An Omarchy bar panel for [sing-box](https://sing-box.sagernet.org): connection
status, live up/down speed, Clash mode switching, and proxy selection — driven
by your own sing-box config over the core's Clash API.

The panel is a control surface, not a manager. **It never writes your config,
never installs the binary, and never escalates privileges.** You run sing-box
the way you already do; the panel finds it, watches it, and drives the parts
its API makes drivable.

## Requirements

- Omarchy
- [sing-box](https://sing-box.sagernet.org) (`sudo pacman -S sing-box`)
- A config with the Clash API enabled:

```json
{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "your-secret"
    }
  }
}
```

## Install

```sh
omarchy plugin add https://github.com/xxxbrian/omarchy-singbox.git --enable
omarchy bar move singbox.omarchy --section right
```

Remove with:

```sh
omarchy plugin remove singbox.omarchy
```

## How the panel finds your core

Every refresh runs the same discovery, and the first hit wins:

1. `~/.config/omarchy-singbox/config` — your explicit override
2. The running `sing-box` process — its `-c`/`-C` arguments name the config it
   is actually using, and its cgroup names the systemd unit that owns it
3. That config's `experimental.clash_api` — controller address and secret
4. `127.0.0.1:9090` with no secret, as a last shot at a core whose config the
   panel could not read

So it works whether sing-box runs under a user unit, was started by hand, or
sits behind a config the panel cannot parse — you only need the override file
for setups discovery cannot see:

```
# ~/.config/omarchy-singbox/config
endpoint = 127.0.0.1:9090
secret = your-secret
unit = my-singbox.service
config = /path/to/config.json
```

## What the panel can do

| | How |
|---|---|
| Status, version, live traffic, connection count | Clash API (`/version`, `/traffic`, `/connections`) |
| Pick a proxy per group, test latency | The groups are the panel's front page, Surge-style: `PUT /proxies/{group}`, `/delay`. The Clash mode is shown read-only for dashboard interop |
| Start / stop / restart | `systemctl` in the scope that owns the unit — a system unit raises a polkit prompt (your desktop's agent asks for authorization); a hand-started core is watch-only |
| Validate a changed config | `sing-box check`, with the journal fetched when a start fails anyway |
| Edit the config | Opens your editor on the file; the panel itself never writes it |

## Keyboard

With the panel open (`Esc` closes or goes back, `Tab` moves to the next panel):

| Key | Action |
|-----|--------|
| `r` | Refresh |
| `t` | Toggle the service |
| `1`–`9` | Expand the Nth group |
| `c` | Configuration page |
| arrows / `hjkl` | Move the cursor; Enter activates |

In a group, left-click a node to select it, right-click to test its latency.

## From a script

```sh
omarchy-shell singbox.omarchy status                # one JSON line
omarchy-shell singbox.omarchy select Proxy "JP DMIT" # pick a node in a group
omarchy-shell singbox.omarchy restart
```

## Troubleshooting

If sing-box will not start, the journal is where the real error lands
(`sing-box check` passes configs with dangling outbound references; they fail
at start):

```sh
journalctl --user -u sing-box.service -n 30 --no-pager
```

The panel offers **Diagnose...** on such failures, which writes the full
output to a `0600` file and points your default Omarchy agent at it.

## Development

```sh
./install.sh --no-restart
make test
make validate
```

## Credits

The architecture, component patterns, and several components follow
[omarchy-mihoro](https://github.com/huacnlee/omarchy-mihoro) (MIT), whose
design this plugin deliberately mirrors.

## License

MIT. sing-box is distributed separately under its own license.
