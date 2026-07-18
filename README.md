# noctalia-plugins

Personal [Noctalia](https://github.com/noctalia-dev/noctalia) v5 plugin source.

Layout matches the multi-plugin git/path source model used by
[community-plugins](https://github.com/noctalia-dev/community-plugins): one
directory per plugin, root `catalog.toml` for discovery.

## Add this source

**Local development (path):**

```sh
noctalia msg plugins source add personal path /home/hcx/Codes/noctalia-plugins
noctalia msg plugins enable 0x1ce/mpris-lyrics
```

**Git (after you push a remote):**

```sh
noctalia msg plugins source add personal git https://github.com/YOURUSER/noctalia-plugins.git
```

## Layout

```text
noctalia-plugins/
├── catalog.toml          # index for the source
├── README.md
├── .gitignore
├── .luaurc
└── mpris-lyrics/         # id 0x1ce/mpris-lyrics
    ├── plugin.toml
    ├── service.luau
    ├── widget.luau
    ├── README.md
    ├── thumbnail.webp
    └── translations/
```

Directory name = the segment of the plugin id after `/`.

## Plugins

| Directory | ID | Description |
| --- | --- | --- |
| `mpris-lyrics` | `0x1ce/mpris-lyrics` | Synced lyrics on the bar |

## Development notes

- `.luau` edits hot-reload while the plugin is enabled.
- `plugin.toml` / manifest changes need disable+enable or a shell reload.
- Fetch editor types (gitignored):  
  `curl -O https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau`
- Docs: https://docs.noctalia.dev/v5/plugins/development/workflow/

### Local checks (optional)

```sh
# regenerate catalog.toml from each plugin.toml
python3 .github/scripts/update_catalog.py

# basic manifest / entry / translation key checks
python3 .github/scripts/validate_plugins.py

# official offline lint (getConfig vs declared settings)
noctalia plugins lint .
```

### GitHub Actions (lean, personal)

Inspired by community-plugins, but **not** a full copy:

| Workflow | Purpose |
| --- | --- |
| `validate.yml` | On push/PR: run `validate_plugins.py` |
| `update-catalog.yml` | On push to `main`: rebuild and commit `catalog.toml` if needed |

**Intentionally omitted** (community-only noise for a solo repo):

- Issue / PR templates and store policy checks
- Thumbnail dimension/size hard fails as CI errors
- Reserved website slug list, monorepo-only repo guards
- Full `unittest` suite for the validator

## License

Each plugin declares its own license in `plugin.toml` (MIT unless stated otherwise).
