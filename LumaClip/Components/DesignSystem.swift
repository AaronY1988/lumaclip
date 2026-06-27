// DesignSystem.swift
// LumaClip — macOS Clipboard Manager
//
// Premium design token system. Defines every spacing, radius,
// typography, shadow, animation, and colour value used across
// the app in one authoritative place. Edit here → consistent
// everywhere.

import SwiftUI
import AppKit
import CoreText

// MARK: - Font Registration
//
// Bundles editorial typefaces (Cormorant Garamond + companions) into the
// app at runtime via Core Text. Typography helpers below query
// `FontRegistration.isRegistered(_:)` before requesting a custom face,
// so a missing or renamed font file degrades gracefully to the equivalent
// system font instead of crashing or rendering system substitution silently.
//
// We register at runtime (rather than via Info.plist's
// `ATSApplicationFontsPath`) so that:
//   1. We can host fonts in `LumaClip/Resources/` regardless of how
//      Xcode flattens the bundle layout.
//   2. We learn which PostScript names actually registered, so the
//      typography helpers can decide between `Font.custom` and the
//      system fallback.
//
// Lives in this file (rather than its own service module) so we don't
// need to mutate the manually-maintained `project.pbxproj`. DesignSystem
// is already in the build target.

enum FontRegistration {

    /// PostScript / family names known to have registered successfully
    /// during `register()`. Read by `Typography._resolved(...)` to decide
    /// whether `Font.custom(name)` is safe.
    private static var registeredNames: Set<String> = []

    /// Marker so a duplicate `register()` call (preview reload, AppDelegate
    /// re-entry) is a cheap no-op rather than a CoreText warning storm.
    private static var didRegister = false

    /// Idempotently registers every `.ttf` / `.otf` shipped with the app.
    /// Safe to call from `applicationDidFinishLaunching` or earlier — does
    /// not require a live run-loop.
    static func register() {
        guard !didRegister else { return }
        didRegister = true

        let bundle = Bundle.main
        let urls = ["ttf", "otf"].flatMap { ext -> [URL] in
            bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }

        guard !urls.isEmpty else {
            #if DEBUG
            print("[FontRegistration] No bundled fonts found.")
            #endif
            return
        }

        for url in urls { _registerFont(at: url) }

        #if DEBUG
        print("[FontRegistration] Registered \(registeredNames.count) name(s):")
        for name in registeredNames.sorted() { print("  · \(name)") }
        #endif
    }

    /// True when `name` was loaded by `register()` or is otherwise known
    /// to NSFontManager (some macOS-system faces count as available
    /// without explicit registration).
    static func isRegistered(_ name: String) -> Bool {
        if registeredNames.contains(name) { return true }
        return NSFontManager.shared.availableFonts.contains(name)
    }

    private static func _registerFont(at url: URL) {
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        if !success {
            #if DEBUG
            let errString = (error?.takeRetainedValue()).map {
                CFErrorCopyDescription($0) as String? ?? "?"
            } ?? "unknown"
            print("[FontRegistration] Failed to register \(url.lastPathComponent): \(errString)")
            #else
            error?.release()
            #endif
            return
        }

        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor] else { return }

        for descriptor in descriptors {
            if let psName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                registeredNames.insert(psName)
            }
            if let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                registeredNames.insert(familyName)
            }
        }
    }
}

// MARK: - LumaDesign Namespace

enum LumaDesign {

    // ── Spacing ────────────────────────────────────────────────
    enum Space {
        static let px2:  CGFloat = 2
        static let px4:  CGFloat = 4
        static let px6:  CGFloat = 6
        static let px8:  CGFloat = 8
        static let px10: CGFloat = 10
        static let px12: CGFloat = 12
        static let px14: CGFloat = 14
        static let px16: CGFloat = 16
        static let px20: CGFloat = 20
        static let px24: CGFloat = 24
        static let px28: CGFloat = 28
        static let px32: CGFloat = 32
        static let px40: CGFloat = 40

        // Semantic aliases
        static let xs:   CGFloat = px4
        static let sm:   CGFloat = px8
        static let md:   CGFloat = px12
        static let lg:   CGFloat = px16
        static let xl:   CGFloat = px24
        static let xxl:  CGFloat = px32
    }

    // Backward-compat alias
    typealias Spacing = Space

    // ── Corner Radius ──────────────────────────────────────────
    enum Radius {
        static let xs:   CGFloat = 4
        static let sm:   CGFloat = 6
        static let md:   CGFloat = 8
        static let lg:   CGFloat = 10
        static let xl:   CGFloat = 14
        static let xxl:  CGFloat = 18
        static let pill: CGFloat = 999
    }

