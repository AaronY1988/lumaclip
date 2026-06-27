// RetentionRule.swift
// LumaClip - macOS Clipboard Manager
//
// Model for automatic expiry rules. Rules can target
// a specific content type or category, applying a TTL
// (time-to-live) in seconds to matching clipboard items.

import Foundation

// MARK: - Retention Target

/// Determines what a retention rule applies to.
enum RetentionTarget: Codable, Hashable {
    case contentType(ContentType)
    case category(UUID)
    /// Rule applies to items copied from a specific app. The associated
    /// value matches `ClipboardItem.sourceApp` — historically the localized
    /// app name (e.g. "Slack"). Intentionally string-typed (not bundleID)
    /// to match how sourceApp is currently captured upstream.
    case sourceApp(String)
    case all

    // Custom coding for SQLite storage
    enum CodingKeys: String, CodingKey {
        case type, value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .contentType(let ct):
            try container.encode("contentType", forKey: .type)
            try container.encode(ct.rawValue, forKey: .value)
        case .category(let id):
            try container.encode("category", forKey: .type)
            try container.encode(id.uuidString, forKey: .value)
        case .sourceApp(let name):
            try container.encode("sourceApp", forKey: .type)
            try container.encode(name, forKey: .value)
        case .all:
            try container.encode("all", forKey: .type)
            try container.encode("", forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)

        switch type {
        case "contentType":
            self = .contentType(ContentType(rawValue: value) ?? .unknown)
        case "category":
            // A malformed UUID here is a data-integrity bug — silently
            // minting a fresh UUID would make the rule point at a category
            // that doesn't exist, which then fails to match anything and
            // looks like the rule is simply broken. Surface the corruption
            // so callers can repair/drop the row instead.
            guard let uuid = UUID(uuidString: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Invalid UUID string for RetentionTarget.category: \(value)"
                )
            }
            self = .category(uuid)
        case "sourceApp":
            self = .sourceApp(value)
        default:
            self = .all
        }
    }
}

// MARK: - Retention Rule

/// Defines an automatic expiry policy for clipboard items.
struct RetentionRule: Identifiable, Hashable, Codable {
    let id: UUID
    var target: RetentionTarget
    var duration: TimeInterval   // seconds until expiry
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        target: RetentionTarget = .all,
        duration: TimeInterval = 86400 * 7, // 7 days default
        isEnabled: Bool = true
    ) {
        self.id = id
        self.target = target
        self.duration = duration
        self.isEnabled = isEnabled
    }

    // MARK: Computed

    /// Human-readable duration string
    var durationLabel: String {
        let hours = Int(duration) / 3600
        let days = hours / 24

        if days > 0 {
            return days == 1 ? "1 day" : "\(days) days"
        } else if hours > 0 {
            return hours == 1 ? "1 hour" : "\(hours) hours"
        } else {
            let minutes = Int(duration) / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
    }

    /// Target description
    var targetLabel: String {
        switch target {
        case .contentType(let ct):
            return ct.label
        case .category:
            return "Category".loc
        case .sourceApp(let name):
            return name.isEmpty ? "App".loc : "\("App".loc): \(name)"
        case .all:
            return "All Items".loc
        }
    }

    // MARK: Preset Durations

    static let presetDurations: [(String, TimeInterval)] = [
        ("1 Hour", 3600),
        ("6 Hours", 3600 * 6),
        ("1 Day", 86400),
        ("3 Days", 86400 * 3),
        ("7 Days", 86400 * 7),
        ("14 Days", 86400 * 14),
        ("30 Days", 86400 * 30),
        ("90 Days", 86400 * 90),
        ("Never", 0),
    ]
}
