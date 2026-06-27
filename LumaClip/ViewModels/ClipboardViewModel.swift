// ClipboardViewModel.swift
// LumaClip - macOS Clipboard Manager
//
// Primary ViewModel for the clipboard history UI.
// Manages item list, selection, sidebar filter, search,
// and all user actions (copy, delete, restore, favorite, etc.)

import Foundation
import Combine
import AppKit
import SwiftUI          // withAnimation for animated delete/restore

// MARK: - Focus Zone

/// Which "column" currently holds keyboard focus. Drives the Finder-like
/// column-view navigation: arrows move within the current zone; ←/→ shift
/// the active zone left/right. MainPanelView owns the transitions between
/// zones (e.g. opening the drawer when focus enters it).
enum FocusZone: Equatable {
    case sidebar
    case list
    case drawer
}

// MARK: - Clipboard ViewModel

@MainActor
final class ClipboardViewModel: ObservableObject {

    // MARK: - Published State

    /// Current sidebar selection
    @Published var activeFilter: SidebarFilter = .all

    /// All displayed items for current filter
    @Published var items: [ClipboardItem] = []

    /// Pre-partitioned lists — updated in loadData() to avoid
    /// re-filtering on every SwiftUI body evaluation.
    @Published var pinnedItems: [ClipboardItem] = []
    @Published var unpinnedItems: [ClipboardItem] = []

    /// Fast O(1) category lookup by ID — rebuilt in loadData().
    private(set) var categoryMap: [UUID: Category] = [:]

    /// Currently selected item (for detail panel)
    @Published var selectedItem: ClipboardItem?

    /// IDs of all items in the current multi-selection (Cmd+click)
    @Published var selectedItems: Set<UUID> = []

    /// True when two or more items are multi-selected
    var isMultiSelectMode: Bool { !selectedItems.isEmpty }

    /// Search query text
    @Published var searchQuery: String = ""

    /// Active content type filter (nil = show all types)
    @Published var selectedContentType: ContentType? = nil

    /// Available categories
    @Published var categories: [Category] = []

    /// Retention rules
    @Published var retentionRules: [RetentionRule] = []

    /// Loading state
    @Published var isLoading: Bool = false

    /// Item counts for sidebar badges
    @Published var allCount: Int = 0
    @Published var favoritesCount: Int = 0
    @Published var recentCount: Int = 0
    @Published var trashCount: Int = 0

    /// Keyboard-navigated selection index
    @Published var selectedIndex: Int = 0

    /// Whether the main panel is visible
    @Published var isPanelVisible: Bool = false

    /// Fires every time showPanel() is called, even if the panel is already visible.
    /// This ensures the window always comes to front.
    let showPanelRequested = PassthroughSubject<Void, Never>()

    /// Pulse animation trigger for new copies
    @Published var newCopyPulse: Bool = false

    /// ID of the item currently being hovered over as a drag drop target
    @Published var dropTargetID: UUID? = nil

    /// FIFO queue of clip IDs the user has staged for sequential pasting.
    /// "Paste Next" pops the front and copies it to the system clipboard;
    /// the user then presses ⌘V in whichever app is frontmost. Survives
    /// across list reloads because it stores IDs, not ClipboardItem
    /// structs. Cleared on app quit.
    @Published var pasteQueue: [UUID] = []

    // ── Keyboard coordination signals ───────────────────────────
    /// Toggled by Right arrow — request to move keyboard focus rightward
    /// (sidebar → list → Inspector). MainPanelView is the listener and
    /// owns the actual focus-zone transitions. → behaves like Finder's
    /// column view: focus jumps across columns rather than just toggling
    /// a panel. (The Inspector itself is now a fixed column, so there's
    /// no open/close semantics to coordinate.)
    @Published var focusRightRequested: Bool = false
    /// Toggled by Left arrow — request to move keyboard focus leftward
    /// (drawer → list → sidebar). MainPanelView decides whether to also
    /// hide the drawer (per design: it stays visible — only focus moves).
    @Published var focusLeftRequested: Bool = false
    /// Which UI zone currently holds keyboard focus. Used by the keyboard
    /// handler to dispatch ↑/↓ (move within zone) and by views to render
    /// a subtle focus ring on the active column. MainPanelView is the
    /// authoritative writer; other views read.
    @Published var focusedZone: FocusZone = .list
    /// Set true by ⌘F to request search field focus
    /// Toggled when Enter key copies an item — lets list show toast
    @Published var keyboardCopyPerformed: Bool = false

    // ── Row exit-animation state (shared by list + detail panel) ─────
    /// IDs currently playing their delete-exit animation
    @Published var deletingIDs:  Set<UUID> = []
    /// IDs currently playing their restore-exit animation
    @Published var restoringIDs: Set<UUID> = []
    /// IDs showing the brief green flash before restoring
    @Published var flashingIDs:  Set<UUID> = []

