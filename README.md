# LumaClip

A fast, native clipboard manager for macOS — keep everything you copy, find it instantly, and paste it back anywhere. Now with **file management**: copy files in Finder and re-paste them whenever you need.

> 中文：一个原生 macOS 剪贴板管理器。复制过的文本、链接、图片、代码、文件全部保留并自动分类，随时搜索、快速粘贴。

---

## Features

- **Clipboard history** — text, links, emails, code, colors, and images are captured automatically and never lost.
- **Smart categories** — clips are auto-sorted (Code, Email, Links, Notes, Screenshots…). File clips are sorted by type into **PDF / Word / Excel / PowerPoint**.
- **File management** — copy a file in Finder and LumaClip keeps it. Small files are copied into a local vault so they survive the original being moved or deleted; large files are kept as a reference. Re-paste real files anytime.
- **Full-text search** — substring search across history (trigram FTS), including OCR text from screenshots.
- **Quick Paste** — a global hotkey command palette to search and paste into any app in seconds.
- **Bundles** — save a group of clips and paste them in sequence (great for forms and repetitive workflows).
- **Privacy-minded** — local-only SQLite storage, optional password skipping, sensitive-content detection, burn-after-paste, per-app blacklist, and retention rules.
- **Favorites, pinning, trash, undo**, and a floating quick-access button.

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15 or later (to build)

## Build & Run

1. Open `LumaClip.xcodeproj` in Xcode.
2. Select the **LumaClip** scheme and press **⌘R**.

> Note: LumaClip is **not sandboxed** (`com.apple.security.app-sandbox = false`) because it needs to monitor the system clipboard, register global hotkeys, and read/write files for the file-management feature. On first launch macOS may ask for permissions.

Default shortcuts: **⌘⇧V** toggle the panel · **⌘⇧P** Quick Paste (configurable in Settings).

## Tech

- SwiftUI + AppKit, SQLite (raw C API, zero dependencies), Vision (OCR), Carbon (global hotkeys).

## Built with Claude

LumaClip started as a personal tool and was built largely by pairing with Claude — describing what I wanted, reviewing the result, and iterating. Contributions and ideas are welcome.

## License

[MIT](LICENSE) © 2026 Aaron Yang
