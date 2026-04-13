# MPRIS Lyrics

Pure-QML synchronized lyrics plugin for Noctalia.

## What It Does

- Reads the active track and playback position from Noctalia's `MediaService`
- Fetches lyrics from `LRCLIB`
- Parses LRC inside QML/JS
- Renders a compact line in the bar and a contextual lyrics card on the desktop

## Notes

- This plugin does not use `mpris-lyrics-rs`
- Synced lyrics require `syncedLyrics` to be available from `LRCLIB`
- If only plain lyrics are available, the plugin shows them as unsynced fallback text

## Local Dev

Keep the folder name as `mpris-lyrics` so Noctalia will pick up `manifest.json` correctly when the plugin is copied or symlinked into `~/.config/noctalia/plugins/`.
