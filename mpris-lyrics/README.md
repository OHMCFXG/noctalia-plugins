# MPRIS Lyrics

Synchronized lyrics plugin for Noctalia.

## What It Does

- Reads the active track and playback position from Noctalia's `MediaService`
- Fetches and parses synced lyrics
- Renders a compact line in the bar and a contextual lyrics card on the desktop

## Notes

- Plain lyrics are shown as a fallback when synced lyrics are unavailable

## Local Dev

Keep the folder name as `mpris-lyrics` so Noctalia will pick up `manifest.json` correctly when the plugin is copied or symlinked into `~/.config/noctalia/plugins/`.
