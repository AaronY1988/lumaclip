// ClipboardListView.swift
// LumaClip — macOS Clipboard Manager
//
// Five improvements over the original:
//   1. Color-coded 3px left border per content type for instant visual scanning
//   2. Swipe-to-reveal actions (copy, pin, favorite, delete) with spring physics
//   3. ⌘1–⌘9 keyboard shortcuts to instantly copy the first 9 items
//   4. Pinned items shown in a dedicated section above regular items
//   5. Content-aware row previews (color swatch chip for hex colors)

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag Payload
//
// Two Transferable shapes — one for text clips (exports as .txt via
// .utf8PlainText), one for image clips (.jpg via .jpeg). Using the
// specific UTType is what gives Finder a proper filename extension;
// an earlier single-payload version that used `.data` produced files
// literally named "data" because that UTType carries no extension.
//
// Both shapes also expose a ProxyRepresentation(String) so the list's
// in-row reorder drop (`.dropDestination(for: String.self)`) keeps
// working against the same draggable source.

fileprivate struct ClipboardTextDragPayload: Transferable {
    let itemID: String
    let content: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.itemID)

        FileRepresentation(exportedContentType: .utf8PlainText) { payload in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try payload.content.write(to: tmp, atomically: true, encoding: .utf8)
            return SentTransferredFile(tmp)
        }
    }
}

fileprivate struct ClipboardImageDragPayload: Transferable {
    let itemID: String
    let imageData: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.itemID)

        FileRepresentation(exportedContentType: .jpeg) { payload in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try payload.imageData.write(to: tmp)
            return SentTransferredFile(tmp)
        }
    }
}

/// ViewModifier that attaches the right .draggable Transferable for
/// the clip's content type. Wrapping the branching here keeps
/// `rowButton` clean and gives each branch its own Transferable kind,
/// which is what makes Finder produce properly-named .txt / .jpg files.
fileprivate struct ClipDraggableModifier<Preview: View>: ViewModifier {
    let item: ClipboardItem
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if item.contentType == .image, let data = item.imageData {
            content.draggable(
                ClipboardImageDragPayload(
                    itemID: item.id.uuidString,
                    imageData: data,
                    filename: dragFilename(for: item)
                ),
                preview: preview
            )
        } else {
            content.draggable(
                ClipboardTextDragPayload(
                    itemID: item.id.uuidString,
                    content: item.content,
                    filename: dragFilename(for: item)
                ),
                preview: preview
            )
        }
    }
}

/// Suggest a sensible filename for drag-out. Uses the clip's title for
/// text (sanitized to filesystem-safe chars) and always appends a short
/// id suffix to avoid collisions in the tmp directory.
fileprivate func dragFilename(for item: ClipboardItem) -> String {
    let shortID = String(item.id.uuidString.prefix(8))
    if item.contentType == .image {
        return "LumaClip-\(shortID).jpg"
    }
    let base = item.title
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
    let trimmed = String(base.prefix(40))
    let stem = trimmed.isEmpty ? "Clip" : trimmed
    return "\(stem)-\(shortID).txt"
}

// MARK: - Clipboard List View

