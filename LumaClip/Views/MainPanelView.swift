// MainPanelView.swift
// LumaClip — macOS Clipboard Manager
//
// Root SwiftUI view. Background is fully transparent so the
// NSVisualEffectView + tint layer underneath shows through as
// macOS native frosted glass.
//
// Premium redesign: elevated panel hierarchy, command-center top bar,
// refined sidebar integration, polished drawer animation.

import SwiftUI
import AppKit

// MARK: - Window Drag Lock

private struct WindowDragLock: NSViewRepresentable {
    func makeNSView(context: Context) -> LockView { LockView() }
    func updateNSView(_ v: LockView, context: Context) {}
    final class LockView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Main Panel View

struct MainPanelView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.colorScheme)  private var scheme
    @EnvironmentObject private var settings: AppSettings
    // Observe the active language so the whole panel rebuilds (and every
    // `.loc` lookup re-evaluates) when the user switches language live.
    @ObservedObject private var i18n = LocalizationManager.shared

    private var palette: LumaPalette { LumaPalette(scheme: scheme) }

    /// Width of the fixed Inspector column. Wider than the previous
    /// drawer (308 → 385) to give the editorial header, URL meta card,
    /// and action buttons room to breathe — the old width pushed the
    /// "Copy & paste" CTA into a cramped 2-line wrap on long titles.
    /// If you ever want to make it user-resizable, this is the value
    /// to bind.
    fileprivate static let detailColumnWidth: CGFloat = 385

    var body: some View {
        ZStack(alignment: .trailing) {

            // ── Three-column fixed layout ───────────────────────
            //
            // Was: sidebar + content + sliding drawer overlay.
            // Now:  sidebar + content + Inspector column, all inline
            // and always laid out alongside the rest. The Inspector
            // is suppressed for filter modes that own the full content
            // area (Settings, Bundles) — there's nothing to inspect
            // when those views are showing, and surrendering the column
            // gives them more room.
            HStack(alignment: .top, spacing: 0) {

                // ── Sidebar ─────────────────────────────────────
                SidebarView(viewModel: viewModel)
                    .frame(width: 210)
                    .frame(maxHeight: .infinity)
                    .background(
                        scheme == .dark
                            ? palette.sidebarBg
                            : Color(hex: 0xF2F2F7)
                    )
                    .background(WindowDragLock())

                // ── Main content column ─────────────────────────
                mainContentColumn

                // ── Inspector column (fixed) ────────────────────
                if isDetailEligible(for: viewModel.activeFilter) {
                    detailColumn
                        .frame(width: Self.detailColumnWidth)
                        .frame(maxHeight: .infinity)
                }
            }

            // ── Onboarding overlay ──────────────────────────────
            //
            // Shown the first launch (`hasSeenOnboarding == false`) and
            // any time the user re-triggers from Settings → "Show Welcome
            // Tour" by flipping the flag back to false. Sits on top of
            // everything else (zIndex 100) so it's modal w.r.t. the panel.
            if !settings.hasSeenOnboarding {
                OnboardingOverlay {
                    // Persist on dismiss. The card-shrink animation inside
                    // OnboardingOverlay's `dismiss()` already played by the
                    // time this closure fires; wrapping the flag flip in
                    // `withAnimation` ensures the conditional removal
                    // also fades the overlay's residual layers smoothly
                    // rather than blinking off.
                    withAnimation(.easeOut(duration: 0.20)) {
                        settings.hasSeenOnboarding = true
                    }
                }
                .zIndex(100)
                .transition(.opacity)
            }
        }
        .background(Color.clear)
        .id(i18n.language)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(palette.borderDefault, lineWidth: 0.5)
        )
        // Global keyboard handler. Lives at the panel level (not on the
        // clipboard list) so arrow-key sidebar navigation continues to
        // work when the right pane is showing Bundles or Settings — both
        // of which unmount ClipboardListView entirely.
        .modifier(KeyboardNavigationModifier(viewModel: viewModel))
        .lumaPaletteEnvironment(scheme: scheme)
        // Re-route focus when navigating into a filter that hides the
        // Inspector (Settings / Bundles). Without this, focus could be
        // stranded in the now-detached `.drawer` zone and the user
        // would have to click before keyboard nav resumed.
        .onChange(of: viewModel.activeFilter) { newFilter in
            if !isDetailEligible(for: newFilter),
               viewModel.focusedZone == .drawer {
                viewModel.focusedZone = .sidebar
            }
        }
        // Right arrow → shift focus rightward across columns.
        // Sidebar → list → detail. With the Inspector now permanently
        // mounted, focus simply hops between columns without any
        // open/close ceremony.
        .onChange(of: viewModel.focusRightRequested) { _ in
            shiftFocusRight()
        }
        // Left arrow → shift focus leftward (detail → list → sidebar).
        .onChange(of: viewModel.focusLeftRequested) { _ in
            shiftFocusLeft()
        }
    }

    // MARK: - Focus zone transitions

    /// Move the focused zone one step to the right.
    ///
    /// Stops at `.list` — the Inspector column is passive (it just
    /// reflects the list selection), so there's nothing to "navigate
    /// into" there. If `.drawer` ever appears as the live zone (legacy
    /// state from before the layout change), we fold it back to `.list`
    /// so subsequent arrow keys behave consistently.
    private func shiftFocusRight() {
        switch viewModel.focusedZone {
        case .sidebar:
            // Settings and Bundles own the full content area and have
            // no clipboard list to land focus on — stay in sidebar so
            // ↑↓ keep navigating sidebar items.
            guard isDetailEligible(for: viewModel.activeFilter) else { return }
            withAnimation(LumaDesign.Motion.select) {
                viewModel.focusedZone = .list
            }

        case .list, .drawer:
            // Already at the rightmost focusable zone — nothing further
            // to the right. (`.drawer` is treated the same as `.list`.)
            break
        }
    }

    /// Move the focused zone one step to the left.
    private func shiftFocusLeft() {
        switch viewModel.focusedZone {
        case .drawer, .list:
            // From the list (or any legacy `.drawer` state) hop back
            // to the sidebar.
            withAnimation(LumaDesign.Motion.select) {
                viewModel.focusedZone = .sidebar
            }

        case .sidebar:
            // Already at the leftmost column.
            break
        }
    }

    /// Whether the Inspector column should render for a given filter.
    /// Settings and Bundles take over the content area, so the column
    /// hides there to give them more room.
    private func isDetailEligible(for filter: SidebarFilter) -> Bool {
        switch filter {
        case .settings, .bundles: return false
        default:                  return true
        }
    }

    // MARK: - Main Content Column
    //
    // Pulled out of `body` because the original inline expression — VStack
    // with a multi-shadowed RoundedRectangle background, an overlay, a
    // clipShape, a conditional focus-ring overlay, and three padding
    // modifiers, all containing scheme-conditional Color ternaries — was
    // too deeply nested for the SwiftUI type-checker, which gave up with:
    //   "The compiler is unable to type-check this expression in
    //    reasonable time; try breaking up the expression into distinct
    //    sub-expressions."
    // Splitting the background, focus-ring, and outer container into their
    // own typed properties shrinks the per-expression complexity below the
    // solver's budget. Behaviour is identical to the previous inline form.

    private var mainContentColumn: some View {
        VStack(spacing: 0) {
            // Command bar / top area
            //
            // The search bar's suggestions dropdown renders *below* the
            // CommandTopBar's 52pt fixed frame — i.e. it overflows
            // downward into the sibling area. SwiftUI draws VStack
            // siblings in declaration order (later on top), so without
            // an explicit zIndex the hairline + contentArea would
            // overdraw the dropdown. Raising the top bar's zIndex keeps
            // the dropdown visually on top without changing layout.
            CommandTopBar(viewModel: viewModel)
                .zIndex(1)

            // Hairline under top bar
            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)

            // Content area
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowDragLock())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(mainContentCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(listFocusRing)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .padding(.trailing, 8)
        .background(outerPanelBackground)
    }

    /// The rounded card sitting behind the main content column —
    /// fill + hairline border + dual shadow. Pulls colours from the
    /// editorial palette so light mode renders on solid paper instead
    /// of a translucent overlay (the previous 85% white wash muddied
    /// against the warm cream appBg).
    private var mainContentCardBackground: some View {
        let fillColor: Color = palette.listBg
        let strokeColor: Color = palette.borderSubtle
        let bigShadow: Color = scheme == .dark
            ? Color.black.opacity(0.40)
            : Color.black.opacity(0.06)
        let smallShadow: Color = scheme == .dark
            ? Color.black.opacity(0.20)
            : Color.black.opacity(0.02)
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

    /// Keyboard-focus ring for the list zone. Animated so focus shifts
    /// snap rather than flicker. Uses the lime accent for visibility
    /// against the paper-cream surrounding chrome.
    private var listFocusRing: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(
                viewModel.focusedZone == .list
                    ? palette.accentBright.opacity(0.65)
                    : Color.clear,
                lineWidth: 1.5
            )
            .animation(LumaDesign.Motion.select,
                       value: viewModel.focusedZone)
    }

    /// Flat backdrop sitting behind the rounded content card. Matches
    /// the editorial appBg (paper cream / graphite) so the cards float
    /// on a single warm ground, not a generic system-grey wash.
    private var outerPanelBackground: some View {
        palette.appBg
    }

    // MARK: Content Area

    @ViewBuilder
    private var contentArea: some View {
        Group {
            if case .settings = viewModel.activeFilter {
                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .bundles = viewModel.activeFilter {
                BundlesView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ClipboardListView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Detail Column (Inspector)
    //
    // Was a sliding drawer overlay; now an inline column rendered as a
    // sibling of `mainContentColumn`. The frame width is owned by the
    // parent HStack so this view just fills the slot it's given.
    //
    // The header is an editorial eyebrow only — no close button, since
    // the Inspector is part of the layout now and not toggleable. To
    // hide it, navigate to a filter that owns the full content area
    // (Settings / Bundles); `isDetailEligible(for:)` will collapse the
    // column automatically.

    private var detailColumn: some View {
        VStack(spacing: 0) {
            inspectorHeader
                .frame(height: 48)

            Rectangle()
                .fill(palette.borderSubtle)
                .frame(height: 0.5)

            DetailPanelView(viewModel: viewModel)
                .frame(maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.detailBg)
        )
        .modifier(GlassInsetModifier(
            colorScheme: scheme,
            wellColor: palette.detailBg,
            cornerRadius: 24
        ))
        // The Inspector is intentionally passive — it doesn't receive a
        // keyboard-focus ring. Arrow navigation stops at `.list`; the
        // Inspector reflects whatever the list selection is, so showing
        // an extra focus indicator here would be redundant.
        .lumaShadow(LumaDesign.Elevation.low)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .padding(.trailing, 8)
    }

    private var inspectorHeader: some View {
        HStack(spacing: 6) {
            Text("INSPECTOR".loc)
                .font(LumaDesign.Typography.mono(9, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(palette.textTertiary)
            Text("/".loc)
                .font(LumaDesign.Typography.serifItalic(13))
                .foregroundStyle(palette.textQuaternary)
            Text("Preview".loc)
                .font(LumaDesign.Typography.serifItalic(15))
                .foregroundStyle(palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Panel Modifier (surface backdrop)

struct PanelModifier: ViewModifier {
    let scheme: ColorScheme
    let fill:   Color
    var cornerRadius: CGFloat = 20
    var showBorder: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        scheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Command Top Bar

struct CommandTopBar: View {
    @ObservedObject var viewModel: ClipboardViewModel

    @Environment(\.colorScheme)  private var scheme
    @Environment(\.lumaPalette)  private var palette
    @EnvironmentObject private var settings: AppSettings

    @State private var isSearchFocused = false

    var body: some View {
        HStack(spacing: 10) {

            // ── Command search (full-width) ──────────────────────
            TokenSearchBarView(viewModel: viewModel)
                .frame(maxWidth: .infinity)

            // ── Right controls cluster ───────────────────────────
            HStack(spacing: 6) {

                // Paste queue (only shown when non-empty). Click "paste
                // next"; secondary-click clears the whole queue. Badge
                // count updates live via @Published pasteQueue.
                if !viewModel.pasteQueue.isEmpty {
                    PasteQueueBadge(viewModel: viewModel)
                        .environment(\.lumaPalette, palette)
                }

                // Sync pill — editorial treatment per spec §5.2.
                //
                // Combines what was previously two separate elements
                // (clip-count badge + a free-floating status dot) into
                // one pill that reads "85 synced" with a leading green
                // pulse. The pulse is the existing `StatusDot`, so the
                // semantic — "we're actively monitoring the pasteboard"
                // — is unchanged; only the visual shifts left and the
                // language ("clips" → "synced") matches the spec.
                HStack(spacing: 6) {
                    StatusDot(isActive: ClipboardService.shared.isMonitoring)
                    Text("\(viewModel.allCount)".loc)
                        .font(LumaDesign.Typography.mono(11, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .monospacedDigit()
                    Text("synced".loc)
                        .font(LumaDesign.Typography.sans(11))
                        .foregroundStyle(palette.textTertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                        .fill(palette.searchBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                        )
                )

                // Density toggle — last remaining top-bar control.
                // The previous "show detail" toggle is gone now that
                // the Inspector is permanent.
                TopBarIconButton(
                    icon: settings.listDensity.icon,
                    help: settings.listDensity == .compact
                        ? "Switch to comfortable view"
                        : "Switch to compact view"
                ) {
                    withAnimation(LumaDesign.Motion.select) {
                        settings.listDensity = settings.listDensity == .compact
                            ? .comfortable : .compact
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 52)
    }
}

// MARK: - Paste Queue Badge

/// Pill showing the current paste-queue count. Primary click pops the
/// next queued clip onto the system clipboard (user pastes into their
/// target app with ⌘V); secondary click clears the whole queue.
struct PasteQueueBadge: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.lumaPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button {
            _ = viewModel.pasteNextInQueue()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(viewModel.pasteQueue.count)".loc)
                    .font(LumaDesign.Typography.mono(11, weight: .semibold))
                    .monospacedDigit()
                Text("queued".loc)
                    .font(LumaDesign.Typography.sans(11))
                    .foregroundStyle(palette.textTertiary)
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .fill(palette.accent.opacity(isHovered ? 0.20 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .strokeBorder(palette.accent.opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Paste next queued clip (⌘V in target app to drop it in). Right-click to clear.".loc)
        .contextMenu {
            Button { _ = viewModel.pasteNextInQueue() } label: {
                Label("Paste Next".loc, systemImage: "arrowshape.right")
            }
            Divider()
            Button(role: .destructive) {
                viewModel.clearPasteQueue()
            } label: {
                Label("Clear Queue".loc, systemImage: "trash")
            }
        }
    }
}

// MARK: - Top Bar Icon Button

struct TopBarIconButton: View {
    let icon:     String
    var isActive: Bool = false
    let help:     String
    let action:   () -> Void

    @State private var isHovered = false
    @Environment(\.lumaPalette) private var palette
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isActive
                        ? palette.accent
                        : (isHovered ? palette.textPrimary : palette.textSecondary)
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                        .fill(
                            isActive
                                ? palette.accentDim
                                : (isHovered ? palette.hoverBg : Color.clear)
                        )
                )
                .animation(LumaDesign.Motion.quick, value: isActive)
                .animation(LumaDesign.Motion.quick, value: isHovered)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }
}
