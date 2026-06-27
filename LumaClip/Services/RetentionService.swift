// RetentionService.swift
// LumaClip - macOS Clipboard Manager
//
// Manages automatic cleanup of expired clipboard items
// and trash bin purging on a scheduled timer.

import Foundation
import Combine

// MARK: - Retention Service

final class RetentionService: ObservableObject {
    static let shared = RetentionService()

    private let database = DatabaseService.shared
    private let settings = AppSettings.shared
    private var cleanupTimer: Timer?

    /// Cleanup interval: every 5 minutes
    private let cleanupInterval: TimeInterval = 300

    private init() {}

    // MARK: - Start / Stop

    /// Start the periodic cleanup timer
    func startCleanupSchedule() {
        guard cleanupTimer == nil else { return }

        // Run immediately on start
        performCleanup()

        cleanupTimer = Timer.scheduledTimer(
            withTimeInterval: cleanupInterval,
            repeats: true
        ) { [weak self] _ in
            self?.performCleanup()
        }

        if let timer = cleanupTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Stop the cleanup timer
    func stopCleanupSchedule() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    // MARK: - Cleanup

    /// Perform all cleanup operations
    func performCleanup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            // 1. Soft-delete expired items
            self.database.cleanupExpiredItems()

            // 2. Purge old trash items
            let trashDays = self.settings.trashRetentionDays
            self.database.purgeOldTrashItems(olderThanDays: trashDays)

            // 3. Trim history to max count
            let maxCount = self.settings.maxHistoryCount
            self.database.trimHistory(maxCount: maxCount)

            // Notify UI to refresh
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .retentionCleanupCompleted,
                    object: nil
                )
            }
        }
    }

    /// Apply a retention rule to existing items
    func applyRule(_ rule: RetentionRule) {
        guard rule.isEnabled, rule.duration > 0 else { return }

        let items = database.fetchItems(limit: 10000)
        let expiryDate = Date().addingTimeInterval(rule.duration)

        for item in items {
            var shouldApply = false

            switch rule.target {
            case .all:
                shouldApply = true
            case .contentType(let ct):
                shouldApply = item.contentType == ct
            case .category(let catId):
                shouldApply = item.categoryId == catId
            case .sourceApp(let app):
                shouldApply = !app.isEmpty
                    && item.sourceApp.caseInsensitiveCompare(app) == .orderedSame
            }

            if shouldApply && item.expiresAt == nil {
                database.setExpiry(itemId: item.id, expiresAt: expiryDate)
            }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let retentionCleanupCompleted = Notification.Name("com.lumaclip.retentionCleanupCompleted")
}