    // ── Typography Scale ───────────────────────────────────────
    enum Typography {
        // Size constants
        static let caption2: CGFloat = 9
        static let caption:  CGFloat = 10
        static let footnote: CGFloat = 11
        static let body:     CGFloat = 12
        static let callout:  CGFloat = 13
        static let subhead:  CGFloat = 14
        static let title3:   CGFloat = 15

        // ── Common system-font descriptors (legacy callers) ────
        static func caption(_ weight: Font.Weight = .regular) -> Font {
            sans(caption, weight: weight)
        }
        static func footnote(_ weight: Font.Weight = .regular) -> Font {
            sans(footnote, weight: weight)
        }
        static func body(_ weight: Font.Weight = .regular) -> Font {
            sans(body, weight: weight)
        }
        static func callout(_ weight: Font.Weight = .regular) -> Font {
            sans(callout, weight: weight)
        }
        static func subhead(_ weight: Font.Weight = .semibold) -> Font {
            sans(subhead, weight: weight)
        }
        static func micro(_ weight: Font.Weight = .medium) -> Font {
            sans(caption2, weight: weight)
        }

        // ── Editorial typography stack ────────────────────────
        //
        // Three faces, picked to mirror the redesign spec while being
        // bundle-friendly on macOS:
        //
        //   serif → Cormorant Garamond (variable, bundled in Resources/)
        //           — used for editorial headlines, "Clipstore", region
        //           titles, Inspector eyebrow titles. Italic variant also
        //           ships, used by `serifItalic`.
        //
        //   sans  → SF Pro (system) — paragraph text, list rows, labels.
        //           Spec asks for Geist; SF Pro is its close macOS cousin
        //           and saves a font binary. Swap names below if you ever
        //           ship Geist in Resources/.
        //
        //   mono  → SF Mono (system) — kbd badges, URL previews, counters,
        //           micro-uppercase eyebrows. Same swap path as sans.
        //
        // All three are wrapped through `_resolved(...)` which falls back
        // to the equivalent system face if the bundled font failed to
        // register at launch (printed by `FontRegistration.register()`).
        // That keeps the app readable even if a font file is removed.

        /// Editorial serif (Cormorant Garamond). Use for display titles
        /// and the brand name. For mid-paragraph italics, prefer
        /// `serifItalic(_:)` — toggling `italic` here flips the variant.
        ///
        /// Variable fonts can ship under several PostScript spellings
        /// depending on the file's `name` table — we try the family name
        /// first (most reliable for Font.custom), then common stems, then
        /// fall back to the system serif.
        static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
            let candidates: [String] = italic
                ? ["CormorantGaramond-Italic", "Cormorant Garamond Italic", "Cormorant Garamond"]
                : ["CormorantGaramond-Regular", "Cormorant Garamond"]
            return _resolved(candidates: candidates, system: .serif, size: size)
        }

        /// Italic variant of `serif`. Pulled out so callers don't have to
        /// remember the boolean argument — `Typography.serifItalic(22)`
        /// reads better at a use-site than `Typography.serif(22, italic: true)`.
        static func serifItalic(_ size: CGFloat) -> Font {
            serif(size, italic: true)
        }

