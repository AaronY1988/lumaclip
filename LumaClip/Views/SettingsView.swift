// SettingsView.swift
// LumaClip - macOS Clipboard Manager
//
// Full settings panel with sections for General, Privacy,
// Retention, Appearance, and Data management.

import SwiftUI
import Carbon    // cmdKey, shiftKey, optionKey, controlKey

// MARK: - Settings View

// MARK: - Danger Action (confirmation state)

private enum DangerAction: Identifiable {
    case runCleanup, emptyTrash, clearHistory, resetEverything
    var id: Int {
        switch self {
        case .runCleanup:      return 0
        case .emptyTrash:      return 1
        case .clearHistory:    return 2
        case .resetEverything: return 3
        }
    }
    var title: String {
        switch self {
        case .runCleanup:      return "Run Cleanup Now?"
        case .emptyTrash:      return "Empty Trash?"
        case .clearHistory:    return "Clear All History?"
        case .resetEverything: return "Reset Everything?"
        }
    }
    var message: String {
        switch self {
        case .runCleanup:
            return "This will immediately apply your retention rules and permanently delete expired items. This cannot be undone."
        case .emptyTrash:
            return "All items in the Trash will be permanently deleted. This cannot be undone."
        case .clearHistory:
            return "All clipboard history will be permanently deleted. Starred favorites and pinned items will be kept. This cannot be undone."
        case .resetEverything:
            return "This will permanently delete ALL clips, rules, and custom categories, and restore the 7 default categories. This action cannot be undone."
        }
    }
    var confirmLabel: String {
        switch self {
        case .runCleanup:      return "Run Cleanup"
        case .emptyTrash:      return "Empty Trash"
        case .clearHistory:    return "Clear History"
        case .resetEverything: return "Reset Everything"
        }
    }
}

// MARK: - Commit-On-Release Slider
//
// Wraps a standard Slider so that the bound value is only written when the
// user releases the mouse. During drag we track a local `@State` so the
// slider and the accompanying display label feel responsive, but we avoid
// hammering UserDefaults (and everything downstream of `AppSettings`'s
// `didSet` — retention, layout, Combine observers) on every slider tick.
//
// Use the trailing `label` closure to render a value-dependent view (e.g. a
// count readout). It receives the *staged* value during a drag and the
// committed value otherwise, so the readout previews as the user scrubs.
//
// `step` is optional. Pass a non-nil step (e.g. `4`, `0.05`) for sliders
// whose underlying value space is naturally discrete and where SwiftUI's
// built-in step-snap feels right. Pass `nil` for sliders that should glide
// smoothly under the user's mouse — the caller is then responsible for any
// snapping, typically by rounding inside its own `set` closure (see
// `PresetSlider`). The on-release commit is wrapped in a spring so even
// when the caller snaps, the thumb's settle is animated rather than a hard
// jump from drag-position to snapped-position.
private struct CommitOnReleaseSlider<Label: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    @ViewBuilder let label: (Double) -> Label

    @State private var staged: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        HStack {
            sliderView
            label(isDragging ? staged : value)
        }
        .onAppear { staged = value }
    }

    @ViewBuilder
    private var sliderView: some View {
        let binding = Binding(
            get: { isDragging ? staged : value },
            set: { staged = $0 }
        )
        let onEditing: (Bool) -> Void = { editing in
            if editing {
                staged = value
                isDragging = true
            } else {
                // Animate the settle: gives the thumb a smooth glide from
                // its drag-end position to whatever the caller's `set`
                // rounds it to, rather than a visible jump.
                withAnimation(LumaDesign.Motion.select) {
                    value = staged
                    isDragging = false
                }
            }
        }
        if let step = step {
            Slider(value: binding, in: range, step: step, onEditingChanged: onEditing)
        } else {
            Slider(value: binding, in: range, onEditingChanged: onEditing)
        }
    }
}

// MARK: - Preset Slider
//
// A slider that snaps to a fixed list of preset values (e.g. retention
// presets like 1, 3, 7, 14, 30, 90, 0/Forever) by binding the slider to an
// *index* into the presets array. Visually evenly-spaced regardless of the
// underlying numeric distribution. Renders a readout of the currently
// selected preset's label and a row of tick labels beneath.
//
// Wraps `CommitOnReleaseSlider` so the bound `selection` is only written when
// the user releases the thumb — matching the rest of the settings panel and
// keeping AppSettings/UserDefaults updates batched.
private struct PresetSlider: View {
    @Binding var selection: Int
    let presets: [(value: Int, label: String)]

