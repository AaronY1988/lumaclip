// FloatingButtonWindow.swift
// LumaClip - macOS Clipboard Manager
//
// Custom NSPanel subclass that creates a floating, draggable
// circular button on the desktop. Features glass-style appearance,
// edge snapping, hover animations, and new-copy pulse effect.
// This is the primary entry point for the clipboard manager UI.

import AppKit
import SwiftUI
import Combine

// MARK: - Floating Panel

/// Borderless, floating NSPanel that stays above all windows.
/// Handles dragging, edge-snapping, and click-through behavior.
class FloatingPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating behavior configuration
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false

        // Appear on all spaces
        self.hidesOnDeactivate = false
    }
}

// MARK: - Floating Button Window Controller

/// Manages the floating button panel lifecycle and positioning.
final class FloatingButtonWindowController: NSWindowController {

    private var viewModel: ClipboardViewModel
    private let settings = AppSettings.shared
    private var isDragging = false
    private var dragStartPoint: NSPoint = .zero
    private var windowStartOrigin: NSPoint = .zero
    private var cancellables = Set<AnyCancellable>()
    /// Local-event monitors installed in `setupDragTracking`. Retained so they
    /// can be removed in `deinit`; otherwise they outlive the controller and
    /// keep firing (and keep a strong ref to their own closure) forever.
    private var dragEventMonitor: Any?
    private var mouseUpEventMonitor: Any?

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel

        // Default position: right edge, vertically centered
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let buttonSize = CGFloat(AppSettings.shared.floatingButtonSize)
        let initialRect = NSRect(
            x: screenFrame.maxX - buttonSize - 12,
            y: screenFrame.midY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )

        let panel = FloatingPanel(contentRect: initialRect)

        super.init(window: panel)

