// MainPanelWindow.swift
// LumaClip — macOS Clipboard Manager
//
// Layer stack (bottom → top):
//   1. RoundedContainerView — CALayer corner mask clips everything
//   2. NSVisualEffectView   — frosted-glass behind-window blur
//   3. Tint NSView          — thin colour wash over the blur
//   4. NSHostingView        — SwiftUI content (transparent bg)

import AppKit
import SwiftUI
import QuartzCore
import Combine

extension Notification.Name {
    static let lumaClipHidePanel = Notification.Name("com.lumaclip.hidePanel")
}

// MARK: - Rounded Container View

final class RoundedContainerView: NSView {
    private let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds    = true
        layer?.cornerRadius     = cornerRadius
        layer?.cornerCurve      = .continuous
        layer?.backgroundColor  = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Main Panel

class MainPanel: NSPanel {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Default size sized for the fixed three-column layout:
        //   sidebar 210 + list (~493pt at this width) + Inspector 385.
        // List trimmed -15% and Inspector widened +25% relative to the
        // previous proportions so titles + meta read tighter on the
        // list side and the Inspector's CTA / URL meta card no longer
        // crowd themselves on long content.
        let w: CGFloat = 1110, h: CGFloat = 680
        super.init(
            contentRect: NSRect(x: screen.midX - w/2, y: screen.midY - h/2, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level                        = .floating
        collectionBehavior           = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque                     = false
        backgroundColor              = .clear
        hasShadow                    = true
        isMovableByWindowBackground  = true
        titlebarAppearsTransparent   = true
        titleVisibility              = .hidden
        // Hard floor for the three-column layout. Below this the
        // Inspector starts crowding the list rows.
        minSize                      = NSSize(width: 980, height: 520)
        hidesOnDeactivate            = false

        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedKey),
            name: NSWindow.didResignKeyNotification, object: self)
    }

    @objc private func resignedKey() {
        // If a child window (SwiftUI sheet, popover, context menu) is now key,
        // do NOT hide — the panel is still logically "in use".
        if let keyWin = NSApp.keyWindow, keyWin != self {
            if keyWin.parent == self { return }
            if keyWin.sheetParent == self { return }
            // Auxiliary NSPanels (popovers, sheets, context menus, QuickPaste HUD)
            // are our own UI and should not count as losing focus. Using a class-
            // and level-based check instead of the prior fragile size heuristic
            // (which mis-fired for any small utility window, even unrelated ones).
            if keyWin is NSPanel { return }
            if keyWin.level.rawValue > NSWindow.Level.normal.rawValue { return }
        }
        // Route through the controller's hidePanel() for the genie effect
        NotificationCenter.default.post(name: .lumaClipHidePanel, object: self)
    }
}

// MARK: - Main Panel Window Controller

final class MainPanelWindowController: NSWindowController {

    private let viewModel:   ClipboardViewModel
    private let settings  =  AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    private weak var vev:         NSVisualEffectView?
    private weak var tintLayer:   NSView?
    private weak var hostingView: NSHostingView<AnyView>?

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        let panel = MainPanel()
        super.init(window: panel)
        build(panel: panel)
        applyMode(settings.appearanceMode, to: panel)
        observeMode(panel: panel)
        // Hide request from MainPanel.resignedKey (routed via notification to get genie effect)
        NotificationCenter.default.addObserver(
            forName: .lumaClipHidePanel, object: panel, queue: .main
        ) { [weak self] _ in self?.hidePanel() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build(panel: MainPanel) {
        let bounds = panel.contentRect(forFrameRect: panel.frame)

        // Layer 1 — corner mask
        let container = RoundedContainerView(frame: bounds, cornerRadius: 26)
        container.autoresizingMask = [.width, .height]

        // Layer 2 — blur
        let blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.blendingMode     = .behindWindow
        blur.state            = .active
        blur.wantsLayer       = true
        container.addSubview(blur)
        vev = blur

        // Layer 3 — colour tint
        let tint = NSView(frame: container.bounds)
        tint.autoresizingMask   = [.width, .height]
        tint.wantsLayer         = true
        container.addSubview(tint)
        tintLayer = tint

        // Layer 4 — SwiftUI
        let hv = NSHostingView(
            rootView: AnyView(contentView(colorScheme: resolvedScheme(settings.appearanceMode)))
        )
        hv.frame = container.bounds
        hv.autoresizingMask = [.width, .height]
        hv.wantsLayer = true
        hv.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hv)
        hostingView = hv

        panel.contentView = container
    }

