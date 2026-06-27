// OnboardingView.swift
// LumaClip — macOS Clipboard Manager
//
// Multi-step welcome experience shown the first time the app launches
// (and again on demand via the Settings → General → "Show Welcome Tour"
// button). Renders as a custom overlay inside the main panel — not a
// system sheet — so the visual language matches the rest of the app's
// editorial paper-cream / graphite aesthetic.
//
// Visual alignment:
//   - Card surface uses palette.detailBg (paper / graphite) — not a
//     generic gradient.
//   - Headlines use LumaDesign.Typography.serif / serifItalic — same
//     Cormorant Garamond stack as the sidebar wordmark.
//   - Body and meta text use palette.textSecondary / textTertiary.
//   - Primary CTA uses the signature focusInk-card with focusPaper text
//     and accentBright (lime) underline — same treatment as the
//     focused list row and Quick Paste highlight.
//   - Per-step accents are pulled from the editorial palette
//     (accent, accentMint, accentBright, accentPink, accentBlue,
//     accentWarm) — no SaaS rainbow.
//
// Six steps, each with a LIVE animated demo of the feature it describes:
//   1. Welcome    · pitch                   + brand mark + drifting sparkles
//   2. Capture    · how clips get in        + ⌘C keypress + streaming clip rows
//   3. Navigate   · keyboard shortcuts      + mini three-column panel cycling focus
//   4. Organize   · bundles & favorites     + items animating into a bundle card
//   5. Search     · token search            + typewriter tokens + filtering result list
//   6. Customize  · retention/theme/hotkey  + live-toggling settings panel
//
// All demos are real SwiftUI views with springy, timer-driven animations —
// not screenshots. They auto-play on appear.

import SwiftUI

// =====================================================================
// MARK: - Step Model
// =====================================================================

private struct OnboardingStep: Identifiable {
    enum Demo {
        case welcome, capture, navigate, organize, search, customize
    }

    enum AccentRole {
        case brand        // deep green + lime
        case mint         // accentMint
        case lime         // accentBright (the focus color)
        case pink         // accentPink
        case blue         // accentBlue
        case warm         // accentWarm
    }

    let id: Int
    let title: String      // serif (regular)
    let titleItalic: String // serifItalic — appended after title
    let body: String
    let role: AccentRole
    let demo: Demo

    // Computed (not stored) so each `.loc` lookup re-evaluates for the
    // active language — a `static let` would freeze the strings to
    // whichever language was current at first access.
    static var all: [OnboardingStep] { [
        .init(
            id: 0,
            title: "Welcome to ".loc,
            titleItalic: "LumaClip",
            body: "Your clipboard, supercharged. Every copy you make stays one keystroke away — without you having to think about it.".loc,
            role: .brand,
            demo: .welcome
        ),
        .init(
            id: 1,
            title: "Everything you copy, ".loc,
            titleItalic: "kept".loc,
            body: "Text, images, links, and code — silently captured the moment you press ⌘C. Auto-classified, searchable, and never leaves your Mac.".loc,
            role: .mint,
            demo: .capture
        ),
        .init(
            id: 2,
            title: "Master the ".loc,
            titleItalic: "keyboard".loc,
            body: "Finder-style column navigation. Arrows move focus across sidebar, list, and inspector — without lifting your hands.".loc,
            role: .lime,
            demo: .navigate
        ),
        .init(
            id: 3,
            title: "Bundles for ".loc,
            titleItalic: "repeat workflows".loc,
            body: "Group related clips into a Bundle, then paste them in order with one keystroke. Forms, drafts, boilerplate — solved.".loc,
            role: .pink,
            demo: .organize
        ),
        .init(
            id: 4,
            title: "Find anything in ".loc,
            titleItalic: "milliseconds".loc,
            body: "Type to filter, or use tokens like type:url and after:today to narrow down to the exact clip you remember.".loc,
            role: .blue,
            demo: .search
        ),
        .init(
            id: 5,
            title: "Make it ".loc,
            titleItalic: "yours".loc,
            body: "Retention windows, theme, and global hotkeys — every default is a starting point. Tune them in Settings.".loc,
            role: .warm,
            demo: .customize
        ),
    ] }
}

extension LumaPalette {
    /// The accent color for an onboarding step's editorial role.
    fileprivate func stepColor(_ role: OnboardingStep.AccentRole) -> Color {
        switch role {
        case .brand: return accent
        case .mint:  return accentMint
        case .lime:  return accentBright
        case .pink:  return accentPink
        case .blue:  return accentBlue
        case .warm:  return accentWarm
        }
    }
}

// =====================================================================
// MARK: - Onboarding Overlay
// =====================================================================

