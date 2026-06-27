// Category.swift
// LumaClip - macOS Clipboard Manager
//
// Model for user-defined categories to organize clipboard items.
// Each category has a name, SF Symbol icon, and accent color.

import Foundation
import SwiftUI

// MARK: - Category Color

/// Predefined color options for categories.
/// Stored as a string enum for SQLite compatibility.
enum CategoryColor: String, Codable, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, mint

    var id: String { rawValue }

    /// SwiftUI Color mapping
    var color: Color {
        switch self {
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .teal:   return .teal
        case .indigo: return .indigo
        case .mint:   return .mint
        }
    }

    /// Human-readable label
    var label: String { rawValue.capitalized }
}

// MARK: - Category

/// User-defined organizational category for clipboard items.
struct Category: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var icon: String        // SF Symbol name
    var color: CategoryColor

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "tag",
        color: CategoryColor = .blue
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
    }

    // MARK: Default Categories
    //
    // Fixed UUIDs keep seeding idempotent — calling insertCategory (INSERT OR REPLACE)
    // with the same UUID is always safe and won't create duplicates.

    /// Parse a compile-time UUID literal. A bad literal is a programmer error,
    /// so fail loudly with a message pointing at the offending string — much
    /// better than a cryptic `UUID(uuidString:)!` force-unwrap crash.
    private static func uuidLiteral(_ s: String) -> UUID {
        guard let uuid = UUID(uuidString: s) else {
            preconditionFailure("Invalid UUID literal in Category.defaultCategories: \(s)")
        }
        return uuid
    }

    // Stable IDs for the document categories that file clips auto-sort
    // into. Referenced directly (not by name match) so routing can't be
    // hijacked by a same-named user category, and survives renames.
    static let pdfCategoryId        = uuidLiteral("00000000-0000-0000-0000-000000000008")
    static let wordCategoryId       = uuidLiteral("00000000-0000-0000-0000-000000000009")
    static let excelCategoryId      = uuidLiteral("00000000-0000-0000-0000-00000000000a")
    static let powerPointCategoryId = uuidLiteral("00000000-0000-0000-0000-00000000000b")

    static let defaultCategories: [Category] = [
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000001"),
            name: "Code",
            icon: "chevron.left.forwardslash.chevron.right",
            color: .green
        ),
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000002"),
            name: "Email",
            icon: "envelope",
            color: .teal
        ),
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000003"),
            name: "Links",
            icon: "link",
            color: .orange
        ),
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000004"),
            name: "Mobile",
            icon: "phone",
            color: .purple
        ),
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000005"),
            name: "Notes",
            icon: "note.text",
            color: .yellow
        ),
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000006"),
            name: "Personal",
            icon: "person",
            color: .pink
        ),
        Category(
            id: uuidLiteral("00000000-0000-0000-0000-000000000007"),
            name: "Screenshots",
            icon: "camera.viewfinder",
            color: .blue
        ),
        // Document categories — file clips are auto-sorted here by their
        // file extension (see ClipboardService.fileCategoryId).
        Category(
            id: pdfCategoryId,
            name: "PDF",
            icon: "doc.richtext",
            color: .red
        ),
        Category(
            id: wordCategoryId,
            name: "Word",
            icon: "doc.text",
            color: .indigo
        ),
        Category(
            id: excelCategoryId,
            name: "Excel",
            icon: "tablecells",
            color: .green
        ),
        Category(
            id: powerPointCategoryId,
            name: "PowerPoint",
            icon: "rectangle.on.rectangle",
            color: .orange
        ),
    ]
}
