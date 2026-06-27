// TokenSearchBar.swift
// LumaClip — macOS Clipboard Manager
//
// Token/chip-based search UI that sits on top of the existing
// string-based parseSearch() backend. Tokens are visual chips
// representing operator:value pairs (type:url, from:Safari, etc.)
// The bar serialises them back into the raw searchQuery string
// the ViewModel already understands.

import SwiftUI

// MARK: - Search Token Model

/// A single search filter token displayed as a chip.
struct SearchToken: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let value: String

    enum Kind: String, CaseIterable {
        case type    = "type"
        case from    = "from"
        case date    = "date"
        case pinned  = "pinned"
        case fav     = "fav"

        var label: String {
            switch self {
            case .type:   return "Type"
            case .from:   return "From"
            case .date:   return "Date"
            case .pinned: return "Pinned"
            case .fav:    return "Favorites"
            }
        }

        var icon: String {
            switch self {
            case .type:   return "doc"
            case .from:   return "app.badge"
            case .date:   return "calendar"
            case .pinned: return "pin"
            case .fav:    return "star"
            }
        }

        var color: Color {
            switch self {
            case .type:   return Color(hue: 0.58, saturation: 0.60, brightness: 0.78)  // blue
            case .from:   return Color(hue: 0.78, saturation: 0.48, brightness: 0.72)  // muted purple
            case .date:   return Color(hue: 0.08, saturation: 0.65, brightness: 0.85)  // warm orange
            case .pinned: return Color(hue: 0.08, saturation: 0.65, brightness: 0.85)  // warm orange
            case .fav:    return Color(hue: 0.13, saturation: 0.75, brightness: 0.90)  // gold
            }
        }
    }

    /// The raw string representation this token serialises to
    /// (e.g. "type:url", "from:Safari", "pinned:yes").
    var serialized: String {
        "\(kind.rawValue):\(value)"
    }
}

// MARK: - Autocomplete Suggestion

struct SearchSuggestion: Identifiable, Equatable {
    let id = UUID()
    let display: String       // shown in dropdown
    let icon: String          // SF Symbol
    let token: SearchToken    // what gets inserted on pick
}

// MARK: - Token Search Bar View