struct OnboardingOverlay: View {
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.lumaPalette) private var paletteFromEnv

    /// We may be presented in a context where `lumaPalette` wasn't injected
    /// (e.g. preview, or a host that forgot to set it). Fall back to a
    /// fresh palette built from the current scheme so colors still render.
    private var palette: LumaPalette {
        // Heuristic: a default-injected palette is fine; we use it. Otherwise
        // construct one from the active color scheme.
        LumaPalette(scheme: scheme)
    }

    @State private var stepIndex: Int = 0
    @State private var didAppear: Bool = false
    @State private var goingForward: Bool = true

    private var step: OnboardingStep { OnboardingStep.all[stepIndex] }
    private var isLastStep: Bool { stepIndex == OnboardingStep.all.count - 1 }
    private var isFirstStep: Bool { stepIndex == 0 }
    private var accent: Color { palette.stepColor(step.role) }

    var body: some View {
        ZStack {
            scrim
            card
                .frame(width: 540, height: 640)
                .scaleEffect(didAppear ? 1 : 0.94)
                .opacity(didAppear ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                didAppear = true
            }
        }
        .onExitCommand { dismiss() }
    }

    // MARK: Scrim — frosted backdrop with paper / graphite tint

    private var scrim: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(didAppear ? 1 : 0)
            .overlay(
                (scheme == .dark
                 ? Color(hex: 0x0F0E0C).opacity(0.55)
                 : Color(hex: 0xE8E2D6).opacity(0.45))
                    .opacity(didAppear ? 1 : 0)
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { /* absorb */ }
            .animation(.easeOut(duration: 0.30), value: didAppear)
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            // ── Top chrome: skip button ─────────────────────────
            HStack {
                Spacer()
                Button(action: dismiss) {
                    HStack(spacing: 5) {
                        Text("Skip".loc)
                            .font(LumaDesign.Typography.sans(11, weight: .semibold))
                            .tracking(0.4)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(palette.hoverBg.opacity(0.6))
                    )
                    .overlay(
                        Capsule().strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Skip the tour (Esc)".loc)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)

            // ── Step content ────────────────────────────────────
            stepBody
                .frame(maxHeight: .infinity)

            // ── Footer ──────────────────────────────────────────
            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
                .padding(.top, 12)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.borderDefault, lineWidth: 0.75)
        )
        .lumaShadow(LumaDesign.Elevation.high)
        .shadow(color: .black.opacity(scheme == .dark ? 0.50 : 0.10),
                radius: 32, x: 0, y: 16)
    }

    private var cardBackground: some View {
        ZStack {
            // Paper / graphite ground
            palette.detailBg

            // Subtle paper-grain hatch (light) or graphite vignette (dark)
            if scheme == .light {
                LinearGradient(
                    colors: [
                        Color(hex: 0xFAF7F0),
                        palette.detailBg,
                        Color(hex: 0xF6F2E9),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .blendMode(.multiply)
                .opacity(0.6)
            } else {
                RadialGradient(
                    colors: [
                        Color(hex: 0x2D2A26),
                        palette.detailBg,
                    ],
                    center: .topLeading,
                    startRadius: 50, endRadius: 600
                )
                .opacity(0.7)
            }

            // Step-tinted ambient glow at the top — uses the step's accent
            // but pulled way down so it reads as warmth, not color.
            LinearGradient(
                colors: [
                    accent.opacity(scheme == .dark ? 0.10 : 0.06),
                    accent.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .center
            )
            .animation(.easeInOut(duration: 0.50), value: step.id)

            // Editorial top hairline — like the focused-card lime accent.
            VStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0),
                                accent.opacity(0.55),
                                accent.opacity(0),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                Spacer()
            }
            .animation(.easeInOut(duration: 0.50), value: step.id)
        }
    }

    // MARK: Step body

    private var stepBody: some View {
        ZStack {
            ForEach(OnboardingStep.all) { s in
                if s.id == stepIndex {
                    StepContentView(step: s, palette: palette, accent: accent)
                        .transition(stepTransition)
                }
            }
        }
        .animation(LumaDesign.Motion.panel, value: stepIndex)
    }

    private var stepTransition: AnyTransition {
        let inEdge:  Edge = goingForward ? .trailing : .leading
        let outEdge: Edge = goingForward ? .leading  : .trailing
        return .asymmetric(
            insertion: .move(edge: inEdge).combined(with: .opacity),
            removal:   .move(edge: outEdge).combined(with: .opacity)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            // ── Back button ─────────────────────────────────────
            Button(action: back) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back".loc)
                        .font(LumaDesign.Typography.sans(12, weight: .semibold))
                        .tracking(0.2)
                }
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(palette.hoverBg)
                )
                .overlay(
                    Capsule().strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(PressableScale())
            .opacity(isFirstStep ? 0 : 1)
            .disabled(isFirstStep)
            .animation(.easeInOut(duration: 0.20), value: isFirstStep)

            Spacer()

            ProgressDots(
                count: OnboardingStep.all.count,
                active: stepIndex,
                tint: accent,
                idle: palette.borderStrong.opacity(0.45)
            )

            Spacer()

            // ── Primary CTA — focusInk card + accentBright keyline ──
            //
            // This is the same treatment used by the focused list row
            // and Quick Paste — near-black ink card with cream text and
            // a lime hairline. Editorial, not SaaS-gradient.
            Button(action: next) {
                HStack(spacing: 7) {
                    Text(isLastStep ? "Get Started" : "Next")
                        .font(LumaDesign.Typography.sans(13, weight: .semibold))
                        .tracking(0.3)
                    Image(systemName: isLastStep ? "arrow.right" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(palette.focusPaper)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    ZStack {
                        Capsule().fill(palette.focusInk)
                        // Lime keyline at the bottom — the LumaClip signature
                        VStack {
                            Spacer()
                            Capsule()
                                .fill(palette.accentBright.opacity(0.85))
                                .frame(height: 1.5)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 1)
                        }
                    }
                )
                .overlay(
                    Capsule().strokeBorder(
                        palette.accentBright.opacity(0.30),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: palette.focusInk.opacity(0.45), radius: 12, y: 4)
                .shadow(color: palette.accentBright.opacity(0.18), radius: 14, y: 0)
            }
            .buttonStyle(PressableScale())
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private func next() {
        if isLastStep { dismiss(); return }
        goingForward = true
        withAnimation(LumaDesign.Motion.panel) { stepIndex += 1 }
    }

    private func back() {
        guard !isFirstStep else { return }
        goingForward = false
        withAnimation(LumaDesign.Motion.panel) { stepIndex -= 1 }
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.22)) { didAppear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onDismiss() }
    }
}

// =====================================================================
// MARK: - Step Content
// =====================================================================

private struct StepContentView: View {
    let step: OnboardingStep
    let palette: LumaPalette
    let accent: Color

    var body: some View {
        VStack(spacing: 14) {
            // ── Eyebrow — step number, mono caps ────────────────
            Text("STEP \(step.id + 1)  ·  \(stepEyebrow)".loc)
                .font(LumaDesign.Typography.mono(9, weight: .semibold))
                .foregroundStyle(accentForEyebrow)
                .tracking(2.0)
                .padding(.top, 4)

            // ── Title — editorial serif with italic stylization ─
            if #available(macOS 14.0, *) {
                (
                    Text(step.title)
                        .font(LumaDesign.Typography.serif(28))
                        .foregroundStyle(palette.textPrimary)
                    +
                    Text(step.titleItalic)
                        .font(LumaDesign.Typography.serifItalic(28))
                        .foregroundStyle(palette.textPrimary)
                )
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .kerning(-0.3)
            } else {
                // Fallback on earlier versions
            }

            // ── Body ────────────────────────────────────────────
            Text(step.body)
                .font(LumaDesign.Typography.sans(13))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 50)
                .fixedSize(horizontal: false, vertical: true)

            // ── Live demo ───────────────────────────────────────
            Group {
                switch step.demo {
                case .welcome:    WelcomeDemo(palette: palette, accent: accent)
                case .capture:    CaptureDemo(palette: palette, accent: accent)
                case .navigate:   NavigateDemo(palette: palette, accent: accent)
                case .organize:   OrganizeDemo(palette: palette, accent: accent)
                case .search:     SearchDemo(palette: palette, accent: accent)
                case .customize:  CustomizeDemo(palette: palette, accent: accent)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)
        }
    }

    private var stepEyebrow: String {
        switch step.demo {
        case .welcome:   return "Welcome"
        case .capture:   return "Capture"
        case .navigate:  return "Navigate"
        case .organize:  return "Bundles"
        case .search:    return "Search"
        case .customize: return "Customize"
        }
    }

    /// For the lime step, eyebrow needs a darker tint to stay legible
    /// against paper.
    private var accentForEyebrow: Color {
        if step.role == .lime { return palette.accent }
        return accent
    }
}

