# Noctalia Plugins by hcx

Custom plugin registry for [Noctalia Shell](https://github.com/noctalia-dev/noctalia-shell).

This repository is an unofficial plugin source maintained by [hcx](https://github.com/OHMCFXG). It is meant to be added to Noctalia as a custom repository and currently publishes plugins that are maintained outside the main registry.

If you are looking for the official community registry, see [noctalia-dev/noctalia-plugins](https://github.com/noctalia-dev/noctalia-plugins).

## Available Plugins

| Plugin | Description | Tags | Docs |
| --- | --- | --- | --- |
| `mpris-lyrics` | Synced lyrics for Noctalia bar and desktop widgets. Supports LRCLib and QQ Music, configurable source priority, and player filtering. | `Bar`, `Desktop`, `Music` | [README](./mpris-lyrics/README.md) |

## Add This Repository to Noctalia

Noctalia supports custom plugin sources through the plugin settings UI.

1. Open `Settings -> Plugins -> Sources`.
2. Click `Add custom repository`.
3. Use any display name you like.
4. Set the repository URL to:

```text
https://github.com/OHMCFXG/noctalia-plugins
```

Noctalia clones the Git repository and reads `registry.json` from the repository root, so you should add the repository URL, not the raw `registry.json` URL.

## Repository Layout

Each plugin lives in its own top-level directory. The repository root also contains a generated `registry.json` file that Noctalia uses to discover available plugins.

```text
.
├── registry.json
├── README.md
└── plugin-name/
    ├── manifest.json
    ├── README.md
    ├── preview.png / preview.webp / preview.jpg
    ├── Main.qml
    ├── BarWidget.qml
    ├── DesktopWidget.qml
    ├── Panel.qml
    └── Settings.qml
```

Not every QML entry point is required. Use only the files your plugin actually provides.

## Manifest Expectations

For new or updated plugins, the manifest should include the fields that this repository's CI validates:

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "author": "Your Name",
  "repository": "https://github.com/OHMCFXG/noctalia-plugins",
  "description": "Short plugin description",
  "entryPoints": {
    "main": "Main.qml",
    "barWidget": "BarWidget.qml",
    "desktopWidget": "DesktopWidget.qml",
    "settings": "Settings.qml"
  },
  "tags": ["Bar", "Utility"]
}
```

Notes:

- `id` should be lowercase and use letters, numbers, and dashes only.
- `repository` should point to this GitHub repository.
- `official` should not be added manually.
- Plugin-specific settings and metadata can be stored in the manifest as needed.

## Contributing

Pull requests are welcome for new plugins, fixes, and documentation updates.

When adding a new plugin directory, include at least:

- `manifest.json`
- `README.md`
- `preview.*`

Before opening a PR:

- Test the plugin in Noctalia Shell.
- Keep plugin documentation inside the plugin directory.
- Do not include `registry.json` in your PR. It is generated automatically after changes to `manifest.json` are merged into `main`.

## Registry Automation

This repository includes GitHub Actions for:

- manifest validation on pull requests
- first-time plugin directory checks
- automatic `registry.json` generation after manifest changes on `main`

Implementation details for the registry update script are documented in [`.github/workflows/README.md`](./.github/workflows/README.md).

## Plugin Notes

Plugin-specific requirements are documented in each plugin directory. For example, [`mpris-lyrics`](./mpris-lyrics/README.md) documents its external dependencies and configurable settings.

## License

The repository root is licensed under [MIT](./LICENSE). Individual plugins may document additional licensing details in their own directories.