struct ClipboardListView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.lumaPalette) private var palette

    /// Shortcut to current density setting
    private var density: ListDensity { settings.listDensity }

    // Toast state
    @State private var toastVisible = false
    @State private var toastWork: DispatchWorkItem?

    // Pre-partitioned by ViewModel — no per-body recomputation
    private var pinnedItems: [ClipboardItem] { viewModel.pinnedItems }
    private var unpinnedItems: [ClipboardItem] { viewModel.unpinnedItems }

    /// Copy an item and show the "Copied" toast.
    private func copy(_ item: ClipboardItem) {
        viewModel.copyItem(item)
        showToast()
    }

    /// O(n) index lookup — only called for visible rows thanks to LazyVStack.
    private func globalIndex(of item: ClipboardItem) -> Int {
        viewModel.items.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    /// Index within the unpinned partition.
    private func unpinnedIndex(of item: ClipboardItem) -> Int {
        unpinnedItems.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    // MARK: - Time Bucketing
    //
    // Visual-only: takes the existing `unpinnedItems` (already sorted
    // newest-first by the view model) and slices it into Today /
    // Yesterday / This Week / Earlier groups. The slicing is order-
    // preserving — `unpinnedIndex` and the ⌘1–⌘9 shortcut mapping
    // continue to read the same flat sequence, so keyboard behaviour
    // is unchanged.

    private enum TimeBucket: String, CaseIterable {
        case today, yesterday, thisWeek, earlier

        var label: String {
            switch self {
            case .today:     return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek:  return "This Week"
            case .earlier:   return "Earlier"
            }
        }
    }

    /// Bucket assignment driven by `Calendar.current` so it follows the
    /// user's locale week-start. "This week" excludes today and
    /// yesterday — those have their own buckets — and resolves
    /// strictly within the current calendar week, not "the last 7 days".
    private static func bucket(for date: Date,
                               relativeTo now: Date,
                               calendar: Calendar = .current) -> TimeBucket {
        if calendar.isDateInToday(date)     { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        return .earlier
    }

    /// Pre-grouped slice of `unpinnedItems`. Computed once per body
    /// pass; LazyVStack consumes the result. Returns the buckets in
    /// chronological order with empty buckets dropped, so an old
    /// archive that has nothing from this week skips the "This Week"
    /// header instead of leaving a stranded label.
    private var unpinnedBuckets: [(TimeBucket, [ClipboardItem])] {
        let now = Date()
        var grouped: [TimeBucket: [ClipboardItem]] = [:]
        for item in unpinnedItems {
            let b = Self.bucket(for: item.createdAt, relativeTo: now)
            grouped[b, default: []].append(item)
        }
        return TimeBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }

    private func showToast() {
        // Cancel any pending hide
        toastWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            toastVisible = true
        }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                toastVisible = false
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Kept for historical compatibility with any hold-out call site.
    /// New row layout uses whitespace gaps between card-style rows
    /// rather than full-width hairlines, so this view returns an
    /// effectively invisible spacer to avoid double-gap if it sneaks
    /// back in. Safe to delete once verified no other file references it.
    private var rowDivider: some View {
        Color.clear.frame(height: 0)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
          VStack(spacing: 0) {
            FilterChipsView(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if viewModel.items.isEmpty {
                EmptyStateView(filter: viewModel.activeFilter)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Spec §5.3: 6pt gap between card-shaped rows.
                        // Section headers handle their own surrounding
                        // whitespace via padding modifiers below.
                        LazyVStack(spacing: 6) {

                            // ── Pinned section ───────────────────────────────
                            if !pinnedItems.isEmpty {
                                SectionHeader(title: "Pinned".loc, icon: "pin.fill", color: palette.accentWarm)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 6)

                                ForEach(pinnedItems) { item in
                                    animatedRow(for: item,
                                                globalIndex: globalIndex(of: item),
                                                shortcutIndex: nil)
                                }
                            }

                            // ── Time-bucketed unpinned items ─────────────────
                            //
                            // The shortcut index for ⌘1–⌘9 follows the flat
                            // unpinned order across all buckets, so users see
                            // the digit on whichever rows happen to land in
                            // the top 9 visual positions regardless of which
                            // bucket they're in.
                            ForEach(Array(unpinnedBuckets.enumerated()), id: \.offset) { bucketIdx, pair in
                                let (bucket, bucketItems) = pair

                                SectionHeader(
                                    title: bucket.label,
                                    icon: nil,
                                    color: palette.textTertiary
                                )
                                .padding(.horizontal, 14)
                                .padding(.top, bucketIdx == 0 && pinnedItems.isEmpty ? 6 : 10)

                                ForEach(bucketItems) { item in
                                    let uIdx = unpinnedIndex(of: item)
                                    animatedRow(
                                        for: item,
                                        globalIndex: pinnedItems.count + uIdx,
                                        shortcutIndex: uIdx < 9 ? uIdx : nil
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: viewModel.selectedIndex) { newIndex in
                        guard newIndex >= 0, newIndex < viewModel.items.count else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(viewModel.items[newIndex].id, anchor: .center)
                        }
                    }
                }
            }

            // Multi-select action bar — shown whenever ≥1 item is selected via ⌘-click
            if viewModel.isMultiSelectMode {
                MultiSelectBar(
                    count: viewModel.selectedItems.count,
                    totalCount: viewModel.items.count,
                    isAllSelected: viewModel.isAllSelected,
                    isTrash: viewModel.activeFilter == .trash,
                    onSelectAll: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                            viewModel.selectAll()
                        }
                    },
                    onDelete: { viewModel.deleteMultiSelected() },
                    onCancel: { withAnimation { viewModel.clearMultiSelection() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Trash bar
            if case .trash = viewModel.activeFilter, !viewModel.items.isEmpty {
                EmptyTrashBar { viewModel.emptyTrash() }
            }
          }
          // KeyboardNavigationModifier was previously mounted here, but
          // it lives on MainPanelView now so the global key monitor
          // survives navigation into Bundles / Settings (which unmount
          // ClipboardListView entirely).
          // ── Show toast when keyboard Enter copies an item ─────
          .onChange(of: viewModel.keyboardCopyPerformed) { _ in
              showToast()
          }
          // ── ⌘1–⌘9 instant copy shortcuts (hidden buttons, window-level) ──
          .background(
              Group {
                  let slots = min(unpinnedItems.count, 9)
                  if slots > 0 { shortcutButton(index: 0) }
                  if slots > 1 { shortcutButton(index: 1) }
                  if slots > 2 { shortcutButton(index: 2) }
                  if slots > 3 { shortcutButton(index: 3) }
                  if slots > 4 { shortcutButton(index: 4) }
                  if slots > 5 { shortcutButton(index: 5) }
                  if slots > 6 { shortcutButton(index: 6) }
                  if slots > 7 { shortcutButton(index: 7) }
                  if slots > 8 { shortcutButton(index: 8) }
              }
          )

          // ── Copy toast ────────────────────────────────────────────────
          if toastVisible {
              CopyToastView()
                  .padding(.bottom, 14)
                  .transition(
                      .asymmetric(
                          insertion: .move(edge: .bottom).combined(with: .opacity),
                          removal:   .opacity
                      )
                  )
                  .allowsHitTesting(false)
          }
        } // ZStack
    }

    // MARK: - Row Builder

    @ViewBuilder
    private func rowButton(for item: ClipboardItem,
                           globalIndex: Int,
                           shortcutIndex: Int?) -> some View {
        ClipboardRowView(
            item: item,
            category: viewModel.category(for: item),
            isSelected: viewModel.selectedItem?.id == item.id,
            isMultiSelected: viewModel.selectedItems.contains(item.id),
            isMultiSelectActive: viewModel.isMultiSelectMode,
            isTrash: viewModel.activeFilter == .trash,
            shortcutIndex: shortcutIndex,
            onCopy: { copy(item) },
            onFavorite: { viewModel.toggleFavorite(item) },
            onPin: { viewModel.togglePin(item) },
            onDelete: { viewModel.animateDelete(item) },
            onRestore: { viewModel.animateRestore(item) },
            onToggleSelect: {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                    viewModel.toggleMultiSelection(item)
                }
            },
            organizeData: RowOrganizeData(
                categories: viewModel.categories,
                bundles: viewModel.bundles,
                onSetCategory: { item, catId in viewModel.setCategory(item, categoryId: catId) },
                onAddToBundle: { item, bundle in viewModel.addItemToBundle(item, bundle: bundle) },
                onSetExpiry:   { item, date in viewModel.setExpiry(item, expiresAt: date) }
            )
        )
        .contentShape(Rectangle())
        // Double-click → copy + toast; single-click → select (or multi-select with ⌘)
        .onTapGesture(count: 2) { copy(item) }
        .onTapGesture(count: 1) {
            let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            if isCmd {
                // ⌘-click toggles this item in the multi-selection
                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                    viewModel.toggleMultiSelection(item)
                }
            } else {
                // Plain click — clear multi-selection, do normal single-select
                if viewModel.isMultiSelectMode {
                    withAnimation { viewModel.clearMultiSelection() }
                }
                viewModel.selectedItem = item
                viewModel.selectedIndex = globalIndex
            }
            // A row click is an explicit mouse interaction with the list
            // zone — bring keyboard focus along so subsequent ↑↓ go to
            // list nav (not the previously focused column).
            if viewModel.focusedZone != .list {
                withAnimation(LumaDesign.Motion.select) {
                    viewModel.focusedZone = .list
                }
            }
        }
        .id(item.id)
        // Drag this item. The payload carries both a UUID string (for
        // the in-list reorder drop target) and a typed file representation
        // so Finder materialises a real .txt or .jpg file. Branching
        // here (vs. a single payload with a dynamic UTType) is the only
        // way to keep a specific exportedContentType per clip kind —
        // FileRepresentation's UTType is a compile-time constant.
        .modifier(ClipDraggableModifier(item: item, preview: { dragPreview(for: item) }))
        // Drop zone: reorder by dragging onto another item
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let sourceIDStr = droppedIDs.first,
                  let sourceID = UUID(uuidString: sourceIDStr),
                  sourceID != item.id else { return false }
            viewModel.moveItem(sourceID, toPositionOf: item.id)
            return true
        } isTargeted: { targeted in
            viewModel.dropTargetID = targeted ? item.id : nil
        }
        .overlay(
            Group {
                if viewModel.dropTargetID == item.id {
                    VStack {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                        Spacer()
                    }
                }
            }
        )
        .contextMenu {
            // ── Primary actions ──────────────────────────────────
            Button { copy(item) } label: {
                Label("Copy".loc, systemImage: "doc.on.doc")
            }
            Button {
                copy(item); viewModel.isPanelVisible = false
            } label: {
                Label("Copy & Dismiss".loc, systemImage: "doc.on.doc.fill")
            }

            Divider()

            // ── Toggle actions ───────────────────────────────────
            Button { viewModel.toggleFavorite(item) } label: {
                Label(item.isFavorite ? "Unfavorite" : "Favorite",
                      systemImage: item.isFavorite ? "star.slash" : "star")
            }
            Button { viewModel.togglePin(item) } label: {
                Label(item.isPinned ? "Unpin" : "Pin",
                      systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            Button { viewModel.toggleBurnAfterPaste(item) } label: {
                Label(item.isBurnAfterPaste
                      ? "Cancel Burn After Paste"
                      : "Burn After Paste",
                      systemImage: item.isBurnAfterPaste ? "flame.fill" : "flame")
            }
            if viewModel.pasteQueue.contains(item.id) {
                Button { viewModel.dequeuePaste(item.id) } label: {
                    Label("Remove from Paste Queue".loc,
                          systemImage: "rectangle.stack.badge.minus")
                }
            } else {
                Button { viewModel.enqueueForPaste(item) } label: {
                    Label("Add to Paste Queue".loc,
                          systemImage: "rectangle.stack.badge.plus")
                }
            }
            Button { viewModel.toggleSensitive(item) } label: {
                Label(item.isSensitive
                      ? "Unmark as Sensitive"
                      : "Mark as Sensitive",
                      systemImage: item.isSensitive
                          ? "lock.shield.fill"
                          : "lock.shield")
            }

            Divider()

            // ── Smart actions + transforms ───────────────────────
            itemActionsMenu(item: item)
            itemTransformsMenu(item: item)

            Divider()

            // ── Organize ─────────────────────────────────────────
            itemOrganizeMenu(item: item)

            Divider()

            // ── Destructive ──────────────────────────────────────
            itemDestructiveMenu(item: item)
        }
    }

    // MARK: - Animated Row Wrapper

    /// Wraps rowButton inside AnimatedExitView so LazyVStack gets a proper
    /// per-row dependency on the animation-state Bindings.
    @ViewBuilder
    private func animatedRow(for item: ClipboardItem,
                             globalIndex: Int,
                             shortcutIndex: Int?) -> some View {
        AnimatedExitView(
            itemID:       item.id,
            deletingIDs:  $viewModel.deletingIDs,
            restoringIDs: $viewModel.restoringIDs,
            flashingIDs:  $viewModel.flashingIDs
        ) {
            rowButton(for: item, globalIndex: globalIndex, shortcutIndex: shortcutIndex)
        }
    }

    // Hidden button for ⌘N keyboard shortcut — works at window level, no focus needed
    @ViewBuilder
    private func shortcutButton(index: Int) -> some View {
        let digit = index + 1
        if index < unpinnedItems.count {
            Button {
                copy(unpinnedItems[index])
            } label: {
                EmptyView()
            }
            .keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command)
            .hidden()
        }
    }

    // Lightweight drag preview shown while dragging
    @ViewBuilder
    private func dragPreview(for item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.contentType.iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        )
        .frame(maxWidth: 260)
    }

    // MARK: - Context Menu Sections

    /// Organize actions: Category, Bundle, Expiry (reused in context menu + hover More)
    @ViewBuilder
    private func itemOrganizeMenu(item: ClipboardItem) -> some View {
        if case .trash = viewModel.activeFilter {
            // No organize actions in trash
            EmptyView()
        } else {
            if !viewModel.categories.isEmpty {
                Menu {
                    Button { viewModel.setCategory(item, categoryId: nil) } label: {
                        Label("None".loc, systemImage: "xmark")
                    }
                    Divider()
                    ForEach(viewModel.categories) { cat in
                        Button { viewModel.setCategory(item, categoryId: cat.id) } label: {
                            Label(cat.name, systemImage: cat.icon)
                        }
                    }
                } label: {
                    Label("Set Category".loc, systemImage: "tag")
                }
            }

            if !viewModel.bundles.isEmpty {
                Menu {
                    ForEach(viewModel.bundles) { bundle in
                        Button {
                            viewModel.addItemToBundle(item, bundle: bundle)
                        } label: {
                            Label(bundle.name, systemImage: bundle.icon)
                        }
                    }
                } label: {
                    Label("Add to Bundle".loc, systemImage: "rectangle.stack.badge.plus")
                }
            }

            Menu {
                Button { viewModel.setExpiry(item, expiresAt: nil) } label: {
                    Label("No Expiry".loc, systemImage: "infinity")
                }
                Divider()
                ForEach(RetentionRule.presetDurations, id: \.1) { label, duration in
                    if duration > 0 {
                        Button {
                            viewModel.setExpiry(item, expiresAt: Date().addingTimeInterval(duration))
                        } label: {
                            Text(label)
                        }
                    }
                }
            } label: {
                Label("Set Expiry".loc, systemImage: "clock.arrow.circlepath")
            }
        }
    }

    // MARK: - Smart Quick Actions

    /// Content-type-aware actions that surface "open in browser" for
    /// URLs, "reveal in Finder" for file paths, QR generation for any
    /// text, and so on. Rendered as a submenu so the top-level context
    /// menu stays lean on clips that have no applicable action.
    @ViewBuilder
    private func itemActionsMenu(item: ClipboardItem) -> some View {
        let contents = item.content.trimmingCharacters(in: .whitespacesAndNewlines)

        Menu {
            // URL actions ------------------------------------------------
            if item.contentType == .url {
                Button { openURL(contents) } label: {
                    Label("Open in Browser".loc, systemImage: "safari")
                }
                Button { copyAsMarkdownLink(contents) } label: {
                    Label("Copy as Markdown Link".loc, systemImage: "link.badge.plus")
                }
            }

            // File path actions ------------------------------------------
            if item.contentType == .path {
                Button { revealInFinder(contents) } label: {
                    Label("Reveal in Finder".loc, systemImage: "folder")
                }
                Button { quickLook(contents) } label: {
                    Label("Quick Look".loc, systemImage: "eye")
                }
            }

            // Colour actions ---------------------------------------------
            if item.contentType == .color {
                Button {
                    if let rgb = ColorTransforms.hexToRGB(contents) {
                        clipboardService.copyToClipboard(rgb)
                        showToast()
                    }
                } label: {
                    Label("Copy as rgb()".loc, systemImage: "paintpalette")
                }
            }

            // QR — applicable to anything short-ish. CoreImage rejects
            // extremely long payloads, so cap at ~2000 chars.
            if item.contentType != .image, contents.count <= 2_000 {
                Button { generateQRCode(for: contents) } label: {
                    Label("Generate QR Code".loc, systemImage: "qrcode")
                }
            }
        } label: {
            Label("Actions".loc, systemImage: "bolt")
        }
    }

    // MARK: - Paste Transforms

    /// Deterministic content transforms grouped by category so the menu
    /// isn't a flat list of 20+ rows. Applying a transform copies the
    /// result to the clipboard — the poll timer will pick it up and save
    /// it as a fresh clip, preserving the original.
    @ViewBuilder
    private func itemTransformsMenu(item: ClipboardItem) -> some View {
        if item.contentType != .image {
            Menu {
                Menu {
                    transformButton(.upperCase, item: item)
                    transformButton(.lowerCase, item: item)
                    transformButton(.titleCase, item: item)
                    transformButton(.snakeCase, item: item)
                    transformButton(.camelCase, item: item)
                    transformButton(.kebabCase, item: item)
                } label: {
                    Label("Case".loc, systemImage: "textformat")
                }

                Menu {
                    transformButton(.urlEncode, item: item)
                    transformButton(.urlDecode, item: item)
                    transformButton(.base64Encode, item: item)
                    transformButton(.base64Decode, item: item)
                    transformButton(.escapeHTML, item: item)
                    transformButton(.unescapeHTML, item: item)
                } label: {
                    Label("Encoding".loc, systemImage: "chevron.left.forwardslash.chevron.right")
                }

                if PasteTransform.jsonPretty.applicable(to: item.contentType) {
                    Menu {
                        transformButton(.jsonPretty, item: item)
                        transformButton(.jsonMinify, item: item)
                    } label: {
                        Label("JSON".loc, systemImage: "curlybraces")
                    }

                    Menu {
                        transformButton(.linesSort, item: item)
                        transformButton(.linesDedup, item: item)
                        transformButton(.linesReverse, item: item)
                    } label: {
                        Label("Lines".loc, systemImage: "list.bullet")
                    }
                }

                Menu {
                    transformButton(.trimWhitespace, item: item)
                    transformButton(.collapseWhitespace, item: item)
                } label: {
                    Label("Whitespace".loc, systemImage: "arrow.left.and.right")
                }

                if item.contentType == .color {
                    Divider()
                    transformButton(.hexToRGB, item: item)
                    transformButton(.rgbToHex, item: item)
                }
            } label: {
                Label("Transform".loc, systemImage: "wand.and.stars")
            }
        }
    }

    /// Individual transform menu row. Disabled if the current content
    /// fails to transform (e.g. invalid JSON → JSON Pretty grayed out).
    @ViewBuilder
    private func transformButton(_ transform: PasteTransform, item: ClipboardItem) -> some View {
        Button {
            applyTransform(transform, to: item)
        } label: {
            Label(transform.label, systemImage: transform.icon)
        }
    }

    /// Apply a transform and push the result to the clipboard. The poll
    /// timer picks it up within ~0.5s and stores it as a fresh clip, so
    /// the user can trace back the transformed output in their history.
    /// Failed transforms (e.g. non-JSON through JSON Pretty) surface a
    /// gentle system-beep hint rather than silently no-op.
    private func applyTransform(_ transform: PasteTransform, to item: ClipboardItem) {
        guard let output = transform.apply(to: item.content), !output.isEmpty else {
            NSSound.beep()
            return
        }
        clipboardService.copyToClipboard(output)
        showToast()
    }

    // MARK: - Smart Action Helpers

    private var clipboardService: ClipboardService { .shared }

    private func openURL(_ text: String) {
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyAsMarkdownLink(_ text: String) {
        let host = URL(string: text)?.host ?? text
        let markdown = "[\(host)](\(text))"
        clipboardService.copyToClipboard(markdown)
        showToast()
    }

    private func revealInFinder(_ path: String) {
        // Expand leading ~ and keep absolute paths as-is.
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func quickLook(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        NSWorkspace.shared.open(url)
    }

    /// QR → JPEG on the clipboard. The next poll captures it as an image
    /// clip, so the generated QR lives in history like any other.
    private func generateQRCode(for text: String) {
        guard let data = QRCodeGenerator.jpegData(from: text) else {
            NSSound.beep()
            return
        }
        clipboardService.copyImageToClipboard(data)
        showToast()
    }

    /// Destructive actions (delete / restore)
    @ViewBuilder
    private func itemDestructiveMenu(item: ClipboardItem) -> some View {
        if case .trash = viewModel.activeFilter {
            Button { viewModel.animateRestore(item) } label: {
                Label("Restore".loc, systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                viewModel.animatePermanentDelete(item)
            } label: {
                Label("Delete Permanently".loc, systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                viewModel.animateDelete(item)
            } label: {
                Label("Move to Trash".loc, systemImage: "trash")
            }
        }
    }
}

// MARK: - Animated Exit View
//
// A proper View struct (not a @ViewBuilder function) so that LazyVStack
// can track @Binding dependencies at the individual-row level.
// When deletingIDs / restoringIDs / flashingIDs change, only the
// AnimatedExitView instances that are currently rendered (visible) are
// invalidated, which is exactly what we need for smooth exit animations.

private struct AnimatedExitView<Content: View>: View {
    let itemID: UUID
    @Binding var deletingIDs:  Set<UUID>
    @Binding var restoringIDs: Set<UUID>
    @Binding var flashingIDs:  Set<UUID>
    @ViewBuilder let content: () -> Content

    var body: some View {
        let isDeleting  = deletingIDs.contains(itemID)
        let isRestoring = restoringIDs.contains(itemID)
        let isFlashing  = flashingIDs.contains(itemID)

        content()
            // ── Delete: shrink toward trailing edge, drift right, blur out ──
            .scaleEffect(
                isDeleting ? CGSize(width: 0.78, height: 0.82) : CGSize(width: 1, height: 1),
                anchor: .trailing
            )
            // ── Restore: shrink slightly toward leading edge ──────────────
            .scaleEffect(
                isRestoring ? CGSize(width: 0.88, height: 0.92) : CGSize(width: 1, height: 1),
                anchor: .leading
            )
            .opacity(isDeleting || isRestoring ? 0 : 1)
            .offset(x: isDeleting ? 40 : (isRestoring ? -32 : 0),
                    y: isDeleting ? 4 : 0)
            .blur(radius: isDeleting ? 4 : 0)
            // ── Green flash overlay for restore ───────────────────────────
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.green.opacity(isFlashing ? 0.18 : 0))
                    .allowsHitTesting(false)
            )
            .animation(.spring(response: 0.26, dampingFraction: 0.86), value: isDeleting)
            .animation(.spring(response: 0.28, dampingFraction: 0.80), value: isRestoring)
            .animation(.easeOut(duration: 0.12), value: isFlashing)
    }
}

// MARK: - Section Header
//
// Editorial section divider: small mono uppercase label on the left,
// a hairline that fills the remaining width on the right (per spec
// §5.3). The optional icon is preserved for "Pinned" / status-style
// headers; the time-bucket headers (Today / Yesterday / etc.) pass
// `nil` and read as pure typographic markers.

private struct SectionHeader: View {
    let title: String
    let icon:  String?
    let color: Color
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(title.uppercased())
                .font(LumaDesign.Typography.mono(9, weight: .bold))
                .foregroundStyle(palette.textTertiary)
                .tracking(1.4)

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Filter Chips

struct FilterChipsView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                // "All types" pill
                FilterChip(
                    label: "All".loc,
                    icon: "square.grid.2x2",
                    isActive: viewModel.selectedContentType == nil,
                    activeColor: palette.accent
                ) { viewModel.clearContentFilter() }

                // Per-type pills
                ForEach(ContentType.allCases) { type in
                    FilterChip(
                        label: type.label,
                        icon: type.iconName,
                        isActive: viewModel.selectedContentType == type,
                        activeColor: palette.accent
                    ) { viewModel.applyContentFilter(type) }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct FilterChip: View {
    let label:       String
    let icon:        String
    var isActive:    Bool = false
    var activeColor: Color = .accentColor
    var action:      () -> Void = {}

    @State private var isHovered  = false
    @State private var isPressed  = false
    @Environment(\.colorScheme)  private var scheme
    @Environment(\.lumaPalette)  private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(LumaDesign.Typography.sans(11, weight: isActive ? .semibold : .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            // Spec §5.2: active = ink-on-paper, inactive = paper-on-faint
            // hairline. Switches the previous accent-tinted treatment
            // for the editorial monochrome chip.
            .foregroundStyle(
                isActive
                    ? palette.focusPaper
                    : (isHovered ? palette.textPrimary : palette.textSecondary)
            )
            .background(
                Capsule()
                    .fill(
                        isActive
                            ? palette.focusInk
                            : (isHovered ? palette.hoverBg : palette.cardBg)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isActive
                                    ? Color.clear
                                    : palette.borderDefault,
                                lineWidth: 0.5
                            )
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(LumaDesign.Motion.instant) { isPressed = true } }
                .onEnded   { _ in withAnimation(LumaDesign.Motion.instant) { isPressed = false } }
        )
        .animation(LumaDesign.Motion.quick, value: isActive)
        .animation(LumaDesign.Motion.quick, value: isHovered)
    }
}

// MARK: - Clipboard Row
//
// Premium list item with swipe-to-reveal actions:
//   • Type icon (color-coded) or image thumbnail
//   • Auto-generated title (bold, 1 line)
//   • Preview body (secondary, 1 line)
//   • Metadata row: relative time · source app · category tag
//   • Status badges (pin / fav) in resting state
//   • Swipe right (←) → Pin, Favorite, Delete (or Delete in trash)
//   • Swipe left  (→) → Copy (or Restore in trash)
//   • Full swipe auto-triggers primary action
//   • Rubber-band physics + spring snap for premium feel
//   • Stronger selected state with left accent bar

/// Static data bag passed to each row for the "More (…)" menu,
/// so the row doesn't need to subscribe to the entire ViewModel.
struct RowOrganizeData {
    let categories: [Category]
    let bundles: [ClipBundle]
    var onSetCategory: ((ClipboardItem, UUID?) -> Void)?
    var onAddToBundle: ((ClipboardItem, ClipBundle) -> Void)?
    var onSetExpiry:   ((ClipboardItem, Date?) -> Void)?
}

struct ClipboardRowView: View {
    let item: ClipboardItem
    let category: Category?
    let isSelected: Bool
    var isMultiSelected: Bool = false      // true when this item is in the multi-select set
    var isMultiSelectActive: Bool = false   // true when ANY item is multi-selected (shows checkboxes on all rows)
    let isTrash: Bool
    var shortcutIndex: Int?        // 0-based → displayed as ⌘1…⌘9
    var onCopy:     (() -> Void)?
    var onFavorite: (() -> Void)?
    var onPin:      (() -> Void)?
    var onDelete:   (() -> Void)?
    var onRestore:  (() -> Void)?
    var onToggleSelect: (() -> Void)?
    var organizeData: RowOrganizeData?

    @State private var isHovered = false
    @State private var offset: CGFloat = 0
    @Environment(\.colorScheme)  private var colorScheme
    @Environment(\.lumaPalette)  private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: AppSettings

    private var isLight: Bool        { colorScheme == .light }
    private var density: ListDensity { settings.listDensity }

    var body: some View {
        ZStack {
            // ── Swipe action buttons (behind the row) ─────────────
            HStack(spacing: 0) {
                leadingSwipeActions
                    .opacity(offset > 4 ? 1 : 0)
                Spacer(minLength: 0)
                trailingSwipeActions
                    .opacity(offset < -4 ? 1 : 0)
            }

            // ── Main row content (slides left / right) ────────────
            HStack(spacing: 0) {

            // ── Multi-select checkbox (visible when any item is selected) ──
            if isMultiSelectActive {
                Button(action: { onToggleSelect?() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isMultiSelected ? Color.accentColor : Color.primary.opacity(0.25),
                                lineWidth: isMultiSelected ? 0 : 1.5
                            )
                            .frame(width: 20, height: 20)

                        if isMultiSelected {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 20, height: 20)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isMultiSelected)
            }

            // ── Type icon / image thumbnail ────────────────────────
            // The source-app icon is overlaid as a corner badge on either
            // the type chip or the image thumbnail, sized in proportion
            // to the host so it stays balanced across density modes.
            if item.contentType == .image, let nsImg = item.nsImage {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: density.thumbSize, height: density.thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: density.thumbCorner))
                    .overlay(
                        RoundedRectangle(cornerRadius: density.thumbCorner)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        SourceAppIconBadge(
                            appName: item.sourceApp,
                            size: max(11, density.thumbSize * 0.45)
                        )
                        .offset(x: 4, y: 4)
                    }
                    .padding(.leading, 14)
            } else {
                Image(systemName: item.contentType.iconName)
                    .font(.system(size: density.iconSize, weight: .medium))
                    .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
                    .frame(width: density.iconFrame, height: density.iconFrame)
                    .background(
                        RoundedRectangle(cornerRadius: density.iconCorner, style: .continuous)
                            .fill(isSelected
                                  ? palette.accent.opacity(0.12)
                                  : palette.textSecondary.opacity(0.08))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        SourceAppIconBadge(
                            appName: item.sourceApp,
                            size: max(12, density.iconFrame * 0.6)
                        )
                        .offset(x: 4, y: 3)
                    }
                    .padding(.leading, 14)
            }

            // ── Content column: title + preview + meta ─────────────
            VStack(alignment: .leading, spacing: density == .compact ? 2 : 3) {

                // Title — bold, single line
                Text(item.title)
                    .font(.system(size: density.titleSize, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Preview body — shown in comfortable mode only
                if density.showPreview,
                   !item.preview.isEmpty,
                   item.preview != item.title {
                    Text(item.preview)
                        .font(.system(size: density.previewSize))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Metadata row
                HStack(spacing: 4) {
                    Text(item.relativeTime)
                        .font(.system(size: density.metaSize))
                        .foregroundStyle(palette.textTertiary)

                    if !item.sourceApp.isEmpty {
                        Text("·".loc)
                            .font(.system(size: density.metaSize))
                            .foregroundStyle(palette.textQuaternary)
                        Text(item.sourceApp)
                            .font(.system(size: density.metaSize))
                            .foregroundStyle(palette.textTertiary)
                    }

                    // Color swatch chip
                    if item.contentType == .color,
                       let swatch = extractColor(from: item.content) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swatch)
                            .frame(width: density == .compact ? 20 : 28, height: density == .compact ? 8 : 10)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                    }

                    // Category tag
                    if let cat = category {
                        Text(cat.name)
                            .font(.system(size: density == .compact ? 8 : 9, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, density == .compact ? 4 : 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.textSecondary.opacity(0.10)))
                    }
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 4)

            // ── Right cluster: resting badges ↔ hover quick actions ──
            //
            // Same horizontal slot, cross-faded by `isHovered`. Badges
            // are information (state of the item); quick actions are
            // verbs (things the user can do to it) — you never need
            // both visible simultaneously, and swapping them keeps the
            // row compact. The ⌘N shortcut number stays visible in
            // both states so users can always see the keybinding.
            ZStack(alignment: .trailing) {
                // Resting badges
                HStack(spacing: 5) {
                    if item.isSensitive {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hue: 0.08, saturation: 0.75, brightness: 0.90))
                            .help("Sensitive content detected".loc)
                    }
                    if item.isBurnAfterPaste {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hue: 0.02, saturation: 0.70, brightness: 0.92))
                            .help("Burns after next paste".loc)
                    }
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0xFFCC00))
                    }
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.textTertiary)
                    }
                    if let idx = shortcutIndex {
                        Text("⌘\(idx + 1)".loc)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.textQuaternary)
                    }
                }
                .opacity(isHovered ? 0 : 1)
                .allowsHitTesting(!isHovered)

                // Hover quick-action cluster. `allowsHitTesting` is
                // gated on `isHovered` so the invisible buttons don't
                // steal clicks from the row's own tap gestures when
                // the pointer is elsewhere.
                quickActions
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
            .padding(.trailing, 14)
        }
        .padding(.vertical, density == .compact ? 8 : 10)
        .padding(.horizontal, 4)
        .background(rowBackground)
        // Spec §6: hovered rows nudge 2pt to the trailing edge so the
        // pointer feels like it's pulling the row out for inspection.
        // Suppressed entirely when the OS-level Reduce Motion flag is
        // set — keeps the row visually still but the border/shadow
        // hover treatment continues to fire so the affordance is still
        // legible. No translation while a swipe is in progress
        // (`offset != 0`) so the gesture isn't fighting an opposing
        // transform.
        .offset(x: offset + (!reduceMotion && isHovered && offset == 0 ? 2 : 0))
        .animation(LumaDesign.Motion.quick, value: isHovered)
        } // ZStack
        .clipShape(RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous))
        // ── Trackpad two-finger swipe → drives $offset ──
        .background(
            TrackpadSwipeHandler(
                offset: $offset,
                leadingWidth: leadingWidth,
                trailingWidth: trailingWidth,
                snapThreshold: Self.snapThreshold,
                onFullSwipeLeading:  { isTrash ? onRestore?() : onCopy?() },
                onFullSwipeTrailing: { onDelete?() }
            )
        )
        // Multi-select highlight
        .overlay {
            if isMultiSelected {
                Rectangle()
                    .fill(Color.accentColor.opacity(isLight ? 0.06 : 0.08))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isMultiSelected)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isMultiSelectActive)
        .animation(.easeOut(duration: 0.10), value: isHovered)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
            // Auto-dismiss revealed actions when cursor leaves the row
            if !hovering && offset != 0 {
                withAnimation(.spring(response: 0.40, dampingFraction: 0.85)) {
                    offset = 0
                }
            }
        }
    }

    // MARK: - Swipe Actions

    private var rowCorner: CGFloat { 0 }
    private var actionSize: CGFloat { density == .compact ? 54 : 62 }
    private var leadingWidth: CGFloat { actionSize }
    private var trailingWidth: CGFloat { isTrash ? actionSize : actionSize * 3 }
    private static let snapThreshold: CGFloat = 36

    // MARK: - Hover Quick Actions
    //
    // Cluster of tap-target buttons revealed on hover. Each button
    // forwards to the row's existing `on*` callbacks so the view
    // model — not the row — owns the actual mutation and undo
    // registration. No new ViewModel surface is introduced; this is
    // pure UI rehydration of callbacks that were already wired.

    @ViewBuilder
    private var quickActions: some View {
        HStack(spacing: 2) {
            if isTrash {
                quickActionButton(
                    icon: "arrow.uturn.backward",
                    help: "Restore"
                ) { onRestore?() }

                quickActionButton(
                    icon: "trash",
                    help: "Delete permanently",
                    tint: Color(hue: 0.0, saturation: 0.72, brightness: 0.88)
                ) { onDelete?() }
            } else {
                quickActionButton(
                    icon: "doc.on.doc",
                    help: "Copy"
                ) { onCopy?() }

                quickActionButton(
                    icon: item.isPinned ? "pin.slash.fill" : "pin",
                    help: item.isPinned ? "Unpin" : "Pin",
                    tint: item.isPinned ? .orange : nil
                ) { onPin?() }

                quickActionButton(
                    icon: item.isFavorite ? "star.slash.fill" : "star",
                    help: item.isFavorite ? "Unfavorite" : "Favorite",
                    tint: item.isFavorite ? Color(hex: 0xFFCC00) : nil
                ) { onFavorite?() }

                // More / Organize menu. Only rendered when the parent
                // passed in organizeData — i.e. outside trash. The
                // Menu popup takes its own event capture once open,
                // so the row's hover state flipping off doesn't close
                // it mid-navigation.
                if let data = organizeData {
                    Menu {
                        organizeMenuContent(data: data)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions".loc)
                }

                quickActionButton(
                    icon: "trash",
                    help: "Move to Trash",
                    tint: Color(hue: 0.0, saturation: 0.72, brightness: 0.88)
                ) { onDelete?() }
            }
        }
    }

    @ViewBuilder
    private func quickActionButton(
        icon: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? palette.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Organize submenu content for the hover More button. Mirrors
    /// the context-menu version at `ClipboardListView.itemOrganizeMenu`
    /// but routes through the passed-in `RowOrganizeData` callbacks
    /// so the row doesn't need a ViewModel reference.
    @ViewBuilder
    private func organizeMenuContent(data: RowOrganizeData) -> some View {
        if !data.categories.isEmpty {
            Menu {
                Button { data.onSetCategory?(item, nil) } label: {
                    Label("None".loc, systemImage: "xmark")
                }
                Divider()
                ForEach(data.categories) { cat in
                    Button { data.onSetCategory?(item, cat.id) } label: {
                        Label(cat.name, systemImage: cat.icon)
                    }
                }
            } label: {
                Label("Set Category".loc, systemImage: "tag")
            }
        }

        if !data.bundles.isEmpty {
            Menu {
                ForEach(data.bundles) { bundle in
                    Button { data.onAddToBundle?(item, bundle) } label: {
                        Label(bundle.name, systemImage: bundle.icon)
                    }
                }
            } label: {
                Label("Add to Bundle".loc, systemImage: "rectangle.stack.badge.plus")
            }
        }

        Menu {
            Button { data.onSetExpiry?(item, nil) } label: {
                Label("No Expiry".loc, systemImage: "infinity")
            }
            Divider()
            ForEach(RetentionRule.presetDurations, id: \.1) { label, duration in
                if duration > 0 {
                    Button {
                        data.onSetExpiry?(item, Date().addingTimeInterval(duration))
                    } label: {
                        Text(label)
                    }
                }
            }
        } label: {
            Label("Set Expiry".loc, systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private var leadingSwipeActions: some View {
        let progress = min(max(offset / leadingWidth, 0), 1)
        if isTrash {
            swipeActionCell(icon: "arrow.uturn.backward", label: "Restore".loc,
                            color: .green, progress: progress) {
                dismissAndRun { onRestore?() }
            }
        } else {
            swipeActionCell(icon: "doc.on.doc", label: "Copy".loc,
                            color: palette.accent, progress: progress) {
                dismissAndRun { onCopy?() }
            }
        }
    }

    @ViewBuilder
    private var trailingSwipeActions: some View {
        let progress = min(max(-offset / trailingWidth, 0), 1)
        if isTrash {
            swipeActionCell(icon: "trash", label: "Delete".loc,
                            color: .red, progress: progress) {
                dismissAndRun { onDelete?() }
            }
        } else {
            swipeActionCell(icon: item.isPinned ? "pin.slash.fill" : "pin",
                            label: item.isPinned ? "Unpin" : "Pin",
                            color: .orange, progress: progress) {
                dismissAndRun { onPin?() }
            }
            swipeActionCell(icon: item.isFavorite ? "star.fill" : "star",
                            label: item.isFavorite ? "Unfav" : "Fav",
                            color: Color(hue: 0.13, saturation: 0.85, brightness: 0.92),
                            progress: progress) {
                dismissAndRun { onFavorite?() }
            }
            swipeActionCell(icon: "trash", label: "Delete".loc,
                            color: Color(hue: 0.0, saturation: 0.72, brightness: 0.88),
                            progress: progress) {
                dismissAndRun { onDelete?() }
            }
        }
    }

    @ViewBuilder
    private func swipeActionCell(
        icon: String, label: String, color: Color,
        progress: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: density == .compact ? 13 : 15, weight: .semibold))
                Text(label)
                    .font(.system(size: density == .compact ? 8 : 9.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(0.3 + 0.7 * Double(progress))
            .frame(width: actionSize)
            .frame(maxHeight: .infinity)
            .background(color)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(progress > 0.7)
    }

    private func dismissAndRun(_ action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            offset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            action()
        }
    }

    // MARK: - Background
    //
    // Editorial card-shaped row background per spec §5.3.
    //   default  → surface card, subtle hairline
    //   hover    → strong hairline, faint shadow
    //   selected → lime-tinted ground, lime border, soft glow.
    // The selected state keeps the row's inline text/icon colours
    // readable (no inversion) — full deep-ink-slab focused row is a
    // separate follow-up that would need a coordinated re-tune of
    // every inline foregroundStyle inside the row.

    private var rowBackground: some View {
        let fill: Color = {
            if isSelected { return palette.selectedBg }
            if isHovered  { return palette.cardBg }
            return palette.cardBg
        }()

        let border: Color = {
            if isSelected { return palette.accentBright.opacity(0.55) }
            if isHovered  { return palette.borderStrong }
            return palette.borderSubtle
        }()

        let shadowColor: Color = {
            if isSelected { return palette.accentBright.opacity(0.18) }
            if isHovered  { return Color.black.opacity(0.06) }
            return Color.clear
        }()

        let shadowRadius: CGFloat = isSelected ? 10 : (isHovered ? 4 : 0)
        let shadowY: CGFloat = isSelected ? 4 : (isHovered ? 2 : 0)

        return RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .strokeBorder(border, lineWidth: isSelected ? 1 : 0.5)
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    }

    // MARK: - Aging Heat Map Helpers

    private var ageFraction: Double {
        let age = Date().timeIntervalSince(item.createdAt)
        return min(age / (30 * 86400), 1.0)
    }

    private var rowOpacity: Double {
        let minOpacity = 0.65
        return minOpacity + (1.0 - minOpacity) * (1.0 - ageFraction)
    }

    private var isHot: Bool {
        Date().timeIntervalSince(item.createdAt) < 300
    }

    private var isWarm: Bool {
        Date().timeIntervalSince(item.createdAt) < 86400 && !isHot
    }

    // MARK: - Helpers

    private var typeColor: Color {
        item.contentType.color
    }

    /// Try to parse a CSS hex string into a SwiftUI Color.
    private func extractColor(from text: String) -> Color? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return nil }
        let hex = s.dropFirst()
        var rgb: UInt64 = 0
        if hex.count == 3 {
            let r = String(repeating: String(hex.prefix(1)), count: 2)
            let g = String(repeating: String(hex.dropFirst(1).prefix(1)), count: 2)
            let b = String(repeating: String(hex.dropFirst(2).prefix(1)), count: 2)
            Scanner(string: r+g+b).scanHexInt64(&rgb)
        } else if hex.count == 6 {
            Scanner(string: String(hex)).scanHexInt64(&rgb)
        } else {
            return nil
        }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255.0,
                     green: Double((rgb >> 8)  & 0xFF) / 255.0,
                     blue:  Double(rgb          & 0xFF) / 255.0)
    }
}

