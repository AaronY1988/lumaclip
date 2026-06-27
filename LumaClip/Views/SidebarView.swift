// SidebarView.swift
// LumaClip — macOS Clipboard Manager
//
// Premium redesign: cleaner grouping, refined selection treatment,
// tasteful category colours, smooth hover/active states, and a
// polished brand area at the top. Preserves all existing actions.

import SwiftUI

// MARK: - Sidebar View

struct SidebarView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.colorScheme)  private var scheme
    @Environment(\.lumaPalette)  private var palette
    @EnvironmentObject private var settings: AppSettings

    @State private var showCategoryPopup = false
    @State private var editingCategory:   Category? = nil
    @State private var categoriesExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Nav card container ──────────────────────────────
            VStack(alignment: .leading, spacing: 0) {

                // ── Brand header (with gear menu) ───────────────
                //
                // Editorial brand block at the top of the sidebar. The
                // gear menu absorbs Trash + Settings, which previously
                // lived in a "SYSTEM" section pinned at the bottom — the
                // bottom is now reserved for the Storage card so storage
                // hygiene reads at a glance and the trash/settings
                // entries become tools you reach for, not chrome you
                // stare at all session.
                brandHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                SidebarSectionDivider()
                    .padding(.bottom, 6)

                // ── Scrollable nav ──────────────────────────────
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // 1. Primary Navigation
                        navSection {
                            SidebarNavItem(
                                icon: "tray.full.fill",
                                label: "All Clips".loc,
                                count: viewModel.allCount,
                                isSelected: viewModel.activeFilter == .all,
                                action: { viewModel.switchFilter(.all) }
                            )
                            SidebarNavItem(
                                icon: "star.fill",
                                label: "Favorites".loc,
                                count: viewModel.favoritesCount > 0 ? viewModel.favoritesCount : nil,
                                isSelected: viewModel.activeFilter == .favorites,
                                action: { viewModel.switchFilter(.favorites) }
                            )
                            SidebarNavItem(
                                icon: "clock.fill",
                                label: "Recent".loc,
                                count: nil,
                                isSelected: viewModel.activeFilter == .recent,
                                action: { viewModel.switchFilter(.recent) }
                            )
                            SidebarNavItem(
                                icon: "pin.fill",
                                label: "Pinned".loc,
                                count: viewModel.pinnedItems.count > 0 ? viewModel.pinnedItems.count : nil,
                                iconTint: palette.accentWarm,
                                isSelected: false,
                                action: { /* pinned items shown inline in list */ }
                            )
                        }

                        // 2. Categories
                        SidebarSectionDivider()

                        categorySectionHeader
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        if categoriesExpanded {
                            categoriesContent
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal:   .opacity
                                    )
                                )
                        }

                        // 3. Bundles
                        SidebarSectionDivider()
                            .padding(.top, 4)

                        sectionLabel("COLLECTIONS")
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        navSection {
                            SidebarNavItem(
                                icon: "rectangle.stack.fill",
                                label: "Bundles".loc,
                                count: viewModel.bundles.isEmpty ? nil : viewModel.bundles.count,
                                isSelected: viewModel.activeFilter == .bundles,
                                action: { viewModel.switchFilter(.bundles) }
                            )
                        }

                        Color.clear.frame(height: 8)
                    }
                }
                .layoutPriority(1)

                // ── Storage card (pinned bottom) ────────────────
                //
                // Replaces the previous Trash + Settings rows. Driven
                // by `viewModel.allCount` and `AppSettings.maxHistoryCount`
                // — both of which exist already; no new persistence,
                // no new computation, just a different visual surface
                // for data the app already tracks.
                StorageCard(
                    used: viewModel.allCount,
                    capacity: settings.maxHistoryCount
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 6)
            }
            .padding(.bottom, 0)
            .background(sidebarCardBackground)
            // Keyboard-focus ring: a subtle accent stroke that appears
            // only when this zone holds focus. Animated so the user
            // sees the focus snap from column to column rather than
            // flicker.
            .overlay(sidebarFocusRing)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showCategoryPopup) {
            CategoryEditorPopup(
                viewModel: viewModel,
                editingCategory: editingCategory,
                onDismiss: {
                    showCategoryPopup = false
                    editingCategory = nil
                }
            )
        }
    }

    // MARK: - Card Background & Focus Ring (extracted for type-checker)
    //
    // The original inline `.background(RoundedRectangle…fill…overlay…
    // shadow…shadow)` with `.overlay(RoundedRectangle…)` chain — every
    // color a scheme-conditional ternary — exceeded the SwiftUI type-
    // checker's complexity budget on macOS 13's Swift compiler. Each
    // helper below is a small, separately-typed `some View`, which keeps
    // the constraint solver well within bounds. Behaviour matches the
    // previous inline form exactly.

    /// Rounded card sitting behind the sidebar's nav contents — fill +
    /// hairline border + dual shadow.
    private var sidebarCardBackground: some View {
        let fillColor: Color = scheme == .dark
            ? Color.white.opacity(0.05)
            : Color.white.opacity(0.85)
        let strokeColor: Color = scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
        let bigShadow: Color = scheme == .dark
            ? Color.black.opacity(0.40)
            : Color.black.opacity(0.08)
        let smallShadow: Color = scheme == .dark
            ? Color.black.opacity(0.20)
            : Color.black.opacity(0.03)
        let bigRadius: CGFloat = scheme == .dark ? 12 : 8
        let bigYOffset: CGFloat = scheme == .dark ? 4 : 2

        return RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 0.5)
            )
            .shadow(color: bigShadow, radius: bigRadius, x: 0, y: bigYOffset)
            .shadow(color: smallShadow, radius: 2, x: 0, y: 1)
    }

    /// Keyboard-focus ring for the sidebar zone.
    private var sidebarFocusRing: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(
                viewModel.focusedZone == .sidebar
                    ? palette.accent.opacity(0.55)
                    : Color.clear,
                lineWidth: 1.5
            )
            .animation(LumaDesign.Motion.select,
                       value: viewModel.focusedZone)
    }

    // MARK: Brand Header
    //
    // Editorial brand block per the redesign spec:
    //   – Square ink-black mark with a lime-green inner stroke; serif "L"
    //     glyph centred (Cormorant Garamond falls back to system serif).
    //   – Wordmark uses the same serif: roman "Luma" + italic "Clip".
    //     The italic split is a deliberate editorial gesture — same trick
    //     the spec calls for in "Clip<em>store</em>", adapted to the
    //     actual product name.
    //   – Mono caption underneath shows the marketing version pulled from
    //     `Bundle.main`. Tracked in code (not hard-coded) so it reflects
    //     whatever ships.
    //   – A gear menu on the right opens Trash and Settings — neither
    //     route changed; both still call `viewModel.switchFilter(...)`,
    //     just from a different surface.
    private var brandHeader: some View {
        HStack(spacing: 10) {

            // ── Brand mark ──────────────────────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(palette.focusInk)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                palette.accentBright.opacity(0.50),
                                lineWidth: 1
                            )
                            .padding(2)
                    )

                Text("L".loc)
                    .font(LumaDesign.Typography.serifItalic(20))
                    .foregroundStyle(palette.focusPaper)
                    .offset(y: -1)
            }

            // ── Wordmark + version ──────────────────────────────
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text("Luma".loc)
                        .font(LumaDesign.Typography.serif(19))
                        .foregroundStyle(palette.textPrimary)
                    Text("Clip".loc)
                        .font(LumaDesign.Typography.serifItalic(19))
                        .foregroundStyle(palette.textSecondary)
                }
                .kerning(-0.2)

                Text(versionCaption)
                    .font(LumaDesign.Typography.mono(9, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .tracking(0.6)
            }

            Spacer(minLength: 4)

            // ── Gear menu (Trash / Settings) ────────────────────
            Menu {
                Button {
                    viewModel.switchFilter(.trash)
                } label: {
                    Label(
                        viewModel.trashCount > 0
                            ? "\("Trash".loc) (\(viewModel.trashCount))"
                            : "Trash".loc,
                        systemImage: "trash"
                    )
                }
                Button {
                    viewModel.switchFilter(.settings)
                } label: {
                    Label("Settings".loc, systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.hoverBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More".loc)
        }
    }

    /// Marketing version + edition, pulled from `Bundle.main` so the
    /// caption stays accurate after a bump. Falls back to a flat label
    /// if the plist key is missing (shouldn't happen — Xcode generates it).
    private var versionCaption: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v \(v ?? "—") · CLIP"
    }

    // MARK: Category Section Header

    private var categorySectionHeader: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(LumaDesign.Motion.select) {
                    categoriesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(categoriesExpanded ? 90 : 0))
                        .animation(LumaDesign.Motion.select, value: categoriesExpanded)

                    sectionLabel("CATEGORIES")
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Add category button
            Button {
                editingCategory = nil
                showCategoryPopup = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.xs, style: .continuous)
                            .fill(palette.hoverBg)
                    )
            }
            .buttonStyle(.plain)
            .help("New category".loc)
        }
    }

    // MARK: Categories Content

    @ViewBuilder
    private var categoriesContent: some View {
        if viewModel.categories.isEmpty {
            HStack {
                Text("No categories yet".loc)
                    .font(LumaDesign.Typography.serifItalic(12))
                    .foregroundStyle(palette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        } else {
            VStack(spacing: 1) {
                ForEach(viewModel.categories) { category in
                    SidebarNavItem(
                        icon: category.icon,
                        label: category.name,
                        count: viewModel.categoryCount(for: category.id),
                        iconTint: category.color.color,
                        // Spec §3: categories show a coloured square mark
                        // instead of a flat tinted SF Symbol. The mark
                        // wraps the user's chosen icon — colour AND glyph
                        // both convey identity, which is stronger than
                        // either alone (we don't lose the icon the user
                        // picked when they made the category).
                        markStyle: .colorBlock,
                        isSelected: viewModel.activeFilter == .category(category.id),
                        action: { viewModel.switchFilter(.category(category.id)) }
                    )
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        guard let idStr = droppedIDs.first,
                              let itemID = UUID(uuidString: idStr) else { return false }
                        viewModel.setCategory(itemId: itemID, categoryId: category.id)
                        return true
                    } isTargeted: { _ in }
                    .onTapGesture(count: 2) {
                        editingCategory = category
                        showCategoryPopup = true
                    }
                    .contextMenu {
                        Button {
                            editingCategory = category
                            showCategoryPopup = true
                        } label: {
                            Label("Edit Category".loc, systemImage: "pencil")
                        }
                        Divider()
                        Button("Delete Category".loc, role: .destructive) {
                            viewModel.deleteCategory(category)
                        }
                    }
                }
            }
            .padding(.horizontal, 7)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func navSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 1) {
            content()
        }
        .padding(.horizontal, 7)
    }

    /// Spec §3 calls for: Mono · 9px · 700 weight · 0.16em uppercase
    /// tracking. The previous label used the system sans at semibold —
    /// retuned to monospace + heavier tracking so section labels read
    /// as "data eyebrows" rather than "header text".
    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(LumaDesign.Typography.mono(9, weight: .bold))
            .foregroundStyle(palette.textTertiary)
            .tracking(1.6)
    }
}

