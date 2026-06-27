// ClipboardItem.swift
// LumaClip - macOS Clipboard Manager
//
// Core data model representing a single clipboard entry.
// Supports soft-delete for Trash Bin, favorites, pinning,
// category assignment, and automatic expiry.

import Foundation
import SwiftUI
import AppKit

// MARK: - Content Type Classification

/// Represents the detected type of clipboard content.
/// Used for filtering, icon display, and retention rules.
enum ContentType: String, Codable, CaseIterable, Identifiable {
    case text = "text"
    case url = "url"
    case email = "email"
    case code = "code"
    case phone = "phone"
    case color = "color"
    case image = "image"
    case path = "path"
    case file = "file"
    case unknown = "unknown"

    var id: String { rawValue }

    /// SF Symbol name for each content type
    var iconName: String {
        switch self {
        case .text:    return "doc.text"
        case .url:     return "link"
        case .email:   return "envelope"
        case .code:    return "chevron.left.forwardslash.chevron.right"
        case .phone:   return "phone"
        case .color:   return "paintpalette"
        case .image:   return "photo"
        case .path:    return "folder"
        case .file:    return "doc.fill"
        case .unknown: return "doc"
        }
    }

    /// Human-readable label
    var label: String {
        switch self {
        case .text:    return "Text".loc
        case .url:     return "URL".loc
        case .email:   return "Email".loc
        case .code:    return "Code".loc
        case .phone:   return "Phone".loc
        case .color:   return "Color".loc
        case .image:   return "Image".loc
        case .path:    return "File Path".loc
        case .file:    return "File".loc
        case .unknown: return "Unknown".loc
        }
    }

    /// Color representation for each content type.
    /// Designed for clear visual hierarchy:
    ///   code = green, link = blue, image = purple, text = neutral gray
    var color: Color {
        switch self {
        case .text:    return Color(hue: 0.0, saturation: 0.0, brightness: 0.50)   // neutral gray
        case .url:     return Color(hue: 0.58, saturation: 0.72, brightness: 0.82) // blue
        case .email:   return Color(hue: 0.08, saturation: 0.75, brightness: 0.90) // warm orange
        case .code:    return Color(hue: 0.38, saturation: 0.68, brightness: 0.72) // green
        case .phone:   return Color(hue: 0.55, saturation: 0.50, brightness: 0.70) // soft teal
        case .color:   return Color(hue: 0.92, saturation: 0.60, brightness: 0.82) // rose
        case .image:   return Color(hue: 0.78, saturation: 0.58, brightness: 0.78) // purple
        case .path:    return Color(hue: 0.10, saturation: 0.45, brightness: 0.62) // brown
        case .file:    return Color(hue: 0.62, saturation: 0.55, brightness: 0.80) // indigo
        case .unknown: return Color(hue: 0.0, saturation: 0.0, brightness: 0.58)   // dim gray
        }
    }
}

// MARK: - File Entry

/// One captured file inside a `ClipboardItem` of type `.file`.
///
/// A single clipboard "file clip" can hold several files (multi-select
/// copy in Finder). Each entry is either *stored* — its bytes were
/// copied into LumaClip's on-disk vault so it survives the original
/// being moved/deleted — or *reference-only* — only the original path
/// is remembered (used for large files / folders above the vault
/// threshold). The list is serialised to JSON in the `file_meta`
/// column rather than stored via `Codable`, mirroring how `imageData`
/// lives in its own BLOB column.
struct FileEntry: Codable, Hashable {
    /// Original file name including extension, e.g. "report.pdf".
    var name: String
    /// File size in bytes (0 for folders / unknown).
    var byteSize: Int64
    /// True when the bytes were copied into the vault; false for
    /// reference-only entries (large files, folders, or copy failures).
    var stored: Bool
    /// Path relative to the vault directory, e.g. "<hash>/report.pdf".
    /// Empty for reference-only entries.
    var vaultPath: String
    /// Absolute path of the original file at capture time. Used for
    /// reference-only paste-back and "Reveal original in Finder".
    var originalPath: String

