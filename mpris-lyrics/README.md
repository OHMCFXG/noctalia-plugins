# MPRIS Lyrics

Synchronized lyrics plugin for Noctalia bar and desktop widgets.

## Overview

- Reads track metadata and playback state from Noctalia's `MediaService`
- Shows the current lyric line in the bar widget
- Shows the current line plus optional context lines in the desktop widget
- Supports `LRCLib` and `QQ Music`, with configurable source priority
- Supports player filtering with case-insensitive substring matching

## External Dependencies

- `curl`
  Required for `QQ Music` requests.
- `playerctl`
  Optional but recommended. Improves lyric sync after seeking, pausing, and resuming playback.

## Settings

- Primary lyrics source
- Lyric offset
  Positive values make lyrics appear earlier; negative values make them appear later.
- Request timeout
- Bar max width
- Adaptive or fixed bar width mode
- Hide bar widget when idle
- Show bar status dot
- Player filter mode: `off`, `blacklist`, `whitelist`
- Player filter rules using case-insensitive substring matching
- Widget width
- Context line count
- Current line font size
- Line spacing
- Context opacity
- Text alignment
- Track meta visibility
- Hide when idle
- Background visibility
- Rounded corners