// =====================================================================
// MARK: - Demo 1 · Welcome
// =====================================================================
//
// Mirrors the actual sidebar brand mark: a focusInk rounded square with
// a serif italic "L" in focusPaper, ringed by accentBright (lime). A
// gentle conic-gradient ring pulses around it; six sparkles drift outward
// on staggered delays. Below the mark, the "LumaClip" wordmark renders
// in the same serif/serifItalic split used in the sidebar.

private struct WelcomeDemo: View {
    let palette: LumaPalette
    let accent: Color

    @State private var ringRotation: Double = 0
    @State private var glyphPulse: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                // Drifting sparkles
                ForEach(0..<6, id: \.self) { i in
                    Sparkle(seed: i, accent: palette.accentBright, palette: palette)
                }

                // Slow rotating conic ring (subtle, editorial)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                palette.accentBright.opacity(0.0),
                                palette.accentBright.opacity(0.55),
                                palette.accent.opacity(0.85),
                                palette.accentBright.opacity(0.55),
                                palette.accentBright.opacity(0.0),
                            ],
                            center: .center
                        ),
                        lineWidth: 2.5
                    )
                    .frame(width: 152, height: 152)
                    .rotationEffect(.degrees(ringRotation))
                    .blur(radius: 0.4)

                // Soft halo
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                palette.accentBright.opacity(0.18),
                                palette.accent.opacity(0.10),
                                Color.clear,
                            ],
                            center: .center, startRadius: 4, endRadius: 88
                        )
                    )
                    .frame(width: 152, height: 152)

                // Brand mark — focusInk square, serif L, lime keyline
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(palette.focusInk)
                        .frame(width: 88, height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(
                                    palette.accentBright.opacity(0.55),
                                    lineWidth: 1
                                )
                                .padding(3)
                        )

                    Text("L".loc)
                        .font(LumaDesign.Typography.serifItalic(48))
                        .foregroundStyle(palette.focusPaper)
                        .offset(y: -2)

                    // Lime keyline at the bottom of the mark
                    VStack {
                        Spacer()
                        Capsule()
                            .fill(palette.accentBright)
                            .frame(width: 36, height: 2)
                            .padding(.bottom, 7)
                            .shadow(color: palette.accentBright.opacity(0.7), radius: 6)
                    }
                    .frame(width: 88, height: 88)
                }
                .scaleEffect(glyphPulse)
                .shadow(color: palette.focusInk.opacity(0.30), radius: 16, y: 6)
            }
            .frame(height: 168)

            // Wordmark — same as sidebar
            HStack(spacing: 0) {
                Text("Luma".loc)
                    .font(LumaDesign.Typography.serif(20))
                    .foregroundStyle(palette.textPrimary)
                Text("Clip".loc)
                    .font(LumaDesign.Typography.serifItalic(20))
                    .foregroundStyle(palette.textSecondary)
            }
            .kerning(-0.3)
        }
        .onAppear {
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                glyphPulse = 1.04
            }
        }
    }
}

private struct Sparkle: View {
    let seed: Int
    let accent: Color
    let palette: LumaPalette

    @State private var travel: CGFloat = 0
    @State private var fade:   Double = 0

    var body: some View {
        let angle = Double(seed) / 6.0 * 360.0
        let radians = angle * .pi / 180
        let radius: CGFloat = 56 + travel * 70

        Image(systemName: "sparkle")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(accent.opacity(0.95))
            .shadow(color: accent.opacity(0.6), radius: 5)
            .opacity(fade)
            .offset(
                x: CGFloat(cos(radians)) * radius,
                y: CGFloat(sin(radians)) * radius
            )
            .onAppear {
                let delay = Double(seed) * 0.45
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeOut(duration: 2.6)
                                    .repeatForever(autoreverses: false)) {
                        travel = 1
                    }
                    withAnimation(.easeInOut(duration: 2.6)
                                    .repeatForever(autoreverses: true)) {
                        fade = 1
                    }
                }
            }
    }
}

// =====================================================================
// MARK: - Demo 2 · Capture
// =====================================================================
//
// A live "stream" of clipboard items. Each tick, the ⌘C keycap pulses
// and a new clip row springs in at the top — using exactly the same
// visual structure as the real ClipboardListView: 3px left color border
// for content type, sans body, mono kbd badge for ⌘N shortcut.

private struct CaptureDemoClip: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let title: String
    let typeLabel: String
    let sourceApp: String
    let typeColor: KeyPath<LumaPalette, Color>
}

private struct CaptureDemo: View {
    let palette: LumaPalette
    let accent: Color