        // Set SwiftUI content — ensure fully transparent hosting view
        let hostingView = NSHostingView(
            rootView: FloatingButtonView(viewModel: viewModel)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.borderWidth = 0
        hostingView.layer?.borderColor = nil
        hostingView.layer?.shadowOpacity = 0
        panel.contentView = hostingView

        // Add drag tracking
        setupDragTracking()

        // Observe settings changes to resize/re-opacity the window
        setupSettingsObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Settings Observers

    private func setupSettingsObservers() {
        // React to button size changes
        settings.$floatingButtonSize
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSize in
                self?.resizePanel(to: CGFloat(newSize))
            }
            .store(in: &cancellables)

        // React to button opacity changes
        settings.$floatingButtonOpacity
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newOpacity in
                self?.window?.alphaValue = CGFloat(newOpacity)
            }
            .store(in: &cancellables)
    }

    /// Resize the floating panel while keeping its center position
    private func resizePanel(to size: CGFloat) {
        guard let window = window else { return }
        let oldFrame = window.frame
        let centerX = oldFrame.midX
        let centerY = oldFrame.midY

        let newFrame = NSRect(
            x: centerX - size / 2,
            y: centerY - size / 2,
            width: size,
            height: size
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(newFrame, display: true)
        }

        // Also resize the hosting view and keep it transparent
        window.contentView?.frame = NSRect(x: 0, y: 0, width: size, height: size)
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.layer?.borderWidth = 0
    }

    // MARK: - Drag Handling

    private func setupDragTracking() {
        // Monitor for mouse drag events on the panel
        dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self,
                  let window = self.window,
                  event.window == window
            else { return event }

            if !self.isDragging {
                self.isDragging = true
                self.dragStartPoint = NSEvent.mouseLocation
                self.windowStartOrigin = window.frame.origin
            }

            let currentPoint = NSEvent.mouseLocation
            let dx = currentPoint.x - self.dragStartPoint.x
            let dy = currentPoint.y - self.dragStartPoint.y

            let newOrigin = NSPoint(
                x: self.windowStartOrigin.x + dx,
                y: self.windowStartOrigin.y + dy
            )
            window.setFrameOrigin(newOrigin)

            return event
        }

        mouseUpEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self = self, self.isDragging else { return event }
            self.isDragging = false
            self.snapToEdge()
            return event
        }
    }

    deinit {
        // Tear down NSEvent monitors — without this they stay live for the
        // rest of the app's lifetime and keep their closures (and captured
        // self-refs) alive past window teardown.
        if let monitor = dragEventMonitor    { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseUpEventMonitor { NSEvent.removeMonitor(monitor) }
    }

    /// Snap the floating button to the nearest screen edge
    private func snapToEdge() {
        guard let window = window,
              let screen = NSScreen.main?.visibleFrame
        else { return }

        let frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let margin: CGFloat = 12

        // Determine nearest horizontal edge
        let distToLeft = center.x - screen.minX
        let distToRight = screen.maxX - center.x

        var targetX: CGFloat
        if distToLeft < distToRight {
            targetX = screen.minX + margin
        } else {
            targetX = screen.maxX - frame.width - margin
        }

        // Clamp vertical position
        let targetY = max(screen.minY + margin,
                         min(frame.origin.y, screen.maxY - frame.height - margin))

        let targetFrame = NSRect(
            x: targetX,
            y: targetY,
            width: frame.width,
            height: frame.height
        )

        // Animate snap
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Show / Hide

    func show() {
        window?.alphaValue = CGFloat(settings.floatingButtonOpacity)
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Returns the centre point of the floating button in screen coordinates.
    var buttonScreenCenter: NSPoint? {
        guard let w = window else { return nil }
        let f = w.frame
        return NSPoint(x: f.midX, y: f.midY)
    }
}

// MARK: - Floating Button SwiftUI View

/// The visual appearance of the floating button.
/// Glass-morphism style with hover and pulse animations.
struct FloatingButtonView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var i18n = LocalizationManager.shared

    @State private var isHovered = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var hoverTask: DispatchWorkItem?

    private var buttonSize: CGFloat { CGFloat(settings.floatingButtonSize) }
    /// Icon is 84% of the frame so it has room to scale up on hover without clipping
    private var iconDisplaySize: CGFloat { buttonSize * 0.84 }

    var body: some View {
        ZStack {
            // Soft pulse ring on new copy
            if viewModel.newCopyPulse {
                PulseRing(size: buttonSize)
            }

            // Use the actual app icon from the asset catalog
            Image("FloatingIcon")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconDisplaySize, height: iconDisplaySize)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
                .scaleEffect(isHovered ? 1.10 : 1.0)
                .scaleEffect((viewModel.newCopyPulse == true) ? 1.06 : 1.0)
        }
        .frame(width: buttonSize, height: buttonSize)
        .background(Color.clear)
        .id(i18n.language)
        .opacity(isMonitoring ? settings.floatingButtonOpacity : 0.3)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: viewModel.newCopyPulse == true)
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            if hovering {
                // Show panel after a short pause so quick passes don't trigger it.
                // Skip if the panel is already visible — avoids re-triggering the
                // show animation when the user moves back onto the floating button
                // while the window is already open.
                guard !viewModel.isPanelVisible else { return }
                let task = DispatchWorkItem {
                    if isHovered && !viewModel.isPanelVisible { viewModel.showPanel() }
                }
                hoverTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
            }
        }
        .onTapGesture {
            viewModel.togglePanel()
        }
        .contextMenu {
            Button {
                viewModel.showPanel()
            } label: {
                Label("Show Clipboard".loc, systemImage: "clipboard")
            }

            Divider()

            if viewModel.bundles.isEmpty {
                Text("No Bundles".loc)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.bundles) { bundle in
                    Button {
                        viewModel.startBundleSession(bundle)
                    } label: {
                        Label(bundle.name, systemImage: bundle.icon)
                    }
                }
            }

            Divider()

            Button {
                viewModel.switchFilter(.bundles)
                viewModel.showPanel()
            } label: {
                Label("Manage Bundles…".loc, systemImage: "square.stack.3d.up")
            }
        }
    }

    /// Computed monitoring state from ClipboardService
    private var isMonitoring: Bool {
        ClipboardService.shared.isMonitoring
    }
}

private struct SymbolPulseIfAvailable: ViewModifier {
    let pulseValue: Bool
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.pulse, value: pulseValue)
        } else {
            content
        }
    }
}

// MARK: - Soft Pulse Ring

/// Three concentric rings that expand outward and fade, very gently.
private struct PulseRing: View {
    let size: CGFloat
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(
                        Color.white.opacity(animating ? 0 : 0.22 - Double(i) * 0.06),
                        lineWidth: 1.2
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(animating ? 1.55 + CGFloat(i) * 0.18 : 1.0)
                    .animation(
                        .easeOut(duration: 1.4)
                        .delay(Double(i) * 0.22)
                        .repeatForever(autoreverses: false),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
        .allowsHitTesting(false)
    }
}