        /// Sans body face. We currently use the system sans (SF Pro on
        /// macOS) — drop a Geist variant into Resources/ and add its
        /// PostScript name to `candidates` to switch over without touching
        /// any call-sites.
        static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            _resolved(candidates: [], system: .default, size: size).weight(weight)
        }

        /// Monospaced face — kbd badges, URL bodies, micro-eyebrows.
        /// Same swap path as `sans` if you ship Geist Mono later.
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// Resolve the first registered candidate to a `Font.custom`,
        /// falling back to the design-tagged system font when none of the
        /// candidates are available. SwiftUI would silently substitute on
        /// an unknown name; the explicit fallback here keeps the system
        /// font's metrics (line height, x-height) instead.
        private static func _resolved(candidates: [String],
                                      system design: Font.Design,
                                      size: CGFloat) -> Font {
            for name in candidates where FontRegistration.isRegistered(name) {
                return Font.custom(name, size: size)
            }
            return .system(size: size, design: design)
        }
    }


    // ── Animation Curves ──────────────────────────────────────
    enum Motion {
        /// 100ms snap — button presses, instant feedback
        static let instant  = SwiftUI.Animation.easeOut(duration: 0.10)
        /// 150ms — hover transitions, micro reveals
        static let quick    = SwiftUI.Animation.easeOut(duration: 0.15)
        /// 200ms — colour/opacity changes
        static let smooth   = SwiftUI.Animation.easeInOut(duration: 0.20)
        /// spring(0.22, 0.86) — selection highlight slides
        static let select   = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.86)
        /// spring(0.28, 0.88) — panel slides, drawer
        static let panel    = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.88)
        /// spring(0.35, 0.72) — bouncy badges, toasts
        static let bounce   = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.72)
    }

    // Backward-compat
    typealias Animation = Motion

    // ── Shadows ───────────────────────────────────────────────
    enum Elevation {
        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }

        /// Hairline inner border lift
        static let micro = Shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 0.5)
        /// Card surface pop
        static let low   = Shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 1)
        /// Floating panel
        static let mid   = Shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 3)
        /// Drawer / overlay
        static let high  = Shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 6)
        /// Glow (accent-coloured)
        static func glow(_ color: Color, intensity: CGFloat = 0.22) -> Shadow {
            Shadow(color: color.opacity(intensity), radius: 12, x: 0, y: 0)
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply a LumaDesign elevation shadow.
    func lumaShadow(_ e: LumaDesign.Elevation.Shadow) -> some View {
        shadow(color: e.color, radius: e.radius, x: e.x, y: e.y)
    }
}

// MARK: - Semantic Colour Roles

