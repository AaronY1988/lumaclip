// SidebarFilter.swift
// LumaClip - macOS Clipboard Manager
//
// Enum representing the different sidebar navigation options.
// Used by DatabaseService to filter clipboard items.

import Foundation

// MARK: - Sidebar Filter

/// Represents different views/filters available in the sidebar
enum SidebarFilter: Equatable, Hashable {
    case all
    case favorites
    case recent
    case category(UUID)
    case trash
    case bundles
    case settings
    
    // MARK: - Display Properties
    
    var label: String {
        switch self {
        case .all:
            return "All Items".loc
        case .favorites:
            return "Favorites".loc
        case .recent:
            return "Recent".loc
        case .category:
            return "Category".loc
        case .trash:
            return "Trash".loc
        case .bundles:
            return "Bundles".loc
        case .settings:
            return "Settings".loc
        }
    }
    
    var iconName: String {
        switch self {
        case .all:
            return "doc.on.doc"
        case .favorites:
            return "star.fill"
        case .recent:
            return "clock"
        case .category:
            return "folder"
        case .trash:
            return "trash"
        case .bundles:
            return "square.stack.3d.up"
        case .settings:
            return "gearshape"
        }
    }
    
    // MARK: - Equatable & Hashable
    
    static func == (lhs: SidebarFilter, rhs: SidebarFilter) -> Bool {
        switch (lhs, rhs) {
        case (.all, .all),
             (.favorites, .favorites),
             (.recent, .recent),
             (.trash, .trash),
             (.bundles, .bundles),
             (.settings, .settings):
            return true
        case (.category(let lhsId), .category(let rhsId)):
            return lhsId == rhsId
        default:
            return false
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .all:
            hasher.combine("all")
        case .favorites:
            hasher.combine("favorites")
        case .recent:
            hasher.combine("recent")
        case .category(let id):
            hasher.combine("category")
            hasher.combine(id)
        case .trash:
            hasher.combine("trash")
        case .bundles:
            hasher.combine("bundles")
        case .settings:
            hasher.combine("settings")
        }
    }
}
