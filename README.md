# Tabby

**A keyboard-driven, grouped window switcher for macOS — with first-class browser tabs.**

Tabby replaces and enhances the standard ⌘-Tab experience. Instead of cycling through apps, you get a fast, searchable switcher that groups windows by application *and* treats your browser tabs as first-class, switchable items.

> Follow development: [@tabbyformac](https://twitter.com/tabbyformac)

---

## Features

- **Application grouping** — windows are grouped under their parent app (Finder, VS Code, Slack, …).
- **First-class browser tabs** — for Chrome, Brave, Safari, Arc, Edge, and Vivaldi, Tabby lists individual tabs as switchable items within the browser's group.
- **Real most-recently-used ordering** — apps are ordered by genuine system activation, just like ⌘-Tab. Your current app sits at the top; selection defaults to the previous one.
- **Live previews** — real-time thumbnails of the selected window in the preview panel.
- **Fully keyboard-driven** — never touch the mouse.

## Keyboard controls

| Key | Action |
| --- | --- |
| Hotkey (e.g. ⌥-Tab) | Open / cycle the switcher |
| ↑ / ↓ / Tab | Navigate |
| → or `~` | Expand a group / explore tabs |
| ← | Collapse a group |
| Return | Focus the selected window or tab |
| ⌘-W / Delete | Close the selected window or tab |
| Esc | Dismiss |

The activation shortcut is configurable in Preferences (⌥-Tab, ⌃-Tab, ⌘-Tab, or ⌘-⌥-Tab).

## Requirements

- **macOS 13 (Ventura) or later**

## Installing

Download the latest `Tabby.dmg` from the [Releases](https://github.com/gnesioai/tabbyformac/releases) page, open it, and drag **Tabby** to your Applications folder.

## Permissions

Tabby requests these macOS permissions to function. All processing happens **locally on your Mac** — see the [Privacy Policy](PRIVACY.md).

- **Accessibility** — to list and switch between open windows.
- **Automation** — to read and switch browser tabs (asked per-browser, the first time you expand one).
- **Screen Recording** — to render live window previews.

You can grant or revoke any of these in **System Settings → Privacy & Security**.

## Privacy

Tabby collects **nothing**. No analytics, no telemetry, no network calls, no accounts. Nothing about you ever leaves your Mac. See [PRIVACY.md](PRIVACY.md).

## License

The source in this repository is **source-available, not open-source** — you may read it, but it may not be copied, modified, built, or redistributed. See [LICENSE.md](LICENSE.md). Use of the app is governed by the [EULA](EULA.md).

## Contact

- Email: **gnesio.ai@gmail.com**
- Twitter/X: **[@tabbyformac](https://twitter.com/tabbyformac)**