    private static let samples: [CaptureDemoClip] = [
        .init(icon: "link",
              title: "https://docs.swift.org/swiftui".loc,
              typeLabel: "Link",
              sourceApp: "Safari",
              typeColor: \.accentWarm),
        .init(icon: "chevron.left.forwardslash.chevron.right",
              title: "@MainActor final class ClipboardService".loc,
              typeLabel: "Code",
              sourceApp: "Xcode",
              typeColor: \.accentMint),
        .init(icon: "envelope.fill",
              title: "aaron@example.com".loc,
              typeLabel: "Email",
              sourceApp: "Mail",
              typeColor: \.accentBlue),
        .init(icon: "paintpalette.fill",
              title: "#1F3A2E".loc,
              typeLabel: "Color",
              sourceApp: "Figma",
              typeColor: \.accentPink),
        .init(icon: "photo.fill",
              title: "Screenshot 2026-05-08.png".loc,
              typeLabel: "Image",
              sourceApp: "Finder",
              typeColor: \.accentPurple),
    ]

    @State private var visible: [CaptureDemoClip] = []
    @State private var nextIndex: Int = 0
    @State private var keyPressed: Bool = false

    private let tick = Timer.publish(every: 1.7, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            // ⌘C keycap row (mono caption)
            HStack(spacing: 7) {
                LumaKeyCap(label: "⌘".loc, pressed: keyPressed, palette: palette, accent: accent)
                LumaKeyCap(label: "C".loc, pressed: keyPressed, palette: palette, accent: accent)

                Text("Captured silently".loc)
                    .font(LumaDesign.Typography.mono(10, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .tracking(0.6)

                Spacer()

                // "Live" indicator dot
                HStack(spacing: 5) {
                    Circle()
                        .fill(palette.accentMint)
                        .frame(width: 6, height: 6)
                        .shadow(color: palette.accentMint.opacity(0.8), radius: 3)
                    Text("LIVE".loc)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .foregroundStyle(palette.textTertiary)
                        .tracking(1.0)
                }
            }

            // Clip stream
            VStack(spacing: 5) {
                ForEach(visible) { clip in
                    DemoClipRow(clip: clip, palette: palette)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.96, anchor: .top)),
                                removal: .opacity
                            )
                        )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.xl, style: .continuous)
                .fill(palette.listBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.xl, style: .continuous)
                .strokeBorder(palette.borderSubtle, lineWidth: 0.75)
        )
        .lumaShadow(LumaDesign.Elevation.low)
        .onAppear { primeAndStart() }
        .onReceive(tick) { _ in advance() }
    }

    private func primeAndStart() {
        visible = []
        nextIndex = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { advance() }
    }

    private func advance() {
        withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) {
            keyPressed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.easeOut(duration: 0.22)) { keyPressed = false }
        }

        let next = Self.samples[nextIndex % Self.samples.count]
        nextIndex += 1
        withAnimation(LumaDesign.Motion.bounce) {
            visible.insert(next, at: 0)
            if visible.count > 4 { visible.removeLast() }
        }
    }
}

private struct DemoClipRow: View {
    let clip: CaptureDemoClip
    let palette: LumaPalette

    var body: some View {
        let typeColor = palette[keyPath: clip.typeColor]

        HStack(spacing: 10) {
            // 3px color rail (matches actual list row color border)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(typeColor)
                .frame(width: 3, height: 28)

            // Type icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(typeColor.opacity(0.16))
                Image(systemName: clip.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(typeColor)
            }
            .frame(width: 24, height: 24)

            // Title + meta
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title)
                    .font(LumaDesign.Typography.sans(12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(clip.typeLabel.uppercased())
                        .font(LumaDesign.Typography.mono(8, weight: .bold))
                        .foregroundStyle(typeColor)
                        .tracking(0.8)
                    Text("·".loc)
                        .foregroundStyle(palette.textQuaternary)
                    Text(clip.sourceApp)
                        .font(LumaDesign.Typography.sans(9, weight: .medium))
                        .foregroundStyle(palette.textTertiary)
                }
            }

            Spacer(minLength: 8)

            // Time meta
            Text("now".loc)
                .font(LumaDesign.Typography.mono(9, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
                .tracking(0.4)
        }
        .padding(.leading, 0)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                .fill(palette.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
        )
    }
}

// =====================================================================
// MARK: - Demo 3 · Navigate
// =====================================================================
//
// Mini three-column panel. Focus cycles between sidebar / list / inspector
// every 1.5s. Active column gets the editorial focus treatment: subtle
// lime hairline frame and the focused row inside renders as a focusInk
// card (the LumaClip selection signature).

private struct NavigateDemo: View {
    let palette: LumaPalette
    let accent: Color

    @State private var focus: Int = 0   // 0 = sidebar, 1 = list, 2 = inspector
    @State private var listSelection: Int = 1

    private let tick = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    private static let listRows: [(label: String, type: String, color: KeyPath<LumaPalette, Color>)] = [
        (label: "github.com/aarony".loc,  type: "Link",  color: \.accentWarm),
        (label: "Quarterly notes".loc,    type: "Text",  color: \.accentPink),
        (label: "func capture()".loc,     type: "Code",  color: \.accentMint),
        (label: "aaron@example.com".loc,  type: "Email", color: \.accentBlue),
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Three-column miniature
            HStack(spacing: 6) {
                column(
                    width: 88,
                    isFocused: focus == 0,
                    content: AnyView(sidebarContent)
                )
                column(
                    width: nil,
                    isFocused: focus == 1,
                    content: AnyView(listContent)
                )
                column(
                    width: 96,
                    isFocused: focus == 2,
                    content: AnyView(inspectorContent)
                )
            }
            .frame(height: 156)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.xl, style: .continuous)
                    .fill(palette.appBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.xl, style: .continuous)
                    .strokeBorder(palette.borderSubtle, lineWidth: 0.75)
            )