    /// Custom sort order (populated by drag-reorder). Persisted across
    /// launches via `UserDefaults` under `customOrderUUIDs` so that a
    /// user's manual arrangement survives app restart. We only keep it
    /// when the user has actually reordered something — an empty array
    /// falls back to the natural pinned/chronological sort in `loadData`.
    private var customOrder: [UUID] = [] {
        didSet { Self.persistCustomOrder(customOrder) }
    }

    /// Key the order lives under. Captured as a constant so callers below
    /// can't typo-drift the string.
    private static let customOrderDefaultsKey = "customOrderUUIDs"

    /// Read the persisted custom order at VM construction time.
    /// Returns an empty array when the key is missing or malformed.
    private static func loadPersistedCustomOrder() -> [UUID] {
        guard let raw = UserDefaults.standard.stringArray(forKey: customOrderDefaultsKey)
        else { return [] }
        return raw.compactMap(UUID.init(uuidString:))
    }

    /// Persist the order as a string array (UserDefaults has no UUID codec).
    /// An empty array clears the key to avoid carrying stale orderings
    /// forward after the user resets their arrangement.
    private static func persistCustomOrder(_ order: [UUID]) {
        let ud = UserDefaults.standard
        if order.isEmpty {
            ud.removeObject(forKey: customOrderDefaultsKey)
        } else {
            ud.set(order.map(\.uuidString), forKey: customOrderDefaultsKey)
        }
    }

    // MARK: - Bundle Support

    /// All saved bundles (drives the Bundles section in sidebar)
    @Published var bundles: [ClipBundle] = []

    /// Active form-fill session (nil when idle)
    @Published var activeBundleSession: BundleSession? = nil

    /// Whether the "create bundle" sheet is showing
    @Published var isCreatingBundle: Bool = false

    // MARK: - Dependencies

    private let database = DatabaseService.shared
    private let clipboardService = ClipboardService.shared
    private let retentionService = RetentionService.shared
    private let bundleService = BundleService.shared
    private var cancellables = Set<AnyCancellable>()

    /// Guard to prevent cascading observer loads
    private var isSwitchingFilter = false

    // MARK: - Undo / Redo

    /// Session-scoped undo history for destructive actions. Surfaced
    /// as @Published so the menu bar can bind Edit → Undo / Redo to
    /// `canUndo` / `canRedo` without polling.
    @Published private(set) var undoRegistry = UndoRegistry()

    /// Re-entry flag: when an undo or redo replays a mutation, the
    /// mutation function should NOT re-record into the stack (that
    /// would break the invariant that the redo stack is walkable).
    /// Guarded by the main-actor boundary so no lock is needed.
    private var isReplayingHistory = false

    // MARK: - Init

    init() {
        // Seed from the persisted order BEFORE the first loadData() so
        // the list renders in the user's saved arrangement on launch
        // rather than popping from chronological → custom after a frame.
        customOrder = Self.loadPersistedCustomOrder()
        setupObservers()
        loadData()
        syncBundles()
    }

    // MARK: - Smart Search Parsing

    /// Parse `type:`, `from:`, `date:`, `pinned:`, `fav:` operator tokens
    /// from the raw query string. Returns the residual text query plus extracted filters.
    struct ParsedSearch {
        var text: String = ""
        var contentType: ContentType? = nil    // type:url / type:text / …
        var sourceApp: String? = nil           // from:Safari
        var dateRange: SearchFilter.DateRange = .all  // date:today / date:week / date:month
        var pinnedOnly: Bool = false           // pinned:yes
        var favOnly: Bool = false              // fav:yes
    }

    func parseSearch(_ raw: String) -> ParsedSearch {
        var result = ParsedSearch()
        var remaining: [String] = []

        for token in raw.components(separatedBy: .whitespaces) where !token.isEmpty {
            let lower = token.lowercased()
            if lower.hasPrefix("type:") {
                let val = String(token.dropFirst(5)).lowercased()
                result.contentType = ContentType.allCases.first {
                    $0.rawValue.lowercased() == val || $0.label.lowercased() == val
                }
            } else if lower.hasPrefix("from:") {
                result.sourceApp = String(token.dropFirst(5))
            } else if lower.hasPrefix("date:") {
                let val = String(token.dropFirst(5)).lowercased()
                switch val {
                case "today":       result.dateRange = .today
                case "week":        result.dateRange = .thisWeek
                case "month":       result.dateRange = .thisMonth
                default: break
                }
            } else if lower == "pinned:yes" || lower == "pinned:true" {
                result.pinnedOnly = true
            } else if lower == "fav:yes" || lower == "fav:true" || lower == "favorite:yes" {
                result.favOnly = true
            } else {
                remaining.append(token)
            }
        }
        result.text = remaining.joined(separator: " ")
        return result
    }

