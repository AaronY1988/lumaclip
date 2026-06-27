// SettingsViewModel.swift
// LumaClip - macOS Clipboard Manager
//
// ViewModel for the Settings panel. Bridges AppSettings
// with the SwiftUI settings views and manages runtime
// operations like data cleanup and blacklist management.

import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Settings Section

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case privacy = "Privacy"
    case retention = "Retention"
    case appearance = "Appearance"
    case data = "Data"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:    return "gear"
        case .privacy:    return "lock.shield"
        case .retention:  return "clock.arrow.circlepath"
        case .appearance: return "paintbrush"
        case .data:       return "externaldrive"
        case .shortcuts:  return "keyboard"
        }
    }
}

// MARK: - Settings ViewModel

@MainActor
final class SettingsViewModel: ObservableObject {

    // MARK: Published State

    @Published var activeSection: SettingsSection = .general
    @Published var settings: AppSettings

    // Privacy
    @Published var blacklistedApps: [String] = []
    @Published var availableApps: [PrivacyService.RunningApp] = []

    // Retention
    @Published var retentionRules: [RetentionRule] = []
    @Published var newRuleTarget: RetentionTarget = .all
    @Published var newRuleDuration: TimeInterval = 86400 * 7

    // Data
    @Published var totalItemCount: Int = 0
    @Published var trashItemCount: Int = 0
    @Published var itemCountsByType: [ContentType: Int] = [:]

    // Backup & Restore — inline status line shown in the Data section
    // after an export/import completes (success or failure).
    @Published var backupStatusMessage: String?
    @Published var backupStatusIsError: Bool = false

    // MARK: Dependencies

    private let database = DatabaseService.shared
    private let privacyService = PrivacyService.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init() {
        self.settings = AppSettings.shared
        loadData()
        setupObservers()
    }

    // MARK: - Data Loading

    func loadData() {
        blacklistedApps = settings.blacklistedApps
        availableApps = privacyService.runningApps
        retentionRules = database.fetchRetentionRules()
        totalItemCount = database.itemCount(filter: .all)
        trashItemCount = database.itemCount(filter: .trash)
        itemCountsByType = database.itemCountsByType()
    }

    private func setupObservers() {
        privacyService.$runningApps
            .receive(on: DispatchQueue.main)
            .assign(to: &$availableApps)

        privacyService.$blacklistedApps
            .receive(on: DispatchQueue.main)
            .assign(to: &$blacklistedApps)
    }

    // MARK: - Privacy Actions

    func toggleAppBlacklist(_ appName: String) {
        privacyService.toggleBlacklist(appName)
        blacklistedApps = privacyService.blacklistedApps
    }

    func isAppBlacklisted(_ appName: String) -> Bool {
        privacyService.isBlacklisted(appName)
    }

    // MARK: - Retention Actions

    func addRetentionRule() {
        let rule = RetentionRule(
            target: newRuleTarget,
            duration: newRuleDuration
        )
        database.insertRetentionRule(rule)
        RetentionService.shared.applyRule(rule)
        loadData()
    }

    func deleteRetentionRule(_ rule: RetentionRule) {
        database.deleteRetentionRule(id: rule.id)
        loadData()
    }

    // MARK: - Backup & Restore Actions

    /// Present a save panel and export the full dataset to the chosen
    /// location as a JSON archive.
    func backupDataToFile() {
        let panel = NSSavePanel()
        panel.title = "Back Up LumaClip Data".loc
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = BackupService.suggestedFilename()
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try BackupService.shared.exportBackup(to: url)
            backupStatusIsError = false
            backupStatusMessage = L("Backup saved to %@", url.lastPathComponent)
        } catch {
            backupStatusIsError = true
            backupStatusMessage = L("Backup failed: %@", error.localizedDescription)
        }
    }

    /// Present an open panel and merge-restore from the chosen backup
    /// file. Existing clips/categories/rules/bundles (matched by ID)
    /// are kept untouched; only new entries are added.
    func restoreDataFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Restore LumaClip Backup".loc
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let summary = try BackupService.shared.restoreBackup(from: url)
            backupStatusIsError = false
            backupStatusMessage = summary.message
            loadData()
            NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
        } catch {
            backupStatusIsError = true
            backupStatusMessage = L("Restore failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Data Actions

    /// Apply retention rules and remove expired items immediately
    func runCleanupNow() {
        RetentionService.shared.performCleanup()
        loadData()
        NotificationCenter.default.post(name: .retentionCleanupCompleted, object: nil)
    }

    /// Permanently delete everything in the trash bin
    func emptyTrash() {
        database.purgeOldTrashItems(olderThanDays: 0)
        loadData()
        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
    }

    /// Delete all clipboard history (keeps starred favorites and pinned items)
    func clearAllHistory() {
        let items = database.fetchItems(limit: 500_000)
        for item in items where !item.isFavorite && !item.isPinned {
            database.permanentlyDeleteItem(id: item.id)
        }
        loadData()
        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
    }

    /// Wipe every item, rule, and custom category — restore factory defaults
    func resetEverything() {
        // 1. Permanently delete all active items (including favorites/pinned)
        let allItems = database.fetchItems(limit: 500_000)
        for item in allItems {
            database.permanentlyDeleteItem(id: item.id)
        }
        // 2. Purge the entire trash
        database.purgeOldTrashItems(olderThanDays: 0)
        // 3. Delete all custom retention rules
        let rules = database.fetchRetentionRules()
        for rule in rules {
            database.deleteRetentionRule(id: rule.id)
        }
        // 4. Wipe all categories, then re-seed the 7 defaults
        let allCats = database.fetchCategories()
        for cat in allCats {
            database.deleteCategory(id: cat.id)
        }
        for cat in Category.defaultCategories {
            database.insertCategory(cat)
        }
        // 5. Refresh UI
        loadData()
        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
        NotificationCenter.default.post(name: .retentionCleanupCompleted, object: nil)
    }
}