            // Keycap legend
            HStack(spacing: 14) {
                kbdLegendItem(keys: ["←", "→"], label: "Switch column".loc, active: true)
                kbdLegendItem(keys: ["↑", "↓"], label: "Move within".loc,   active: focus == 1)
                kbdLegendItem(keys: ["↩"],     label: "Copy".loc,          active: false)
                kbdLegendItem(keys: ["␣"],     label: "Inspect".loc,       active: focus == 2)
            }
        }
        .onReceive(tick) { _ in
            withAnimation(LumaDesign.Motion.select) {
                focus = (focus + 1) % 3
                if focus == 1 {
                    listSelection = (listSelection + 1) % Self.listRows.count
                }
            }
        }
    }

    // MARK: Column wrapper

    private func column(width: CGFloat?, isFocused: Bool, content: AnyView) -> some View {
        content
            .frame(maxWidth: width == nil ? .infinity : nil,
                   maxHeight: .infinity, alignment: .top)
            .frame(width: width)
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .fill(palette.listBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isFocused ? palette.accentBright.opacity(0.85) : palette.borderSubtle,
                        lineWidth: isFocused ? 1.25 : 0.5
                    )
            )
            .shadow(
                color: isFocused ? palette.accentBright.opacity(0.30) : .clear,
                radius: 10
            )
            .animation(LumaDesign.Motion.select, value: isFocused)
    }

    // MARK: Sidebar content

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarLine(label: "All clips".loc, color: palette.accentMint, active: true)
            sidebarLine(label: "Pinned".loc,    color: palette.accentWarm, active: false)
            sidebarLine(label: "Favorites".loc, color: palette.accentYellow, active: false)
            Divider().background(palette.borderSubtle).padding(.vertical, 2)
            sidebarLine(label: "Links".loc,     color: palette.accentWarm, active: false, dot: true)
            sidebarLine(label: "Code".loc,      color: palette.accentMint, active: false, dot: true)
            sidebarLine(label: "Images".loc,    color: palette.accentPurple, active: false, dot: true)
        }
    }

    private func sidebarLine(label: String, color: Color, active: Bool, dot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if dot {
                Circle().fill(color).frame(width: 6, height: 6)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(active ? color : color.opacity(0.5))
                    .frame(width: 9, height: 9)
            }
            Text(label)
                .font(LumaDesign.Typography.sans(9, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? palette.textPrimary : palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(active ? palette.accentDim : Color.clear)
        )
    }

    // MARK: List content

    private var listContent: some View {
        VStack(spacing: 4) {
            ForEach(0..<Self.listRows.count, id: \.self) { i in
                miniListRow(i)
            }
        }
    }

    private func miniListRow(_ i: Int) -> some View {
        let row = Self.listRows[i]
        let typeColor = palette[keyPath: row.color]
        let isSelected = focus == 1 && i == listSelection

        return HStack(spacing: 6) {
            // 3px color rail
            RoundedRectangle(cornerRadius: 1)
                .fill(typeColor)
                .frame(width: 2.5, height: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(typeColor.opacity(isSelected ? 0.28 : 0.18))
                Text(String(row.type.prefix(1)))
                    .font(LumaDesign.Typography.mono(8, weight: .bold))
                    .foregroundStyle(isSelected ? palette.accentBright : typeColor)
            }
            .frame(width: 16, height: 16)

            Text(row.label)
                .font(LumaDesign.Typography.sans(9, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? palette.focusPaper : palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // ⌘N shortcut (only on selected, like real list)
            if isSelected {
                Text("⌘\(i + 1)".loc)
                    .font(LumaDesign.Typography.mono(7, weight: .bold))
                    .foregroundStyle(palette.accentBright)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(palette.accentBright.opacity(0.18))
                    )
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? palette.focusInk : Color.clear)
        )
        .overlay(
            // Lime keyline at the bottom of selected row — signature.
            VStack {
                Spacer()
                Capsule()
                    .fill(isSelected ? palette.accentBright : Color.clear)
                    .frame(height: 1.2)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 1)
            }
        )
        .animation(LumaDesign.Motion.select, value: isSelected)
    }

    // MARK: Inspector content

    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Eyebrow
            Text("INSPECTOR".loc)
                .font(LumaDesign.Typography.mono(7, weight: .bold))
                .foregroundStyle(palette.textTertiary)
                .tracking(1.0)

            // Mock title (italic serif)
            Text("Code".loc)
                .font(LumaDesign.Typography.serifItalic(11))
                .foregroundStyle(palette.textPrimary)

            // Mock content card
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.hoverBg)
                .overlay(
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(palette.textTertiary.opacity(0.45))
                            .frame(width: 60, height: 3)
                        Capsule().fill(palette.textTertiary.opacity(0.45))
                            .frame(width: 44, height: 3)
                        Capsule().fill(palette.textTertiary.opacity(0.45))
                            .frame(width: 50, height: 3)
                    }
                    .padding(6)
                    , alignment: .topLeading
                )
                .frame(height: 42)

            Spacer()

            // Mock CTA — focusInk pill
            HStack(spacing: 4) {
                Capsule()
                    .fill(palette.focusInk)
                    .frame(height: 16)
                    .overlay(
                        Text("Copy".loc)
                            .font(LumaDesign.Typography.sans(7, weight: .semibold))
                            .foregroundStyle(palette.focusPaper)
                    )
                Capsule()
                    .fill(palette.hoverBg)
                    .frame(width: 28, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: Keycap legend

    private func kbdLegendItem(keys: [String], label: String, active: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { k in
                    LumaKeyCap(label: k, pressed: active, palette: palette, accent: palette.accentBright, compact: true)
                }
            }
            Text(label)
                .font(LumaDesign.Typography.mono(8, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
                .tracking(0.4)
        }
    }
}

// =====================================================================
// MARK: - Demo 4 · Organize (Bundles)
// =====================================================================
//
// Loose clip chips on the left fly into a "Tax Form" bundle card on the
// right one at a time, getting numbered as they arrive. The bundle card
// uses the actual editorial style: cream/graphite ground, serif italic
// title, mono count badge.

private struct BundleClip: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let typeColor: KeyPath<LumaPalette, Color>
}