    // MARK: - Data Loading

    /// Load all data from database.
    /// - Parameter skipCounts: when `true`, skip the 4 sidebar badge count queries.
    ///   Used during search-triggered reloads where counts haven't changed.
    func loadData(skipCounts: Bool = false) {
        isLoading = true

        // Parse search operators out of the raw query
        let parsed = parseSearch(searchQuery)
        let ftsQuery = parsed.text.isEmpty ? nil : parsed.text

        var fetched = database.fetchItems(
            filter: activeFilter,
            searchQuery: ftsQuery
        )

        // Operator: type:
        let effectiveContentType = parsed.contentType ?? selectedContentType
        if let contentType = effectiveContentType {
            fetched = fetched.filter { $0.contentType == contentType }
        }

        // Operator: from:
        if let app = parsed.sourceApp, !app.isEmpty {
            fetched = fetched.filter {
                $0.sourceApp.localizedCaseInsensitiveContains(app)
            }
        }

        // Operator: date:
        fetched = applyDateRange(fetched, range: parsed.dateRange)

        // Operator: pinned:yes
        if parsed.pinnedOnly {
            fetched = fetched.filter { $0.isPinned }
        }

        // Operator: fav:yes
        if parsed.favOnly {
            fetched = fetched.filter { $0.isFavorite }
        }

        // Legacy chip filter (when no type: operator present)
        if parsed.contentType == nil, let contentType = selectedContentType {
            fetched = fetched.filter { $0.contentType == contentType }
        }

        // Re-apply any custom order the user set via drag. The order is
        // persisted across launches, so on first load after relaunch we
        // prune stale IDs (items deleted/purged in a prior session) and
        // rewrite the stored copy — keeps drag reorder stable and caps
        // UserDefaults growth.
        if !customOrder.isEmpty {
            let currentIDs = Set(fetched.map(\.id))
            let pruned = customOrder.filter { currentIDs.contains($0) }
            if pruned != customOrder {
                customOrder = pruned
            }
            let orderMap = Dictionary(uniqueKeysWithValues:
                customOrder.enumerated().map { ($1, $0) })
            items = fetched.sorted {
                let ia = orderMap[$0.id] ?? Int.max
                let ib = orderMap[$1.id] ?? Int.max
                return ia < ib
            }
        } else {
            items = fetched
        }

        categories = database.fetchCategories()
        retentionRules = database.fetchRetentionRules()

        // Pre-partition pinned/unpinned so views don't re-filter on every body call
        pinnedItems = items.filter { $0.isPinned }
        unpinnedItems = items.filter { !$0.isPinned }

        // Build O(1) category lookup map
        categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        if !skipCounts { updateCounts() }

        // Preserve selection if possible, and always sync selectedIndex
        // to the item's new position (it may have shifted after pin/unpin/sort).
        if let selected = selectedItem,
           let newIndex = items.firstIndex(where: { $0.id == selected.id }) {
            selectedItem = items[newIndex]
            selectedIndex = newIndex
        } else {
            selectedItem = items.first
            selectedIndex = 0
        }

        isLoading = false
    }

    /// Update sidebar badge counts
    private func updateCounts() {
        allCount = database.itemCount(filter: .all)
        favoritesCount = database.itemCount(filter: .favorites)
        recentCount = database.itemCount(filter: .recent)
        trashCount = database.itemCount(filter: .trash)
    }