    private var currentIndex: Double {
        Double(presets.firstIndex(where: { $0.value == selection }) ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommitOnReleaseSlider(
                value: Binding(
                    get: { currentIndex },
                    set: { newIdx in
                        let clamped = max(0, min(presets.count - 1, Int(newIdx.rounded())))
                        selection = presets[clamped].value
                    }
                ),
                range: 0...Double(max(presets.count - 1, 1)),
                // step: nil → thumb glides smoothly under the cursor instead
                // of jumping in unit increments. The label readout still
                // reflects the nearest preset (rounding below), and on
                // release the underlying slider animates the thumb from its
                // drag-end position to the snapped integer index — so the
                // user sees a continuous "magnet" pull, not a hard snap.
                step: nil
            ) { current in
                let idx = max(0, min(presets.count - 1, Int(current.rounded())))
                Text(presets[idx].label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tint)
                    .frame(width: 64, alignment: .trailing)
            }

            // Tick labels — evenly distributed under the track. Bumped from
            // 9pt to 11pt to clear Apple's HIG legibility floor, and the
            // active tick now reads bolder + tinted (was just a colour
            // shade) so the slider's discrete preset structure is visually
            // honest, not just a continuous-looking control with a hidden
            // snap.
            HStack(spacing: 0) {
                ForEach(presets.indices, id: \.self) { i in
                    let isActive = presets[i].value == selection
                    Text(presets[i].label)
                        .font(.system(
                            size: 11,
                            weight: isActive ? .semibold : .regular
                        ))
                        // Two `Color` arms instead of mixing `.tint` /
                        // `.tertiary` shape styles — those are different
                        // concrete types and a ternary over them won't
                        // type-check without an `AnyShapeStyle` wrapper.
                        // `Color.accentColor` resolves to the same value
                        // `.tint` would in the absence of a `.tint(_:)`
                        // override, which is the case for this view.
                        .foregroundColor(isActive ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .animation(LumaDesign.Motion.quick, value: isActive)
                }
            }
            // Trailing inset matches the readout column above so the tick row
            // aligns with the slider track, not the entire HStack.
            .padding(.trailing, 64)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @State private var pendingDangerAction: DangerAction? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            // ── Editorial settings sidebar ────────────────────────
            //
            // Mono SETTINGS eyebrow up top, ink-active rows below —
            // same active-state pattern as the main app's left rail.
            VStack(alignment: .leading, spacing: 0) {
                Text("SETTINGS".loc)
                    .font(LumaDesign.Typography.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 18)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { section in
                        SettingsSidebarRow(
                            section: section,
                            isActive: viewModel.activeSection == section,
                            action: { viewModel.activeSection = section }
                        )
                    }
                }
                .padding(.horizontal, 6)

                Spacer()
            }
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            .background(palette.sidebarBg)

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(width: 0.5)

            // ── Settings content ───────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch viewModel.activeSection {
                    case .general:
                        generalSection
                    case .privacy:
                        privacySection
                    case .retention:
                        retentionSection
                    case .appearance:
                        appearanceSection
                    case .data:
                        dataSection
                    case .shortcuts:
                        shortcutsSection
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.listBg)
        }
        // ── Danger Zone confirmation dialog ──────────────────────
        .confirmationDialog(
            pendingDangerAction?.title ?? "",
            isPresented: Binding(
                get: { pendingDangerAction != nil },
                set: { if !$0 { pendingDangerAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingDangerAction {
                Button(action.confirmLabel, role: .destructive) {
                    executeDangerAction(action)
                }
                Button("Cancel".loc, role: .cancel) {
                    pendingDangerAction = nil
                }
            }
        } message: {
            Text(pendingDangerAction?.message ?? "")
        }
    }

    // MARK: - Execute danger action

    private func executeDangerAction(_ action: DangerAction) {
        switch action {
        case .runCleanup:      viewModel.runCleanupNow()
        case .emptyTrash:      viewModel.emptyTrash()
        case .clearHistory:    viewModel.clearAllHistory()
        case .resetEverything: viewModel.resetEverything()
        }
        pendingDangerAction = nil
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(title: "General".loc, icon: "gear")

            SettingsToggle(
                title: "Launch at Login".loc,
                subtitle: "Start LumaClip when you log in",
                isOn: $settings.launchAtLogin
            )

            SettingsToggle(
                title: "Show Floating Button".loc,
                subtitle: "Display the floating clipboard button on desktop",
                isOn: $settings.showFloatingButton
            )

            SettingsToggle(
                title: "Skip Duplicates".loc,
                subtitle: "Don't save identical consecutive copies",
                isOn: $settings.skipDuplicates
            )

            SettingsToggle(
                title: "Capture Images".loc,
                subtitle: "Save copied images (screenshots, photos) — uses more storage",
                isOn: $settings.captureImages
            )

            SettingsToggle(
                title: "Capture Files".loc,
                subtitle: "Save files copied from Finder so you can re-paste them anytime",
                isOn: $settings.captureFiles
            )

            if settings.captureFiles {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save Files Up To".loc)
                        .font(LumaDesign.Typography.serif(17))
                        .foregroundStyle(palette.textPrimary)
                    Text("Files at or below this size are copied into LumaClip; larger files are linked to their original location.".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                    CommitOnReleaseSlider(
                        value: Binding(
                            get: { Double(settings.fileVaultMaxMB) },
                            set: { settings.fileVaultMaxMB = Int($0) }
                        ),
                        range: 10...1000,
                        step: 10
                    ) { current in
                        Text("\(Int(current)) MB".loc)
                    }
                }
            }

            SettingsToggle(
                title: "Auto Category".loc,
                subtitle: "Automatically sort clips into matching categories (Links, Code, etc.)",
                isOn: $settings.autoCategory
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Max History Items".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                CommitOnReleaseSlider(
                    value: Binding(
                        get: { Double(settings.maxHistoryCount) },
                        set: { settings.maxHistoryCount = Int($0) }
                    ),
                    range: 100...10000,
                    step: 100
                ) { current in
                    Text("\(Int(current))".loc)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Keyboard Shortcuts".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)

                HotkeyRecorderRow(
                    label: "Toggle Clipboard Panel".loc,
                    description: "Open or close the main clipboard panel",
                    displayString: settings.globalToggleHotkey
                ) { keyCode, mods, display in
                    AppSettings.shared.toggleHotkeyCode = Int(keyCode)
                    AppSettings.shared.toggleHotkeyMods = Int(mods)
                    AppSettings.shared.globalToggleHotkey = display
                }

                HotkeyRecorderRow(
                    label: "Quick Paste".loc,
                    description: "Search and instantly paste into any app",
                    displayString: settings.quickPasteHotkey
                ) { keyCode, mods, display in
                    AppSettings.shared.quickPasteHotkeyCode = Int(keyCode)
                    AppSettings.shared.quickPasteHotkeyMods = Int(mods)
                    AppSettings.shared.quickPasteHotkey = display
                }
            }

            Divider().opacity(0.2)

            // ── Welcome Tour ──────────────────────────────────────
            // Re-trigger the first-launch onboarding overlay. Flipping
            // `hasSeenOnboarding` to false causes MainPanelView's
            // conditional overlay to mount again with full animations.
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome Tour".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                Text("Replay the first-launch tour — useful after a major update or to refresh your memory on shortcuts.".loc)
                    .font(LumaDesign.Typography.serifItalic(12))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    settings.hasSeenOnboarding = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Show Welcome Tour".loc)
                            .font(LumaDesign.Typography.sans(12, weight: .semibold))
                    }
                    .foregroundStyle(palette.accentBright)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                            .fill(palette.focusInk)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(title: "Privacy".loc, icon: "lock.shield")

            SettingsToggle(
                title: "Detect & Skip Passwords".loc,
                subtitle: "Automatically skip password-like text",
                isOn: $settings.detectAndSkipPasswords
            )

            SettingsToggle(
                title: "Pause Tracking".loc,
                subtitle: "Temporarily stop monitoring clipboard",
                isOn: $settings.isTrackingPaused
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Blacklisted Apps".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                Text("Clipboard content from these apps won't be saved".loc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                // Current blacklist
                ForEach(viewModel.blacklistedApps, id: \.self) { appName in
                    HStack {
                        Image(systemName: "app")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(appName)
                            .font(.system(size: 12))
                        Spacer()
                        Button {
                            viewModel.toggleAppBlacklist(appName)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.primary.opacity(0.04))
                    )
                }

                // Suggested apps
                if !PrivacyService.suggestedBlacklist.isEmpty {
                    Text("Suggested".loc)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)

                    ForEach(PrivacyService.suggestedBlacklist, id: \.self) { appName in
                        if !viewModel.isAppBlacklisted(appName) {
                            Button {
                                viewModel.toggleAppBlacklist(appName)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 11))
                                    Text(appName)
                                        .font(.system(size: 12))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Running apps to add
                if !viewModel.availableApps.isEmpty {
                    Text("Running Apps".loc)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)

                    ForEach(viewModel.availableApps) { app in
                        if !viewModel.isAppBlacklisted(app.name) {
                            Button {
                                viewModel.toggleAppBlacklist(app.name)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 11))
                                    Text(app.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Retention Section

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(title: "Retention Rules".loc, icon: "clock.arrow.circlepath")

            VStack(alignment: .leading, spacing: 6) {
                Text("Default Retention".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                PresetSlider(
                    selection: Binding(
                        get: { settings.defaultRetentionDays },
                        set: { v in DispatchQueue.main.async { AppSettings.shared.defaultRetentionDays = v } }
                    ),
                    presets: [
                        (1,  "1d"),
                        (3,  "3d"),
                        (7,  "7d"),
                        (14, "14d"),
                        (30, "30d"),
                        (90, "90d"),
                        (0,  "∞"),
                    ]
                )
                .frame(maxWidth: 400)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Trash Auto-Cleanup".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                PresetSlider(
                    selection: Binding(
                        get: { settings.trashRetentionDays },
                        set: { v in DispatchQueue.main.async { AppSettings.shared.trashRetentionDays = v } }
                    ),
                    presets: [
                        (1,  "1d"),
                        (7,  "7d"),
                        (14, "14d"),
                        (30, "30d"),
                    ]
                )
                .frame(maxWidth: 400)
            }

            Divider().opacity(0.2)

            // Custom rules
            RetentionRulesEditor(viewModel: viewModel)
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "Appearance".loc, icon: "paintbrush")

            // ── Colour Mode ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Colour Mode".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                Text("Controls whether LumaClip uses a light or dark glass theme.".loc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    ForEach(AppearanceMode.allCases) { mode in
                        AppearanceModeCard(
                            mode: mode,
                            isSelected: settings.appearanceMode == mode
                        ) {
                            settings.appearanceMode = mode
                        }
                    }
                }
            }

            Divider().opacity(0.2)

            // ── Language ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Language".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)

                Picker("", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            Divider().opacity(0.2)

            // ── Floating Button ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Floating Button Size".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                CommitOnReleaseSlider(
                    value: $settings.floatingButtonSize,
                    range: 36...72,
                    step: 4
                ) { current in
                    Text("\(Int(current))pt".loc)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Floating Button Opacity".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)
                CommitOnReleaseSlider(
                    value: $settings.floatingButtonOpacity,
                    range: 0.3...1.0,
                    step: 0.05
                ) { current in
                    Text("\(Int(current * 100))%".loc)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                }
            }
        }
    }


    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(title: "Data Management".loc, icon: "externaldrive")