private struct OrganizeDemo: View {
    let palette: LumaPalette
    let accent: Color

    private static let pool: [BundleClip] = [
        .init(label: "Aaron Yang".loc,         typeColor: \.accentPink),
        .init(label: "123 Market St".loc,      typeColor: \.accentMint),
        .init(label: "San Francisco, CA".loc,  typeColor: \.accentYellow),
        .init(label: "aaron@example.com".loc,  typeColor: \.accentBlue),
    ]

    @State private var loose:    [BundleClip] = []
    @State private var inBundle: [BundleClip] = []
    @State private var phase: Int = 0
    @State private var bundleGlow: Bool = false

    private let tick = Timer.publish(every: 0.95, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {

            // ── Loose clips column ──────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("CLIPS".loc)
                    .font(LumaDesign.Typography.mono(8, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
                    .tracking(1.4)

                ForEach(loose) { c in
                    looseChip(c)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)

            // ── Animated arrow ──────────────────────────────────
            VStack {
                Spacer()
                ZStack {
                    Capsule()
                        .fill(accent.opacity(0.18))
                        .frame(width: 32, height: 22)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                }
                Spacer()
            }
            .padding(.top, 18)

            // ── Bundle card ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // Bundle icon — focusInk square (same DNA as brand mark)
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.focusInk)
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accentBright)
                    }
                    .frame(width: 24, height: 24)

                    // Title — serif italic for editorial feel
                    Text("Tax Form".loc)
                        .font(LumaDesign.Typography.serifItalic(13))
                        .foregroundStyle(palette.textPrimary)

                    Spacer()

                    // Count badge — mono pill
                    Text("\(inBundle.count)".loc)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(minWidth: 16)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(accent.opacity(0.18))
                        )
                }

                Divider().background(palette.borderSubtle)

                VStack(spacing: 4) {
                    ForEach(Array(inBundle.enumerated()), id: \.element.id) { (i, c) in
                        bundleItem(index: i + 1, clip: c)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .leading)
                                        .combined(with: .opacity)
                                        .combined(with: .scale(scale: 0.85)),
                                    removal: .opacity
                                )
                            )
                    }
                    if inBundle.isEmpty {
                        Text("Drag clips here".loc)
                            .font(LumaDesign.Typography.serifItalic(10))
                            .foregroundStyle(palette.textTertiary)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(10)
            .frame(width: 200)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.xl, style: .continuous)
                    .fill(palette.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.xl, style: .continuous)
                    .strokeBorder(
                        bundleGlow ? accent : palette.borderDefault,
                        lineWidth: bundleGlow ? 1.25 : 0.75
                    )
            )
            .shadow(color: bundleGlow ? accent.opacity(0.40) : .clear, radius: 14)
            .animation(.easeOut(duration: 0.45), value: bundleGlow)
        }
        .onAppear { reset() }
        .onReceive(tick) { _ in advance() }
    }

    private func looseChip(_ c: BundleClip) -> some View {
        let typeColor = palette[keyPath: c.typeColor]
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(typeColor)
                .frame(width: 2.5, height: 16)
            Circle()
                .fill(typeColor)
                .frame(width: 6, height: 6)
            Text(c.label)
                .font(LumaDesign.Typography.sans(10.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                .fill(palette.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
        )
    }

    private func bundleItem(index: Int, clip: BundleClip) -> some View {
        let typeColor = palette[keyPath: clip.typeColor]
        return HStack(spacing: 7) {
            // Numbered badge — mono digit, focusInk
            Text("\(index)".loc)
                .font(LumaDesign.Typography.mono(9, weight: .bold))
                .foregroundStyle(palette.focusPaper)
                .frame(width: 14, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.focusInk)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(typeColor.opacity(0.55), lineWidth: 0.75)
                )

            Text(clip.label)
                .font(LumaDesign.Typography.sans(10.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.sm, style: .continuous)
                .fill(palette.hoverBg)
        )
    }

    private func reset() {
        loose = Self.pool
        inBundle = []
        phase = 0
        bundleGlow = false
    }

    private func advance() {
        if phase < Self.pool.count {
            withAnimation(LumaDesign.Motion.bounce) {
                if let first = loose.first {
                    loose.removeFirst()
                    inBundle.append(first)
                }
                phase += 1
            }
        } else if phase == Self.pool.count {
            withAnimation(.easeOut(duration: 0.35)) { bundleGlow = true }
            phase += 1
        } else if phase == Self.pool.count + 1 {
            withAnimation(.easeInOut(duration: 0.40)) { bundleGlow = false }
            phase += 1
        } else {
            withAnimation(LumaDesign.Motion.smooth) { reset() }
        }
    }
}

// =====================================================================
// MARK: - Demo 5 · Search
// =====================================================================
//
// Typewriter token-search demo. Tokens appear one at a time with a soft
// spring; then free text is typed character by character. Below, the
// result list filters: non-matches dim and blur.

private struct SearchDemoResult: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let typeColor: KeyPath<LumaPalette, Color>
    let isFav: Bool
    let isURL: Bool
    let matches: Bool
}

private struct SearchDemo: View {
    let palette: LumaPalette
    let accent: Color

    @State private var typedTokens: [SearchToken] = []
    @State private var typedText:   String = ""
    @State private var caretOn:     Bool = true
    @State private var resultStage: Int = 0

    private var allTokens: [SearchToken] {
        [
            .init(text: "type:url",   color: palette.accentWarm),
            .init(text: "after:today", color: palette.accentMint),
            .init(text: "fav:true",   color: palette.accentYellow),
        ]
    }