// MARK: - Sidebar Nav Item

/// Visual treatment for the leading icon slot.
///
/// `.glyph` (default) renders the SF Symbol directly tinted by `iconTint`
/// — used by the primary navigation rows where the icon is the whole
/// point. `.colorBlock` wraps the same SF Symbol inside a small tinted
/// rounded square, surfacing the row's accent colour as a tile rather
/// than just a stroke colour. Used by category rows so the user's
/// chosen accent reads at a glance even when scanning past the icons.
enum SidebarNavMarkStyle {
    case glyph
    case colorBlock
}

struct SidebarNavItem: View {
    let icon:     String
    let label:    String
    let count:    Int?
    var iconTint: Color = .primary
    var markStyle: SidebarNavMarkStyle = .glyph
    let isSelected: Bool
    let action:   () -> Void

    @State  private var isHovered = false
    @Environment(\.colorScheme)  private var scheme
    @Environment(\.lumaPalette)  private var palette
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {

                // ── Mark (icon or colour block) ─────────────────
                mark

                // ── Label ───────────────────────────────────────
                //
                // Selected state flips to the focusPaper token because
                // the row sits on the focusInk slab — the same dark
                // card pattern used by the focused list row, keeping
                // the design language consistent across surfaces.
                Text(label)
                    .font(LumaDesign.Typography.sans(
                        13,
                        weight: isSelected ? .semibold : .medium
                    ))
                    .foregroundStyle(
                        isSelected
                            ? palette.focusPaper
                            : palette.textSecondary
                    )
                    .lineLimit(1)
                    .animation(LumaDesign.Motion.quick, value: isSelected)

                Spacer(minLength: 4)

                // ── Count badge ─────────────────────────────────
                if let count = count, count > 0 {
                    CountBadge(count: count, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(
                        isSelected
                            ? palette.focusInk
                            : (isHovered ? palette.hoverBg : .clear)
                    )
                    .animation(LumaDesign.Motion.quick, value: isSelected)
                    .animation(LumaDesign.Motion.quick, value: isHovered)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var mark: some View {
        switch markStyle {
        case .glyph:
            // Plain icon — flips to lime on the dark active card so it
            // reads alongside the paper-toned label.
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    isSelected
                        ? palette.accentBright
                        : (iconTint == .primary ? palette.textSecondary : iconTint)
                )
                .frame(width: 20, height: 20)
                .animation(LumaDesign.Motion.quick, value: isSelected)

        case .colorBlock:
            // Tinted square mark — keeps the user's chosen colour
            // visible even when the row is selected. Slightly inset
            // glyph so the colour reads as a tile rather than a frame.
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? iconTint
                            : iconTint.opacity(scheme == .dark ? 0.28 : 0.18)
                    )
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? palette.focusInk
                            : iconTint
                    )
            }
            .frame(width: 18, height: 18)
            .animation(LumaDesign.Motion.quick, value: isSelected)
        }
    }
}

