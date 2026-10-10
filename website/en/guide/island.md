---
title: OpenYoink Island
---

# OpenYoink Island <Badge type="tip" text="v1.4.1" />

OpenYoink Island turns the top-center area into a lightweight drag shelf and activity surface. On a notched Mac it joins the camera housing; external and non-notched displays use a floating top capsule.

Island is enabled by default for new installs. Existing users keep their saved surface choices after upgrading, and can enable or disable Island independently in Settings.

The classic edge shelf and Island are independent entrances to the same shelf. You may enable either one or both, and the Shelf module inside Island can be disabled without closing the classic shelf.

The optional Quick Access module keeps favorite folders in a compact grid. Double-clicking a folder uses the current macOS default file manager, so Finder, QSpace, and other replacements work without an app-specific setting. Removing a favorite never removes the actual folder.

Click the compact Island to expand it. Top-edge drag approach stays off by default so browser tab rearrangement is not obstructed; it can be enabled independently in Settings to switch to the Shelf module when files approach the top center. Press `Esc`, click outside, or click the center of the expanded Island to collapse it.

## Clipboard history

v1.6.9 adds optional clipboard history through the menu bar window or Island module library. Displaying the module does not enable recording. Turn recording on in **Settings → General → Clipboard History** to capture new text, HTTP(S) URLs, and PNG/TIFF images; old clipboard contents and copied files are not imported.

Search, filter by type, favorite, preview, copy, add to the shelf, delete, clear, pause, or resume your history. Open it with `⌘⇧V` (configurable). Choose 30, 100, or 300 ordinary entries (30 by default), with 1, 7, or 30 days of retention (7 by default). Up to 30 additional favorites do not expire; all contents share a 20 MiB budget. Disabling recording keeps existing history; clearing deletes history and favorites without changing the current clipboard or shelf.

::: warning Local storage and sensitive content
History is stored as plaintext in the app sandbox, never uploaded or synced. Common password-manager privacy markers and ignored apps are skipped, but unmarked passwords or tokens may still be recorded. Pause recording before copying sensitive data.
:::