/// Exposes the current-context semantic palette so all views
/// read from a single source of truth that handles both dark
/// and light modes cleanly.
struct LumaPalette {

    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }

    // ──────────────────────────────────────────────────────────
    // Editorial palette
    //
    // Replaces the previous generic-SaaS dark/light palette with the
    // warm-paper aesthetic specified in the redesign brief, while keeping
    // every public property name intact so existing call-sites don't have
    // to change.
    //
    // Light mode is the source of truth (paper-cream ground, near-black
    // ink, deep-green primary, lime-green focus highlight). Dark mode
    // mirrors the same DNA on a graphite ground — same hierarchy, same
    // accents, retuned for low-light comfort. We deliberately keep dark
    // mode editorial rather than reverting to system defaults so the
    // design language stays consistent regardless of OS appearance.
    //
    // Hex constants are duplicated rather than DRY'd into a token enum
    // because (a) Swift colour interpolation in this struct is already
    // tight, and (b) seeing both light + dark on the same line makes
    // contrast trade-offs obvious during review.
    // ──────────────────────────────────────────────────────────

    // ── Surfaces ───────────────────────────────────────────────
    /// Outermost window background — paper cream / graphite.
    var appBg:      Color { dark ? Color(hex: 0x1A1916) : Color(hex: 0xF4F1EC) }
    /// Sidebar panel — slightly warmer/cooler than appBg.
    var sidebarBg:  Color { dark ? Color(hex: 0x211F1C) : Color(hex: 0xFAF8F4) }
    /// List / content area — pure surface where rows sit.
    var listBg:     Color { dark ? Color(hex: 0x1A1916) : Color(hex: 0xFFFFFF) }
    /// Detail / Inspector drawer surface.
    var detailBg:   Color { dark ? Color(hex: 0x252320) : Color(hex: 0xFFFFFF) }
    /// Elevated card / row highlight (used as a subtle wash, not a
    /// hard fill — focused-row treatment is handled by `focusInk` below).
    var cardBg:     Color { dark ? Color(hex: 0x252320) : Color(hex: 0xFFFFFF) }
    /// Hover fill — ink at 4% on light, paper at 5% on dark.
    var hoverBg:    Color { dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04) }
    /// Selected row — lime tint sits on top, very low alpha to read
    /// like a wash rather than a slab.
    var selectedBg: Color { dark ? Color(hex: 0xD4FF3F).opacity(0.10) : Color(hex: 0xD4FF3F).opacity(0.18) }

    // ── Borders ────────────────────────────────────────────────
    /// Dividers and card hairlines.
    var borderSubtle:  Color { dark ? Color.white.opacity(0.06) : Color(hex: 0xF0ECE4) }
    /// Default card / input border.
    var borderDefault: Color { dark ? Color.white.opacity(0.12) : Color(hex: 0xE8E4DC) }
    /// Hover / pressed border.
    var borderStrong:  Color { dark ? Color.white.opacity(0.22) : Color(hex: 0xB8B5AD) }

    // ── Text ───────────────────────────────────────────────────
    /// Primary ink — body and headline text.
    var textPrimary:   Color { dark ? Color(hex: 0xECE8E0) : Color(hex: 0x181816) }
    /// Mid-tier text — descriptions, lead-ins.
    var textSecondary: Color { dark ? Color(hex: 0xB5B1A8) : Color(hex: 0x4A4944) }
    /// Quiet text — meta, timestamps, source labels.
    var textTertiary:  Color { dark ? Color(hex: 0x7A766D) : Color(hex: 0x8A877F) }
    /// Whisper text — placeholders, watermark counts, divider notes.
    var textQuaternary:Color { dark ? Color(hex: 0x4A4640) : Color(hex: 0xB8B5AD) }

    // ── Accent ─────────────────────────────────────────────────
    //
    // Two layers of accent in the editorial system:
    //   `accent`        — deep green primary surface (buttons, selection
    //                     state on the dark side of the focused-card).
    //   `accentBright`  — lime-green focus highlight (counts on selected
    //                     nav, focused-card kbd, primary CTA text). Used
    //                     sparingly — see spec §2.
    var accent:        Color { dark ? Color(hex: 0xA8D480) : Color(hex: 0x1F3A2E) }
    var accentDim:     Color { dark ? Color(hex: 0xA8D480).opacity(0.16) : Color(hex: 0x1F3A2E).opacity(0.10) }
    var accentText:    Color { dark ? Color(hex: 0xC8E8A0) : Color(hex: 0x1F3A2E) }
    var accentBright:  Color { Color(hex: 0xD4FF3F) }
    var accentBrightDim: Color { Color(hex: 0xD4FF3F).opacity(0.18) }

    // ── Category / content-type tints (per spec §5.1) ──────────
    //
    // These mirror the spec's category colour dots. They're exposed on
    // `LumaPalette` rather than on `ContentType` so that views always
    // pull tone-correct values for the active scheme — `ContentType.color`
    // remains the canonical icon-tint for the existing classifier flow.
    var accentWarm:    Color { Color(hex: 0xFF6B3D) }   // links
    var accentBlue:    Color { Color(hex: 0x4D6BB8) }   // email
    var accentPink:    Color { Color(hex: 0xD96AA1) }   // text
    var accentYellow:  Color { Color(hex: 0xE8B730) }   // notes
    var accentMint:    Color { Color(hex: 0x2EB872) }   // code, sync-online
    var accentPurple:  Color { Color(hex: 0x9966CC) }   // screenshots / images

    // ── Focus / dark card pivot ────────────────────────────────
    //
    // The focused list row and the primary CTA both render against a
    // near-black ink card regardless of scheme — the lime + paper-text
    // contrast is what gives the design its editorial bite. These two
    // tokens are the depth pair used by both surfaces.
    var focusInk:    Color { Color(hex: 0x1A1A18) }
    var focusInk2:   Color { Color(hex: 0x2A2A26) }
    var focusPaper:  Color { Color(hex: 0xF5F2EA) }     // ink-on-dark text

    // ── AI / Smart feature tint ────────────────────────────────
    //
    // The Inspector's "AI summary" card uses a warm-cream wash with a
    // lime spotlight, not the old purple/violet. These tokens drive that
    // card and any other AI affordance.
    var aiAccent:   Color { dark ? Color(hex: 0xC8E8A0) : Color(hex: 0x1F3A2E) }
    var aiDim:      Color { dark ? Color(hex: 0xA8D480).opacity(0.10) : Color(hex: 0xF8F5EC) }

    // ── Semantic ───────────────────────────────────────────────
    var success:    Color { Color(hex: 0x2EB872) }
    var warning:    Color { Color(hex: 0xE8B730) }
    var danger:     Color { Color(hex: 0xD64545) }
    var dangerDim:  Color { Color(hex: 0xD64545).opacity(0.12) }

    // ── Glass fill (for GlassInset) ────────────────────────────
    var glassFill:  Color { dark ? Color.black.opacity(0.20) : Color.white.opacity(0.70) }

    // ── Search bar ─────────────────────────────────────────────
    var searchBg:   Color { dark ? Color.white.opacity(0.06) : Color(hex: 0xFAF8F4) }

    // ── Divider ────────────────────────────────────────────────
    var divider:    Color { dark ? Color.white.opacity(0.08) : Color(hex: 0xE8E4DC) }

    // ── Window tint (for NSVisualEffectView overlay) ───────────
    //
    // We tint warmer than pure white/black to match the paper-cream
    // identity. The NSVisualEffectView material itself still does the
    // blur — this just biases the post-blur colour cast.
    var windowTintColor: NSColor {
        dark
            ? NSColor(red: 0.10, green: 0.10, blue: 0.09, alpha: 0.60)
            : NSColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 0.60)
    }
}

