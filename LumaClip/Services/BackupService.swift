// BackupService.swift
// LumaClip - macOS Clipboard Manager
//
// Export the full LumaClip dataset (clips — including image data —
// categories, retention rules, and bundles) into a single portable
// JSON archive, and restore from such an archive with merge
// semantics: rows already present (matched by UUID) are left
// untouched, everything else is added.

import Foundation

// MARK: - Archive Format

/// Top-level structure of a LumaClip backup file.
///
/// Dates are encoded as ISO-8601 strings and binary image data as
/// base64, so the file is plain UTF-8 JSON — inspectable, diffable,
/// and resilient to future schema changes via `formatVersion`.
struct BackupArchive: Codable {
    /// Bump when the archive layout changes incompatibly.
    static let currentFormatVersion = 1

    let formatVersion: Int
    let createdAt: Date
    let items: [BackupItem]
    let categories: [Category]
    let retentionRules: [RetentionRule]
    let bundles: [ClipBundle]
}

/// Backup representation of a `ClipboardItem`.
///
/// `ClipboardItem`'s own Codable conformance intentionally excludes
/// `imageData` (it lives in a DB BLOB column), so this mirror struct
/// exists to carry the image bytes through the JSON archive as well.
struct BackupItem: Codable {
    let id: UUID
    let content: String
    let contentType: String
    let sourceApp: String
    let createdAt: Date
    let expiresAt: Date?
    let isFavorite: Bool
    let isPinned: Bool
    let categoryId: UUID?
    let isDeleted: Bool
    let deletedAt: Date?
    /// JPEG bytes — JSONEncoder serializes `Data` as base64 by default.
    let imageData: Data?
    let contentHash: String
    let ocrText: String
    let isSensitive: Bool
    let isBurnAfterPaste: Bool

    init(from item: ClipboardItem) {
        self.id = item.id
        self.content = item.content
        self.contentType = item.contentType.rawValue
        self.sourceApp = item.sourceApp
        self.createdAt = item.createdAt
        self.expiresAt = item.expiresAt
        self.isFavorite = item.isFavorite
        self.isPinned = item.isPinned
        self.categoryId = item.categoryId
        self.isDeleted = item.isDeleted
        self.deletedAt = item.deletedAt
        self.imageData = item.imageData
        self.contentHash = item.contentHash
        self.ocrText = item.ocrText
        self.isSensitive = item.isSensitive
        self.isBurnAfterPaste = item.isBurnAfterPaste
    }

    func toClipboardItem() -> ClipboardItem {
        ClipboardItem(
            id: id,
            content: content,
            contentType: ContentType(rawValue: contentType) ?? .unknown,
            sourceApp: sourceApp,
            createdAt: createdAt,
            expiresAt: expiresAt,
            isFavorite: isFavorite,
            isPinned: isPinned,
            categoryId: categoryId,
            isDeleted: isDeleted,
            deletedAt: deletedAt,
            imageData: imageData,
            contentHash: contentHash,
            ocrText: ocrText,
            isSensitive: isSensitive,
            isBurnAfterPaste: isBurnAfterPaste
        )
    }
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case unreadableFile
    case notABackupFile
    case incompatibleVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The file could not be read."
        case .notABackupFile:
            return "This file is not a valid LumaClip backup."
        case .incompatibleVersion(let v):
            return "This backup was created by a newer version of LumaClip (format v\(v)) and cannot be restored."
        }
    }
}

// MARK: - Restore Summary

/// Counts of what a restore actually added vs. skipped, surfaced
/// in the Settings UI after a restore completes.
struct RestoreSummary {
    var itemsAdded = 0
    var itemsSkipped = 0
    var categoriesAdded = 0
    var rulesAdded = 0
    var bundlesAdded = 0

    var message: String {
        var parts: [String] = []
        parts.append("\(itemsAdded) clip\(itemsAdded == 1 ? "" : "s") added")
        if categoriesAdded > 0 { parts.append("\(categoriesAdded) categor\(categoriesAdded == 1 ? "y" : "ies")") }
        if rulesAdded > 0 { parts.append("\(rulesAdded) rule\(rulesAdded == 1 ? "" : "s")") }
        if bundlesAdded > 0 { parts.append("\(bundlesAdded) bundle\(bundlesAdded == 1 ? "" : "s")") }
        var msg = "Restore complete: " + parts.joined(separator: ", ")
        if itemsSkipped > 0 {
            msg += " (\(itemsSkipped) already present)"
        }
        return msg
    }
}

// MARK: - Backup Service

@MainActor
final class BackupService {
    static let shared = BackupService()

    private let database = DatabaseService.shared

    private init() {}

    // MARK: Coders

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Suggested filename for a new backup, e.g.
    /// "LumaClip Backup 2026-06-10.json".
    static func suggestedFilename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "LumaClip Backup \(formatter.string(from: date)).json"
    }

    // MARK: - Export

    /// Serialize the entire dataset to a JSON archive at `url`.
    /// Includes trashed items so a restore preserves the Trash Bin.
    func exportBackup(to url: URL) throws {
        let archive = BackupArchive(
            formatVersion: BackupArchive.currentFormatVersion,
            createdAt: Date(),
            items: database.fetchAllItemsForBackup().map(BackupItem.init),
            categories: database.fetchCategories(),
            retentionRules: database.fetchRetentionRules(),
            bundles: BundleService.shared.bundles
        )

        let data = try Self.makeEncoder().encode(archive)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Restore (merge)

    /// Restore from a backup archive at `url`.
    ///
    /// Merge semantics: rows whose UUID already exists locally are
    /// skipped — nothing is overwritten or deleted. New clips are
    /// inserted via `insertItem`, which also rebuilds their FTS
    /// entries so restored content is immediately searchable.
    func restoreBackup(from url: URL) throws -> RestoreSummary {
        guard let data = try? Data(contentsOf: url) else {
            throw BackupError.unreadableFile
        }

        let archive: BackupArchive
        do {
            archive = try Self.makeDecoder().decode(BackupArchive.self, from: data)
        } catch {
            throw BackupError.notABackupFile
        }

        guard archive.formatVersion <= BackupArchive.currentFormatVersion else {
            throw BackupError.incompatibleVersion(archive.formatVersion)
        }

        var summary = RestoreSummary()

        // Categories first so restored items can reference them.
        let existingCategoryIDs = Set(database.fetchCategories().map(\.id))
        for category in archive.categories where !existingCategoryIDs.contains(category.id) {
            database.insertCategory(category)
            summary.categoriesAdded += 1
        }

        // Clipboard items — skip IDs that already exist.
        let existingItemIDs = database.allItemIDs()
        for backupItem in archive.items {
            if existingItemIDs.contains(backupItem.id) {
                summary.itemsSkipped += 1
            } else {
                database.insertItem(backupItem.toClipboardItem())
                summary.itemsAdded += 1
            }
        }

        // Retention rules.
        let existingRuleIDs = Set(database.fetchRetentionRules().map(\.id))
        for rule in archive.retentionRules where !existingRuleIDs.contains(rule.id) {
            database.insertRetentionRule(rule)
            summary.rulesAdded += 1
        }

        // Bundles.
        summary.bundlesAdded = BundleService.shared.importBundles(archive.bundles)

        return summary
    }
}
