// QuickPastePanel.swift
// LumaClip — macOS Clipboard Manager

import AppKit
import SwiftUI
import Combine

// MARK: - Shared State (controller ↔ SwiftUI view)

@MainActor
final class QuickPasteState: ObservableObject {
    @Published var query       = ""
    @Published var highlighted = 0
    @Published var results: [ClipboardItem] = []

    // Called by panel-level key intercept
    var moveUp:   (() -> Void)?
    var moveDown: (() -> Void)?
    var paste:    (() -> Void)?
}

// MARK: - Quick Paste NSPanel
// Intercepts ↑ ↓ ↩ in sendEvent — BEFORE the TextField first responder
// sees them — so arrow keys drive the list instead of the cursor.

private final class QuickPanel: NSPanel {

    var onUp:     (() -> Void)?
    var onDown:   (() -> Void)?
    var onEnter:  (() -> Void)?
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        level                       = .floating
        isOpaque                    = false
        backgroundColor             = .clear
        hasShadow                   = true
        hidesOnDeactivate           = false
        isMovableByWindowBackground = true
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    // Intercept navigation keys before any responder (including TextField) gets them
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 126:     onUp?();     return   // ↑
            case 125:     onDown?();   return   // ↓
            case 36, 76:  onEnter?();  return   // ↩  numpad ↩
            case 53:      onEscape?(); return   // ESC
            default:      break
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Controller

@MainActor
final class QuickPasteController: NSObject, NSWindowDelegate {

    private let panel = QuickPanel()
    private let vm:    ClipboardViewModel
    private let state = QuickPasteState()

    init(viewModel: ClipboardViewModel) {
        vm = viewModel
        super.init()
        panel.delegate = self

        // Wire panel key callbacks → state actions
        panel.onUp     = { [weak self] in self?.state.moveUp?()   }
        panel.onDown   = { [weak self] in self?.state.moveDown?() }
        panel.onEnter  = { [weak self] in self?.state.paste?()    }
        panel.onEscape = { [weak self] in self?.dismiss()          }

        let hv = NSHostingView(
            rootView: QuickPasteView(vm: viewModel, state: state, onDismiss: { [weak self] in
                self?.dismiss()
            })
            .environmentObject(AppSettings.shared)
        )
        hv.frame = panel.contentRect(forFrameRect: panel.frame)
        hv.autoresizingMask  = [.width, .height]
        hv.wantsLayer        = true
        hv.layer?.backgroundColor = NSColor.clear.cgColor
        hv.layer?.cornerRadius    = 16
        hv.layer?.cornerCurve     = .continuous
        hv.layer?.masksToBounds   = true
        panel.contentView = hv
    }

    // MARK: Show / Dismiss

    func show() {
        // Reset state fresh each time
        state.query       = ""
        state.highlighted = 0
        state.results     = fetchResults(query: "")

        if let screen = NSScreen.main?.visibleFrame {
            let w = panel.frame.width, h = panel.frame.height
            panel.setFrameOrigin(NSPoint(
                x: screen.midX - w / 2,
                y: screen.midY - h / 2 + screen.height * 0.08
            ))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        }
    }

    // MARK: Fetch — always from ALL clips, ignoring the sidebar filter
    // Uses LIKE-based search (not FTS) so results are always accurate.

    func fetchResults(query: String) -> [ClipboardItem] {
        if query.isEmpty {
            return DatabaseService.shared.fetchItems(filter: .all, searchQuery: nil, limit: 50)
        } else {
            return DatabaseService.shared.searchItems(query: query, limit: 50)
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.dismiss() }
    }
}

// MARK: - SwiftUI View

struct QuickPasteView: View {
    @ObservedObject var vm:    ClipboardViewModel
    @ObservedObject var state: QuickPasteState
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var i18n = LocalizationManager.shared
    @FocusState private var searchFocused: Bool

    /// Snapshot of the global mouse position taken whenever the highlight
    /// changes via the keyboard. While this is non-nil, hover events whose
    /// cursor location matches the snapshot are ignored — that pattern only
    /// occurs when the list scrolls under a stationary cursor and SwiftUI
    /// fires a "fake" hover for whichever row is now under the mouse.
    /// The flag is cleared the moment the user actually moves the mouse.
    @State private var mousePosAtKeyboardNav: CGPoint? = nil

    private var palette: LumaPalette { LumaPalette(scheme: colorScheme) }
    private var isLight: Bool { colorScheme == .light }