struct TokenSearchBarView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings

    private var isLight: Bool { colorScheme == .light }

    /// Structured tokens currently active.
    @State private var tokens: [SearchToken] = []

    /// Free text portion (what the user is currently typing).
    @State private var freeText: String = ""

    /// Whether autocomplete is showing.
    @State private var showSuggestions: Bool = false

    /// Which suggestion is keyboard-highlighted (-1 = none).
    @State private var highlightedSuggestion: Int = -1

    @FocusState private var isTextFieldFocused: Bool

    /// Tracks whether we're currently syncing to avoid loops.
    private var isSyncing = false

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
    }

    // ── Known source apps (derived from loaded items) ─────────
    private var knownApps: [String] {
        let apps = Set(viewModel.items.map(\.sourceApp).filter { !$0.isEmpty })
        return apps.sorted()
    }

    var body: some View {
        let palette = LumaPalette(scheme: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            // ── Main bar ────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textTertiary)

                // Tokens + inline text field
                tokenFlow

                // Clear all
                if !tokens.isEmpty || !freeText.isEmpty {
                    Button { clearAll() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all filters".loc)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Spec §5.2: paper-toned input on a faint hairline.
                // The previous translucent grey overlay clashed with the
                // editorial cream appBg; a flat searchBg + 0.5pt border
                // reads cleaner.
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .fill(palette.searchBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .strokeBorder(
                                isTextFieldFocused
                                    ? palette.borderStrong
                                    : palette.borderDefault,
                                lineWidth: 0.5
                            )
                    )
            )
            .animation(LumaDesign.Motion.quick, value: isTextFieldFocused)
            .onTapGesture {
                isTextFieldFocused = true
            }

            // ── Autocomplete dropdown ───────────────────────────
            if showSuggestions, !suggestions.isEmpty {
                suggestionsDropdown
            }
        }
        // ── Sync: tokens + freeText → viewModel.searchQuery ─────
        .onChange(of: tokens) { _ in syncToViewModel() }
        .onChange(of: freeText) { newText in
            syncToViewModel()
            updateSuggestions(for: newText)
        }
        // ── Sync: viewModel.searchQuery → tokens (initial load) ─
        .onAppear {
            syncFromViewModel()
        }
    }

    // MARK: - Token Flow Layout

    /// Horizontal flow of chips + inline text field.
    private var tokenFlow: some View {
        HStack(spacing: 4) {
            ForEach(tokens) { token in
                TokenChipView(token: token) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        removeToken(token)
                    }
                }
            }

            // Inline text field for free typing
            InlineSearchField(
                text: $freeText,
                isFocused: _isTextFieldFocused,
                placeholder: tokens.isEmpty ? "Search clips, type, source, or date…" : "Add filter…",
                onBackspace: { handleBackspace() },
                onReturn: { handleReturn() },
                onArrowDown: { moveSuggestion(1) },
                onArrowUp: { moveSuggestion(-1) },
                onEscape: {
                    // Clear everything and resign focus
                    showSuggestions = false
                    freeText = ""
                    tokens = []
                    viewModel.searchQuery = ""
                    isTextFieldFocused = false
                    // Redirect focus back to the content view so the list
                    // regains keyboard navigation immediately. Capture the
                    // window we're currently in; if the panel has closed or
                    // changed key status by the time the async runs, do
                    // nothing instead of poking an unrelated window's
                    // first-responder chain.
                    let sourceWindow = NSApp.keyWindow
                    DispatchQueue.main.async {
                        guard let window = sourceWindow,
                              window === NSApp.keyWindow,
                              let contentView = window.contentView
                        else { return }
                        window.makeFirstResponder(contentView)
                    }
                }
            )
            .frame(minWidth: 80)
        }
    }

    // MARK: - Suggestions Dropdown

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    applySuggestion(suggestion)
                } label: {
                    suggestionRow(
                        suggestion: suggestion,
                        isHighlighted: index == highlightedSuggestion
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark
                      ? Color(NSColor.windowBackgroundColor)
                      : Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12),
                        radius: 12, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.06),
                                lineWidth: 0.5)
                )
        )
        .padding(.top, 4)
    }

    private func suggestionRow(suggestion: SearchSuggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 11))
                .foregroundStyle(suggestion.token.kind.color)
                .frame(width: 16)

            Text(suggestion.display)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Spacer()

            Text(suggestion.token.kind.label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted
                      ? Color.accentColor.opacity(0.12)
                      : Color.clear)
        )
    }

    // MARK: - Suggestions Logic

    @State private var suggestions: [SearchSuggestion] = []

    private func updateSuggestions(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            showSuggestions = false
            suggestions = []
            highlightedSuggestion = -1
            return
        }

        var result: [SearchSuggestion] = []

        // ── Detect "operator:" prefix ───────────────────────────
        if trimmed.hasPrefix("type:") {
            let partial = String(trimmed.dropFirst(5))
            let types = ContentType.allCases.filter {
                partial.isEmpty || $0.rawValue.lowercased().hasPrefix(partial) || $0.label.lowercased().hasPrefix(partial)
            }
            result = types.map {
                SearchSuggestion(
                    display: $0.label,
                    icon: $0.iconName,
                    token: SearchToken(kind: .type, value: $0.rawValue)
                )
            }
        } else if trimmed.hasPrefix("from:") {
            let partial = String(trimmed.dropFirst(5))
            let apps = knownApps.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
            result = apps.map {
                SearchSuggestion(
                    display: $0,
                    icon: "app.badge",
                    token: SearchToken(kind: .from, value: $0)
                )
            }
            // Add common fallbacks if no items loaded yet
            if result.isEmpty && partial.isEmpty {
                for app in ["Safari", "Chrome", "Xcode", "Terminal", "Notes", "Mail", "Slack", "Finder"] {
                    result.append(SearchSuggestion(
                        display: app,
                        icon: "app.badge",
                        token: SearchToken(kind: .from, value: app)
                    ))
                }
            }
        } else if trimmed.hasPrefix("date:") {
            let partial = String(trimmed.dropFirst(5))
            let ranges: [(String, String, String)] = [
                ("today", "Today", "calendar"),
                ("week", "This Week", "calendar.badge.clock"),
                ("month", "This Month", "calendar.circle"),
            ]
            result = ranges
                .filter { partial.isEmpty || $0.0.hasPrefix(partial) || $0.1.lowercased().hasPrefix(partial) }
                .map {
                    SearchSuggestion(
                        display: $0.1,
                        icon: $0.2,
                        token: SearchToken(kind: .date, value: $0.0)
                    )
                }
        } else if trimmed.hasPrefix("pinned:") || trimmed == "pinned" {
            result = [
                SearchSuggestion(
                    display: "Pinned only",
                    icon: "pin.fill",
                    token: SearchToken(kind: .pinned, value: "yes")
                )
            ]
        } else if trimmed.hasPrefix("fav:") || trimmed.hasPrefix("favorite:") || trimmed == "fav" {
            result = [
                SearchSuggestion(
                    display: "Favorites only",
                    icon: "star.fill",
                    token: SearchToken(kind: .fav, value: "yes")
                )
            ]
        } else {
            // ── Offer operator hints when no prefix matched ──────
            let operators: [(String, String, String, SearchToken.Kind)] = [
                ("type:", "Filter by content type", "doc", .type),
                ("from:", "Filter by source app", "app.badge", .from),
                ("date:", "Filter by date range", "calendar", .date),
                ("pinned:", "Show pinned only", "pin", .pinned),
                ("fav:", "Show favorites only", "star", .fav),
            ]
            let matching = operators.filter { $0.0.hasPrefix(trimmed) || $0.1.lowercased().contains(trimmed) }
            // Only show operator hints, don't create tokens (user picks one to drill in)
            result = matching.map {
                SearchSuggestion(
                    display: "\($0.0)  — \($0.1)",
                    icon: $0.2,
                    token: SearchToken(kind: $0.3, value: "")
                )
            }
        }

        suggestions = Array(result.prefix(8))
        highlightedSuggestion = suggestions.isEmpty ? -1 : 0
        showSuggestions = !suggestions.isEmpty
    }

    // MARK: - Actions

    private func applySuggestion(_ suggestion: SearchSuggestion) {
        // If the suggestion has an empty value, it's an operator hint →
        // replace freeText with the operator prefix so the user can continue typing
        if suggestion.token.value.isEmpty {
            freeText = suggestion.token.kind.rawValue + ":"
            showSuggestions = false
            // Re-trigger suggestions for the operator
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                updateSuggestions(for: freeText)
            }
            return
        }

        // Don't add duplicate token of the same kind
        tokens.removeAll { $0.kind == suggestion.token.kind }

        withAnimation(.easeOut(duration: 0.15)) {
            tokens.append(suggestion.token)
        }
        freeText = ""
        showSuggestions = false
        highlightedSuggestion = -1
    }

    private func removeToken(_ token: SearchToken) {
        tokens.removeAll { $0.id == token.id }
    }

    private func handleBackspace() {
        if freeText.isEmpty, let last = tokens.last {
            _ = withAnimation(.easeOut(duration: 0.15)) {
                tokens.removeLast()
            }
            // Optionally put the removed token's text back for editing
            freeText = last.serialized + " "
        }
    }

    private func handleReturn() {
        if highlightedSuggestion >= 0, highlightedSuggestion < suggestions.count {
            applySuggestion(suggestions[highlightedSuggestion])
        } else {
            // Just dismiss suggestions; the free text is already in the query
            showSuggestions = false
        }
    }

    private func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlightedSuggestion = max(-1, min(suggestions.count - 1, highlightedSuggestion + delta))
    }

    private func clearAll() {
        withAnimation(.easeOut(duration: 0.15)) {
            tokens.removeAll()
            freeText = ""
        }
        showSuggestions = false
        suggestions = []
        highlightedSuggestion = -1
    }

    // MARK: - Sync: Tokens ↔ ViewModel.searchQuery

    /// Serialise tokens + free text → raw searchQuery string.
    private func syncToViewModel() {
        var parts: [String] = tokens.map(\.serialized)
        let text = freeText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty && !text.hasSuffix(":") {
            parts.append(text)
        }
        let newQuery = parts.joined(separator: " ")
        if viewModel.searchQuery != newQuery {
            viewModel.searchQuery = newQuery
        }
    }

    /// Parse viewModel.searchQuery → tokens + free text (used on appear).
    private func syncFromViewModel() {
        let raw = viewModel.searchQuery
        guard !raw.isEmpty else { return }
        var newTokens: [SearchToken] = []
        var remaining: [String] = []

        for word in raw.components(separatedBy: .whitespaces) where !word.isEmpty {
            let lower = word.lowercased()
            if lower.hasPrefix("type:") {
                let val = String(word.dropFirst(5))
                if !val.isEmpty { newTokens.append(SearchToken(kind: .type, value: val)) }
            } else if lower.hasPrefix("from:") {
                let val = String(word.dropFirst(5))
                if !val.isEmpty { newTokens.append(SearchToken(kind: .from, value: val)) }
            } else if lower.hasPrefix("date:") {
                let val = String(word.dropFirst(5))
                if !val.isEmpty { newTokens.append(SearchToken(kind: .date, value: val)) }
            } else if lower == "pinned:yes" || lower == "pinned:true" {
                newTokens.append(SearchToken(kind: .pinned, value: "yes"))
            } else if lower == "fav:yes" || lower == "fav:true" || lower == "favorite:yes" {
                newTokens.append(SearchToken(kind: .fav, value: "yes"))
            } else {
                remaining.append(word)
            }
        }

        tokens = newTokens
        freeText = remaining.joined(separator: " ")
    }
}

