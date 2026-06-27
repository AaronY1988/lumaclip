// AppDelegate.swift
// LumaClip - macOS Clipboard Manager
//
// Application delegate that manages the app lifecycle.
// Initializes all services, creates the floating button
// and main panel windows, registers global hotkeys,
// and manages the menu bar status item.

import AppKit
import SwiftUI
import Combine

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Window Controllers
    private var floatingButtonController: FloatingButtonWindowController?
    private var mainPanelController: MainPanelWindowController?
    private var bundleHUDController: BundleHUDWindowController?
    private var quickPasteController: QuickPasteController?

    // MARK: Menu Bar
    //
    // The status-item button used to drive a native NSMenu. We've
    // replaced it with an NSPopover hosting a SwiftUI editorial view so
    // the dropdown can render Cormorant Garamond, paper-cream surfaces,
    // mono kbd hints, and the lime-on-ink accents that the rest of the
    // app uses. NSMenu rendering is system-owned and won't accept those.
    private var statusItem: NSStatusItem?
    private var menuBarPopover: NSPopover?

    /// Detects clicks outside the popover (anywhere else on screen) and
    /// dismisses it, mirroring NSMenu's "click-elsewhere kills it"
    /// behaviour. Lives on the global event monitor while the popover is
    /// shown; torn down when it closes so we don't leak handlers.
    private var menuBarOutsideClickMonitor: Any?

    // MARK: Core Objects
    private let viewModel = ClipboardViewModel()
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. Register bundled editorial typefaces (Cormorant Garamond +
        //    any other faces dropped into Resources/). Done first so the
        //    very first SwiftUI render sees the custom fonts available;
        //    if registration fails we fall back to system fonts via
        //    `LumaDesign.Typography._resolved(...)`.
        FontRegistration.register()

        // 1. Start core services
        startServices()

        // 2. Create floating button
        setupFloatingButton()

        // 3. Setup main panel
        setupMainPanel()

        // 4. Setup menu bar item
        setupMenuBar()

        // 5. Setup bundle HUD (persistent floating session bar)
        setupBundleHUD()

        // 6. Setup Quick Paste overlay
        setupQuickPaste()

        // 7. Register global hotkey
        setupHotkey()

        // 7. Observe settings changes
        setupObservers()

        // 8. Hide dock icon (accessory app mode)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardService.shared.stopMonitoring()
        RetentionService.shared.stopCleanupSchedule()
        GlobalHotkeyManager.shared.unregister()
    }

    // MARK: - URL Scheme Handling
    //
    // Supported URLs:
    //   lumaclip://paste?id=<uuid>     — copy a specific clip to the
    //                                    system pasteboard so ⌘V in the
    //                                    frontmost app drops it in
    //   lumaclip://search?q=<text>     — open the panel with its search
    //                                    field prefilled
    //   lumaclip://show                — just bring the panel to front
    //
    // Intended for scripting (Shortcuts, scripts, browser bookmarks) —
    // all behaviour is local; LumaClip never calls out over the network.

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "lumaclip" else { return }
        let host = (url.host ?? "").lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params: [String: String] = (components?.queryItems ?? []).reduce(into: [:]) {
            if let v = $1.value { $0[$1.name.lowercased()] = v }
        }

        switch host {
        case "paste":
            guard let idStr = params["id"], let uuid = UUID(uuidString: idStr) else {
                print("[URLScheme] paste: missing or invalid id")
                return
            }
            guard let item = DatabaseService.shared.fetchItem(id: uuid) else {
                print("[URLScheme] paste: item \(uuid) not found")
                return
            }
            ClipboardService.shared.copyItem(item)
            print("[URLScheme] paste: copied \(uuid) to pasteboard")

        case "search":
            let query = params["q"] ?? ""
            viewModel.searchQuery = query
            viewModel.showPanel()

        case "show", "":
            viewModel.showPanel()

        default:
            print("[URLScheme] unknown command: \(host)")
        }
    }

    // MARK: - Service Initialization

    private func startServices() {
        // Initialize database (singleton, auto-creates on access)
        _ = DatabaseService.shared

        // Start clipboard monitoring
        ClipboardService.shared.startMonitoring()

        // Start retention cleanup schedule
        RetentionService.shared.startCleanupSchedule()

        // Initialize privacy service
        _ = PrivacyService.shared

        // Migration: remove any legacy categories whose names match a default
        // but were created with a random UUID (from old seeding logic).
        // This prevents duplicates when upgrading from an older build.
        let fixedIds = Set(Category.defaultCategories.map { $0.id })
        let existing = DatabaseService.shared.fetchCategories()
        for cat in existing {
            let matchesDefaultName = Category.defaultCategories.contains { $0.name == cat.name }
            let hasOldUUID = !fixedIds.contains(cat.id)
            if matchesDefaultName && hasOldUUID {
                DatabaseService.shared.deleteCategory(id: cat.id)
            }
        }

        // Always ensure default categories exist.
        // INSERT OR REPLACE + fixed UUIDs → idempotent, never creates duplicates.
        for cat in Category.defaultCategories {
            DatabaseService.shared.insertCategory(cat)
        }
    }

    // MARK: - Floating Button

    private func setupFloatingButton() {
        floatingButtonController = FloatingButtonWindowController(viewModel: viewModel)

        if settings.showFloatingButton {
            floatingButtonController?.show()
        }
    }

    // MARK: - Main Panel

    private func setupMainPanel() {
        mainPanelController = MainPanelWindowController(viewModel: viewModel)

        // Observe panel visibility from ViewModel
        viewModel.$isPanelVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                if visible {
                    // Pass the floating button's centre so the panel grows from there
                    self?.mainPanelController?.originHint =
                        self?.floatingButtonController?.buttonScreenCenter
                    self?.mainPanelController?.showPanel()
                } else {
                    self?.mainPanelController?.hidePanel()
                }
            }
            .store(in: &cancellables)

        // Always bring panel to front when showPanel() is called,
        // even if isPanelVisible was already true
        viewModel.showPanelRequested
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.mainPanelController?.originHint =
                    self?.floatingButtonController?.buttonScreenCenter
                self?.mainPanelController?.showPanel()
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let img = NSImage(named: "MenuBarIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                // Fallback to SF Symbol
                button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "LumaClip")
                button.image?.size = NSSize(width: 16, height: 16)
            }

            // Click → toggle the editorial popover. We listen for both
            // left and right click so the surface behaves consistently
            // regardless of which mouse button the user reaches for.
            button.action = #selector(toggleMenuBarPopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Build the popover up-front so first-click is responsive (no
        // first-render lag while we instantiate SwiftUI). The hosted
        // view is itself idempotent — it observes the live view-model
        // and AppSettings, so reopening the popover always shows the
        // current bundle list and tracking state without needing a
        // rebuild step like the old NSMenuDelegate flow.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let actions = MenuBarActions(
            showPanel:           { [weak self] in self?.showPanel() },
            toggleTracking:      { [weak self] in self?.toggleTracking() },
            toggleFloatingButton:{ [weak self] in self?.toggleFloatingButton() },
            openBundlesView:     { [weak self] in self?.openBundlesView() },
            activateBundle:      { [weak self] bundle in
                self?.viewModel.startBundleSession(bundle)
            },
            quit:                { [weak self] in self?.quitApp() }
        )
        let host = NSHostingController(
            rootView: MenuBarPopoverView(
                viewModel: viewModel,
                actions: actions,
                onDismiss: { [weak self] in self?.dismissMenuBarPopover() }
            )
            .environmentObject(settings)
        )
        popover.contentViewController = host
        // Sized once to a sensible default. The hosted SwiftUI view is
        // top-down vertical, so we let height auto-grow via the host
        // controller's intrinsic size while pinning width.
        popover.contentSize = NSSize(width: 280, height: 320)
        menuBarPopover = popover
    }

    // MARK: - Menu Bar Popover Lifecycle

    /// Toggle the editorial popover open/closed against the status-item
    /// button. Mirrors the old "click status icon → menu drops down"
    /// affordance, plus a global outside-click monitor so any click
    /// outside the popover bounds dismisses it.
    @objc private func toggleMenuBarPopover(_ sender: Any?) {
        guard let popover = menuBarPopover,
              let button = statusItem?.button else { return }

        if popover.isShown {
            dismissMenuBarPopover()
            return
        }

        // Visually mark the status item as "open" while the popover is
        // showing — the system would do this automatically for an
        // NSMenu, but for an NSPopover we have to drive it ourselves.
        button.highlight(true)

        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )

        // Outside-click monitor: catches mouse clicks anywhere outside
        // the popover and dismisses it. `.transient` already covers
        // most cases, but the global monitor handles right-click on
        // other windows / Spaces with greater reliability.
        menuBarOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissMenuBarPopover() }
        }
    }

    /// Close the popover, drop the status-item highlight, and remove
    /// the outside-click monitor. Safe to call when the popover is
    /// already closed — each step is a no-op in that state.
    private func dismissMenuBarPopover() {
        menuBarPopover?.performClose(nil)
        statusItem?.button?.highlight(false)
        if let monitor = menuBarOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            menuBarOutsideClickMonitor = nil
        }
    }

    /// Navigate to the Bundles view. Called from the menu-bar popover
    /// "Manage Bundles…" row; identical to the action the old menu
    /// item invoked, kept here as a method so the closures captured in
    /// `MenuBarActions` reference a single source of truth.
    @objc private func openBundlesView() {
        viewModel.switchFilter(.bundles)
        viewModel.showPanel()
    }

    // MARK: - Bundle HUD

    private func setupBundleHUD() {
        bundleHUDController = BundleHUDWindowController(viewModel: viewModel)
    }

    // MARK: - Quick Paste

    private func setupQuickPaste() {
        quickPasteController = QuickPasteController(viewModel: viewModel)
        GlobalHotkeyManager.shared.registerQuickPaste(
            keyCode:   UInt32(settings.quickPasteHotkeyCode),
            modifiers: UInt32(settings.quickPasteHotkeyMods)
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.quickPasteController?.show()
            }
        }
    }

    // MARK: - Global Hotkey

    private func setupHotkey() {
        GlobalHotkeyManager.shared.register(
            keyCode:   UInt32(settings.toggleHotkeyCode),
            modifiers: UInt32(settings.toggleHotkeyMods)
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.viewModel.togglePanel()
            }
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        // Show/hide floating button based on settings
        settings.$showFloatingButton
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                if show {
                    self?.floatingButtonController?.show()
                } else {
                    self?.floatingButtonController?.hide()
                }
            }
            .store(in: &cancellables)

        // Re-register main panel hotkey when user changes it
        settings.$toggleHotkeyCode
            .combineLatest(settings.$toggleHotkeyMods)
            .dropFirst()   // skip initial emission (already registered above)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] code, mods in
                guard self != nil else { return }
                GlobalHotkeyManager.shared.reRegisterToggle(
                    keyCode: UInt32(code), modifiers: UInt32(mods))
            }
            .store(in: &cancellables)

        // Re-register Quick Paste hotkey when user changes it
        settings.$quickPasteHotkeyCode
            .combineLatest(settings.$quickPasteHotkeyMods)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] code, mods in
                guard self != nil else { return }
                GlobalHotkeyManager.shared.reRegisterQuickPaste(
                    keyCode: UInt32(code), modifiers: UInt32(mods))
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu Actions

    @objc private func showPanel() {
        viewModel.showPanel()
    }

    @objc private func toggleTracking() {
        ClipboardService.shared.toggleMonitoring()
    }

    @objc private func toggleFloatingButton() {
        settings.showFloatingButton.toggle()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu Bar Actions Bag
//
// Closure bag passed into `MenuBarPopoverView`. Decouples the SwiftUI
// surface from the AppDelegate so the view doesn't need to know about
// `@objc` methods or NSStatusItem internals — it just calls a closure
// and lets the delegate decide what that means. Keeps the popover view
// reusable in previews and isolates testing surfaces.
struct MenuBarActions {
    let showPanel:            () -> Void
    let toggleTracking:       () -> Void
    let toggleFloatingButton: () -> Void
    let openBundlesView:      () -> Void
    let activateBundle:       (ClipBundle) -> Void
    let quit:                 () -> Void
}

// MARK: - Menu Bar Popover View
//
// Replaces the old native NSMenu the status item used to show. The
// layout follows the same affordance order — Show Clipboard → Bundles
// list → Manage Bundles → Pause Tracking / Toggle Floating Button →
// Quit — but with the editorial language: Cormorant Garamond brand
// mark, mono section eyebrows, ink-active rows, lime accents, and a
// paper-cream surface that matches the rest of the app.
//
// Behaviour is unchanged. Every action calls back through `actions`,
// which AppDelegate wires to the same `@objc` methods the old NSMenu
// used. The bundles list is rendered inline (no submenu hover-flyout)
// because popovers don't naturally support nested fly-outs and an
// inline section is faster to scan for the typical 1–5 bundles a user
// has at hand.
struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var i18n = LocalizationManager.shared

    let actions: MenuBarActions
    let onDismiss: () -> Void

    private var palette: LumaPalette { LumaPalette(scheme: colorScheme) }

    private var versionCaption: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v \(v ?? "—") · CLIP"
    }

    private var isPaused: Bool {
        !ClipboardService.shared.isMonitoring
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Brand header ─────────────────────────────────────
            //
            // Compact version of the sidebar's brand block — same
            // mark, same wordmark — so the popover reads as another
            // surface of the same product, not a separate utility.
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.focusInk)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(palette.accentBright.opacity(0.5), lineWidth: 1)
                                .padding(2)
                        )
                    Text("L".loc)
                        .font(LumaDesign.Typography.serifItalic(16))
                        .foregroundStyle(palette.focusPaper)
                        .offset(y: -1)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text("Luma".loc)
                            .font(LumaDesign.Typography.serif(16))
                            .foregroundStyle(palette.textPrimary)
                        Text("Clip".loc)
                            .font(LumaDesign.Typography.serifItalic(16))
                            .foregroundStyle(palette.textSecondary)
                    }
                    Text(versionCaption)
                        .font(LumaDesign.Typography.mono(8, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(palette.textTertiary)
                }
                Spacer()
                StatusDot(isActive: !isPaused)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            divider

            // ── Primary action ───────────────────────────────────
            menuRow(
                icon: "tray.full",
                label: "Show Clipboard".loc,
                kbd: nil,
                action: { actions.showPanel(); onDismiss() }
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)

            // ── Bundles section ──────────────────────────────────
            sectionLabel("BUNDLES")
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if viewModel.bundles.isEmpty {
                Text("No bundles yet".loc)
                    .font(LumaDesign.Typography.serifItalic(12))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 1) {
                    ForEach(viewModel.bundles) { bundle in
                        bundleRow(bundle)
                    }
                }
                .padding(.horizontal, 8)
            }

            menuRow(
                icon: "rectangle.stack.badge.plus",
                label: "Manage Bundles…".loc,
                kbd: nil,
                action: { actions.openBundlesView(); onDismiss() }
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // ── Toggles ─────────────────────────────────────────
            //
            // These keep the popover open after a click so the user
            // sees the state flip — a small UX improvement over the
            // old NSMenu, which always dismissed.
            divider
                .padding(.top, 10)

            menuRow(
                icon: isPaused ? "play.fill" : "pause.fill",
                label: isPaused ? "Resume Tracking" : "Pause Tracking",
                kbd: nil,
                isActive: isPaused,
                action: { actions.toggleTracking() }
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)

            menuRow(
                icon: settings.showFloatingButton
                    ? "circle.fill" : "circle.dotted",
                label: "Toggle Floating Button".loc,
                kbd: nil,
                isActive: settings.showFloatingButton,
                action: { actions.toggleFloatingButton() }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            // ── Language quick toggle ───────────────────────────
            // Cycles between the two supported languages without
            // leaving the popover. The label shows the language you'll
            // switch *to*; the kbd badge shows the current one.
            menuRow(
                icon: "globe",
                label: settings.appLanguage == .chinese ? "English" : "简体中文",
                kbd: settings.appLanguage.shortLabel,
                action: {
                    settings.appLanguage = settings.appLanguage == .chinese ? .english : .chinese
                }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            divider

            // ── Quit ────────────────────────────────────────────
            menuRow(
                icon: "power",
                label: "Quit LumaClip".loc,
                kbd: "⌘Q",
                action: { actions.quit() }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 264)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.detailBg)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .lumaPaletteEnvironment(scheme: colorScheme)
        .id(i18n.language)
    }

    // MARK: - Row Builders

    /// Single menu row with icon + label + optional kbd hint. Hover
    /// gives the row a faint paper wash; the active variant (used for
    /// "Resume Tracking" when paused, etc.) uses an ink slab so toggles
    /// read as visibly "on".
    @ViewBuilder
    private func menuRow(
        icon: String,
        label: String,
        kbd: String?,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        MenuBarRow(
            icon: icon,
            label: label,
            kbd: kbd,
            isActive: isActive,
            action: action
        )
    }

    /// Bundle row — colour-block icon mark + name + a small "PLAY" kbd
    /// hint to reinforce the click affordance. Tapping starts the
    /// bundle session and dismisses the popover so focus snaps to the
    /// resulting target window.
    @ViewBuilder
    private func bundleRow(_ bundle: ClipBundle) -> some View {
        MenuBarBundleRow(bundle: bundle) {
            actions.activateBundle(bundle)
            onDismiss()
        }
    }

    /// Mono uppercase section eyebrow — same treatment used in the
    /// sidebar so the visual language carries over.
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(LumaDesign.Typography.mono(9, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(palette.textTertiary)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.borderSubtle)
            .frame(height: 0.5)
    }
}