// MARK: - Count Badge

private struct CountBadge: View {
    let count: Int
    let isSelected: Bool
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        // Editorial pill: mono digits with a touch of tracking. When the
        // row is selected the badge becomes a solid lime chip on the
        // dark slab — the spec's "calls attention without shouting"
        // treatment for the active count.
        Text(count > 999 ? "999+" : "\(count)")
            .font(LumaDesign.Typography.mono(10, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(
                isSelected ? palette.focusInk : palette.textTertiary
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? palette.accentBright
                            : palette.borderSubtle
                    )
            )
            .animation(LumaDesign.Motion.quick, value: isSelected)
    }
}

// MARK: - Storage Card
//
// Bottom-pinned summary card replacing the old "SYSTEM" section
// (Trash + Settings — both now live in the brand-area gear menu).
//
// Shows two figures derived from data the app already tracks:
//
//   • Disk used — bytes consumed by every file in LumaClip's
//     Application Support directory (DB + WAL + SHM, plus any
//     image BLOBs stored on the items table). Computed via
//     `DatabaseService.storageBytesUsed()`. Headline figure.
//   • Clips stored — `viewModel.allCount` against
//     `AppSettings.maxHistoryCount`. Drives the progress bar
//     because that's the *real* cap the app enforces (the
//     bytes figure has no quota — the OS just keeps writing).
//
// Disk usage is recomputed when the clip count changes, which
// covers the common cases (insert / delete / restore / empty
// trash). Refreshing on a timer would be cheap but unnecessary
// given how rarely DB files grow without an item-count change.
private struct StorageCard: View {
    let used: Int
    let capacity: Int

