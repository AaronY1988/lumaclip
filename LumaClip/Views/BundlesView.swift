// BundlesView.swift
// LumaClip — macOS Clipboard Manager
//
// View for managing clipboard bundles. Shows all saved bundles
// with their metadata, allows creating new bundles, editing
// existing ones, and managing bundle items.

import SwiftUI

// MARK: - Bundles View

struct BundlesView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lumaPalette) private var palette

    @State private var isCreatingBundle = false
    @State private var editingBundle: ClipBundle? = nil
    @State private var hoveredBundleID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Editorial header ───────────────────────────────
            //
            // Same eyebrow + serif title pattern the Inspector and
            // the menu-bar popover use. Tagline rendered in italic
            // serif so the page reads as the next chapter of the
            // same publication, not a separate utility.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("COLLECTIONS".loc)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(palette.textTertiary)

                    HStack(spacing: 0) {
                        Text("Bundles".loc)
                            .font(LumaDesign.Typography.serif(28))
                            .foregroundStyle(palette.textPrimary)
                    }

                    Text("Sequenced clipboard items, pasted one after another.".loc)
                        .font(LumaDesign.Typography.serifItalic(14))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer()

                // Primary CTA — ink slab + lime label, matching the
                // Inspector's "Copy & paste" button.
                Button {
                    isCreatingBundle = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Bundle".loc)
                            .font(LumaDesign.Typography.sans(12, weight: .semibold))
                    }
                    .foregroundStyle(palette.accentBright)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .fill(palette.focusInk)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)
                .padding(.horizontal, 22)

            // Bundle list
            if viewModel.bundles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.bundles) { bundle in
                            BundleRow(
                                bundle: bundle,
                                isHovered: hoveredBundleID == bundle.id,
                                onActivate: {
                                    viewModel.activateBundle(bundle)
                                },
                                onEdit: {
                                    editingBundle = bundle
                                },
                                onDelete: {
                                    viewModel.deleteBundle(bundle)
                                }
                            )
                            .onHover { hovering in
                                hoveredBundleID = hovering ? bundle.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }
            }
        }
        .sheet(isPresented: $isCreatingBundle) {
            BundleEditorSheet(viewModel: viewModel, bundle: nil)
        }
        .sheet(item: $editingBundle) { bundle in
            BundleEditorSheet(viewModel: viewModel, bundle: bundle)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.textQuaternary)

            VStack(spacing: 6) {
                Text("No bundles yet".loc)
                    .font(LumaDesign.Typography.serif(22))
                    .foregroundStyle(palette.textPrimary)

                Text("A bundle is a small playlist of clips you can paste in sequence — useful for repeated workflows like onboarding emails or fixed code snippets.".loc)
                    .font(LumaDesign.Typography.serifItalic(13))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 320)
            }

            Button {
                isCreatingBundle = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Create your first bundle".loc)
                        .font(LumaDesign.Typography.sans(12, weight: .semibold))
                }
                .foregroundStyle(palette.accentBright)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                        .fill(palette.focusInk)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Bundle Row

struct BundleRow: View {
    let bundle: ClipBundle
    let isHovered: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            // Color-block icon mark — same pattern the sidebar uses
            // for category rows. Replaces the previous hard-circle so
            // the page reads as part of the editorial language.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(bundle.color.color.opacity(colorScheme == .dark ? 0.28 : 0.18))
                Image(systemName: bundle.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(bundle.color.color)
            }
            .frame(width: 40, height: 40)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(bundle.name)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(bundle.itemCount)".loc)
                        .font(LumaDesign.Typography.mono(10, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text(bundle.itemCount == 1 ? "item" : "items")
                        .font(LumaDesign.Typography.sans(11))
                        .foregroundStyle(palette.textTertiary)
                    Text("·".loc)
                        .font(LumaDesign.Typography.sans(11))
                        .foregroundStyle(palette.textQuaternary)
                    Text(bundle.modifiedAt, style: .relative)
                        .font(LumaDesign.Typography.sans(11))
                        .foregroundStyle(palette.textTertiary)
                }
            }

            Spacer()