            // Statistics
            VStack(alignment: .leading, spacing: 8) {
                Text("Statistics".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(palette.textPrimary)

                HStack(spacing: 20) {
                    StatCard(label: "Total Clips".loc, value: "\(viewModel.totalItemCount)")
                    StatCard(label: "In Trash".loc, value: "\(viewModel.trashItemCount)")
                }

                if !viewModel.itemCountsByType.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(viewModel.itemCountsByType.sorted(by: { $0.value > $1.value }), id: \.key) { type, count in
                            VStack(spacing: 2) {
                                Image(systemName: type.iconName)
                                    .font(.system(size: 12))
                                Text("\(count)".loc)
                                    .font(.system(size: 10, weight: .medium))
                                Text(type.label)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 50)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.primary.opacity(0.04))
                            )
                        }
                    }
                }
            }

            Divider().opacity(0.2)

            // ── Backup & Restore ─────────────────────────────────
            backupRestoreSection

            Divider().opacity(0.2)

            // ── Danger Zone ──────────────────────────────────────
            dangerZoneSection
        }
    }

    // MARK: - Backup & Restore

    private var backupRestoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup & Restore".loc)
                .font(LumaDesign.Typography.serif(17))
                .foregroundStyle(palette.textPrimary)

            VStack(spacing: 0) {
                DangerActionRow(
                    icon: "arrow.down.doc.fill",
                    iconColor: Color(hue: 0.58, saturation: 0.72, brightness: 0.82),
                    title: "Back Up Data".loc,
                    subtitle: "Save all clips, categories, rules, and bundles to a file",
                    buttonLabel: "Back Up",
                    isDestructive: false
                ) { viewModel.backupDataToFile() }

                Divider().opacity(0.15).padding(.leading, 48)

                DangerActionRow(
                    icon: "arrow.up.doc.fill",
                    iconColor: Color(hue: 0.38, saturation: 0.68, brightness: 0.72),
                    title: "Restore from Backup".loc,
                    subtitle: "Merge clips from a backup file — existing data is kept",
                    buttonLabel: "Restore",
                    isDestructive: false
                ) { viewModel.restoreDataFromFile() }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.primary.opacity(0.08), lineWidth: 1)
                    )
            )

            // Inline result feedback after a backup or restore
            if let status = viewModel.backupStatusMessage {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.backupStatusIsError
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.backupStatusIsError ? .red : .green)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Text("Danger Zone".loc)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
            }

            // Card container
            VStack(spacing: 0) {
                DangerActionRow(
                    icon: "arrow.clockwise.circle.fill",
                    iconColor: Color(hue: 0.56, saturation: 0.7, brightness: 0.85),
                    title: "Run Cleanup Now".loc,
                    subtitle: "Apply retention rules and remove expired items",
                    buttonLabel: "Run",
                    isDestructive: false
                ) { pendingDangerAction = .runCleanup }

                Divider().opacity(0.15).padding(.leading, 48)

                DangerActionRow(
                    icon: "trash.circle.fill",
                    iconColor: Color(hue: 0.08, saturation: 0.65, brightness: 0.88),
                    title: "Empty Trash".loc,
                    subtitle: "Permanently delete all items currently in the trash",
                    buttonLabel: "Empty",
                    isDestructive: true
                ) { pendingDangerAction = .emptyTrash }

                Divider().opacity(0.15).padding(.leading, 48)

                DangerActionRow(
                    icon: "xmark.bin.circle.fill",
                    iconColor: Color(hue: 0.0, saturation: 0.7, brightness: 0.85),
                    title: "Clear All History".loc,
                    subtitle: "Delete all clips (starred favorites and pinned items are kept)",
                    buttonLabel: "Clear",
                    isDestructive: true
                ) { pendingDangerAction = .clearHistory }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.red.opacity(0.12), lineWidth: 1)
                    )
            )

            // Reset Everything — more prominent, separate card
            Button {
                pendingDangerAction = .resetEverything
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.red.opacity(0.82))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reset Everything".loc)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                        Text("Wipe all data and restore factory defaults".loc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.red.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.red.opacity(0.22), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shortcuts Section

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionHeader(title: "Keyboard Shortcuts".loc, icon: "keyboard")

            // ── Navigation ────────────────────────────────────────
            // Finder-style column navigation: ←/→ shift focus across
            // sidebar → list → drawer; ↑↓ move within whichever column
            // currently holds focus.
            ShortcutGroup(title: "Navigation".loc) {
                ShortcutRow(keys: ["↑", "↓"],       description: "Move within current column")
                ShortcutRow(keys: ["→"],             description: "Move focus right (sidebar → list → detail)")
                ShortcutRow(keys: ["←"],             description: "Move focus left (detail → list → sidebar)")
                ShortcutRow(keys: ["Return"],        description: "Copy selected item")
                ShortcutRow(keys: ["⌫"],            description: "Move selected item to trash")
            }

            // ── Detail Drawer ─────────────────────────────────────
            ShortcutGroup(title: "Detail Drawer".loc) {
                ShortcutRow(keys: ["Space"],         description: "Toggle detail drawer")
                ShortcutRow(keys: ["esc"],           description: "Close detail drawer")
            }

            // ── ⌘ Shortcuts ───────────────────────────────────────
            ShortcutGroup(title: "⌘ Command Shortcuts".loc) {
                ShortcutRow(keys: ["⌘", "P"],       description: "Pin / unpin selected item")
                ShortcutRow(keys: ["⌘", "⌫"],      description: "Delete selected item")
                ShortcutRow(keys: ["⌘", "1–9"],     description: "Copy item at position 1–9")
            }

            // ── Global Shortcuts ──────────────────────────────────
            ShortcutGroup(title: "Global Shortcuts".loc) {
                ShortcutRow(
                    keys: [settings.globalToggleHotkey.isEmpty ? "—" : settings.globalToggleHotkey],
                    description: "Toggle clipboard panel (system-wide)",
                    isGlobal: true
                )
                ShortcutRow(
                    keys: [settings.quickPasteHotkey.isEmpty ? "—" : settings.quickPasteHotkey],
                    description: "Quick Paste (system-wide)",
                    isGlobal: true
                )
                Text("Configure global shortcuts in the General section.".loc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - Shortcut Components

private struct ShortcutGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 1) {
                content()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let description: String
    var isGlobal: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Key badges
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    KbdBadge(label: key)
                }
            }
            .frame(width: 130, alignment: .leading)

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            if isGlobal {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct KbdBadge: View {
    let label: String
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Text(label)
            .font(LumaDesign.Typography.mono(10, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, label.count == 1 ? 6 : 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Settings Sidebar Row
//
// Editorial nav row used in the Settings left rail. Mirrors the main
// sidebar's ink-active treatment (focusInk slab + paper text + lime
// icon) so navigating between Settings sections feels like the same
// app, not a separate preferences pane.

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isActive ? palette.accentBright
                                 : (isHovered ? palette.textPrimary : palette.textSecondary)
                    )
                    .frame(width: 18)

                Text(section.rawValue.loc)
                    .font(LumaDesign.Typography.sans(13, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(
                        isActive ? palette.focusPaper
                                 : (isHovered ? palette.textPrimary : palette.textSecondary)
                    )

                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(
                        isActive ? palette.focusInk
                                 : (isHovered ? palette.hoverBg : Color.clear)
                    )
                    .animation(LumaDesign.Motion.quick, value: isActive)
                    .animation(LumaDesign.Motion.quick, value: isHovered)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Settings Components

/// Editorial section header — mono uppercase eyebrow on top, big serif
/// title below. Replaces the previous "tinted icon + bold sans title"
/// row so every Settings section opens with the same magazine-deck
/// rhythm the rest of the app uses (Inspector, Bundles, etc.).
struct SettingsSectionHeader: View {
    let title: String
    let icon: String

    @Environment(\.lumaPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
                Text(title.uppercased())
                    .font(LumaDesign.Typography.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(palette.textTertiary)
            }
            Text(title)
                .font(LumaDesign.Typography.serif(26))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.bottom, 8)
    }
}

/// Editorial toggle row — wrapped in a paper card so toggles read as
/// individual settings rather than a flat list. Text uses the editorial
/// hierarchy (sans 13/medium title, serif italic 12 subtitle).
struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LumaDesign.Typography.sans(13, weight: .semibold))
                    .foregroundColor(palette.textPrimary)
                Text(subtitle)
                    .font(LumaDesign.Typography.serifItalic(12))
                    .foregroundColor(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(palette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .fill(palette.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                        .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Appearance Mode Card

struct AppearanceModeCard: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    // Swatch background
                    RoundedRectangle(cornerRadius: 16)
                        .fill(swatchFill)
                        .frame(width: 68, height: 44)

                    // Gradient overlay for System mode
                    if mode == .system {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.12), Color(white: 0.90)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 68, height: 44)
                    }

                    Image(systemName: mode.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconColor)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 2 : 1)
                )

                Text(mode.label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var swatchFill: Color {
        switch mode {
        case .dark:   return Color(white: 0.12)
        case .light:  return Color(white: 0.93)
        case .system: return .clear   // gradient overlay handles it
        }
    }

    private var iconColor: Color {
        switch mode {
        case .dark:   return .white
        case .light:  return Color(white: 0.2)
        case .system: return .primary
        }
    }
}

// MARK: - Hotkey Recorder Row

/// An interactive shortcut row. Click "Record" and press any key combo
/// (must include ⌘, ⌃, or ⌥) to update the shortcut.
struct HotkeyRecorderRow: View {
    let label: String
    let description: String
    let displayString: String                   // e.g. "⌘⇧V" — plain value, parent re-renders via @ObservedObject
    let onSave: (_ keyCode: UInt32, _ modifiers: UInt32, _ display: String) -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                Text(description).font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Spacer()

            if isRecording {
                // Capture view sits invisibly in the hierarchy and becomes first responder
                HotkeyCaptureView(
                    onCapture: { keyCode, mods, display in
                        onSave(keyCode, mods, display)   // parent updates settings → re-render
                        isRecording = false
                    },
                    onCancel: { isRecording = false }
                )
                .frame(width: 0, height: 0)   // invisible — just needs to be in the tree

                Text("Press shortcut…".loc)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    )
                    .onTapGesture { isRecording = false }   // tap again to cancel

            } else {
                // Shortcut badge(s)
                HStack(spacing: 3) {
                    ForEach(tokens(from: displayString), id: \.self) { token in
                        Text(token)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.primary.opacity(0.07))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(.primary.opacity(0.12), lineWidth: 1))
                            )
                    }
                }

                Button("Record".loc) { isRecording = true }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.primary.opacity(0.05))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.primary.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(.primary.opacity(0.07), lineWidth: 1))
        )
        .animation(.easeInOut(duration: 0.15), value: isRecording)
    }

    private func tokens(from shortcut: String) -> [String] {
        let modifiers: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        var result: [String] = []
        var remainder = shortcut
        while let first = remainder.first, modifiers.contains(first) {
            result.append(String(first)); remainder.removeFirst()
        }
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }
}

