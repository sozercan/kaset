# Extensions

Kaset can load browser extensions that work with Safari/WebKit. No extensions are included by default, so you choose what to add.

## Managing Extensions

Open **Settings** (⌘,) and navigate to the **Extensions** tab.

### Adding an Extension

1. Click the **+** button in the Extensions tab header.
2. Choose the extension folder that contains `manifest.json`.
3. Kaset adds the extension to the list.
4. Restart Kaset to load it.

> **Compatibility:** Use a Safari/WebKit version of an extension when one is available. Chrome versions can sometimes work, but not always.

### Installing Common Extensions

Kaset adds extension **folders**. It cannot install directly from the Safari App Store, Chrome Web Store, or a downloaded extension package. You need to choose a folder that contains a file named `manifest.json`.

Only use extensions from sources you trust.

#### Best option: use a Safari/WebKit version

If the extension offers a Safari/WebKit download, use that first. Download it, unzip it if needed, then add the folder that contains `manifest.json` in **Settings → Extensions**.

Useful official release pages:

- uBlock Origin Lite: <https://github.com/uBlockOrigin/uBOL-home/releases>
- SponsorBlock: <https://github.com/ajayyy/SponsorBlock/releases>

> **Note:** Safari extensions from the Mac App Store are usually installed as apps. Kaset cannot add those apps directly. Kaset needs the extension folder itself.

#### Fallback: copy the extension from Chrome, Edge, or Brave

Use this if you cannot find a Safari/WebKit version.

1. Install the extension in Chrome, Edge, or Brave:
   - [uBlock Origin Lite](https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh)
   - [SponsorBlock for YouTube](https://chromewebstore.google.com/detail/sponsorblock-for-youtube/mnjggcdmjocbbbhaepdhchncahnbgone)
2. Find the browser profile folder:
   - Chrome: open `chrome://version` and copy **Profile Path**. It is usually `~/Library/Application Support/Google/Chrome/Default`.
   - Microsoft Edge: usually `~/Library/Application Support/Microsoft Edge/Default`.
   - Brave: usually `~/Library/Application Support/BraveSoftware/Brave-Browser/Default`.
3. In Finder, choose **Go → Go to Folder…** and open the extension folder:

   ```text
   <Profile Path>/Extensions/<extension-id>/
   ```

   Use these extension IDs:

   | Extension | ID |
   |---|---|
   | uBlock Origin Lite | `ddkjiahejlhfcafbddmgiahcphecmpfh` |
   | SponsorBlock | `mnjggcdmjocbbbhaepdhchncahnbgone` |

4. Open the newest version folder inside it. The folder name usually looks like `2026.1.1.0_0` or similar.
5. Make sure that folder contains `manifest.json`.
6. In Kaset, open **Settings → Extensions**, click **+**, and choose that version folder.
7. Restart Kaset when prompted.

> **Tip:** If Kaset shows a version number instead of the extension name, copy that version folder somewhere else, rename the copy to something readable like `uBlock Origin Lite`, then add the renamed copy to Kaset.

### What to expect

- Extensions only affect Kaset. They do not change Safari, Chrome, or other browsers.
- YouTube extensions usually affect the YouTube video player. They may not affect YouTube Music unless the extension supports `music.youtube.com`.
- If an extension does not work, try a Safari/WebKit version if one exists.
- Kaset copies the folder you choose. If the extension updates later, remove it from Kaset and add the newer version folder.

### Enabling / Disabling an Extension

Toggle the switch next to any extension. The change takes effect after a restart.

### Removing an Extension

Click the **trash** icon next to any extension, then restart Kaset.

## Behind the Scenes

- Kaset keeps its extension list in `~/Library/Application Support/Kaset/extensions.json`.
- When you add an extension, Kaset copies that folder into `~/Library/Application Support/Kaset/ManagedExtensions/`.
- Kaset loads enabled extensions when the app starts.
- Extensions run inside Kaset's YouTube and YouTube Music web players.

## Troubleshooting

- **Manifest not found:** Make sure you selected the folder that contains `manifest.json`.
- **Extension not loading:** Restart Kaset after adding or enabling it.
- **Extension updates not appearing:** Remove the extension from Kaset, then add the newer version folder.
- **Still stuck:** Open Console.app and filter by `com.sertacozercan.Kaset`, then look for `Extensions` or `WebKit` messages.

## Architecture

See [ADR 0014](adr/0014-extensions.md) for the full architectural decision record.