    init(
        name: String,
        byteSize: Int64 = 0,
        stored: Bool = false,
        vaultPath: String = "",
        originalPath: String = ""
    ) {
        self.name = name
        self.byteSize = byteSize
        self.stored = stored
        self.vaultPath = vaultPath
        self.originalPath = originalPath
    }

    /// Human-readable size, e.g. "1.2 MB".
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// Vault folder component (the first path segment), used for
    /// garbage collection. Empty for reference-only entries.
    var vaultFolder: String {
        guard stored, !vaultPath.isEmpty else { return "" }
        return String(vaultPath.split(separator: "/").first ?? "")
    }
}

// MARK: - Clipboard Item

/// Primary data model for a clipboard history entry.
/// Identifiable and Hashable for use in SwiftUI lists.
struct ClipboardItem: Identifiable, Hashable, Codable {
    let id: UUID
    var content: String
    var contentType: ContentType
    var sourceApp: String
    var createdAt: Date
    var expiresAt: Date?
    var isFavorite: Bool
    var isPinned: Bool
    var categoryId: UUID?
    var isDeleted: Bool
    var deletedAt: Date?

    /// JPEG-compressed image data (nil for text-based items).
    /// Capped at ~2 MB on insert. Excluded from Codable/Hashable
    /// to keep diffing cheap.
    var imageData: Data?

    /// SHA-256 of normalized content, used for exact-duplicate detection.
    /// On capture, a match against an existing non-deleted row promotes that
    /// row's `createdAt` instead of inserting a duplicate.
    var contentHash: String

    /// OCR text extracted from image clips (populated async after insert).
    /// Indexed into FTS alongside `content` so screenshot text is searchable.
    var ocrText: String

    /// True when SensitivityDetector flags the content (credit card, JWT,
    /// API-key shape, etc.). Surfaces a shield in the UI; user may still
    /// interact, but auto-burn-after-paste is suggested.
    var isSensitive: Bool

    /// When true, copying this item to the system pasteboard schedules its
    /// deletion on the next clipboard change (the assumed paste), or after
    /// a short timeout if nothing else is copied.
    var isBurnAfterPaste: Bool

    /// Captured files for `.file` clips (empty for every other type).
    /// Serialised to the `file_meta` JSON column, so — like `imageData`
    /// — it is excluded from `Codable`/`Hashable`. The `= []` default lets
    /// `Codable` synthesis omit it cleanly (non-optional types otherwise
    /// require a default when absent from `CodingKeys`).
    var fileEntries: [FileEntry] = []

    // MARK: Initializer

    init(
        id: UUID = UUID(),
        content: String,
        contentType: ContentType = .text,
        sourceApp: String = "",
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        categoryId: UUID? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        imageData: Data? = nil,
        contentHash: String = "",
        ocrText: String = "",
        isSensitive: Bool = false,
        isBurnAfterPaste: Bool = false,
        fileEntries: [FileEntry] = []
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.categoryId = categoryId
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.imageData = imageData
        self.contentHash = contentHash
        self.ocrText = ocrText
        self.isSensitive = isSensitive
        self.isBurnAfterPaste = isBurnAfterPaste
        self.fileEntries = fileEntries
    }

    // MARK: File Helpers

    /// Number of files held by a `.file` clip.
    var fileCount: Int { fileEntries.count }

    /// Total size in bytes across all captured files.
    var totalFileSize: Int64 { fileEntries.reduce(0) { $0 + $1.byteSize } }

    /// Display name for a file clip: the file name for a single file,
    /// otherwise a count summary like "3 files".
    var fileDisplayName: String {
        if fileEntries.count == 1 {
            return fileEntries[0].name
        }
        return "\(fileEntries.count) " + "files".loc
    }

    /// True when at least one file's bytes live in the vault (vs being a
    /// pure reference). Drives the "stored / linked" badge in the UI.
    var hasStoredFiles: Bool { fileEntries.contains { $0.stored } }

    // MARK: Computed Properties