// MARK: - Token Chip View

/// A single removable chip representing a search token.
private struct TokenChipView: View {
    let token: SearchToken
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: token.kind.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(displayLabel)
                .font(LumaDesign.Typography.sans(11, weight: .semibold))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovered ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(token.kind.color)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(token.kind.color.opacity(isHovered ? 0.20 : 0.14))
                .overlay(
                    Capsule()
                        .strokeBorder(token.kind.color.opacity(isHovered ? 0.40 : 0.24), lineWidth: 0.5)
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var displayLabel: String {
        switch token.kind {
        case .type:
            return ContentType.allCases.first { $0.rawValue.lowercased() == token.value.lowercased() }?.label ?? token.value
        case .date:
            switch token.value.lowercased() {
            case "today": return "Today"
            case "week":  return "This Week"
            case "month": return "This Month"
            default:      return token.value
            }
        case .pinned:
            return "Pinned"
        case .fav:
            return "Favorites"
        default:
            return token.value
        }
    }
}

// MARK: - Inline Search Field
//
// A plain TextField wrapped in an NSViewRepresentable so we can
// intercept specific key events (backspace-on-empty, arrow up/down,
// return, escape) before SwiftUI eats them.

struct InlineSearchField: NSViewRepresentable {
    @Binding var text: String
    @FocusState var isFocused: Bool
    var placeholder: String
    var onBackspace: () -> Void
    var onReturn: () -> Void
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = KeyInterceptingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false

