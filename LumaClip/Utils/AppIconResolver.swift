// AppIconResolver.swift
// LumaClip — macOS Clipboard Manager
//
// Resolves a localized app name (as captured into ClipboardItem.sourceApp)
// to an NSImage of that app's icon. Results are cached, including negative
// lookups, so the row body can call this synchronously on every render.
//
// Resolution order:
//   1. NSWorkspace.runningApplications — fastest, common case, gives the
//      authoritative bundle icon for currently-launched apps.
//   2. Standard app directories — /Applications, ~/Applications,
//      /System/Applications (and Utilities subfolder). Uses
//      NSWorkspace.icon(forFile:) once a matching bundle is found.
//
// Returns nil when the source app cannot be located (rare — happens for
// apps that were uninstalled, renamed, or were captured as "Unknown").

import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppIconResolver {

    static let shared = AppIconResolver()

    private var cache: [String: NSImage] = [:]
    private var misses: Set<String>     = []

    private init() {}

    /// Returns the icon for an app whose `localizedName` matches `name`,
    /// or nil when the app cannot be resolved on this machine.
    func icon(for name: String) -> NSImage? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.caseInsensitiveCompare("Unknown") != .orderedSame
        else { return nil }

        if let hit = cache[key]   { return hit }
        if misses.contains(key)   { return nil }

        if let img = locate(name: key) {
            cache[key] = img
            return img
        }
        misses.insert(key)
        return nil
    }

    /// Drop cached negative results so an app that was just installed or
    /// launched can be picked up on the next render. Positive cache stays;
    /// app icons rarely change at runtime.
    func invalidateMisses() { misses.removeAll() }

    // MARK: - Lookup

    private func locate(name: String) -> NSImage? {
        // 1. Running applications — exact match on localizedName.
        for app in NSWorkspace.shared.runningApplications {
            if let appName = app.localizedName,
               appName.caseInsensitiveCompare(name) == .orderedSame,
               let icon = app.icon {
                return icon
            }
        }

        // 2. Standard application bundle locations.
        let home   = FileManager.default.homeDirectoryForCurrentUser.path
        let bases  = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
        ]
        let fm = FileManager.default
        for base in bases {
            let path = "\(base)/\(name).app"
            if fm.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }
}

// MARK: - SwiftUI Badge

/// Small overlay badge of the source app's icon, designed to sit on the
/// bottom-right corner of a content-type icon. Renders nothing when the
/// app cannot be resolved, so the parent layout collapses gracefully.
struct SourceAppIconBadge: View {
    let appName: String
    /// Visual edge length in points (the rounded square that contains the
    /// app icon). Defaults to 14, suitable for a 24-pt host icon.
    var size: CGFloat = 14

    var body: some View {
        if let img = AppIconResolver.shared.icon(for: appName) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24,
                                     style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9),
                                      lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                .accessibilityLabel(Text("From \(appName)"))
                .help("From \(appName)")
        }
    }
}
