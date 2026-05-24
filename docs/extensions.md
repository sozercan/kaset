# Extensions

Kaset supports user-installed WebKit-compatible browser extensions. No extensions are pre-installed, so you're in full control.

## Managing Extensions

Open **Settings** (⌘,) and navigate to the **Extensions** tab.

### Adding an Extension

1. Click the **+** button in the Extensions tab header.
2. Choose the **root directory** of a WebKit-compatible extension — the folder that contains `manifest.json`.
3. Kaset reads the extension name from `manifest.json` and adds it to the list.
4. Restart Kaset to load it.

> **Compatibility:** Extensions must use the [WebKit Web Extensions API](https://developer.apple.com/documentation/webkit/wkwebextension). Standard Manifest V3 extensions (Chrome/Firefox) may work if they don't rely on browser-specific APIs. Extensions built specifically for Safari/WebKit are the best starting point.

### Enabling / Disabling an Extension

Toggle the switch next to any extension. The change takes effect after a restart.

### Removing an Extension

Click the **trash** icon next to any extension, then restart Kaset.

## How It Works

- **Storage:** The list is saved as JSON at `~/Library/Application Support/Kaset/extensions.json`.
- **Imported files:** Kaset copies each added extension into `~/Library/Application Support/Kaset/ManagedExtensions/` and loads that local snapshot.
- **Security:** Kaset may store a local security-scoped bookmark for the copied extension folder when WebKit needs sandbox-friendly access.
- **Loading:** At launch, `WebKitManager` loads all enabled extensions in order via `WKWebExtensionController`, granting them all requested permissions.

## Troubleshooting

- **Extension not loading:** Open Console.app, filter by subsystem `com.sertacozercan.Kaset` and category `Extensions` or `WebKit`.
- **Extension updates not appearing:** Re-import the extension after changing the original source folder, since Kaset loads the copied snapshot in Application Support.
- **Manifest not found:** Ensure your extension directory contains a `manifest.json` at its root.

## Architecture

See [ADR 0014](adr/0014-extensions.md) for the full architectural decision record.
