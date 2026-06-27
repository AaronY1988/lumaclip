// ClipBundle.swift
// LumaClip - macOS Clipboard Manager
//
// Model for clipboard bundles - collections of clipboard items
// that can be pasted sequentially (form-fill mode).

import Foundation
import SwiftUI

// MARK: - Clipboard Bundle

/// A named collection of clipboard items for sequential pasting
struct ClipBundle: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var icon: String           // SF Symbol name
    var colorName: String      // CategoryColor raw value
    var itemIDs: [UUID]        // Ordered list of clipboard item IDs
    var createdAt: Date
    var modifiedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "square.stack.3d.up",
        colorName: String = "blue",
        itemIDs: [UUID] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorName = colorName
        self.itemIDs = itemIDs
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
    
    // MARK: - Computed Properties
    
    /// Get the color from the color name
    var color: CategoryColor {
        CategoryColor(rawValue: colorName) ?? .blue
    }
    
    /// Number of items in this bundle
    var itemCount: Int {
        itemIDs.count
    }
    
    /// Whether the bundle is empty
    var isEmpty: Bool {
        itemIDs.isEmpty
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ClipBundle, rhs: ClipBundle) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Bundle Session

/// Represents an active form-fill session for sequential pasting
struct BundleSession {
    let bundle: ClipBundle
    var currentIndex: Int
    
    /// Whether all items have been pasted
    var isDone: Bool {
        currentIndex >= bundle.itemIDs.count
    }
    
    /// The ID of the next item to paste (nil if done)
    var nextItemID: UUID? {
        guard currentIndex < bundle.itemIDs.count else { return nil }
        return bundle.itemIDs[currentIndex]
    }
    
    /// Progress percentage (0.0 to 1.0)
    var progress: Double {
        guard !bundle.itemIDs.isEmpty else { return 1.0 }
        return Double(currentIndex) / Double(bundle.itemIDs.count)
    }
    
    /// Progress text for display (e.g., "2 of 5")
    var progressText: String {
        "\(currentIndex) of \(bundle.itemIDs.count)"
    }
}