    private func contentView(colorScheme: ColorScheme) -> some View {
        MainPanelView(viewModel: viewModel)
            .environment(\.colorScheme, colorScheme)
            .environmentObject(settings)
            // Inject premium palette into the environment at the root level
            // so every child view (SidebarView, ClipboardListView, DetailPanelView, etc.)
            // can access LumaPalette via @Environment(\.lumaPalette).
            .lumaPaletteEnvironment(scheme: colorScheme)
    }

    // MARK: Appearance

    private func applyMode(_ mode: AppearanceMode, to panel: NSPanel) {
        // System appearance
        let nsName = mode.nsAppearanceName
        NSApp.appearance   = nsName.map { NSAppearance(named: $0) } ?? nil
        panel.appearance   = nsName.map { NSAppearance(named: $0) } ?? nil

        // When following the system, force-resolve the current system appearance
        // so effectiveAppearance is up-to-date before we query it.
        if mode == .system {
            panel.invalidateShadow()
            panel.displayIfNeeded()
        }

        // Blur material
        vev?.material = material(for: mode, panel: panel)

        // Tint
        tintLayer?.layer?.backgroundColor = tint(for: mode, panel: panel)

        // SwiftUI colorScheme
        let scheme = resolvedScheme(mode, panel: panel)
        hostingView?.rootView = AnyView(contentView(colorScheme: scheme))
    }