            // Hover actions: edit + delete. The Activate CTA is
            // always visible — it's the row's primary affordance.
            HStack(spacing: 6) {
                if isHovered {
                    bundleActionGlyph(icon: "pencil", help: "Edit", action: onEdit)
                    bundleActionGlyph(
                        icon: "trash",
                        help: "Delete",
                        tint: palette.danger,
                        action: onDelete
                    )
                }

                Button(action: onActivate) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Activate".loc)
                            .font(LumaDesign.Typography.sans(11, weight: .semibold))
                    }
                    .foregroundStyle(palette.accentBright)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                            .fill(palette.focusInk)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .fill(palette.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                        .strokeBorder(
                            isHovered ? palette.borderStrong : palette.borderSubtle,
                            lineWidth: 0.5
                        )
                )
                .shadow(
                    color: isHovered ? Color.black.opacity(0.06) : Color.clear,
                    radius: 4, y: 2
                )
        )
        .animation(LumaDesign.Motion.quick, value: isHovered)
    }

    /// Small glyph button used for edit / delete on hover. Matches the
    /// list-row hover action style — paper card, hairline border.
    @ViewBuilder
    private func bundleActionGlyph(
        icon: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Bundle Editor Sheet

struct BundleEditorSheet: View {
    @ObservedObject var viewModel: ClipboardViewModel
    let bundle: ClipBundle?  // nil for new bundle

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lumaPalette) private var palette

    @State private var name: String = ""
    @State private var selectedIcon: String = "square.stack.3d.up"
    @State private var selectedColor: CategoryColor = .blue
    @State private var selectedItems: [UUID] = []

    private let availableIcons = [
        "square.stack.3d.up", "tray.full", "doc.on.doc.fill",
        "folder.fill", "archivebox.fill", "shippingbox.fill",
        "briefcase.fill", "bag.fill", "cart.fill",
        "list.bullet.clipboard.fill", "checklist", "text.badge.checkmark"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Editorial header ───────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bundle == nil ? "NEW BUNDLE" : "EDIT BUNDLE")
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(palette.textTertiary)
                    Text(bundle == nil ? "Compose a new collection" : "Refine collection")
                        .font(LumaDesign.Typography.serif(20))
                        .foregroundStyle(palette.textPrimary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Cancel".loc) { dismiss() }
                        .buttonStyle(.plain)
                        .font(LumaDesign.Typography.sans(12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

                    Button(action: saveBundle) {
                        Text(bundle == nil ? "Create" : "Save")
                            .font(LumaDesign.Typography.sans(12, weight: .semibold))
                            .foregroundStyle(
                                name.isEmpty ? palette.textQuaternary : palette.accentBright
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                                    .fill(name.isEmpty ? palette.cardBg : palette.focusInk)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                                            .strokeBorder(
                                                name.isEmpty ? palette.borderDefault : Color.clear,
                                                lineWidth: 0.5
                                            )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)

            // ── Form ───────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Name
                    fieldSection("NAME") {
                        TextField("Bundle name", text: $name)
                            .textFieldStyle(.plain)
                            .font(LumaDesign.Typography.serif(18))
                            .foregroundColor(palette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                    .fill(palette.searchBg)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                            .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                                    )
                            )
                    }

                    // Icon
                    fieldSection("ICON") {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                            spacing: 8
                        ) {
                            ForEach(availableIcons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(
                                            selectedIcon == icon
                                                ? palette.focusPaper
                                                : palette.textSecondary
                                        )
                                        .frame(width: 42, height: 42)
                                        .background(
                                            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                                                .fill(
                                                    selectedIcon == icon
                                                        ? palette.focusInk
                                                        : palette.cardBg
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                                                        .strokeBorder(
                                                            selectedIcon == icon
                                                                ? selectedColor.color
                                                                : palette.borderSubtle,
                                                            lineWidth: selectedIcon == icon ? 1.5 : 0.5
                                                        )
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Color
                    fieldSection("COLOR") {
                        HStack(spacing: 10) {
                            ForEach(CategoryColor.allCases) { color in
                                Button {
                                    selectedColor = color
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(color.color)
                                            .frame(width: 28, height: 28)
                                        if selectedColor == color {
                                            Circle()
                                                .strokeBorder(palette.focusInk, lineWidth: 2)
                                                .frame(width: 28, height: 28)
                                            Circle()
                                                .strokeBorder(color.color, lineWidth: 1)
                                                .frame(width: 34, height: 34)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }

                    // Items Selection
                    fieldSection("ITEMS · \(selectedItems.count) SELECTED") {
                        ScrollView {
                            VStack(spacing: 3) {
                                if viewModel.items.isEmpty {
                                    Text("No clipboard items available".loc)
                                        .font(LumaDesign.Typography.serifItalic(13))
                                        .foregroundStyle(palette.textTertiary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 24)
                                } else {
                                    ForEach(viewModel.items.prefix(20)) { item in
                                        BundleItemSelector(
                                            item: item,
                                            isSelected: selectedItems.contains(item.id),
                                            onToggle: {
                                                if let index = selectedItems.firstIndex(of: item.id) {
                                                    selectedItems.remove(at: index)
                                                } else {
                                                    selectedItems.append(item.id)
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: 200)
                        .background(
                            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                .fill(palette.searchBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                        .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                                )
                        )
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 540, height: 640)
        .background(palette.detailBg)
        .onAppear {
            if let bundle = bundle {
                name = bundle.name
                selectedIcon = bundle.icon
                selectedColor = bundle.color
                selectedItems = bundle.itemIDs
            }
        }
    }

    /// Mono uppercase eyebrow + content. Reused across the Name / Icon
    /// / Color / Items sections so each form field reads with the same
    /// editorial rhythm.
    @ViewBuilder
    private func fieldSection<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(LumaDesign.Typography.mono(9, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(palette.textTertiary)
            content()
        }
    }

    private func saveBundle() {
        let newBundle = ClipBundle(
            id: bundle?.id ?? UUID(),
            name: name,
            icon: selectedIcon,
            colorName: selectedColor.rawValue,
            itemIDs: selectedItems,
            createdAt: bundle?.createdAt ?? Date(),
            modifiedAt: Date()
        )

        viewModel.saveBundle(newBundle)
        dismiss()
    }
}
// MARK: - Bundle Item Selector

struct BundleItemSelector: View {
    let item: ClipboardItem
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // Checkbox — lime fill when selected, hairline circle
                // when not, matching the editorial monochrome rhythm.
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.clear : palette.borderStrong,
                            lineWidth: 1.2
                        )
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle()
                            .fill(palette.accentBright)
                            .frame(width: 16, height: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.focusInk)
                    }
                }

                // Content type icon mark
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(item.contentType.color.opacity(0.16))
                    Image(systemName: item.contentType.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.contentType.color)
                }
                .frame(width: 22, height: 22)

                // Content preview
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(LumaDesign.Typography.sans(12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(item.formattedDate)
                        .font(LumaDesign.Typography.mono(9, weight: .regular))
                        .foregroundStyle(palette.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(isSelected ? palette.selectedBg : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .animation(LumaDesign.Motion.quick, value: isSelected)
    }
}