        field.onBackspaceEmpty = onBackspace
        field.onReturnKey = onReturn
        field.onArrowDown = onArrowDown
        field.onArrowUp = onArrowUp
        field.onEscapeKey = onEscape

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        // Update callbacks in case closures changed
        if let field = nsView as? KeyInterceptingTextField {
            field.onBackspaceEmpty = onBackspace
            field.onReturnKey = onReturn
            field.onArrowDown = onArrowDown
            field.onArrowUp = onArrowUp
            field.onEscapeKey = onEscape
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: InlineSearchField

        init(_ parent: InlineSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue
            // Defer the @Binding write to the next run loop so it doesn't
            // mutate SwiftUI state mid-render (avoids "undefined behavior" warning).
            DispatchQueue.main.async { [weak self] in
                self?.parent.text = value
            }
        }
    }
}

/// NSTextField subclass that intercepts key events.
private class KeyInterceptingTextField: NSTextField {
    var onBackspaceEmpty: (() -> Void)?
    var onReturnKey: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept Escape
        if event.keyCode == 53 {
            onEscapeKey?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // The text view delegate approach lets us catch keys inside the field editor.
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Install our custom field editor delegate
        if let editor = currentEditor() as? NSTextView {
            let monitor = KeyMonitor(
                textField: self,
                onBackspaceEmpty: { [weak self] in self?.onBackspaceEmpty?() },
                onReturnKey: { [weak self] in self?.onReturnKey?() },
                onArrowDown: { [weak self] in self?.onArrowDown?() },
                onArrowUp: { [weak self] in self?.onArrowUp?() },
                onEscape: { [weak self] in self?.onEscapeKey?() }
            )
            // Store in associated object so it stays alive
            objc_setAssociatedObject(editor, &KeyMonitor.key, monitor, .OBJC_ASSOCIATION_RETAIN)
            editor.delegate = monitor
        }
        return result
    }
}

/// Delegate for the field editor NSTextView that intercepts specific keys.
private class KeyMonitor: NSObject, NSTextViewDelegate {
    static var key: UInt8 = 0

    weak var textField: KeyInterceptingTextField?
    let onBackspaceEmpty: () -> Void
    let onReturnKey: () -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void
    let onEscape: () -> Void

    init(textField: KeyInterceptingTextField,
         onBackspaceEmpty: @escaping () -> Void,
         onReturnKey: @escaping () -> Void,
         onArrowDown: @escaping () -> Void,
         onArrowUp: @escaping () -> Void,
         onEscape: @escaping () -> Void) {
        self.textField = textField
        self.onBackspaceEmpty = onBackspaceEmpty
        self.onReturnKey = onReturnKey
        self.onArrowDown = onArrowDown
        self.onArrowUp = onArrowUp
        self.onEscape = onEscape
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            if textView.string.isEmpty {
                onBackspaceEmpty()
                return true
            }
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onReturnKey()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            onArrowDown()
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            onArrowUp()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape()
            return true
        }
        return false
    }

    // Forward text changes to the NSTextField delegate
    func textDidChange(_ notification: Notification) {
        textField?.textDidChange(notification)
    }
}