    private static let results: [SearchDemoResult] = [
        .init(title: "developer.apple.com/swift-ui".loc,      icon: "link",   typeColor: \.accentWarm, isFav: true,  isURL: true,  matches: true),
        .init(title: "github.com/apple/swift-evolution".loc,  icon: "link",   typeColor: \.accentWarm, isFav: true,  isURL: true,  matches: true),
        .init(title: "Quarterly review notes — Q2 2026".loc,  icon: "doc.text", typeColor: \.accentPink, isFav: false, isURL: false, matches: false),
        .init(title: "swiftpackageindex.com".loc,             icon: "link",   typeColor: \.accentWarm, isFav: true,  isURL: true,  matches: true),
        .init(title: "func capture() async throws { … }".loc, icon: "chevron.left.forwardslash.chevron.right", typeColor: \.accentMint, isFav: false, isURL: false, matches: false),
    ]

    private let caretTimer  = Timer.publish(every: 0.5,  on: .main, in: .common).autoconnect()
    private let cycleTimer  = Timer.publish(every: 0.85, on: .main, in: .common).autoconnect()
    @State private var cycle: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            // ── Search field — mirrors the real TokenSearchBar ──
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)

                ForEach(typedTokens) { tok in
                    HStack(spacing: 3) {
                        Circle().fill(tok.color).frame(width: 5, height: 5)
                        Text(tok.text)
                            .font(LumaDesign.Typography.mono(10, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tok.color.opacity(0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(tok.color.opacity(0.40), lineWidth: 0.5)
                    )
                    .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
                }

                Text(typedText)
                    .font(LumaDesign.Typography.sans(12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)

                if caretOn {
                    Rectangle()
                        .fill(palette.accent)
                        .frame(width: 1.4, height: 13)
                }

                Spacer()

                // Result count — mono caption
                Text(resultStage == 1 ? "3 / 5" : "5")
                    .font(LumaDesign.Typography.mono(9, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .tracking(0.5)
                    .animation(LumaDesign.Motion.smooth, value: resultStage)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .fill(palette.searchBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .strokeBorder(palette.borderDefault, lineWidth: 0.75)
            )

            // ── Result rows ─────────────────────────────────────
            VStack(spacing: 4) {
                ForEach(Self.results) { r in
                    resultRow(r)
                        .opacity(resultStage == 1 && !r.matches ? 0.22 : 1)
                        .scaleEffect(resultStage == 1 && !r.matches ? 0.97 : 1, anchor: .leading)
                        .blur(radius: resultStage == 1 && !r.matches ? 1.5 : 0)
                        .animation(.easeInOut(duration: 0.45), value: resultStage)
                }
            }

            HStack {
                Spacer()
                Text(resultStage == 1 ? "3 matches  ·  2 ms" : "5 clips")
                    .font(LumaDesign.Typography.mono(9, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .tracking(0.6)
                    .animation(LumaDesign.Motion.smooth, value: resultStage)
            }
        }
        .onReceive(caretTimer) { _ in caretOn.toggle() }
        .onReceive(cycleTimer) { _ in tick() }
    }

    private func resultRow(_ r: SearchDemoResult) -> some View {
        let typeColor = palette[keyPath: r.typeColor]
        let isMatch = r.matches && resultStage == 1
        let isLeader = isMatch && r.id == Self.results.first(where: \.matches)?.id

        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(typeColor)
                .frame(width: 2.5, height: 22)

            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(typeColor.opacity(isLeader ? 0.28 : 0.18))
                Image(systemName: r.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isLeader ? palette.accentBright : typeColor)
            }
            .frame(width: 20, height: 20)

            Text(r.title)
                .font(LumaDesign.Typography.sans(11, weight: isLeader ? .semibold : .medium))
                .foregroundStyle(isLeader ? palette.focusPaper : palette.textPrimary)
                .lineLimit(1)

            Spacer()

            if r.isFav {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isLeader ? palette.accentBright : palette.accentYellow)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                .fill(isLeader ? palette.focusInk : palette.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
        )
        .overlay(
            // Lime keyline at the bottom of the leader (focused) match
            VStack {
                Spacer()
                Capsule()
                    .fill(isLeader ? palette.accentBright : Color.clear)
                    .frame(height: 1.2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 1)
            }
        )
        .animation(LumaDesign.Motion.select, value: isLeader)
    }

    private func tick() {
        cycle += 1
        let phase = cycle % 8
        withAnimation(LumaDesign.Motion.bounce) {
            switch phase {
            case 1: typedTokens = [allTokens[0]]
            case 2: typedTokens = Array(allTokens.prefix(2))
            case 3: typedTokens = allTokens
            case 4: typedText = "s"
            case 5: typedText = "swi"
            case 6:
                typedText = "swift"
                resultStage = 1
            case 7: break // hold
            case 0:
                typedTokens = []
                typedText = ""
                resultStage = 0
            default: break
            }
        }
    }

    private struct SearchToken: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let color: Color
    }
}

// =====================================================================
// MARK: - Demo 6 · Customize
// =====================================================================
//
// Settings rows that animate themselves: theme segment slides between
// Light/Dark/System using matchedGeometryEffect; retention pill cycles;
// the launch toggle flips; the ⌃⇧V keycaps pulse.

private struct CustomizeDemo: View {
    let palette: LumaPalette
    let accent: Color

    @State private var themeIndex: Int = 2
    @State private var retentionIndex: Int = 2
    @State private var launchOn: Bool = true
    @State private var hotkeyPulse: Bool = false
    @State private var step: Int = 0

    private let themes: [String] = ["Light", "Dark", "System"]
    private let retentions: [String] = ["1d", "1w", "30d", "Forever"]

    private let tick = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 7) {
            settingRow(
                icon: "circle.lefthalf.filled",
                iconTint: palette.accentBlue,
                title: "Appearance".loc,
                hint: "Match the system or pin to one.",
                trailing: AnyView(
                    SegmentedPill(items: themes, active: themeIndex, palette: palette)
                )
            )

            settingRow(
                icon: "clock.arrow.circlepath",
                iconTint: palette.accentPink,
                title: "Retention".loc,
                hint: "Auto-clean clips you haven't touched.",
                trailing: AnyView(
                    SegmentedPill(items: retentions, active: retentionIndex, palette: palette)
                )
            )

            settingRow(
                icon: "command",
                iconTint: palette.accent,
                title: "Quick Paste hotkey".loc,
                hint: "Open from any app.",
                trailing: AnyView(
                    HStack(spacing: 3) {
                        LumaKeyCap(label: "⌃".loc, pressed: hotkeyPulse, palette: palette, accent: palette.accentBright, compact: true)
                        LumaKeyCap(label: "⇧".loc, pressed: hotkeyPulse, palette: palette, accent: palette.accentBright, compact: true)
                        LumaKeyCap(label: "V".loc, pressed: hotkeyPulse, palette: palette, accent: palette.accentBright, compact: true)
                    }
                )
            )

            settingRow(
                icon: "power",
                iconTint: palette.accentMint,
                title: "Launch at login".loc,
                hint: "Always ready in your menu bar.",
                trailing: AnyView(MiniToggle(on: launchOn, palette: palette))
            )
        }
        .onReceive(tick) { _ in advance() }
    }

    private func advance() {
        step += 1
        switch step % 5 {
        case 0:
            withAnimation(LumaDesign.Motion.select) { themeIndex = 0 }
        case 1:
            withAnimation(LumaDesign.Motion.select) {
                themeIndex = 1; retentionIndex = 0
            }
        case 2:
            withAnimation(LumaDesign.Motion.select) {
                themeIndex = 2; retentionIndex = 3
            }
        case 3:
            withAnimation(LumaDesign.Motion.bounce) { launchOn.toggle() }
        case 4:
            withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { hotkeyPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.easeOut(duration: 0.22)) { hotkeyPulse = false }
            }
        default: break
        }
    }

    private func settingRow(icon: String,
                            iconTint: Color,
                            title: String,
                            hint: String,
                            trailing: AnyView) -> some View {
        HStack(spacing: 11) {
            // Icon tile — colored wash with the icon (matches actual
            // SettingsView row icon style)
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconTint.opacity(0.16))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 26, height: 26)

            // Title + hint
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(LumaDesign.Typography.sans(12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(hint)
                    .font(LumaDesign.Typography.sans(10))
                    .foregroundStyle(palette.textTertiary)
            }

            Spacer()

            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .fill(palette.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .strokeBorder(palette.borderSubtle, lineWidth: 0.75)
        )
    }
}

