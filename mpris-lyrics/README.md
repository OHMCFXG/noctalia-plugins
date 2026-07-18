# MPRIS Lyrics

Synced lyrics on the Noctalia bar for the active media player. Lyrics are fetched
from NetEase Music, QQ Music, or LRCLib (configurable priority).

## Plugin

| Field | Value |
| --- | --- |
| ID | `0x1ce/mpris-lyrics` |
| Entries | Bar widget: `bar`; service: `lyrics` |

## Requirements

Install on `PATH`:

- `busctl` (from systemd) — talks to Noctalia's `dev.noctalia.Mpris` control plane
- `openssl` — required for NetEase Music weapi encryption

Network access is used for LRCLib, NetEase, and QQ Music.

## Usage

1. Add the parent repository as a plugin source (git or path):

```sh
# git
noctalia msg plugins source add personal git https://github.com/OHMCFXG/noctalia-plugins.git

# or local checkout
noctalia msg plugins source add personal path /path/to/noctalia-plugins

noctalia msg plugins enable 0x1ce/mpris-lyrics
```

2. Place the bar widget `0x1ce/mpris-lyrics:bar` on a bar.
3. Play a track in an allowed player. The service fetches lyrics and the bar
   shows the current line.

### Interactions

| Input | Action |
| --- | --- |
| Hover | Tooltip with title, artist, state, and source |
| Right-click | Force refresh lyrics |
| Middle-click | Open widget settings (host built-in) |

### Hide / filter

By default browser players (`firefox`, `chrome`, `zen`) are blacklisted so a
YouTube tab does not steal the active player. Adjust under plugin settings.

## Settings

Noctalia exposes plugin settings in **two places**:

| Where | What |
| --- | --- |
| **Settings → Plugins → gear** | Plugin-level `[[setting]]` (filter + lyrics fetch) |
| **Middle-click the bar widget** | Widget-level `[[widget.setting]]` (bar display) + host built-ins |

### Plugin-level (Plugins gear)

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `playerFilterMode` | select | `blacklist` | `off` / `blacklist` / `whitelist` |
| `playerFilterList` | string_list | firefox, chrome, zen | Substring match on identity / desktop entry |
| `primaryLyricsSource` | select | `netease` | Tried first; fallback order is netease → qqmusic → lrclib |
| `requestTimeoutMs` | int | `5000` | Network timeout (ms) |
| `lyricAdvanceMs` | int | `0` | Positive shows lyrics earlier; usually leave at 0 |

### Widget-level (middle-click `bar`)

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `barMaxWidth` | int | `180` | Max / fixed width (px); min 60 |
| `barWidthMode` | select | `adaptive` | `adaptive` or `fixed`; overflow is truncated |
| `barHideWhenIdle` | bool | `true` | Hide when no active track |
| `showBarStatusDot` | bool | `true` | Colored state indicator |

> Manifest (`plugin.toml`) changes need **disable + enable** (or a shell restart).
> Only `.luau` edits hot-reload.

## IPC

```sh
noctalia msg plugin 0x1ce/mpris-lyrics:lyrics all refresh
```

## Notes

- Track metadata and playback position come from Noctalia's internal D-Bus API
  (`dev.noctalia.Mpris`), not from reimplementing MPRIS discovery. Position is
  host-projected.
- Network requests use `noctalia.http`, which is **libcurl** inside Noctalia
  (not Qt Network / Quickshell XHR). On this machine both **NetEase** (weapi
  encrypt via openssl + `noctalia.http` POST) and **QQ Music** (search + lyric
  via `noctalia.http`) work without spawning an external `curl` process.
  LRCLib uses `noctalia.http` only.
- `requestTimeoutMs` currently budgets the NetEase openssl subprocess; the host
  HTTP client uses its own fixed timeout (~30s).
- This port does **not** include the v4 desktop widget or "prefer player lyrics".
- Entry scripts are self-contained (plugin VMs have no `require`).

## Translations

| File | Language |
| --- | --- |
| `translations/en.json` | English (default / fallback) |
| `translations/zh-Hans.json` | Simplified Chinese |

Noctalia loads `en.json` first, then overlays the shell language file when it is
not English. With the shell set to Simplified Chinese (`zh-Hans`, often selected
as `zh-CN`), status text, tooltips, notifications, and setting labels use the
Chinese strings above.

UI strings go through `noctalia.tr(...)`. Nested JSON keys are flattened with
dots (e.g. `settings.advance.label`).