// MARK: - Trackpad Two-Finger Swipe Handler
//
// Captures two-finger trackpad horizontal swipe (scroll-wheel events
// with `hasPreciseScrollingDeltas`) and drives the row's swipe offset.
// Each visible row installs a lightweight local NSEvent monitor. The
// monitor checks the cursor position against the backing NSView's frame
// so only the row under the pointer drives the offset. Momentum events
// after a horizontal swipe are swallowed so the row doesn't coast.

private struct TrackpadSwipeHandler: NSViewRepresentable {
    @Binding var offset: CGFloat
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    let snapThreshold: CGFloat
    var onFullSwipeLeading:  (() -> Void)?
    var onFullSwipeTrailing: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.view = v
        context.coordinator.installMonitor()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        c.offsetBinding = $offset
        c.lw  = leadingWidth
        c.tw  = trailingWidth
        c.snap = snapThreshold
        c.onLeading  = onFullSwipeLeading
        c.onTrailing = onFullSwipeTrailing
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // ── Coordinator ─────────────────────────────────────────────

    final class Coordinator {
        weak var view: NSView?
        var offsetBinding: Binding<CGFloat>?
        var lw:   CGFloat = 62
        var tw:   CGFloat = 186
        var snap: CGFloat = 36
        var onLeading:  (() -> Void)?
        var onTrailing: (() -> Void)?