    @Environment(\.lumaPalette) private var palette
    @Environment(\.colorScheme) private var scheme

    /// Bytes consumed on disk. Cached in @State so the card doesn't
    /// re-stat the directory on every body re-render — only when
    /// `used` (clip count) actually changes.
    @State private var bytesOnDisk: Int64 = 0

    private var ratio: Double {
        guard capacity > 0 else { return 0 }
        return min(1.0, Double(used) / Double(capacity))
    }

    /// Compact "1.2k" notation for clip counts.
    private static func formatCount(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        let k = Double(n) / 1000
        return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
    }

    /// Byte → human-readable string. Uses `ByteCountFormatter` so the
    /// unit step (KB/MB/GB) and locale formatting follow the system
    /// — same behaviour the Finder Info panel uses.
    private static func formatBytes(_ n: Int64) -> String {
        guard n > 0 else { return "0 KB" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Eyebrow + headline
            HStack(spacing: 6) {
                Text("STORAGE".loc)
                    .font(LumaDesign.Typography.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(palette.textTertiary)
                Spacer()
                Text(Self.formatBytes(bytesOnDisk))
                    .font(LumaDesign.Typography.mono(11, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            // Sub-line: clip count against the cap. Mono digits with
            // a sans connector so the numbers read as data and the
            // separator reads as language.
            HStack(spacing: 4) {
                Text("\(Self.formatCount(used))".loc)
                    .font(LumaDesign.Typography.mono(10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Text("of".loc)
                    .font(LumaDesign.Typography.serifItalic(11))
                    .foregroundStyle(palette.textTertiary)
                Text("\(Self.formatCount(capacity))".loc)
                    .font(LumaDesign.Typography.mono(10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Text("clips".loc)
                    .font(LumaDesign.Typography.sans(10))
                    .foregroundStyle(palette.textTertiary)
            }

            // Progress bar — tracks clip count vs cap, since that's
            // the real quota.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.borderSubtle)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [palette.focusInk, palette.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 5)

            Text("DB, journal, and image data.".loc)
                .font(LumaDesign.Typography.serifItalic(11))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme == .dark
                      ? Color.white.opacity(0.03)
                      : palette.sidebarBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                )
        )
        .onAppear { refreshDiskUsage() }
        .onChange(of: used) { _ in refreshDiskUsage() }
    }

    /// Walk the Application Support/LumaClip directory and sum file
    /// sizes. Done synchronously off the main actor since the work is
    /// 3 file `stat()` calls in practice.
    private func refreshDiskUsage() {
        bytesOnDisk = DatabaseService.storageBytesUsed()
    }
}

// MARK: - Section Divider

private struct SidebarSectionDivider: View {
    @Environment(\.lumaPalette) private var palette
    var body: some View {
        Rectangle()
            .fill(palette.borderSubtle)
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }
}

// MARK: - Category Editor Popup

private struct CategoryEditorPopup: View {
    @ObservedObject var viewModel: ClipboardViewModel
    let editingCategory: Category?
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var selectedIcon: String = "tag"
    @State private var selectedColor: CategoryColor = .blue
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var isEditing: Bool { editingCategory != nil }

    static let iconChoices: [String] = [
        "tag", "folder", "tray", "archivebox",
        "doc.text", "link", "envelope", "phone",
        "person", "person.2", "star", "heart",
        "bookmark", "flag", "bell", "cart",
        "creditcard", "building.2", "house",
        "globe", "map", "location",
        "photo", "camera", "paintbrush", "scissors",
        "terminal", "chevron.left.forwardslash.chevron.right", "cpu", "desktopcomputer",
        "gamecontroller", "headphones", "music.note", "film",
        "book", "graduationcap", "lightbulb", "wrench",
        "hammer", "lock", "key", "shield",
        "airplane", "car", "figure.walk", "leaf",
        "flame", "bolt", "drop", "snowflake",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Title
            Text(isEditing ? "Edit Category" : "New Category")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            // Name field
            VStack(alignment: .leading, spacing: 6) {
                Text("Name".loc)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Category name…", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                            )
                    )
                    .focused($nameFocused)
                    .onSubmit { save() }
            }

            // Icon picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon".loc)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8),
                        spacing: 4
                    ) {
                        ForEach(Self.iconChoices, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 12))
                                .frame(width: 30, height: 30)
                                .foregroundStyle(
                                    selectedIcon == icon
                                        ? selectedColor.color
                                        : Color.secondary.opacity(0.7)
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(
                                            selectedIcon == icon
                                                ? selectedColor.color.opacity(0.16)
                                                : Color.clear
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            selectedIcon == icon
                                                ? selectedColor.color.opacity(0.50)
                                                : Color.clear,
                                            lineWidth: 1.5
                                        )
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation { selectedIcon = icon } }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }

            // Color picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Color".loc)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    ForEach(CategoryColor.allCases) { color in
                        Button {
                            withAnimation(LumaDesign.Motion.quick) {
                                selectedColor = color
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 22, height: 22)
                                if selectedColor == color {
                                    Circle()
                                        .strokeBorder(.white, lineWidth: 2)
                                        .frame(width: 22, height: 22)
                                    Circle()
                                        .fill(color.color.opacity(0.35))
                                        .frame(width: 32, height: 32)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .shadow(color: selectedColor == color ? color.color.opacity(0.45) : .clear, radius: 4)
                        .animation(LumaDesign.Motion.quick, value: selectedColor == color)
                    }
                }
            }

            // Buttons
            HStack {
                Button("Cancel".loc) { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                Spacer()

                Button(isEditing ? "Save Changes" : "Create") { save() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            if let cat = editingCategory {
                name = cat.name
                selectedIcon = cat.icon
                selectedColor = cat.color
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                nameFocused = true
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let existing = editingCategory {
            viewModel.updateCategory(
                Category(id: existing.id, name: trimmed, icon: selectedIcon, color: selectedColor)
            )
        } else {
            viewModel.addCategory(name: trimmed, icon: selectedIcon, color: selectedColor)
        }
        onDismiss()
    }
}

// MARK: - Legacy SidebarItem compatibility shim

/// Used by any remaining call sites that reference the old API.
struct SidebarItem: View {
    let icon:     String
    let label:    String
    let count:    Int?
    var tintColor: Color = .primary
    let isSelected: Bool
    let action:   () -> Void

    var body: some View {
        SidebarNavItem(
            icon: icon,
            label: label,
            count: count,
            iconTint: tintColor,
            isSelected: isSelected,
            action: action
        )
    }
}
