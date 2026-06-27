// LumaClipIntents.swift
// LumaClip — macOS Clipboard Manager
//
// AppIntents exposed to Shortcuts.app, Spotlight, and the Siri-style
// voice surface. Intents are intentionally minimal and local-only —
// everything runs through the same DatabaseService + ClipboardService
// singletons the GUI uses. No network, no AI, no external APIs.
//
// All intents are gated at macOS 13 (matching the app's deployment
// target); older systems don't include the AppIntents framework so
// compilation bails out gracefully via @available.

import Foundation
import AppIntents
import AppKit

// MARK: - App Shortcuts Bundle

@available(macOS 13.0, *)
struct LumaClipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyLatestClipIntent(),
            phrases: [
                "Copy latest clip from \(.applicationName)",
                "Paste last clip with \(.applicationName)",
            ],
            shortTitle: "Copy Latest Clip",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: ShowClipboardIntent(),
            phrases: [
                "Show clipboard in \(.applicationName)",
                "Open \(.applicationName) history",
            ],
            shortTitle: "Show Clipboard",
            systemImageName: "clipboard"
        )
        AppShortcut(
            intent: SearchClipsIntent(),
            phrases: [
                "Search clips in \(.applicationName)",
            ],
            shortTitle: "Search Clips",
            systemImageName: "magnifyingglass"
        )
    }
}

// MARK: - Copy Latest Clip

@available(macOS 13.0, *)
struct CopyLatestClipIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Latest Clip"
    static var description = IntentDescription(
        "Copies the most recent clipboard item to the system clipboard, ready to paste with ⌘V.",
        categoryName: "Clipboard"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let items = DatabaseService.shared.fetchItems(filter: .all, limit: 1)
        guard let latest = items.first else {
            return .result(value: "")
        }
        await MainActor.run { ClipboardService.shared.copyItem(latest) }
        return .result(value: latest.content)
    }
}

// MARK: - Show Clipboard Panel

@available(macOS 13.0, *)
struct ShowClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Clipboard"
    static var description = IntentDescription(
        "Opens the LumaClip history panel.",
        categoryName: "Clipboard"
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Posting the same notification the URL scheme uses so the
        // AppDelegate's lifecycle owns panel presentation. Avoids
        // direct singleton coupling from inside the intent.
        if let url = URL(string: "lumaclip://show") {
            NSWorkspace.shared.open(url)
        }
        return .result()
    }
}

// MARK: - Search Clips

@available(macOS 13.0, *)
struct SearchClipsIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Clips"
    static var description = IntentDescription(
        "Search the clipboard history and return matching snippets.",
        categoryName: "Clipboard"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Limit", default: 10)
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let bounded = max(1, min(50, limit))
        let items = DatabaseService.shared.fetchItems(
            filter: .all,
            searchQuery: query,
            limit: bounded
        )
        let snippets = items.map { item -> String in
            let snippet = item.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return String(snippet.prefix(200))
        }
        return .result(value: snippets)
    }
}