        private var monitor: Any?
        private var tracking  = false
        private var locked    = false
        private var horiz     = false
        private var cumX: CGFloat = 0

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        // MARK: Event Handler

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Only precise (trackpad) events
            guard event.hasPreciseScrollingDeltas,
                  let view = view, view.bounds.size != .zero,
                  let window = view.window else { return event }

            // Is the cursor over this row *and* is the row the topmost
            // view at that point? The second half matters because the
            // Detail drawer overlays the rows on the right edge of the
            // window — a plain `bounds.contains(loc)` check returns true
            // for rows that are visually covered by the drawer, letting
            // horizontal scrolls inside the drawer's Quick Transforms
            // row swipe the underlying row by mistake.
            let loc = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(loc) else { return event }
            if let hit = window.contentView?.hitTest(event.locationInWindow),
               hit !== view, !hit.isDescendant(of: view) {
                // Another view (drawer, modal, etc.) is on top here —
                // don't steal the scroll from it, and drop any
                // in-progress tracking that cumulative-X might carry
                // over from a previous gesture over this row.
                tracking = false
                locked   = false
                horiz    = false
                cumX     = 0
                return event
            }

            // Swallow momentum after a tracked horizontal swipe
            if event.momentumPhase != [] {
                return tracking ? nil : event
            }