// MARK: - Menu Bar Row Internals
//
// Pulled into their own structs so each owns its `@State private var
// isHovered` and the row hover doesn't bleed into siblings (which it
// would if the state lived on the popover view).

private struct MenuBarRow: View {
    let icon: String
    let label: String
    let kbd: String?
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isActive ? palette.accentBright
                                 : (isHovered ? palette.focusPaper : palette.textSecondary)
                    )
                    .frame(width: 18)

                Text(label)
                    .font(LumaDesign.Typography.sans(13, weight: .medium))
                    .foregroundStyle(
                        isActive || isHovered
                            ? palette.focusPaper
                            : palette.textPrimary
                    )

                Spacer(minLength: 4)

                if let kbd {
                    Text(kbd)
                        .font(LumaDesign.Typography.mono(10, weight: .semibold))
                        .foregroundStyle(
                            (isActive || isHovered)
                                ? palette.focusPaper.opacity(0.55)
                                : palette.textTertiary
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(
                        isActive || isHovered
                            ? palette.focusInk
                            : Color.clear
                    )
            )
            .animation(LumaDesign.Motion.quick, value: isHovered)
            .animation(LumaDesign.Motion.quick, value: isActive)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MenuBarBundleRow: View {
    let bundle: ClipBundle
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered
                              ? bundle.color.color
                              : bundle.color.color.opacity(0.18))
                    Image(systemName: bundle.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovered
                                         ? palette.focusInk
                                         : bundle.color.color)
                }
                .frame(width: 18, height: 18)

                Text(bundle.name)
                    .font(LumaDesign.Typography.sans(13, weight: .medium))
                    .foregroundStyle(
                        isHovered ? palette.focusPaper : palette.textPrimary
                    )
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("PLAY".loc)
                    .font(LumaDesign.Typography.mono(8, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(
                        isHovered
                            ? palette.accentBright
                            : palette.textQuaternary
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(isHovered ? palette.focusInk : Color.clear)
            )
            .animation(LumaDesign.Motion.quick, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

