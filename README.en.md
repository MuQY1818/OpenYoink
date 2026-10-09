<div align="center">

<img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" alt="OpenYoink icon">

# OpenYoink

**Drag it. Park it. Drop it later.**

A temporary shelf for macOS. Drop files, text, images, or links at the screen edge
or in the notch, switch windows, then drag them to their destination.

<br>

[![Latest release](https://img.shields.io/github/v/release/MuQY1818/OpenYoink?display_name=tag&sort=semver&style=flat-square)](https://github.com/MuQY1818/OpenYoink/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/MuQY1818/OpenYoink/total?style=flat-square)](https://github.com/MuQY1818/OpenYoink/releases)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![GitHub Stars](https://img.shields.io/github/stars/MuQY1818/OpenYoink?style=flat-square)](https://github.com/MuQY1818/OpenYoink/stargazers)
[![MIT license](https://img.shields.io/github/license/MuQY1818/OpenYoink?style=flat-square)](LICENSE)

[Download](https://github.com/MuQY1818/OpenYoink/releases/latest) ·
[Website](https://muqy1818.github.io/OpenYoink/) ·
[Guide](https://muqy1818.github.io/OpenYoink/en/guide/) ·
[中文](README.md)

</div>

<br>

<a href="https://muqy1818.github.io/OpenYoink/">
  <img src="docs/images/banner.jpg" width="100%" alt="OpenYoink — Drag it. Park it. Drop it later.">
</a>

To send a file from Downloads to a chat, drop it in OpenYoink first. Let go of the mouse, switch to the chat window, then drag it out.

OpenYoink lives in the menu bar without a Dock icon. Use the side shelf, the notch interface, or both. They share the same contents.

## Features

- Store files, folders, text, images, and links. Mail messages, calendar events, and contacts are supported when the source app provides them.
- Preview with Space, select multiple items, group them into stacks, reorder them, or return to recent items.
- Open the shelf with an edge tab, a shortcut, a mouse-shake gesture, or a drag. Automatic triggers can be disabled per app.
- Optional clipboard history with search, preview, copy, and add-to-shelf actions. Recording is off by default.
- Multiple displays, Spaces, and full-screen apps; English and Chinese UI; launch at login and automatic updates.

The notch interface also shows transfers, battery power, system status, and music, and can open favorite folders. Modules can be turned off individually. See [Island modules](#island-modules).

## Install

Requires macOS 15 Sequoia or later. Supports Apple Silicon and Intel Macs.

### Homebrew (recommended)

```bash
brew install --cask muqy1818/tap/openyoink
```

Homebrew downloads the package from GitHub Releases and removes OpenYoink's quarantine attribute after installation. This bypasses quarantine checks for this app; it does not mean the build is notarized by Apple.

### Manual installation

1. Download the latest DMG from [GitHub Releases](https://github.com/MuQY1818/OpenYoink/releases/latest).
2. Open the DMG and drag OpenYoink into `Applications`.
3. If macOS blocks the first launch, right-click OpenYoink in Finder and choose **Open**, or allow it under **System Settings → Privacy & Security**.

> [!NOTE]
> Community builds on GitHub Releases are ad-hoc signed and not notarized by Apple. macOS may block a manual installation. Automatic updates use Sparkle EdDSA verification, which does not replace verification of the first download or Apple notarization.

<details>
<summary>Still unable to open the app?</summary>

First confirm that the package came from GitHub Releases above. Run `shasum -a 256 OpenYoink-VERSION.dmg` (replace `VERSION` with the release number), then compare it with the checksum in the matching release notes or [Homebrew cask](https://github.com/MuQY1818/homebrew-tap/blob/main/Casks/openyoink.rb).

After checking the source and checksum, you can remove OpenYoink's quarantine attribute with the command below. This bypasses Gatekeeper's quarantine check for this app:

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

</details>

## Quick start

| Action               | How                                                        |
| -------------------- | ---------------------------------------------------------- |
| Show / hide          | `⌘⇧Space`, the menu bar item, or click the screen edge tab |
| Add content          | Drop onto the shelf or the edge tab                        |
| Managed move         | Hold `⌘` while importing; the original goes to the Trash after a copy is confirmed. [Details](#file-safety-and-lifecycle) |
| Park clipboard       | Press `⌘⇧Space` twice                                      |
| Quick Look           | Select a card and press `Space`, or double-click           |
| Multi-select         | Hold `⌘` and click, or marquee-select an empty area       |
| Remove               | Hover and click `×`, press `Delete`, or use the context menu |
| Reposition           | Drag the edge tab, or pick a position in Settings          |
| Enable / disable Island | Settings → General → OpenYoink Island                    |

Drag-to-expand at the top of the screen is off by default and can be enabled in Settings. Side-shelf drag triggers are configured separately. See the [guide](https://muqy1818.github.io/OpenYoink/en/guide/) for more.

## Island modules

OpenYoink Island is enabled for new installs. On a Mac with a notch, content sits on either side of it. Other displays use a floating pill at the top.

| Module | What it does |
| --- | --- |
| Shelf | Shares content with the side shelf, including drag-and-drop, preview, and organization |
| Transfers | Shows asynchronous file delivery progress and failures |
| Timer | Preset or custom countdowns, with pause and resume |
| Battery | Battery level, charging/discharging power, and a two-minute power graph |
| System Status | CPU, memory, network, disk, and app usage |
| Now Playing | Track information, artwork, progress, and playback controls |
| Quick Access | Favorite folders; double-click to open in the system's default file manager, including Finder or QSpace |
| Clipboard History | Search, preview, and reuse recently copied content |

Now Playing, Quick Access, and Clipboard History modules are off by default. Enabling the clipboard module does not turn on recording.

## File safety and lifecycle

Regular imports reference the original file without moving it. Removing a card or choosing "remove after drop" does not delete the original. Drops onto Finder request a copy; the destination decides whether to accept it.

> [!WARNING]
> Holding `⌘` while importing uses managed move: OpenYoink copies the content into its sandbox, confirms the copy, then moves the original to the Trash. If a step fails, it keeps the original and falls back to a regular reference. The original is recoverable only until the Trash is emptied.

For managed moves, the shelf card and sandbox copy are deleted only after the destination confirms delivery, regardless of the regular "after drop" policy. Failed or cancelled drops keep both for retry.

<details>
<summary>How each content type is stored and cleaned up</summary>

| Content                          | How OpenYoink handles it                                  |
| -------------------------------- | --------------------------------------------------------- |
| Files and folders                | Keeps a sandbox bookmark to the original location         |
| Plain text and links             | Stored directly in the shelf data                         |
| Images, HTML, RTF                | Saved as files in the app sandbox                         |
| Contacts, events, mail messages  | Saved as `.vcf`, `.ics`, `.eml` when the source provides them |

If the original file is moved, deleted, or on an offline disk, its card is unavailable until the reference resolves again.

Text and links are stored with their cards and cleared when the cards are removed. Files created for images, rich text, and mail are normally cleaned up on the next launch after their cards are removed. You can also review and clear unused files in **Settings → Storage**.

Regular file drops provide a file URL and a Chromium-compatible filename. Managed moves use a file promise and wait for confirmation of the destination write. Compatibility depends on the receiving app or website.

</details>

## Privacy and permissions

- No account, analytics, or telemetry. Content stays in the local sandbox under `Application Support/OpenYoink`.
- App Sandbox is enabled. File access comes from content you drag in or choose. Normal use does not require Accessibility or Input Monitoring permissions.
- Automatic update checks are on by default and can be disabled. The app's background network requests go to GitHub Pages / Releases to check for and download updates.
- Now Playing does not use the network. It prefers a local helper; its Apple Music / Spotify AppleScript fallback may request Automation permission. A module failure does not affect the shelf.
- Quick Access stores references only to folders you add. Removing a favorite does not delete the folder, and macOS chooses the default app for opening it.

### Clipboard history

Recording is off by default. While it is disabled, OpenYoink reads the clipboard only when you double-press the shortcut to save it. Enabling or resuming recording captures only newly copied text, HTTP(S) URLs, and PNG/TIFF images, not existing clipboard content or copied files.

History is stored as plaintext on this Mac, without uploads or sync. Limits are 30 entries and 20 MiB total. Choose 1, 7, or 30 days of retention, with 7 days as the default. Turning recording off keeps existing history; clearing it deletes the saved entries.

Common password-manager privacy markers and ignored apps are skipped, but not all sensitive content can be detected. Pause recording before copying passwords or tokens.

## Build from source

You need macOS 15+ and Xcode 26+.

```bash
git clone https://github.com/MuQY1818/OpenYoink.git
cd OpenYoink

xcodebuild \
  -project Open-Yoink.xcodeproj \
  -scheme OpenYoink \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Open-Yoink.xcodeproj \
  -scheme OpenYoink \
  -destination 'platform=macOS' \
  test \
  -only-testing:OpenYoinkTests
```

Built with Swift 6, SwiftUI, and AppKit. Local builds do not require a `DEVELOPMENT_TEAM`. The test command above runs app unit tests, not UI automation.

[`Scripts/make-release.sh`](Scripts/make-release.sh) supports Developer ID signing and notarization, or an explicit `--adhoc` community build. Signing failures do not trigger an automatic fallback.

## Contributing

For bugs or feature suggestions, open an [issue](https://github.com/MuQY1818/OpenYoink/issues). Include your macOS version, OpenYoink version, and steps to reproduce. Please keep private files and clipboard content out of screenshots.

Pull requests are welcome too. Discuss larger changes in an issue first, and run the full unit test suite before submitting code.

## Star history

<a href="https://www.star-history.com/?repos=MuQY1818%2FOpenYoink&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date&amp;theme=dark">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date">
    <img src="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date" width="800" alt="OpenYoink GitHub stars over time">
  </picture>
</a>

## Credits and license

OpenYoink is released under the [MIT License](LICENSE). It is an independent open-source project, not affiliated with the commercial Yoink app or its developers.

Updates use [Sparkle](https://sparkle-project.org/); the star chart is provided by [Star History](https://www.star-history.com/). Third-party components and licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

<br>

<div align="center">

© 2026 weijue · MIT License

</div>