    /// Smart title auto-generated from content and type.
    /// Short, single-line, designed for scanning at a glance.
    var title: String {
        switch contentType {
        case .url:
            // Extract domain as title
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let host = url.host {
                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                // Include path hint if short enough
                let path = url.path
                if path.count > 1 && path.count < 30 {
                    return "\(domain)\(path)"
                }
                return domain
            }
            return String(trimmed.prefix(50))

        case .email:
            return content.trimmingCharacters(in: .whitespacesAndNewlines)

        case .color:
            let hex = content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return hex.hasPrefix("#") ? hex : "#\(hex)"

        case .image:
            if let dims = imageDimensions {
                return "\("Image".loc) \(dims.width)×\(dims.height)"
            }
            return "Image".loc

        case .phone:
            return content.trimmingCharacters(in: .whitespacesAndNewlines)

        case .code:
            // First meaningful line (skip blank lines / comments)
            let lines = content.components(separatedBy: .newlines)
            let meaningful = lines.first {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("//") && !t.hasPrefix("#") && !t.hasPrefix("/*")
            }
            let line = meaningful ?? lines.first ?? "Code snippet"
            return String(line.trimmingCharacters(in: .whitespaces).prefix(60))

        case .path:
            // Show filename from path
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.split(separator: "/").last {
                return String(last)
            }
            return String(trimmed.prefix(50))

        case .file:
            return fileDisplayName

        case .text, .unknown:
            // First non-blank line, capped
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            let clean = firstLine.trimmingCharacters(in: .whitespaces)
            if clean.count > 60 {
                return String(clean.prefix(57)) + "…"
            }
            return clean.isEmpty ? "Empty clip" : clean
        }
    }

    /// Two-line preview for list display (body text below the title)
    var preview: String {
        // File clips: summarise count + total size (and the storage mode)
        // rather than echoing the space-joined filenames held in `content`.
        if contentType == .file {
            let sizeStr = ByteCountFormatter.string(
                fromByteCount: totalFileSize, countStyle: .file
            )
            let mode = hasStoredFiles ? "Saved".loc : "Linked".loc
            if fileEntries.count <= 1 {
                return "\(sizeStr) · \(mode)"
            }
            return "\(fileEntries.count) " + "files".loc + " · \(sizeStr) · \(mode)"
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)

        // Skip the first line (already shown as title) for multi-line content
        let bodyLines: [String]
        if lines.count > 1 {
            bodyLines = Array(lines.dropFirst().prefix(2))
        } else {
            // Single-line: show truncated version as preview
            bodyLines = [String(trimmed.prefix(120))]
        }

        let joined = bodyLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if joined.count > 120 {
            return String(joined.prefix(117)) + "…"
        }
        return joined
    }

    /// Whether this item has expired
    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }

    /// Shared formatter to avoid re-creating on every cell render
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Relative time string (e.g., "2 min ago")
    var relativeTime: String {
        Self.relativeDateFormatter.localizedString(for: createdAt, relativeTo: Date())
    }

    /// Character count or image size display
    var characterCount: String {
        if contentType == .image, let data = imageData {
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
        if contentType == .file {
            return ByteCountFormatter.string(fromByteCount: totalFileSize, countStyle: .file)
        }
        return "\(content.count) \("chars".loc)"
    }

    /// Returns an NSImage from the stored JPEG data (cached by SwiftUI).
    var nsImage: NSImage? {
        guard let data = imageData else { return nil }
        return NSImage(data: data)
    }

    /// Image dimensions parsed from the `content` description string
    /// (format: "Image WxH").
    var imageDimensions: (width: Int, height: Int)? {
        guard contentType == .image else { return nil }
        let parts = content.replacingOccurrences(of: "Image ", with: "")
                           .split(separator: "×")
        guard parts.count == 2,
              let w = Int(parts[0]),
              let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    /// Formatted date string
    var formattedDate: String {
        relativeTime
    }

    // MARK: Codable — imageData excluded (stored separately in DB BLOB)

    private enum CodingKeys: String, CodingKey {
        case id, content, contentType, sourceApp, createdAt, expiresAt
        case isFavorite, isPinned, categoryId, isDeleted, deletedAt
        case contentHash, ocrText, isSensitive, isBurnAfterPaste
        // imageData intentionally omitted — stored as a BLOB column
        // fileEntries intentionally omitted — stored as the file_meta JSON column
    }

    // MARK: Hashable — identity-based only

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}