            switch event.phase {
            case .began:
                tracking = false; locked = false; horiz = false; cumX = 0
                return event          // always pass .began through

            case .changed:
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                // Lock axis on first significant movement
                if !locked, abs(dx) > 1.5 || abs(dy) > 1.5 {
                    locked = true
                    horiz  = abs(dx) >= abs(dy)
                }
                guard horiz else { return event }   // vertical → ScrollView
                tracking = true

                // Dampen the delta for a smoother, more deliberate feel
                cumX += dx * 0.6

                // Rubber-band past reveal width
                var o = cumX
                if o > lw  { o =  lw + Self.rubber( o - lw, limit: 40) }
                if o < -tw { o = -(tw + Self.rubber(abs(o) - tw, limit: 40)) }
                offsetBinding?.wrappedValue = o
                return nil                          // consume horizontal scroll

            case .ended, .cancelled:
                guard tracking else { return event }

                let h = cumX

                // ── Full swipe right → primary leading action ─────
                if h > lw * 2 {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                        offsetBinding?.wrappedValue = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                        self?.onLeading?()
                    }
                    tracking = false; return nil
                }
                // ── Full swipe left → primary trailing action ─────
                if h < -tw * 1.6 {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                        offsetBinding?.wrappedValue = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                        self?.onTrailing?()
                    }
                    tracking = false; return nil
                }
                // ── Snap to reveal or snap back ───────────────────
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    if h > snap       { offsetBinding?.wrappedValue =  lw }
                    else if h < -snap { offsetBinding?.wrappedValue = -tw }
                    else              { offsetBinding?.wrappedValue =  0  }
                }
                tracking = false; return nil

            default:
                return event
            }
        }

        private static func rubber(_ excess: CGFloat, limit: CGFloat) -> CGFloat {
            guard excess > 0 else { return 0 }
            return limit * (1 - exp(-excess / limit))
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let filter: SidebarFilter
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                // Icon container with glow ring
                ZStack {
                    Circle()
                        .fill(palette.borderSubtle)
                        .frame(width: 68, height: 68)
                    Circle()
                        .strokeBorder(palette.borderDefault, lineWidth: 0.75)
                        .frame(width: 68, height: 68)
                    Image(systemName: emptyIcon)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(palette.textTertiary)
                }

                VStack(spacing: 6) {
                    Text(emptyTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)

                    Text(emptySubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var emptyIcon: String {
        switch filter {
        case .all:       return "clipboard"
        case .favorites: return "star"
        case .recent:    return "clock"
        case .trash:     return "trash"
        default:         return "tray"
        }
    }
    private var emptyTitle: String {
        switch filter {
        case .all:       return "No Clips Yet"
        case .favorites: return "No Favorites"
        case .recent:    return "Nothing Recent"
        case .trash:     return "Trash is Empty"
        default:         return "No Items"
        }
    }
    private var emptySubtitle: String {
        switch filter {
        case .all:       return "Copy something to get started.\nLumaClip will capture it here."
        case .favorites: return "Star clips to surface them quickly."
        case .recent:    return "Items copied in the last 24 hours\nwill appear here."
        case .trash:     return "Deleted clips move here\nuntil permanently removed."
        default:         return "No items match this filter."
        }
    }
}

// MARK: - Multi-Select Action Bar

private struct MultiSelectBar: View {
    let count: Int
    let totalCount: Int
    let isAllSelected: Bool
    let isTrash: Bool
    let onSelectAll: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var showConfirm = false
    @State private var isDeleteHovered = false
    @State private var isCancelHovered = false
    @State private var isSelectAllHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isLight: Bool { colorScheme == .light }

    var body: some View {
        HStack(spacing: 0) {

            // ── Left: count pill ────────────────────────────────
            HStack(spacing: 6) {
                Text("\(count)".loc)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))

                Text(count == 1 ? "item selected" : "items selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // ── Right: actions ──────────────────────────────────
            if showConfirm {
                // Inline confirmation
                HStack(spacing: 8) {
                    Text(isTrash ? "Delete permanently?" : "Move to trash?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showConfirm = false }
                    } label: {
                        Text("No".loc)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showConfirm = false
                        onDelete()
                    } label: {
                        Text("Yes, delete".loc)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                HStack(spacing: 8) {
                    // Select All / Deselect
                    if isAllSelected {
                        Button {
                            onCancel()
                        } label: {
                            Text("Deselect All".loc)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isCancelHovered ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.primary.opacity(isCancelHovered ? 0.08 : 0.04))
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { isCancelHovered = $0 }
                    } else {
                        Button {
                            onCancel()
                        } label: {
                            Text("Deselect".loc)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isCancelHovered ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.primary.opacity(isCancelHovered ? 0.08 : 0.04))
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { isCancelHovered = $0 }

                        Button {
                            onSelectAll()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("All".loc)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(isSelectAllHovered ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(isSelectAllHovered ? 0.08 : 0.04))
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isSelectAllHovered = $0 }
                    }

                    // Delete
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                            showConfirm = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                            Text(isTrash ? "Delete" : "Trash")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isDeleteHovered ? Color.red : Color.red.opacity(0.85))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isDeleteHovered = $0 }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(isLight
                    ? Color(NSColor.windowBackgroundColor)
                    : Color(NSColor.controlBackgroundColor).opacity(0.90)
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 4, y: -2)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.80), value: showConfirm)
    }
}

// MARK: - Empty Trash Bar
//
// Styled to match the glass aesthetic: subtle separator on top,
// muted text + icon in default state, gentle highlight on hover,
// inline confirmation that slides in without a loud red banner.

private struct EmptyTrashBar: View {
    let action: () -> Void
    @State private var isHovered = false
    @State private var showConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            if showConfirm {
                // ── Inline confirmation ──────────────────────────
                HStack(spacing: 10) {
                    Text("Delete all items permanently?".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showConfirm = false }
                    } label: {
                        Text("Cancel".loc)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        action()
                        withAnimation(.easeOut(duration: 0.15)) { showConfirm = false }
                    } label: {
                        Text("Delete All".loc)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.red.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                // ── Default state ────────────────────────────────
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        showConfirm = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                        Text("Empty Trash".loc)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.primary.opacity(isHovered ? 0.08 : 0.04))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            // Subtle top separator matching the glass divider style
            Rectangle()
                .fill(Color.clear)
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(.primary.opacity(0.08)),
                    alignment: .top
                )
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showConfirm)
    }
}

// MARK: - Keyboard Navigation
//
// Uses an NSEvent local monitor so key events are captured regardless
// of which SwiftUI element holds focus. This reliably handles arrow
// keys, Return, Space, Delete, and ⌘-modified shortcuts.
//
// Key map:
//   ↑ / ↓           Move selection
//   Enter            Copy selected item
//   Space            Toggle detail drawer
//   ⌘ F              Focus search field
//   ⌘ Delete         Delete selected item
//   ⌘ P              Toggle pin on selected item
//   ⌘ 1–9            Copy Nth item (handled by hidden shortcut buttons)

/// Adds the global keyboard handler. Mounted at the **panel** level
/// (MainPanelView) — not the list level — so the monitor stays installed
/// when the user navigates to Bundles or Settings, where ClipboardListView
/// is unmounted. Without this lift, arrow-key sidebar navigation would
/// silently die the moment the right pane swapped to a non-list view.
struct KeyboardNavigationModifier: ViewModifier {
    @ObservedObject var viewModel: ClipboardViewModel

    func body(content: Content) -> some View {
        content
            .background(
                KeyboardEventHandler(viewModel: viewModel)
                    .frame(width: 0, height: 0)
            )
    }
}

/// NSView-based keyboard event handler that installs a local monitor.
struct KeyboardEventHandler: NSViewRepresentable {
    @ObservedObject var viewModel: ClipboardViewModel

    // macOS key codes
    private static let kUpArrow: Int      = 126
    private static let kDownArrow: Int    = 125
    private static let kLeftArrow: Int    = 123  // hide detail drawer
    private static let kRightArrow: Int   = 124  // shift focus to Inspector
    private static let kReturn: Int       = 36
    private static let kDelete: Int       = 51   // backspace
    private static let kFwdDelete: Int    = 117  // fn+Delete
    private static let kP: Int            = 35
    private static let kZ: Int            = 6

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        let vm = viewModel

        // Install a local event monitor — fires for all key events in the app.
        // Local monitors are app-scoped; no need for a keyWindow guard.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let hasCmd = event.modifierFlags.contains(.command)

            // ── ⌘-shortcuts — always handled regardless of focus ──
            if hasCmd {
                let hasShift = event.modifierFlags.contains(.shift)

                // Exception: ⌘Z / ⌘⇧Z while a text field is focused
                // should go to the field's own undo (undo typing),
                // not our list-level undo. Detecting a field editor
                // here mirrors the guard further down for unmodified keys.
                if code == Self.kZ {
                    let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    if let tv = activeWindow?.firstResponder as? NSTextView, tv.isFieldEditor {
                        return event
                    }
                }

                // ⌘⌫ and ⌘P operate on the active clip selection — gate
                // them when no clip list is on screen (Bundles, Settings).
                // ⌘Z stays unconditional: undo applies to clip mutations
                // that happened when the list WAS visible, and the user
                // can reasonably want to undo from anywhere.
                let isClipListActive: Bool = {
                    switch vm.activeFilter {
                    case .settings, .bundles: return false
                    default:                  return true
                    }
                }()

                switch code {
                case Self.kDelete:
                    guard isClipListActive else { return event }
                    Task { @MainActor in vm.deleteSelected() }
                    return nil
                case Self.kP:
                    guard isClipListActive else { return event }
                    Task { @MainActor in vm.pinSelected() }
                    return nil
                case Self.kZ:
                    // ⌘Z → undo, ⌘⇧Z → redo. Swallow the event regardless
                    // of whether the stack has anything left — letting
                    // it fall through can cause AppKit to beep when no
                    // responder upstream claims the shortcut.
                    Task { @MainActor in
                        if hasShift {
                            if vm.canRedo { vm.redo() }
                        } else {
                            if vm.canUndo { vm.undo() }
                        }
                    }
                    return nil
                default:
                    return event
                }
            }

            // ── Text field guard ──────────────────────────────────
            // AppKit sets isFieldEditor = true on the shared NSTextView that
            // handles editing for any NSTextField (including our InlineSearchField).
            // SwiftUI's own internal NSTextViews are NOT field editors, so this
            // correctly passes through only when the search bar is active.
            // (Checking tv.delegate is NSTextField was wrong: KeyMonitor replaces
            //  the field editor's delegate, so that check always failed.)
            let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow
            if let tv = activeWindow?.firstResponder as? NSTextView, tv.isFieldEditor {
                return event   // search bar is active — let it handle all keys
            }

            // ── Unmodified navigation shortcuts ───────────────────
            //
            // Finder-style column navigation:
            //   ↑ ↓ — move within the currently focused zone
            //   →    — shift focus rightward (sidebar → list → drawer)
            //   ←    — shift focus leftward  (drawer → list → sidebar)
            //
            // ↑/↓ dispatch is driven by `focusedZone` so the same physical
            // key drives sidebar-item nav or list-row nav depending on
            // where focus currently sits. Right/Left only emit a directed
            // signal; MainPanelView owns the actual focus transitions and
            // any drawer open/close that comes with them.
            //
            // Now that this handler is mounted on MainPanelView (not on
            // ClipboardListView), it stays installed when the right pane
            // is showing Bundles or Settings. Arrow keys still need to
            // work there for sidebar navigation, but Return / Space /
            // Backspace operate on `selectedItem`, which would silently
            // act on a hidden clip list — so we let those keys pass
            // through to native handlers (form controls, button actions)
            // when no clip list is on screen.
            let isClipListVisible: Bool = {
                switch vm.activeFilter {
                case .settings, .bundles: return false
                default:                  return true
                }
            }()

            switch code {
            case Self.kUpArrow:
                Task { @MainActor in
                    switch vm.focusedZone {
                    case .sidebar: vm.moveSidebarSelectionUp()
                    case .list:    vm.moveSelectionUp()
                    case .drawer:  break  // drawer doesn't yet have keyboard nav
                    }
                }
                return nil
            case Self.kDownArrow:
                Task { @MainActor in
                    switch vm.focusedZone {
                    case .sidebar: vm.moveSidebarSelectionDown()
                    case .list:    vm.moveSelectionDown()
                    case .drawer:  break
                    }
                }
                return nil
            case Self.kReturn:
                guard isClipListVisible else { return event }
                Task { @MainActor in vm.copySelected() }
                return nil
            case Self.kRightArrow:
                Task { @MainActor in vm.focusRightRequested.toggle() }
                return nil
            case Self.kLeftArrow:
                Task { @MainActor in vm.focusLeftRequested.toggle() }
                return nil
            case Self.kDelete, Self.kFwdDelete:
                guard isClipListVisible else { return event }
                Task { @MainActor in vm.deleteSelected() }
                return nil
            default:
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var monitor: Any?
    }
}

/// A simple NSView subclass that can become first responder
/// and forward key events.
private class KeyCaptureView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let handler = onKeyDown, handler(event) {
            return // handled
        }
        super.keyDown(with: event)
    }
}

// MARK: - Instant Row Button Style

private struct InstantRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

// MARK: - Copy Toast

private struct CopyToastView: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            Text("Copied to clipboard".loc)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        )
    }
}
