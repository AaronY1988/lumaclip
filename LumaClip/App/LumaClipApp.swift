// LumaClipApp.swift
// LumaClip - macOS Clipboard Manager
//
// App entry point. Uses @NSApplicationDelegateAdaptor to bridge
// the SwiftUI app lifecycle with our custom NSApplicationDelegate
// which manages windows, services, and the menu bar.

import SwiftUI

// MARK: - App Entry Point

@main
struct LumaClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use a Settings scene as a placeholder.
        // All windows are managed by AppDelegate via NSPanel.
        Settings {
            EmptyView()
        }
    }
}