// MARK: - Hotkey Capture (NSViewRepresentable)

/// A zero-size view that becomes first responder and captures the next key combo.
private struct HotkeyCaptureView: NSViewRepresentable {
    let onCapture: (UInt32, UInt32, String) -> Void
    let onCancel:  () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let v = HotkeyCaptureNSView()
        v.onCapture = onCapture
        v.onCancel  = onCancel
        return v
    }
    func updateNSView(_ v: HotkeyCaptureNSView, context: Context) {
        v.onCapture = onCapture
        v.onCancel  = onCancel
    }
}

final class HotkeyCaptureNSView: NSView {
    var onCapture: ((UInt32, UInt32, String) -> Void)?
    var onCancel:  (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }   // ESC = cancel

        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Require at least ⌘, ⌃, or ⌥ (shift alone is not enough)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            return
        }

        var carbonMods: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbonMods |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option)  { carbonMods |= UInt32(optionKey);  display += "⌥" }
        if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey);   display += "⇧" }
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey);     display += "⌘" }

        let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
        display += key

        onCapture?(UInt32(event.keyCode), carbonMods, display)
    }

    override func flagsChanged(with event: NSEvent) { /* swallow modifier-only events */ }
}

// MARK: - Retention Rules Editor

private struct RetentionRulesEditor: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingAddForm = false
    @State private var editingRuleID: UUID? = nil
    @State private var draftTarget: RetentionTarget = .all
    @State private var draftDuration: TimeInterval = 86400 * 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Custom Rules".loc)
                    .font(LumaDesign.Typography.serif(17))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    editingRuleID = nil
                    draftTarget   = .all
                    draftDuration = 86400 * 7
                    showingAddForm = true
                } label: {
                    Label("Add Rule".loc, systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Inline add form
            if showingAddForm && editingRuleID == nil {
                RetentionRuleForm(
                    target:   $draftTarget,
                    duration: $draftDuration,
                    onSave: {
                        let rule = RetentionRule(target: draftTarget, duration: draftDuration)
                        DatabaseService.shared.insertRetentionRule(rule)
                        RetentionService.shared.applyRule(rule)
                        viewModel.loadData()
                        showingAddForm = false
                    },
                    onCancel: { showingAddForm = false }
                )
            }

            // Existing rules
            ForEach(viewModel.retentionRules) { rule in
                if editingRuleID == rule.id {
                    RetentionRuleForm(
                        target:   $draftTarget,
                        duration: $draftDuration,
                        onSave: {
                            var updated = rule
                            updated.target   = draftTarget
                            updated.duration = draftDuration
                            DatabaseService.shared.insertRetentionRule(updated)
                            viewModel.loadData()
                            editingRuleID  = nil
                            showingAddForm = false
                        },
                        onCancel: {
                            editingRuleID  = nil
                            showingAddForm = false
                        }
                    )
                } else {
                    HStack {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(rule.targetLabel)
                            .font(.system(size: 12))
                        Text("→".loc)
                            .foregroundStyle(.tertiary)
                        Text(rule.durationLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Circle()
                            .fill(rule.isEnabled ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        // Edit button
                        Button {
                            draftTarget    = rule.target
                            draftDuration  = rule.duration
                            editingRuleID  = rule.id
                            showingAddForm = false
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        // Delete button
                        Button {
                            viewModel.deleteRetentionRule(rule)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.04)))
                }
            }
        }
    }
}

// MARK: - Retention Rule Form

private struct RetentionRuleForm: View {
    @Binding var target:   RetentionTarget
    @Binding var duration: TimeInterval
    let onSave:   () -> Void
    let onCancel: () -> Void

    /// Mirrors the sourceApp string so the TextField stays responsive
    /// even when `target` is swapped between cases by the kind picker.
    @State private var appName: String = ""

    /// Picker-friendly tag type — plain enum with no associated values so
    /// SwiftUI can match `.tag(...)` reliably across rebuilds. The binding
    /// below translates between this and the actual `RetentionTarget`.
    private enum TargetKind: String, Hashable, CaseIterable {
        case all, text, url, email, phone, code, color, sourceApp
    }

    private let kinds: [(String, TargetKind)] = [
        ("All Items",   .all),
        ("Text",        .text),
        ("URLs",        .url),
        ("Email",       .email),
        ("Phone",       .phone),
        ("Code",        .code),
        ("Color",       .color),
        ("From App",    .sourceApp),
    ]

    private func kind(of t: RetentionTarget) -> TargetKind {
        switch t {
        case .all: return .all
        case .contentType(let ct):
            switch ct {
            case .text:  return .text
            case .url:   return .url
            case .email: return .email
            case .phone: return .phone
            case .code:  return .code
            case .color: return .color
            default:     return .all
            }
        case .category:  return .all  // not exposed in this form
        case .sourceApp: return .sourceApp
        }
    }

    private func makeTarget(for kind: TargetKind) -> RetentionTarget {
        switch kind {
        case .all:       return .all
        case .text:      return .contentType(.text)
        case .url:       return .contentType(.url)
        case .email:     return .contentType(.email)
        case .phone:     return .contentType(.phone)
        case .code:      return .contentType(.code)
        case .color:     return .contentType(.color)
        case .sourceApp: return .sourceApp(appName)
        }
    }

    private var kindBinding: Binding<TargetKind> {
        Binding(
            get: { kind(of: target) },
            set: { target = makeTarget(for: $0) }
        )
    }

    private var appNameBinding: Binding<String> {
        Binding(
            get: { appName },
            set: {
                appName = $0
                target = .sourceApp($0)
            }
        )
    }

    private var isSourceAppSelected: Bool {
        if case .sourceApp = target { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Target picker
            HStack {
                Text("Apply to".loc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: kindBinding) {
                    ForEach(kinds, id: \.1) { label, k in
                        Text(label).tag(k)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            // App name input — only when .sourceApp is the selected kind
            if isSourceAppSelected {
                HStack {
                    Text("App name".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("e.g. Slack", text: appNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }

            // Duration picker
            HStack {
                Text("Keep for".loc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $duration) {
                    ForEach(RetentionRule.presetDurations, id: \.1) { label, secs in
                        Text(label).tag(secs)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            // Save / Cancel
            HStack(spacing: 8) {
                Button("Save".loc, action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel".loc, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.1), lineWidth: 1)))
        .onAppear {
            // When editing an existing .sourceApp rule, seed the TextField.
            if case .sourceApp(let name) = target { appName = name }
        }
    }
}

// MARK: - Danger Action Row

private struct DangerActionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let buttonLabel: String
    let isDestructive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            // Icon — color-block mark instead of bare glyph, matching
            // the rest of the app's iconography.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconColor.opacity(0.16))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 36, height: 36)

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LumaDesign.Typography.sans(13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(subtitle)
                    .font(LumaDesign.Typography.serifItalic(12))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Action button — destructive shows danger-tint fill,
            // non-destructive uses paper card.
            Button(action: action) {
                Text(buttonLabel)
                    .font(LumaDesign.Typography.sans(11, weight: .semibold))
                    .foregroundStyle(isDestructive ? palette.danger : palette.textPrimary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                            .fill(
                                isDestructive
                                    ? palette.dangerDim.opacity(isHovered ? 1.4 : 1.0)
                                    : palette.cardBg
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                                    .strokeBorder(
                                        isDestructive
                                            ? palette.danger.opacity(0.30)
                                            : palette.borderDefault,
                                        lineWidth: 0.5
                                    )
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(LumaDesign.Motion.quick, value: isHovered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let label: String
    let value: String

    @Environment(\.lumaPalette) private var palette

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(LumaDesign.Typography.serif(24))
                .foregroundStyle(palette.textPrimary)
            Text(label.uppercased())
                .font(LumaDesign.Typography.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(palette.textTertiary)
        }
        .frame(width: 110, height: 68)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .fill(palette.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                        .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                )
        )
    }
}
