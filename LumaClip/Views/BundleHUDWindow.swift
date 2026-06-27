// BundleHUDWindow.swift
// LumaClip - macOS Clipboard Manager
//
// A persistent, always-on-top floating mini-bar shown during an active
// bundle form-fill session. Stays visible even when the main panel hides,
// so the user can paste into any app and tap Next without losing their place.

import AppKit
import SwiftUI
import Combine

// MARK: - HUD Panel (never hides on resign-key)

private final class BundleHUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level                       = .floating
        isOpaque                    = false
        backgroundColor             = .clear
        hasShadow                   = true
        hidesOnDeactivate           = false
        isMovableByWindowBackground = true
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUD Window Controller
// Marked @MainActor to match ClipboardViewModel's actor isolation.

@MainActor
final class BundleHUDWindowController: NSObject {

    private let panel: BundleHUDPanel
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: ClipboardViewModel) {
        panel = BundleHUDPanel()
        super.init()

        // Embed the SwiftUI HUD view
        let hv = NSHostingView(rootView: BundleHUDView(viewModel: viewModel)
            .environmentObject(AppSettings.shared)
        )
        hv.frame = panel.contentRect(forFrameRect: panel.frame)
        hv.autoresizingMask = [.width, .height]
        hv.wantsLayer = true
        hv.layer?.backgroundColor = NSColor.clear.cgColor
        // Clip to rounded rect at the AppKit layer level — eliminates the
        // rectangular corner artifacts that show through the transparent window.
        hv.layer?.cornerRadius = 14
        hv.layer?.cornerCurve  = .continuous   // matches SwiftUI's RoundedRectangle
        hv.layer?.masksToBounds = true
        panel.contentView = hv

        // Show / hide in sync with activeBundleSession
        viewModel.$activeBundleSession
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                if session != nil {
                    self?.showHUD()
                } else {
                    self?.hideHUD()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Show / Hide

    private func showHUD() {
        if let screen = NSScreen.main?.visibleFrame {
            let w = panel.frame.width
            panel.setFrameOrigin(NSPoint(
                x: screen.midX - w / 2,
                y: screen.minY + 16
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideHUD() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        }
    }
}

// MARK: - HUD SwiftUI View

struct BundleHUDView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var i18n = LocalizationManager.shared

    private var isLight: Bool { colorScheme == .light }

    /// HUD background: accent in light mode, near-black in dark mode.
    private var hudBg: Color {
        isLight ? Color(hex: 0x007AFF) : Color.black.opacity(0.82)
    }

    /// "Next" button pill: white background with accent text in light mode,
    /// white background with dark text in dark mode.
    private var nextBg:   Color { Color.white }
    private var nextText: Color { isLight ? Color(hex: 0x007AFF) : Color.black.opacity(0.85) }

    var body: some View {
        if let session = viewModel.activeBundleSession {
            HStack(spacing: 0) {

                // Left: progress ring + bundle name
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                        let pct = Double(session.currentIndex) /
                                  Double(max(session.bundle.itemIDs.count, 1))
                        Circle()
                            .trim(from: 0, to: pct)
                            .stroke(Color.white,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(session.currentIndex)".loc)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.bundle.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(L("Step %d of %d — paste now, then Next", session.currentIndex, session.bundle.itemIDs.count))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.leading, 14)

                Spacer()

                // Right: Cancel + Next
                HStack(spacing: 8) {
                    Button {
                        viewModel.cancelBundleSession()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel bundle session".loc)

                    Button {
                        viewModel.advanceBundleSession()
                    } label: {
                        HStack(spacing: 5) {
                            Text("Next".loc)
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(nextText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(nextBg)
                                .shadow(color: .black.opacity(0.15), radius: 4)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Copy next clip and advance".loc)
                }
                .padding(.trailing, 12)
            }
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(hudBg)
            )
            .id(i18n.language)
        } else {
            Color.clear
        }
    }
}