    var body: some View {
        VStack(spacing: 0) {

            // ── Editorial header (eyebrow + search) ───────────────────
            //
            // Mono "QUICK PASTE / Command palette" eyebrow sits above the
            // search input — same pattern as the Inspector and the
            // sidebar's section labels, so the panel feels like part of
            // the same surface family rather than a separate modal.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("QUICK PASTE".loc)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(palette.textTertiary)
                    Text("·".loc)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .foregroundStyle(palette.textQuaternary)
                    Text("Command palette".loc)
                        .font(LumaDesign.Typography.serifItalic(13))
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    quickPasteKbd("ESC", color: palette.textTertiary)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textTertiary)

                    TextField("Search clips…", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(LumaDesign.Typography.serif(20))
                        .foregroundColor(palette.textPrimary)
                        .focused($searchFocused)

                    if !state.query.isEmpty {
                        Button { state.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search".loc)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)

            // ── Results list ──────────────────────────────────────────
            if state.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(palette.textQuaternary)
                    Text("No matches".loc)
                        .font(LumaDesign.Typography.serifItalic(15))
                        .foregroundStyle(palette.textSecondary)
                    Text("TRY A DIFFERENT QUERY".loc)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(state.results.enumerated()), id: \.element.id) { i, item in
                                QuickPasteRow(
                                    item: item,
                                    index: i,
                                    isHighlighted: state.highlighted == i,
                                    query: state.query,
                                    palette: palette
                                )
                                .id(i)
                                .onTapGesture { state.highlighted = i; pasteHighlighted() }
                                .onHover { hovering in
                                    guard hovering else { return }
                                    // Suppress the "fake" hover that fires when the list
                                    // scrolls under a stationary cursor after keyboard nav.
                                    if let saved = mousePosAtKeyboardNav,
                                       saved == NSEvent.mouseLocation {
                                        return
                                    }
                                    mousePosAtKeyboardNav = nil
                                    state.highlighted = i
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                    }
                    .onChange(of: state.highlighted) { idx in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)

            // ── Footer ────────────────────────────────────────────────
            HStack(spacing: 14) {
                footerHint(key: "↑↓", label: "Navigate".loc)
                footerHint(key: "↩",  label: "Paste".loc)
                Spacer()
                HStack(spacing: 4) {
                    Text("\(state.results.count)".loc)
                        .font(LumaDesign.Typography.mono(10, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text("clips".loc)
                        .font(LumaDesign.Typography.sans(11))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        // Editorial container: paper-cream / graphite ground with a
        // hairline border, matching the main panel's card chrome.
        // Replaces the old `Color.white | .regularMaterial` split — the
        // material is no longer needed since the palette already handles
        // the dark-mode ground correctly.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.detailBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                )
        )
        .onAppear {
            searchFocused = true
            // Register actions back onto state so panel key intercept can call them
            state.moveUp   = moveUp
            state.moveDown = moveDown
            state.paste    = pasteHighlighted
        }
        // Re-fetch whenever query changes — LIKE search, not FTS
        .onChange(of: state.query) { q in
            state.highlighted = 0
            if q.isEmpty {
                state.results = DatabaseService.shared.fetchItems(filter: .all, searchQuery: nil, limit: 50)
            } else {
                state.results = DatabaseService.shared.searchItems(query: q, limit: 50)
            }
        }
        .id(i18n.language)
    }

    // MARK: - Actions

    private func moveUp() {
        mousePosAtKeyboardNav = NSEvent.mouseLocation
        state.highlighted = max(0, state.highlighted - 1)
    }

    private func moveDown() {
        mousePosAtKeyboardNav = NSEvent.mouseLocation
        state.highlighted = min(state.results.count - 1, state.highlighted + 1)
    }

    private func pasteHighlighted() {
        guard state.highlighted < state.results.count else { return }
        let item = state.results[state.highlighted]
        vm.copyItem(item)
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            simulatePaste()
        }
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap:   .cgAnnotatedSessionEventTap)
    }

    private func footerHint(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            quickPasteKbd(key, color: palette.textSecondary)
            Text(label)
                .font(LumaDesign.Typography.sans(11))
                .foregroundStyle(palette.textTertiary)
        }
    }

    /// Mono kbd badge with the editorial paper-card treatment. Pulled
    /// out of `footerHint` because the same shape is also used for the
    /// ESC indicator in the header.
    private func quickPasteKbd(_ key: String, color: Color) -> some View {
        Text(key)
            .font(LumaDesign.Typography.mono(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Row

private struct QuickPasteRow: View {
    let item:          ClipboardItem
    let index:         Int
    let isHighlighted: Bool
    let query:         String          // "" when no active search
    let palette:       LumaPalette

    var body: some View {
        HStack(spacing: 11) {
            // ── Type mark ─────────────────────────────────────────
            //
            // Keeps the source-app corner badge intact so the user can
            // tell at a glance which app the clip came from. On the
            // highlighted row the mark switches to the lime accent so
            // it pops against the dark slab.
            Image(systemName: item.contentType.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHighlighted
                    ? palette.accentBright
                    : item.contentType.color)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHighlighted
                              ? Color.white.opacity(0.10)
                              : item.contentType.color.opacity(0.14))
                )
                .overlay(alignment: .bottomTrailing) {
                    SourceAppIconBadge(appName: item.sourceApp, size: 13)
                        .offset(x: 4, y: 3)
                }

            // ── Snippet ───────────────────────────────────────────
            //
            // Smart-snippet logic preserved verbatim — the only change
            // is which palette tokens the highlighted/normal text resolve
            // to. Match-run gets the lime accent on dark, accent-warm
            // (link orange) on light so the matched substring reads as
            // "the part you searched for" without stealing focus from
            // the rest of the snippet.
            snippetText
                .font(LumaDesign.Typography.sans(13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            // ── ⌘N kbd badge ──────────────────────────────────────
            if index < 9 {
                Text("⌘\(index + 1)".loc)
                    .font(LumaDesign.Typography.mono(10, weight: .semibold))
                    .foregroundStyle(isHighlighted
                        ? palette.focusInk
                        : palette.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isHighlighted
                                ? palette.accentBright
                                : palette.borderSubtle)
                    )
            }

            // ── Source app pill ───────────────────────────────────
            if !item.sourceApp.isEmpty {
                Text(item.sourceApp)
                    .font(LumaDesign.Typography.sans(10, weight: .medium))
                    .foregroundColor(isHighlighted
                        ? palette.focusPaper.opacity(0.65)
                        : palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            // Editorial highlight: deep ink slab with paper text + lime
            // accents. This is the spec's "focused row" treatment — the
            // QuickPaste panel is a command palette where one row owns
            // the user's attention, so going dramatic is appropriate
            // (the main list uses a quieter lime wash for the same
            // reason: it has many simultaneous rows to scan).
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .fill(isHighlighted ? palette.focusInk : Color.clear)
        )
        .animation(.easeInOut(duration: 0.14), value: isHighlighted)
    }

    // MARK: - Smart snippet with inline highlight

    /// Returns a `Text` view showing the portion of the item's content that
    /// contains the search match, with the matched run bolded + coloured.
    /// Falls back to the normal preview when there is no active query.
    private var snippetText: Text {
        let qLower = query.lowercased()
        let bodyColor:  Color = isHighlighted ? palette.focusPaper : palette.textPrimary
        let matchColor: Color = isHighlighted ? palette.accentBright : palette.accentWarm
        let dimColor:   Color = isHighlighted ? palette.focusPaper.opacity(0.7)
                                              : palette.textSecondary

        // File clips: lead with the file name (the size/“已保存” detail is
        // shown dimmed after it). The single-line quick panel otherwise
        // only renders `preview`, which hides the name entirely.
        if item.contentType == .file {
            return Text(item.fileDisplayName).foregroundColor(bodyColor)
                 + Text("  ·  \(item.characterCount)").foregroundColor(dimColor)
        }

        // No search — show normal preview in standard colour
        guard !qLower.isEmpty else {
            return Text(item.preview).foregroundColor(bodyColor)
        }

        let content = item.content
        let lower   = content.lowercased()

        // Couldn't find the query in this item — show preview
        guard let matchRange = lower.range(of: qLower) else {
            return Text(item.preview).foregroundColor(bodyColor)
        }

        // Centre a ~120-char window around the match
        let matchStart  = lower.distance(from: lower.startIndex, to: matchRange.lowerBound)
        let padBefore   = 40
        let windowLen   = 120
        let start       = max(0, matchStart - padBefore)
        let startIdx    = content.index(content.startIndex, offsetBy: start)
        let raw         = String(content[startIdx...].prefix(windowLen))

        let leadDot  = start > 0
        let trailDot = (start + windowLen) < content.count

        // Find the match inside the extracted window
        let rawLower = raw.lowercased()
        guard let winRange = rawLower.range(of: qLower) else {
            // Shouldn't happen, but fall back gracefully
            return Text((leadDot ? "…" : "") + raw + (trailDot ? "…" : ""))
                .foregroundColor(bodyColor)
        }

        let before = (leadDot ? "…" : "") + String(raw[..<winRange.lowerBound])
        let match  = String(raw[winRange])
        let after  = String(raw[winRange.upperBound...]) + (trailDot ? "…" : "")

        return Text(before).foregroundColor(bodyColor)
             + Text(match).fontWeight(.semibold).foregroundColor(matchColor)
             + Text(after).foregroundColor(bodyColor)
    }
}