    /// Apply a date range filter to an item array (in-memory)
    private func applyDateRange(_ items: [ClipboardItem], range: SearchFilter.DateRange) -> [ClipboardItem] {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .all: return items
        case .today:
            let start = cal.startOfDay(for: now)
            return items.filter { $0.createdAt >= start }
        case .thisWeek:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            guard let start = cal.date(from: comps) else { return items }
            return items.filter { $0.createdAt >= start }
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            guard let start = cal.date(from: comps) else { return items }
            return items.filter { $0.createdAt >= start }
        case .custom(let from, let to):
            return items.filter { $0.createdAt >= from && $0.createdAt <= to }
        }
    }

    /// A one-line hint describing active smart search operators (shown in UI)
    var searchHint: String? {
        guard !searchQuery.isEmpty else { return nil }
        let p = parseSearch(searchQuery)
        var hints: [String] = []
        if let t = p.contentType  { hints.append("type:\(t.label)") }
        if let a = p.sourceApp    { hints.append("from:\(a)") }
        if p.dateRange != .all    { hints.append("date:\(p.dateRange.label)") }
        if p.pinnedOnly           { hints.append("pinned") }
        if p.favOnly              { hints.append("favorites") }
        if !p.text.isEmpty        { hints.append("\"\(p.text)\"") }
        return hints.isEmpty ? nil : hints.joined(separator: " · ")
    }

    // MARK: - Sidebar Navigation

    /// Switch the active sidebar filter. Resets search, content type chip,
    /// and selection, then reloads data exactly once (no cascading).
    func switchFilter(_ filter: SidebarFilter) {
        // Any path into switchFilter is a sidebar interaction (a click,
        // an arrow-key nav, the global hotkey to jump to a section), so
        // it should land focus in the sidebar zone. Set this BEFORE the
        // same-filter guard so re-clicking the already-active item still
        // moves keyboard focus there.
        focusedZone = .sidebar
        guard filter != activeFilter else { return }
        isSwitchingFilter = true
        searchQuery = ""
        selectedContentType = nil
        selectedIndex = 0
        activeFilter = filter
        isSwitchingFilter = false
        // Bundles and Settings are UI-only screens; no item load needed
        if case .bundles = filter { syncBundles(); return }
        if case .settings = filter { return }
        loadData()
    }

    // MARK: - Content Type Filter (chips)

    /// Apply or toggle a content-type chip filter. Calls loadData() directly
    /// so there's no Combine chain that can drop or delay the update.
    func applyContentFilter(_ type: ContentType) {
        if selectedContentType == type {
            selectedContentType = nil   // tap same chip → deselect
        } else {
            selectedContentType = type
        }
        selectedIndex = 0
        loadData()
    }

    func clearContentFilter() {
        guard selectedContentType != nil else { return }
        selectedContentType = nil
        selectedIndex = 0
        loadData()
    }

    // MARK: - Observers

    private func setupObservers() {
        // Reload when clipboard changes.
        // NotificationCenter posts on the same thread as the poster (main RunLoop timer),
        // so we use RunLoop.main scheduler to stay synchronous on main.
        NotificationCenter.default.publisher(for: .clipboardDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadData()
                self.triggerNewCopyPulse()
            }
            .store(in: &cancellables)

        // Reload after retention cleanup
        NotificationCenter.default.publisher(for: .retentionCleanupCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadData()
            }
            .store(in: &cancellables)

        // Debounced search — skip badge count queries (search doesn't change totals)
        $searchQuery
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.isSwitchingFilter else { return }
                self.loadData(skipCounts: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - User Actions

    /// Copy item content to system clipboard (text or image)
    func copyItem(_ item: ClipboardItem) {
        clipboardService.copyItem(item)
    }

    /// Copy and dismiss panel
    func copyAndDismiss(_ item: ClipboardItem) {
        copyItem(item)
        isPanelVisible = false
    }

    /// Soft delete item (move to trash)
    func deleteItem(_ item: ClipboardItem) {
        if !isReplayingHistory {
            undoRegistry.record(.deletion(itemID: item.id))
        }
        database.softDeleteItem(id: item.id)
        if selectedItem?.id == item.id {
            selectedItem = nil
        }
        loadData()
    }

    /// Restore item from trash
    func restoreItem(_ item: ClipboardItem) {
        database.restoreItem(id: item.id)
        loadData()
    }

    /// Permanently delete item. Permanent deletes can't be reversed,
    /// so this also wipes any history pointing at the item — a stale
    /// undo entry here would otherwise fail silently later on.
    func permanentlyDeleteItem(_ item: ClipboardItem) {
        if !isReplayingHistory {
            // We don't know which direction the doomed item sat on the
            // stack (it could be a pending redo), so clear wholesale.
            undoRegistry.clear()
        }
        database.permanentlyDeleteItem(id: item.id)
        if selectedItem?.id == item.id {
            selectedItem = nil
        }
        loadData()
        // Reclaim any vault files this clip held (no-op for non-file clips).
        FileVaultService.shared.garbageCollect()
    }

    // MARK: - Animated Delete / Restore
    //
    // These wrap the data-mutation functions above with SwiftUI
    // exit animations so that both the list rows AND the detail
    // panel buttons trigger the same visual effects.

    /// Animated soft-delete: shrink-right + blur + fade, then data removal.
    func animateDelete(_ item: ClipboardItem) {
        _ = withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            deletingIDs.insert(item.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                self.deleteItem(item)
            }
            self.deletingIDs.remove(item.id)
        }
    }

    /// Animated permanent delete: faster, more decisive version.
    func animatePermanentDelete(_ item: ClipboardItem) {
        _ = withAnimation(.spring(response: 0.20, dampingFraction: 0.90)) {
            deletingIDs.insert(item.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                self.permanentlyDeleteItem(item)
            }
            self.deletingIDs.remove(item.id)
        }
    }

    /// Animated restore: green flash → slide-left + fade → data change.
    func animateRestore(_ item: ClipboardItem) {
        _ = withAnimation(.easeOut(duration: 0.12)) {
            flashingIDs.insert(item.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self else { return }
            _ = withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                self.restoringIDs.insert(item.id)
            }
            _ = withAnimation(.easeIn(duration: 0.12)) {
                self.flashingIDs.remove(item.id)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                self.restoreItem(item)
            }
            self.restoringIDs.remove(item.id)
        }
    }

    /// Empty entire trash
    func emptyTrash() {
        // Any pending undo pointing at a trashed item is now orphaned —
        // nothing in the DB to restore — so drop the whole stack rather
        // than let `undo` silently no-op and look broken.
        undoRegistry.clear()
        let trashItems = database.fetchItems(filter: .trash, limit: 10000)
        for item in trashItems {
            database.permanentlyDeleteItem(id: item.id)
        }
        loadData()
        // Reclaim vault files freed by emptying the trash.
        FileVaultService.shared.garbageCollect()
    }

    /// Toggle favorite status
    func toggleFavorite(_ item: ClipboardItem) {
        let current = items.first(where: { $0.id == item.id }) ?? item
        let newValue = !current.isFavorite
        if !isReplayingHistory {
            undoRegistry.record(.favoriteToggle(
                itemID: item.id, previousValue: current.isFavorite
            ))
        }
        database.toggleFavorite(id: item.id, isFavorite: newValue)
        loadData()
    }

    // MARK: - Paste Queue

    /// Add an item to the end of the paste queue. No-op if already queued.
    /// Clips stay in the queue until explicitly pasted or cleared, so the
    /// user can queue several and paste them into a form in order.
    func enqueueForPaste(_ item: ClipboardItem) {
        guard !pasteQueue.contains(item.id) else { return }
        pasteQueue.append(item.id)
    }

    /// Remove a single item from the queue (order-preserving).
    func dequeuePaste(_ itemID: UUID) {
        pasteQueue.removeAll { $0 == itemID }
    }

    /// Pop the front of the queue and copy that clip to the clipboard.
    /// Returns the item that was pasted (or nil if the queue was empty).
    /// Caller is expected to trigger ⌘V in the frontmost app; LumaClip
    /// doesn't synthesise the paste itself.
    @discardableResult
    func pasteNextInQueue() -> ClipboardItem? {
        guard !pasteQueue.isEmpty else { return nil }
        let nextID = pasteQueue.removeFirst()
        // Look up the item — prefer the in-memory list, fall back to DB
        // so a queued clip outside the current sidebar filter still works.
        let item = items.first(where: { $0.id == nextID })
            ?? database.fetchItem(id: nextID)
        guard let item else { return nil }
        clipboardService.copyItem(item)
        return item
    }

    /// Flush the queue without pasting.
    func clearPasteQueue() {
        pasteQueue.removeAll()
    }

    /// Toggle burn-after-paste flag. A burn-flagged item soft-deletes
    /// itself as soon as the system clipboard changes again (i.e. after
    /// the user pastes), or after a short timeout if nothing else is
    /// copied. Intended for one-shot sensitive content (tokens, 2FA codes).
    func toggleBurnAfterPaste(_ item: ClipboardItem) {
        let current = items.first(where: { $0.id == item.id }) ?? item
        database.toggleBurnAfterPaste(id: item.id, isBurn: !current.isBurnAfterPaste)
        loadData()
    }

    /// Toggle the manual "sensitive" marker. Auto-detected on insert
    /// via SensitivityDetector; this lets the user override either way.
    func toggleSensitive(_ item: ClipboardItem) {
        let current = items.first(where: { $0.id == item.id }) ?? item
        database.toggleSensitive(id: item.id, isSensitive: !current.isSensitive)
        loadData()
    }

    /// Toggle pin status.
    /// Always reads the current `isPinned` state from `items` (the authoritative
    /// in-memory list) to guard against stale captured struct values.
    func togglePin(_ item: ClipboardItem) {
        let current = items.first(where: { $0.id == item.id }) ?? item
        let newValue = !current.isPinned
        if !isReplayingHistory {
            undoRegistry.record(.pinToggle(
                itemID: item.id, previousValue: current.isPinned
            ))
        }
        database.togglePinned(id: item.id, isPinned: newValue)
        loadData()
    }

    /// Update item category (from ClipboardItem)
    func setCategory(_ item: ClipboardItem, categoryId: UUID?) {
        let current = items.first(where: { $0.id == item.id }) ?? item
        if !isReplayingHistory {
            undoRegistry.record(.categoryChange(
                itemID: item.id,
                previousCategoryId: current.categoryId,
                newCategoryId: categoryId
            ))
        }
        database.updateCategory(itemId: item.id, categoryId: categoryId)
        loadData()
    }

    /// Update item category by item UUID — used by drag-and-drop from sidebar
    func setCategory(itemId: UUID, categoryId: UUID?) {
        let previous = items.first(where: { $0.id == itemId })?.categoryId
        if !isReplayingHistory {
            undoRegistry.record(.categoryChange(
                itemID: itemId,
                previousCategoryId: previous,
                newCategoryId: categoryId
            ))
        }
        database.updateCategory(itemId: itemId, categoryId: categoryId)
        // Reset custom order so the item appears in its new category position
        customOrder = []
        loadData()
    }

    /// Drag-to-reorder: move `sourceID` to the position of `targetID`.
    func moveItem(_ sourceID: UUID, toPositionOf targetID: UUID) {
        // Build order from current display if none exists yet
        var order = customOrder.isEmpty ? items.map(\.id) : customOrder
        guard let srcIdx = order.firstIndex(of: sourceID),
              let dstIdx = order.firstIndex(of: targetID),
              srcIdx != dstIdx else { return }
        order.remove(at: srcIdx)
        let insertAt = srcIdx < dstIdx ? dstIdx : dstIdx
        order.insert(sourceID, at: insertAt)
        customOrder = order
        // Re-sort the live items array immediately (no DB round-trip needed)
        let orderMap = Dictionary(uniqueKeysWithValues:
            customOrder.enumerated().map { ($1, $0) })
        items = items.sorted {
            let ia = orderMap[$0.id] ?? Int.max
            let ib = orderMap[$1.id] ?? Int.max
            return ia < ib
        }
        dropTargetID = nil
    }

    /// Set item expiry
    func setExpiry(_ item: ClipboardItem, expiresAt: Date?) {
        database.setExpiry(itemId: item.id, expiresAt: expiresAt)
        loadData()
    }

    /// Update an entire clipboard item
    func updateItem(_ item: ClipboardItem) {
        database.updateItem(item)
        loadData()
    }

    /// Update an image item's data and dimensions after editing
    func updateImageItem(id: UUID, jpegData: Data, width: Int, height: Int) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.imageData = jpegData
        item.content = "Image \(width)×\(height)"
        database.updateItem(item)
        loadData()
    }

    // MARK: - Category Management

    /// Add a new category
    func addCategory(name: String, icon: String, color: CategoryColor) {
        let category = Category(name: name, icon: icon, color: color)
        database.insertCategory(category)
        loadData()
    }

    /// Update an existing category (name, icon, color)
    func updateCategory(_ category: Category) {
        database.insertCategory(category) // INSERT OR REPLACE
        loadData()
    }

    /// Delete a category
    func deleteCategory(_ category: Category) {
        database.deleteCategory(id: category.id)
        loadData()
    }

    // MARK: - Retention Rules

    /// Add a retention rule
    func addRetentionRule(_ rule: RetentionRule) {
        database.insertRetentionRule(rule)
        retentionService.applyRule(rule)
        loadData()
    }

    /// Delete a retention rule
    func deleteRetentionRule(_ rule: RetentionRule) {
        database.deleteRetentionRule(id: rule.id)
        loadData()
    }

    // MARK: - Undo / Redo

    /// True when there is at least one action the user can undo.
    /// Proxy into the registry so menu items can bind directly.
    var canUndo: Bool { undoRegistry.canUndo }

    /// True when there is at least one action the user can redo.
    var canRedo: Bool { undoRegistry.canRedo }

    /// Human-readable label for the next undo action (e.g. "Delete",
    /// "Pin") — useful for populating the standard "Undo Delete" menu
    /// title. Returns `nil` when the undo stack is empty.
    var undoLabel: String? {
        guard let action = undoRegistry.peekUndo else { return nil }
        return Self.label(for: action)
    }

    /// Counterpart to `undoLabel` for the redo side.
    var redoLabel: String? {
        guard let action = undoRegistry.peekRedo else { return nil }
        return Self.label(for: action)
    }

    private static func label(for action: UndoableAction) -> String {
        switch action {
        case .deletion:        return "Delete".loc
        case .pinToggle:       return "Pin".loc
        case .favoriteToggle:  return "Favorite".loc
        case .categoryChange:  return "Move to Category".loc
        }
    }

    /// Undo the most recent destructive action. Silently no-ops when
    /// the stack is empty or the target item has been permanently
    /// deleted (e.g. purged by retention between record and undo).
    func undo() {
        guard let action = undoRegistry.popForUndo() else { return }
        isReplayingHistory = true
        defer { isReplayingHistory = false }

        switch action {
        case .deletion(let itemID):
            // Item is in trash; restore it directly (bypassing the
            // `restoreItem` wrapper is fine — restore has no inverse
            // to track, and we want the loadData to happen once below).
            database.restoreItem(id: itemID)

        case .pinToggle(let itemID, let previousValue):
            // Undo pin by setting back to previous state (NOT toggling
            // the current value — another mutation could have flipped it).
            database.togglePinned(id: itemID, isPinned: previousValue)

        case .favoriteToggle(let itemID, let previousValue):
            database.toggleFavorite(id: itemID, isFavorite: previousValue)

        case .categoryChange(let itemID, let previousCategoryId, _):
            database.updateCategory(itemId: itemID, categoryId: previousCategoryId)
        }
        loadData()
    }

    /// Redo the most recently undone action. Mirror image of `undo()`.
    func redo() {
        guard let action = undoRegistry.popForRedo() else { return }
        isReplayingHistory = true
        defer { isReplayingHistory = false }

        switch action {
        case .deletion(let itemID):
            // Re-apply the delete.
            database.softDeleteItem(id: itemID)
            if selectedItem?.id == itemID { selectedItem = nil }

        case .pinToggle(let itemID, let previousValue):
            // Redo = the opposite of "previousValue" (i.e., forward).
            database.togglePinned(id: itemID, isPinned: !previousValue)

        case .favoriteToggle(let itemID, let previousValue):
            database.toggleFavorite(id: itemID, isFavorite: !previousValue)

        case .categoryChange(let itemID, _, let newCategoryId):
            database.updateCategory(itemId: itemID, categoryId: newCategoryId)
        }
        loadData()
    }

    // MARK: - Keyboard Navigation

    /// Move selection up
    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        selectedItem = items[selectedIndex]
    }

    /// Move selection down
    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
        selectedItem = items[selectedIndex]
    }

    // MARK: - Sidebar Keyboard Navigation

    /// The ordered list of sidebar items the user can land on with the
    /// keyboard. Mirrors SidebarView's visual order. Categories expand
    /// inline so they're spliced in between Recent and Bundles. "Pinned"
    /// is intentionally excluded — it's not a real filter, just a section
    /// of the All view, so it would dead-end keyboard nav.
    var navigableSidebarFilters: [SidebarFilter] {
        var list: [SidebarFilter] = [.all, .favorites, .recent]
        list.append(contentsOf: categories.map { .category($0.id) })
        list.append(contentsOf: [.bundles, .trash, .settings])
        return list
    }

    /// Move sidebar highlight to the previous navigable item (live-commits
    /// `activeFilter`, matching the click behaviour). No-op at the top.
    func moveSidebarSelectionUp() {
        let order = navigableSidebarFilters
        guard let i = order.firstIndex(of: activeFilter), i > 0 else { return }
        switchFilter(order[i - 1])
    }

    /// Move sidebar highlight to the next navigable item. No-op at the bottom.
    func moveSidebarSelectionDown() {
        let order = navigableSidebarFilters
        guard let i = order.firstIndex(of: activeFilter), i < order.count - 1 else { return }
        switchFilter(order[i + 1])
    }

    /// Copy the selected item (without dismissing the panel)
    func copySelected() {
        guard let item = selectedItem else { return }
        copyItem(item)
        keyboardCopyPerformed.toggle()
    }

    /// Select and copy current item, then dismiss panel
    func selectCurrent() {
        guard let item = selectedItem else { return }
        copyAndDismiss(item)
    }

    /// Toggle pin on the currently selected item
    func pinSelected() {
        guard let item = selectedItem else { return }
        togglePin(item)
    }

    /// Delete the currently selected item (trash or permanent delete)
    func deleteSelected() {
        guard let item = selectedItem else { return }
        if case .trash = activeFilter {
            animatePermanentDelete(item)
        } else {
            animateDelete(item)
        }
    }

    // MARK: - Multi-Select

    /// Toggle an item in/out of the multi-selection set.
    func toggleMultiSelection(_ item: ClipboardItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
        // Keep the detail panel tracking the most-recently toggled item
        selectedItem = item
    }

    /// Clear the entire multi-selection.
    func clearMultiSelection() {
        selectedItems = []
    }

    /// Select all currently visible items.
    func selectAll() {
        selectedItems = Set(items.map(\.id))
    }

    /// Whether every visible item is currently selected.
    var isAllSelected: Bool {
        !items.isEmpty && selectedItems.count == items.count
    }

    /// Animated batch delete for all currently multi-selected items.
    /// Uses the same shrink-right + blur exit animation as single-item deletes.
    func deleteMultiSelected() {
        let targets = items.filter { selectedItems.contains($0.id) }
        guard !targets.isEmpty else { return }

        // Kick off exit animations for all targets simultaneously
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            for item in targets { deletingIDs.insert(item.id) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                for item in targets {
                    if case .trash = self.activeFilter {
                        self.database.permanentlyDeleteItem(id: item.id)
                    } else {
                        self.database.softDeleteItem(id: item.id)
                    }
                }
                self.selectedItems = []
                if let sel = self.selectedItem, targets.contains(where: { $0.id == sel.id }) {
                    self.selectedItem = nil
                }
                self.loadData()
            }
            for item in targets { self.deletingIDs.remove(item.id) }
        }
    }

    // MARK: - Panel Visibility

    /// Toggle main panel
    func togglePanel() {
        isPanelVisible.toggle()
        if isPanelVisible {
            loadData()
            focusNewestItem()
        }
    }

    /// Show main panel (always brings to front, even if already visible)
    func showPanel() {
        isPanelVisible = true
        loadData()
        focusNewestItem()
        showPanelRequested.send()
    }

    /// Move keyboard focus to the most-recent clip whenever the panel
    /// opens, so the user lands on the latest item instead of wherever
    /// the previous selection happened to be. The list view observes
    /// `selectedIndex` and scrolls the highlighted row into view.
    private func focusNewestItem() {
        focusedZone = .list
        guard !items.isEmpty else {
            selectedItem = nil
            selectedIndex = 0
            return
        }
        // The list is ordered pinned-first, so `items.first` may be an
        // older pinned clip. The "latest item" the user just copied is the
        // one with the most recent timestamp — find it explicitly.
        let newestIndex = items.indices.max { items[$0].createdAt < items[$1].createdAt } ?? 0
        // Nudge selectedIndex first so the list's onChange scroll fires
        // even when the target was already the current selection.
        if selectedIndex == newestIndex { selectedIndex = -1 }
        selectedItem = items[newestIndex]
        selectedIndex = newestIndex
    }

    /// Hide main panel
    func hidePanel() {
        isPanelVisible = false
    }

    // MARK: - Animations

    /// Trigger new copy pulse on floating button
    private func triggerNewCopyPulse() {
        newCopyPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.newCopyPulse = false
        }
    }

    // MARK: - Helpers

    /// Get category for an item
    func category(for item: ClipboardItem) -> Category? {
        guard let catId = item.categoryId else { return nil }
        return categoryMap[catId]
    }

    /// Count items in a specific category
    func categoryCount(for categoryId: UUID) -> Int {
        database.itemCount(filter: .category(categoryId))
    }

    // MARK: - Bundle Management

    /// Keep `bundles` in sync with BundleService
    func syncBundles() {
        bundles = bundleService.bundles
    }

    func createBundle(name: String, icon: String, color: CategoryColor, itemIDs: [UUID] = []) {
        let bundle = ClipBundle(name: name, icon: icon, colorName: color.rawValue, itemIDs: itemIDs)
        bundleService.save(bundle)
        syncBundles()
    }

    func saveBundle(_ bundle: ClipBundle) {
        bundleService.save(bundle)
        syncBundles()
    }

    func deleteBundle(_ bundle: ClipBundle) {
        bundleService.delete(bundle)
        syncBundles()
    }

    func activateBundle(_ bundle: ClipBundle) {
        startBundleSession(bundle)
    }

    func addItemToBundle(_ item: ClipboardItem, bundle: ClipBundle) {
        bundleService.appendItem(item.id, to: bundle.id)
        syncBundles()
    }

    func removeItemFromBundle(_ itemID: UUID, bundle: ClipBundle) {
        bundleService.removeItem(itemID, from: bundle.id)
        syncBundles()
    }

    // MARK: - Form-Fill Mode

    /// Start a sequential paste session for a bundle.
    /// The first item is immediately copied to the clipboard.
    func startBundleSession(_ bundle: ClipBundle) {
        let session = BundleSession(bundle: bundle, currentIndex: 0)
        activeBundleSession = session
        advanceBundleSession()
    }

    /// Copy the next item in the active bundle session to the clipboard.
    func advanceBundleSession() {
        guard var session = activeBundleSession else { return }
        guard !session.isDone else {
            activeBundleSession = nil
            return
        }
        if let nextID = session.nextItemID,
           let item = items.first(where: { $0.id == nextID })
              ?? database.fetchItems(filter: .all, limit: 10000).first(where: { $0.id == nextID }) {
            copyItem(item)
        }
        session.currentIndex += 1
        activeBundleSession = session.isDone ? nil : session
    }

    /// Cancel the active bundle session.
    func cancelBundleSession() {
        activeBundleSession = nil
    }

    /// Resolve a bundle to the ClipboardItems it references (in order).
    func resolveBundle(_ bundle: ClipBundle) -> [ClipboardItem] {
        let allItems = database.fetchItems(filter: .all, limit: 50000)
        let lookup = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        return bundle.itemIDs.compactMap { lookup[$0] }
    }
}