// MARK: Customize sub-components

private struct SegmentedPill: View {
    let items: [String]
    let active: Int
    let palette: LumaPalette

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                ZStack {
                    if idx == active {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.focusInk)
                            .matchedGeometryEffect(id: "seg-active", in: ns)
                            .overlay(
                                // Lime keyline — signature treatment
                                VStack {
                                    Spacer()
                                    Capsule()
                                        .fill(palette.accentBright)
                                        .frame(height: 1)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 0.5)
                                }
                            )
                    }
                    Text(item)
                        .font(LumaDesign.Typography.mono(9, weight: .bold))
                        .foregroundStyle(idx == active ? palette.focusPaper : palette.textTertiary)
                        .tracking(0.5)
                }
                .frame(minWidth: 24)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.hoverBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.borderSubtle, lineWidth: 0.5)
        )
        .animation(LumaDesign.Motion.select, value: active)
    }
}

private struct MiniToggle: View {
    let on: Bool
    let palette: LumaPalette

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? palette.focusInk : palette.borderStrong.opacity(0.45))
                .frame(width: 32, height: 18)
                .overlay(
                    // Lime keyline when on
                    Capsule()
                        .strokeBorder(
                            on ? palette.accentBright.opacity(0.50) : Color.clear,
                            lineWidth: 0.75
                        )
                )

            Circle()
                .fill(on ? palette.accentBright : palette.focusPaper)
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .padding(.horizontal, 2)
        }
        .animation(LumaDesign.Motion.bounce, value: on)
    }
}

// =====================================================================
// MARK: - Shared: LumaKeyCap
// =====================================================================
//
// Editorial keyboard cap. Follows the project's keyboard-badge styling:
// rounded mono digit on a paper/graphite chip with a hairline border.
// When pressed, the chip flips to focusInk with focusPaper text and a
// lime keyline — the same focus signature as the selected list row.

private struct LumaKeyCap: View {
    let label: String
    var pressed: Bool = false
    let palette: LumaPalette
    var accent: Color
    var compact: Bool = false

    var body: some View {
        Text(label)
            .font(LumaDesign.Typography.mono(compact ? 9 : 11, weight: .bold))
            .foregroundStyle(pressed ? palette.focusPaper : palette.textPrimary)
            .padding(.horizontal, label.count == 1 ? (compact ? 5 : 7) : (compact ? 6 : 9))
            .padding(.vertical, compact ? 2 : 4)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
                        .fill(pressed ? palette.focusInk : palette.cardBg)

                    if pressed {
                        VStack {
                            Spacer()
                            Capsule()
                                .fill(palette.accentBright)
                                .frame(height: compact ? 0.8 : 1.2)
                                .padding(.horizontal, 3)
                                .padding(.bottom, 1)
                        }
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
                    .strokeBorder(
                        pressed ? palette.accentBright.opacity(0.50) : palette.borderDefault,
                        lineWidth: 0.75
                    )
            )
            .shadow(
                color: pressed ? palette.focusInk.opacity(0.40) : palette.borderSubtle.opacity(0.5),
                radius: pressed ? 5 : 1.5,
                y: pressed ? 2 : 0.5
            )
            .scaleEffect(pressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: pressed)
    }
}

// =====================================================================
// MARK: - Progress Dots
// =====================================================================
//
// Editorial: thin pills, lime fill on the active step, hairlines on idle.

private struct ProgressDots: View {
    let count: Int
    let active: Int
    let tint: Color
    let idle: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == active
                          ? AnyShapeStyle(tint)
                          : AnyShapeStyle(idle))
                    .frame(width: i == active ? 22 : 5, height: 5)
                    .animation(LumaDesign.Motion.select, value: active)
            }
        }
    }
}

// =====================================================================
// MARK: - Pressable Scale Button Style
// =====================================================================

private struct PressableScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(LumaDesign.Motion.quick, value: configuration.isPressed)
    }
}