    private func observeMode(panel: MainPanel) {
        // React to user changing the appearance setting
        settings.$appearanceMode
            .receive(on: RunLoop.main)
            .sink { [weak self, weak panel] mode in
                guard let self, let panel else { return }
                self.applyMode(mode, to: panel)
            }
            .store(in: &cancellables)

        // React to macOS switching between dark/light automatically.
        // When mode == .system, the setting doesn't change but the
        // tint layer, material, and SwiftUI colorScheme all need updating.
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self, weak panel] _ in
                guard let self, let panel else { return }
                if self.settings.appearanceMode == .system {
                    self.applyMode(.system, to: panel)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Helpers

    private func isDarkActive(panel: NSPanel? = nil) -> Bool {
        let appearance = panel?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func material(for mode: AppearanceMode, panel: NSPanel) -> NSVisualEffectView.Material {
        let dark = isDarkActive(panel: panel)
        switch mode {
        case .dark:          return .underWindowBackground
        case .light:         return .sidebar
        case .system:        return dark ? .underWindowBackground : .sidebar
        }
    }

    private func tint(for mode: AppearanceMode, panel: NSPanel) -> CGColor {
        let dark: Bool
        switch mode {
        case .dark:   dark = true
        case .light:  dark = false
        case .system: dark = isDarkActive(panel: panel)
        }
        if dark {
            return NSColor(white: 0.05, alpha: 0.28).cgColor
        } else {
            return NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.60).cgColor
        }
    }

    private func resolvedScheme(_ mode: AppearanceMode, panel: NSPanel? = nil) -> ColorScheme {
        switch mode {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return isDarkActive(panel: panel) ? .dark : .light
        }
    }

    // MARK: Show / Hide

    /// Set this to the floating button's screen-centre before calling showPanel()
    /// so the genie animation originates from / collapses back to that point.
    var originHint: NSPoint? = nil

    func showPanel() {
        guard let window else { return }

        // ── 1. Place window at its final resting position ────────────────
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fw = window.frame.width, fh = window.frame.height
        let finalFrame = NSRect(
            x: screen.midX - fw / 2,
            y: screen.midY - fh / 2,
            width: fw, height: fh
        )
        window.setFrame(finalFrame, display: false)
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        // AppKit would auto-focus the first acceptsFirstResponder control
        // (our NSTextField search bar). Redirect first responder to the
        // content view so the list gets keyboard input by default.
        window.makeFirstResponder(window.contentView)

        // ── 2. Fallback if no layer (shouldn't happen) ───────────────────
        guard let layer = window.contentView?.layer else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // ── 3. Compute the genie origin in normalised layer coords ───────
        //       (0,0) = bottom-left of panel  (1,1) = top-right
        let btn = originHint ?? NSPoint(x: finalFrame.midX, y: finalFrame.midY)
        let ax  = (btn.x - finalFrame.minX) / fw   // may be outside [0,1] — that's fine
        let ay  = (btn.y - finalFrame.minY) / fh

        // ── 4. Set anchor point without moving the layer visually ────────
        //       Core Animation rule: position = anchorPoint × bounds.size
        //       (for a root content layer whose superlayer origin == window origin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.anchorPoint = CGPoint(x: ax, y: ay)
        layer.position    = CGPoint(x: ax * fw, y: ay * fh)
        CATransaction.commit()

        // ── 5. Genie-spring expand ───────────────────────────────────────
        //       Model value = final state; .backwards fill shows fromValue first.

        // Scale: spring from a tiny dot → full size
        let scaleAnim               = CASpringAnimation(keyPath: "transform")
        scaleAnim.fromValue         = CATransform3DMakeScale(0.01, 0.01, 1.0)
        scaleAnim.toValue           = CATransform3DIdentity
        scaleAnim.damping           = 20.0
        scaleAnim.stiffness         = 320.0
        scaleAnim.mass              = 1.0
        scaleAnim.initialVelocity   = 8.0
        scaleAnim.duration          = 0.52
        scaleAnim.fillMode          = .backwards
        scaleAnim.isRemovedOnCompletion = true

        // Fade: invisible → opaque over the first ~0.18 s
        let fadeAnim                = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue          = 0
        fadeAnim.toValue            = 1
        fadeAnim.duration           = 0.18
        fadeAnim.fillMode           = .backwards
        fadeAnim.isRemovedOnCompletion = true

        // Model values (what remains after animations remove themselves)
        layer.transform = CATransform3DIdentity
        layer.opacity   = 1

        layer.add(scaleAnim, forKey: "genie.show.scale")
        layer.add(fadeAnim,  forKey: "genie.show.fade")

        // ── 6. Return anchor to centre once animation settles ────────────
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak layer] in
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position    = CGPoint(x: fw * 0.5, y: fh * 0.5)
            CATransaction.commit()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func hidePanel() {
        guard let window else { return }
        // Guard against being called again while the window is already hidden
        // (e.g. when the ViewModel syncs isPanelVisible = false and the
        //  AppDelegate sink calls us a second time).
        guard window.isVisible else { return }

        guard let layer = window.contentView?.layer else {
            window.orderOut(nil)
            viewModel.isPanelVisible = false
            return
        }

        let fw = window.frame.width, fh = window.frame.height
        let frame = window.frame

        // Genie collapses back toward the floating button
        let btn = originHint ?? NSPoint(x: frame.midX, y: frame.midY)
        let ax  = (btn.x - frame.minX) / fw
        let ay  = (btn.y - frame.minY) / fh

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.anchorPoint = CGPoint(x: ax, y: ay)
        layer.position    = CGPoint(x: ax * fw, y: ay * fh)
        CATransaction.commit()

        // Shrink
        let shrink                     = CABasicAnimation(keyPath: "transform")
        shrink.fromValue               = CATransform3DIdentity
        shrink.toValue                 = CATransform3DMakeScale(0.01, 0.01, 1.0)
        shrink.duration                = 0.22
        shrink.timingFunction          = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.8, 0.6)
        shrink.fillMode                = .forwards
        shrink.isRemovedOnCompletion   = false

        // Fade out
        let fade                       = CABasicAnimation(keyPath: "opacity")
        fade.fromValue                 = 1
        fade.toValue                   = 0
        fade.duration                  = 0.16
        fade.fillMode                  = .forwards
        fade.isRemovedOnCompletion     = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak layer] in
            self?.window?.orderOut(nil)
            // Reset layer to a clean state for the next showPanel()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.removeAllAnimations()
            layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.position    = CGPoint(x: fw * 0.5, y: fh * 0.5)
            layer?.transform   = CATransform3DIdentity
            layer?.opacity     = 1
            CATransaction.commit()
            // Sync ViewModel so isPanelVisible accurately reflects reality.
            // The AppDelegate sink will call hidePanel() again, but the
            // guard window.isVisible above will short-circuit it immediately.
            self?.viewModel.isPanelVisible = false
        }
        layer.add(shrink, forKey: "genie.hide.scale")
        layer.add(fade,   forKey: "genie.hide.fade")
        CATransaction.commit()
    }

    func togglePanel() {
        window?.isVisible == true ? hidePanel() : showPanel()
    }
}
