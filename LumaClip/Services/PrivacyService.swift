// PrivacyService.swift
// LumaClip - macOS Clipboard Manager
//
// Manages app blacklisting for clipboard tracking.
// Provides the list of running apps for the user to select
// which ones should be excluded from monitoring.

import Foundation
import AppKit
import Combine

// MARK: - Privacy Service

final class PrivacyService: ObservableObject {
    static let shared = PrivacyService()

    @Published var runningApps: [RunningApp] = []
    @Published var blacklistedApps: [String] = []

    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Running App Model

    struct RunningApp: Identifiable, Hashable {
        let id: String  // bundle identifier
        let name: String
        let icon: NSImage?

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: RunningApp, rhs: RunningApp) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Init

    private init() {
        blacklistedApps = settings.blacklistedApps
        refreshRunningApps()

        // Listen for app launch/termination
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appStateChanged),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appStateChanged),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        // Balance the two `addObserver(self,...)` registrations above so the
        // notification center doesn't hold stale references if this service
        // is ever deallocated (singletons included, for test harnesses).
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - App List

    /// Refresh the list of currently running apps
    func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let name = app.localizedName,
                      let bundleId = app.bundleIdentifier
                else { return nil }
                return RunningApp(
                    id: bundleId,
                    name: name,
                    icon: app.icon
                )
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        DispatchQueue.main.async { [weak self] in
            self?.runningApps = apps
        }
    }

    @objc private func appStateChanged(_ notification: Notification) {
        refreshRunningApps()
    }

    // MARK: - Blacklist Management

    /// Add an app to the blacklist
    func blacklistApp(_ appName: String) {
        guard !blacklistedApps.contains(appName) else { return }
        blacklistedApps.append(appName)
        settings.blacklistedApps = blacklistedApps
    }

    /// Remove an app from the blacklist
    func removeFromBlacklist(_ appName: String) {
        blacklistedApps.removeAll { $0 == appName }
        settings.blacklistedApps = blacklistedApps
    }

    /// Check if an app is blacklisted
    func isBlacklisted(_ appName: String) -> Bool {
        blacklistedApps.contains(appName)
    }

    /// Toggle blacklist status
    func toggleBlacklist(_ appName: String) {
        if isBlacklisted(appName) {
            removeFromBlacklist(appName)
        } else {
            blacklistApp(appName)
        }
    }

    // MARK: - Common Privacy-Sensitive Apps

    /// Suggested apps to blacklist for privacy
    static let suggestedBlacklist: [String] = [
        "1Password",
        "Keychain Access",
        "LastPass",
        "Bitwarden",
        "Dashlane",
        "KeePassXC",
    ]
}