// MARK: - Environment Key

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = LumaPalette(scheme: .dark)
}

extension EnvironmentValues {
    var lumaPalette: LumaPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// Inject the palette from any view that has colorScheme
extension View {
    func lumaPaletteEnvironment(scheme: ColorScheme) -> some View {
        environment(\.lumaPalette, LumaPalette(scheme: scheme))
    }
}

// MARK: - GlassInsetModifier (upgraded)

struct GlassInsetModifier: ViewModifier {
    let colorScheme: ColorScheme
    var wellColor: Color? = nil
    var cornerRadius: CGFloat = 22
    var borderWidth: CGFloat = 0.5

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color.black.opacity(0.06),
                        lineWidth: borderWidth
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fillColor: Color {
        if colorScheme == .dark { return Color.black.opacity(0.20) }
        return wellColor ?? Color.white.opacity(0.70)
    }
}

// MARK: - Premium Button Style

struct LumaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.lumaPalette) private var palette
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumaDesign.Typography.body(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, LumaDesign.Space.md)
            .padding(.vertical, LumaDesign.Space.px6)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(palette.accent)
                    .shadow(color: palette.accent.opacity(0.20), radius: 3, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.01 : 1.0))
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(LumaDesign.Motion.instant, value: configuration.isPressed)
            .animation(LumaDesign.Motion.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

struct LumaSecondaryButtonStyle: ButtonStyle {
    @Environment(\.lumaPalette) private var palette
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumaDesign.Typography.body(.medium))
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, LumaDesign.Space.md)
            .padding(.vertical, LumaDesign.Space.px6)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.md, style: .continuous)
                    .fill(isHovered
                          ? palette.hoverBg
                          : palette.borderSubtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.md)
                            .stroke(palette.borderDefault, lineWidth: 0.5)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(LumaDesign.Motion.instant, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Keyboard Shortcut Badge

struct KeyboardShortcutBadge: View {
    let keys: String
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Text(keys)
            .font(.system(size: LumaDesign.Typography.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.xs, style: .continuous)
                    .fill(palette.borderSubtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.xs)
                            .stroke(palette.borderDefault, lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Content Type Badge

struct ContentTypeBadge: View {
    let type: ContentType
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: type.iconName)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            if !compact {
                Text(type.label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.2)
            }
        }
        .foregroundStyle(type.color)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule()
                .fill(type.color.opacity(scheme == .dark ? 0.14 : 0.10))
        )
    }
}

// MARK: - Section Header Label

struct LumaSectionHeader: View {
    let title: String
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: LumaDesign.Typography.caption, weight: .semibold))
            .foregroundStyle(palette.textQuaternary)
            .tracking(0.8)
    }
}

// MARK: - Animated Separator

struct LumaDivider: View {
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.borderSubtle)
            .frame(height: 0.5)
    }
}

// MARK: - Pulse Effect

struct PulseEffect: ViewModifier {
    let isActive: Bool
    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: isActive) { newValue in
                guard newValue else { return }
                withAnimation(.easeInOut(duration: 0.15)) { scale = 1.08 }
                withAnimation(.easeInOut(duration: 0.15).delay(0.15)) { scale = 1.0 }
            }
    }
}

extension View {
    func pulseEffect(isActive: Bool) -> some View {
        modifier(PulseEffect(isActive: isActive))
    }
}

// MARK: - Conditional Modifier

extension View {
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - HoverEffect (legacy compat)

struct HoverEffect: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? 0.04 : 0)
            .animation(LumaDesign.Motion.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func subtleHover() -> some View { modifier(HoverEffect()) }
    func glassBackground(cornerRadius: CGFloat = LumaDesign.Radius.md) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - GlassBackground (legacy compat)

struct GlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = LumaDesign.Radius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(scheme == .dark
                          ? Color.black.opacity(0.22)
                          : Color.white.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                scheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.06),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 1)
            )
    }
}

// MARK: - Premium Status Indicator

struct StatusDot: View {
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(Color(hex: 0x34D399).opacity(pulse ? 0 : 0.30))
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulse ? 1.6 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                            pulse = true
                        }
                    }
            }
            Circle()
                .fill(isActive ? Color(hex: 0x34D399) : Color(hex: 0xF59E0B))
                .frame(width: 6, height: 6)
        }
    }
}
