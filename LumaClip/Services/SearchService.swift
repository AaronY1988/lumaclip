// SearchService.swift
// LumaClip - macOS Clipboard Manager
//
// Provides search functionality with debouncing and filtering.
// Wraps DatabaseService's FTS5 full-text search with additional
// in-memory filtering capabilities.

import Foundation
import Combine

// MARK: - Search Filter

/// Configurable search filter parameters
struct SearchFilter: Equatable {
    var query: String = ""
    var contentType: ContentType? = nil
    var categoryId: UUID? = nil
    var favoritesOnly: Bool = false
    var dateRange: DateRange = .all

    enum DateRange: Equatable {
        case all
        case today
        case thisWeek
        case thisMonth
        case custom(from: Date, to: Date)

        var label: String {
            switch self {
            case .all:       return "All Time"
            case .today:     return "Today"
            case .thisWeek:  return "This Week"
            case .thisMonth: return "This Month"
            case .custom:    return "Custom"
            }
        }

        static let allCases: [DateRange] = [.all, .today, .thisWeek, .thisMonth]
    }

    var isEmpty: Bool {
        query.isEmpty && contentType == nil && categoryId == nil && !favoritesOnly && dateRange == .all
    }
}

// MARK: - Search Service

final class SearchService: ObservableObject {
    static let shared = SearchService()

    @Published var filter = SearchFilter()
    @Published var results: [ClipboardItem] = []
    @Published var isSearching: Bool = false

    private let database = DatabaseService.shared
    private var searchCancellable: AnyCancellable?
    private let searchQueue = DispatchQueue(label: "com.lumaclip.search", qos: .userInteractive)

    private init() {
        setupDebounce()
    }

    // MARK: - Debounced Search

    /// Setup debounced search on filter changes
    private func setupDebounce() {
        searchCancellable = $filter
            .debounce(for: .milliseconds(150), scheduler: searchQueue)
            .removeDuplicates()
            .sink { [weak self] filter in
                self?.executeSearch(filter: filter)
            }
    }

    /// Execute search with current filter
    private func executeSearch(filter: SearchFilter) {
        DispatchQueue.main.async { [weak self] in
            self?.isSearching = true
        }

        var sidebarFilter: SidebarFilter = .all
        if filter.favoritesOnly {
            sidebarFilter = .favorites
        } else if let catId = filter.categoryId {
            sidebarFilter = .category(catId)
        }

        let query = filter.query.isEmpty ? nil : filter.query

        var items = database.fetchItems(
            filter: sidebarFilter,
            searchQuery: query,
            limit: 500
        )

        // Apply content type filter
        if let contentType = filter.contentType {
            items = items.filter { $0.contentType == contentType }
        }

        // Apply date range filter
        items = applyDateFilter(items, range: filter.dateRange)

        DispatchQueue.main.async { [weak self] in
            self?.results = items
            self?.isSearching = false
        }
    }

    // MARK: - Date Filtering

    private func applyDateFilter(_ items: [ClipboardItem], range: SearchFilter.DateRange) -> [ClipboardItem] {
        let calendar = Calendar.current
        let now = Date()

        switch range {
        case .all:
            return items
        case .today:
            let startOfDay = calendar.startOfDay(for: now)
            return items.filter { $0.createdAt >= startOfDay }
        case .thisWeek:
            guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
            else { return items }
            return items.filter { $0.createdAt >= weekStart }
        case .thisMonth:
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            else { return items }
            return items.filter { $0.createdAt >= monthStart }
        case .custom(let from, let to):
            return items.filter { $0.createdAt >= from && $0.createdAt <= to }
        }
    }

    // MARK: - Quick Actions

    /// Clear search filter
    func clearSearch() {
        filter = SearchFilter()
    }

    /// Search for specific text
    func search(_ text: String) {
        filter.query = text
    }
}
