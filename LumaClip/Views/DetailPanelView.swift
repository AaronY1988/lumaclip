// DetailPanelView.swift
// LumaClip - macOS Clipboard Manager
//
// Right column: full content preview with metadata display
// and action buttons (copy, favorite, pin, category, expiry,
// delete/restore). Content-aware rendering for URLs, colors,
// code, and email types.

import SwiftUI

// MARK: - Detail Panel View

struct DetailPanelView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.colorScheme)  private var colorScheme
    @Environment(\.lumaPalette)  private var palette
    @EnvironmentObject private var settings: AppSettings

    private var isLight: Bool       { colorScheme == .light }

    /// Brief flash when a transform result is copied
    @State private var transformFlashText: String? = nil

    /// "Copied" toast state
    @State private var toastVisible = false
    @State private var toastWork: DispatchWorkItem?

    /// Edit clip sheet
    @State private var showEditSheet = false

    private func showCopyToast() {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            toastVisible = true
        }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                toastVisible = false
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let item = viewModel.selectedItem {
                    selectedItemView(item)
                        .id(item.id)
                        .tint(isLight ? Color(hex: 0x007AFF) : nil)
                } else {
                    noSelectionView
                }
            }

            // ── Copy toast overlay ───────────────────────────
            if toastVisible {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("Copied".loc)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                )
                .padding(.bottom, 14)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let item = viewModel.selectedItem {
                ClipEditorSheet(item: item, viewModel: viewModel)
            }
        }
    }

    // MARK: - No Selection

    private var noSelectionView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(palette.borderSubtle)
                        .frame(width: 60, height: 60)
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(palette.textTertiary)
                }
                VStack(spacing: 5) {
                    Text("No clip selected".loc)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text("Click a clip to preview its contents".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Selected Item

    @ViewBuilder
    private func selectedItemView(_ item: ClipboardItem) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {

                // ── Editorial header (per spec §5.4) ────────────────
                //
                // Mono eyebrow → serif title → chip row (type · source ·
                // time). Replaces the old "type pill / char count" line
                // with a deeper layout that reads like a magazine deck:
                // small eyebrow on top, big title under it, mid-weight
                // metadata under that.
                inspectorHeader(for: item)

                // ── Quick Transform Bar ────────────────────────────
                TransformBarView(item: item) { resultText in
                    transformFlashText = resultText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        transformFlashText = nil
                    }
                }

                // Transform result flash banner
                if let flash = transformFlashText {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text(flash)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.green.opacity(0.2), lineWidth: 1))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Content-aware preview
                contentPreview(for: item)

                // Metadata section
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("DETAILS".loc)
                            .font(LumaDesign.Typography.mono(9, weight: .bold))
                            .foregroundStyle(palette.textTertiary)
                            .tracking(1.6)
                        Spacer()
                    }
                    .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        MetadataRow(label: "Copied".loc, value: formattedDate(item.createdAt))
                        MetadataRow(label: "Source".loc, value: item.sourceApp.isEmpty ? "Unknown" : item.sourceApp)
                        if let expiresAt = item.expiresAt {
                            MetadataRow(
                                label: "Expires".loc,
                                value: formattedDate(expiresAt),
                                valueColor: expiresAt < Date() ? palette.danger : palette.textSecondary
                            )
                        }
                        if let category = viewModel.category(for: item) {
                            MetadataRow(
                                label: "Category".loc,
                                value: category.name,
                                valueColor: category.color.color
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .fill(palette.borderSubtle.opacity(0.5))
                    )
                }

                Rectangle()
                    .fill(palette.borderSubtle)
                    .frame(height: 0.5)

                // Actions
                actionButtons(for: item)
            }
            .padding(16)
        }
    }

    // MARK: - Inspector Header
    //
    // Three-line header per spec §5.4:
    //   1. mono eyebrow — "INSPECTOR / Preview"
    //   2. big serif title — `item.title` (already type-aware via
    //      `ClipboardItem.title`, which produces a sensible string for
    //      every content type — domains for URLs, hex for colours, etc.)
    //   3. chip row — type label, source app, relative time. Uses the
    //      same accent palette the new sidebar/list use, so the
    //      Inspector reads as a continuation of the same surface.
    //
    // Pulls all values from existing `ClipboardItem` accessors — no new
    // fields, no new computation, just a different visual arrangement.
    @ViewBuilder
    private func inspectorHeader(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Eyebrow
            HStack(spacing: 6) {
                Text("INSPECTOR".loc)
                    .font(LumaDesign.Typography.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(palette.textTertiary)
                Text("·".loc)
                    .font(LumaDesign.Typography.mono(9, weight: .bold))
                    .foregroundStyle(palette.textQuaternary)
                Text("Preview".loc)
                    .font(LumaDesign.Typography.serifItalic(13))
                    .foregroundStyle(palette.textSecondary)
            }

            // Big serif title — line height tuned so the descender of a
            // serif italic doesn't crash into the chip row below.
            Text(item.title)
                .font(LumaDesign.Typography.serif(22))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            // Chip row: type · source · time
            HStack(spacing: 6) {
                inspectorChip(
                    label: item.contentType.label.uppercased(),
                    style: .filled(item.contentType.color)
                )
                if !item.sourceApp.isEmpty {
                    inspectorChip(
                        label: item.sourceApp,
                        style: .outline
                    )
                }
                inspectorChip(
                    label: item.relativeTime,
                    style: .ink
                )
                Spacer()
                Text(item.characterCount)
                    .font(LumaDesign.Typography.mono(10, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    /// Visual treatments shared across the three header chips. Defined
    /// inline (not exported) because they're specific to the Inspector's
    /// metadata strip — different surfaces (lists, sidebar) need their
    /// own, slightly different chip styles.
    private enum InspectorChipStyle {
        case filled(Color)   // type chip — tinted background, ink text
        case outline         // source chip — paper card with hairline
        case ink             // time chip — ink slab with paper text
    }

    @ViewBuilder
    private func inspectorChip(label: String, style: InspectorChipStyle) -> some View {
        let baseFont = LumaDesign.Typography.mono(9, weight: .bold)

        switch style {
        case .filled(let tint):
            Text(label)
                .font(baseFont)
                .tracking(0.6)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.16))
                )

        case .outline:
            Text(label)
                .font(LumaDesign.Typography.sans(10, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.cardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                        )
                )

        case .ink:
            Text(label)
                .font(LumaDesign.Typography.sans(10, weight: .semibold))
                .foregroundStyle(palette.focusPaper)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.focusInk)
                )
        }
    }

    // MARK: - Content-Aware Preview

    @ViewBuilder
    private func contentPreview(for item: ClipboardItem) -> some View {
        switch item.contentType {
        case .image:
            imagePreview(item)
        case .color:
            colorPreview(item.content)
        case .url:
            urlPreview(item.content)
        case .email:
            emailPreview(item.content)
        case .code:
            codePreview(item.content)
        case .file:
            filePreview(item)
        default:
            standardTextPreview(item.content)
        }
    }

    // MARK: - File Preview

    @ViewBuilder
    private func filePreview(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("\(item.fileCount) " + (item.fileCount == 1 ? "File".loc : "Files".loc))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.characterCount)   // total size for file clips
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(item.fileEntries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 10) {
                    Image(systemName: fileSymbol(for: entry.name))
                        .font(.system(size: 16))
                        .foregroundStyle(ContentType.file.color)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(entry.sizeString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.stored ? "Saved".loc : "Linked".loc)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        (entry.stored ? Color.green : Color.orange).opacity(0.16)
                                    )
                                )
                                .foregroundStyle(entry.stored ? Color.green : Color.orange)
                        }
                    }

                    Spacer()

                    if FileVaultService.shared.resolveURL(for: entry) != nil {
                        Button {
                            revealInFinder(entry)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder".loc)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.04))
                )
            }

            if !item.hasStoredFiles {
                Text("These files are linked to their original location. If the originals move or are deleted, they can no longer be pasted.".loc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    /// SF Symbol for a filename based on its extension.
    private func fileSymbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "": return "folder.fill"
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            return "photo.fill"
        case "mp4", "mov", "avi", "mkv", "m4v": return "film.fill"
        case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx", "csv": return "tablecells.fill"
        case "ppt", "pptx": return "rectangle.on.rectangle.fill"
        case "swift", "py", "js", "ts", "java", "c", "cpp", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    /// Reveal an entry's resolved file (vault copy or original) in Finder.
    private func revealInFinder(_ entry: FileEntry) {
        guard let url = FileVaultService.shared.resolveURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Image Preview

    @ViewBuilder
    private func imagePreview(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full image scaled to fit panel width
            if let nsImg = item.nsImage {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            } else {
                // Fallback if data can't render
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Unable to render image".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.primary.opacity(0.04))
                )
            }

            // Image metadata
            VStack(alignment: .leading, spacing: 6) {
                if let dims = item.imageDimensions {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(dims.width) × \(dims.height) px".loc)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }

                if let data = item.imageData {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("· JPEG".loc)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Color Preview

    @ViewBuilder
    private func colorPreview(_ content: String) -> some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = parseColor(from: trimmed)

        VStack(alignment: .leading, spacing: 10) {
            Text("Color Preview".loc)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // Large swatch
            ZStack {
                if let color = color {
                    Color(nsColor: color)
                } else {
                    Color.gray.opacity(0.3)
                    Text("Cannot parse color".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: color.map { Color(nsColor: $0).opacity(0.3) } ?? .clear, radius: 8, x: 0, y: 4)

            // Hex value + parsed components
            if let color = color {
                HStack(spacing: 12) {
                    // Hex
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HEX".loc)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(normalizeHex(trimmed))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    Divider().frame(height: 28)

                    // RGB
                    let rgb = extractRGB(from: color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RGB".loc)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("\(rgb.r), \(rgb.g), \(rgb.b)".loc)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.primary.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.primary.opacity(0.06), lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - URL Preview

    @ViewBuilder
    private func urlPreview(_ content: String) -> some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = extractDomain(from: trimmed)
        let parts = splitURL(trimmed)

        // Editorial URL card per spec §5.4 — single bordered card, mono
        // URL with the protocol greyed and the domain in `accentWarm`,
        // followed by a derived-facts strip (domain · length).
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("URL".loc)
                    .font(LumaDesign.Typography.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(palette.textTertiary)
                Spacer()
                Button {
                    if let url = URL(string: trimmed) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("OPEN".loc)
                            .font(LumaDesign.Typography.mono(9, weight: .bold))
                            .tracking(1.0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(palette.accentWarm)
                }
                .buttonStyle(.plain)
                .help("Open in browser".loc)
            }

            // Mono URL: protocol (quiet) + domain (warm) + path (mid).
            // Wrapping with `Text` concatenation lets the three slices
            // share a single line-wrap rule rather than fighting layout
            // as separate views.
            (
                Text(parts.scheme).foregroundColor(palette.textQuaternary) +
                Text(parts.domain).foregroundColor(palette.accentWarm).fontWeight(.semibold) +
                Text(parts.rest).foregroundColor(palette.textSecondary)
            )
            .font(LumaDesign.Typography.mono(11, weight: .regular))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(3)
            .truncationMode(.middle)

            // 2x2 facts grid — derived locally, no requests.
            HStack(spacing: 12) {
                urlFact(label: "DOMAIN".loc, value: domain)
                urlFact(label: "LENGTH".loc, value: "\(trimmed.count)")
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                .fill(palette.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                        .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                )
        )
    }

    /// Single derived-fact cell used in the URL meta card. Mono
    /// uppercase label above, mid-weight value below.
    @ViewBuilder
    private func urlFact(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(LumaDesign.Typography.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .font(LumaDesign.Typography.sans(11, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Locally splits a URL string into `scheme://`, `domain`, `path…`
    /// for the tri-coloured mono display in the URL preview card.
    /// Falls back gracefully when the input isn't a parseable URL.
    private func splitURL(_ s: String) -> (scheme: String, domain: String, rest: String) {
        guard let url = URL(string: s),
              let host = url.host else {
            return ("", s, "")
        }
        let scheme = url.scheme.map { "\($0)://" } ?? ""
        let prefix = "\(scheme)\(host)"
        let rest = String(s.dropFirst(prefix.count))
        return (scheme, host, rest)
    }

    // MARK: - Email Preview

    @ViewBuilder
    private func emailPreview(_ content: String) -> some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        let username = parts.first ?? trimmed
        let domain = parts.count > 1 ? parts[1] : ""

        VStack(alignment: .leading, spacing: 10) {
            Text("Email Address".loc)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // Email card
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    // Single full address line. Was previously two lines
                    // (truncated address + redundant "Domain: …" subtitle).
                    // The subtitle existed only to recover information lost
                    // to single-line truncation; allowing the address itself
                    // to wrap to two lines accomplishes the same thing
                    // without repeating the domain twice on short addresses.
                    HStack(spacing: 0) {
                        Text(username)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !domain.isEmpty {
                            Text("@".loc)
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                            Text(domain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tint)
                        }
                    }
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Compose button
                Button {
                    composeEmail(to: trimmed)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Compose email (falls back to copying address)".loc)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.primary.opacity(0.06), lineWidth: 1)
                    )
            )
        }
    }

    /// Open the user's default mail client composing to `address`.
    /// Falls back to copying the address to the clipboard if no mailto handler
    /// is installed (or `NSWorkspace.open` reports failure for any reason).
    private func composeEmail(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Percent-encode the local part / domain in case of unusual characters.
        // `urlPathAllowed` keeps `@`, `.`, and most address-safe chars intact.
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed

        if let url = URL(string: "mailto:\(encoded)"),
           NSWorkspace.shared.open(url) {
            return
        }

        // Fallback: no default mail handler — copy the address so the user
        // can paste it into whatever they actually use.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
    }

    // MARK: - Code Preview

    @ViewBuilder
    private func codePreview(_ content: String) -> some View {
        let language = detectLanguage(from: content)
        let truncated = content.count > 5000 ? String(content.prefix(5000)) + "\n…(truncated)" : content

        VStack(alignment: .leading, spacing: 6) {
            // Header row with language badge
            HStack {
                Text("Content".loc)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let lang = language {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 8))
                        Text(lang)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                    )
                }
            }

            ScrollView {
                Text(truncated)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.windowBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Standard Text Preview

    @ViewBuilder
    private func standardTextPreview(_ content: String) -> some View {
        let truncated = content.count > 5000 ? String(content.prefix(5000)) + "\n…(truncated)" : content

        VStack(alignment: .leading, spacing: 0) {
            Text("Content".loc)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.textQuaternary)
                .tracking(0.8)
                .textCase(.uppercase)
                .padding(.bottom, 8)

            ScrollView {
                Text(truncated)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .fill(palette.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .stroke(palette.borderDefault, lineWidth: 0.5)
                    )
            )
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for item: ClipboardItem) -> some View {
        VStack(spacing: 6) {
            // Primary: Copy & Edit row
            //
            // Spec §5.4: "Copy & paste" is the focal action — ink slab
            // with lime label, weight 2/3 of the row. Edit sits beside
            // it as a secondary glyph button. Click handler is unchanged
            // (still `viewModel.copyItem`); only the visual is editorial.
            HStack(spacing: 8) {
                Button {
                    viewModel.copyItem(item)
                    showCopyToast()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy & paste".loc)
                            .font(LumaDesign.Typography.sans(12, weight: .semibold))
                    }
                    .foregroundStyle(palette.accentBright)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .fill(palette.focusInk)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                if item.contentType != .image && item.contentType != .file {
                    Button {
                        showEditSheet = true
                    } label: {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                    .fill(palette.cardBg)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                                            .strokeBorder(palette.borderDefault, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Edit content".loc)
                }
            }

            // Toggle actions row
            HStack(spacing: 8) {
                ActionButton(
                    icon: item.isFavorite ? "star.fill" : "star",
                    label: item.isFavorite ? "Unfav" : "Favorite",
                    tint: .yellow,
                    isActive: item.isFavorite
                ) {
                    viewModel.toggleFavorite(item)
                }

                ActionButton(
                    icon: item.isPinned ? "pin.fill" : "pin",
                    label: item.isPinned ? "Unpin" : "Pin",
                    tint: .orange,
                    isActive: item.isPinned
                ) {
                    viewModel.togglePin(item)
                }
            }

            // Category & Expiry pickers (side by side)
            HStack(spacing: 8) {
                if !viewModel.categories.isEmpty {
                    Menu {
                        Button("None".loc) {
                            viewModel.setCategory(item, categoryId: nil)
                        }
                        Divider()
                        ForEach(viewModel.categories) { cat in
                            Button {
                                viewModel.setCategory(item, categoryId: cat.id)
                            } label: {
                                Label(cat.name, systemImage: cat.icon)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "tag")
                                .font(.system(size: 11))
                            Text("Category".loc)
                                .font(.system(size: 12))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.primary.opacity(0.04))
                        )
                    }
                    .menuStyle(.borderlessButton)
                }

                Menu {
                    Button("No Expiry".loc) {
                        viewModel.setExpiry(item, expiresAt: nil)
                    }
                    Divider()
                    ForEach(RetentionRule.presetDurations, id: \.1) { label, duration in
                        if duration > 0 {
                            Button(label) {
                                viewModel.setExpiry(
                                    item,
                                    expiresAt: Date().addingTimeInterval(duration)
                                )
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                        Text("Expiry".loc)
                            .font(.system(size: 12))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                        }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.primary.opacity(0.04))
                    )
                }
                .menuStyle(.borderlessButton)
            }

            Divider().opacity(0.15)

            // Delete / Restore (uses animated wrappers so list rows animate)
            if item.isDeleted {
                HStack(spacing: 8) {
                    Button {
                        viewModel.animateRestore(item)
                    } label: {
                        Label("Restore".loc, systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.animatePermanentDelete(item)
                    } label: {
                        Label("Delete".loc, systemImage: "trash")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button(role: .destructive) {
                    viewModel.animateDelete(item)
                } label: {
                    Label("Move to Trash".loc, systemImage: "trash")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    /// Parse #RGB or #RRGGBB hex string → NSColor
    private func parseColor(from string: String) -> NSColor? {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private func normalizeHex(_ string: String) -> String {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !hex.hasPrefix("#") { hex = "#" + hex }
        if hex.count == 4 { // #RGB → #RRGGBB
            let chars = Array(hex.dropFirst())
            hex = "#" + chars.map { "\($0)\($0)" }.joined()
        }
        return hex
    }

    private func extractRGB(from color: NSColor) -> (r: Int, g: Int, b: Int) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255))
        )
    }

    /// Extract domain from a URL string
    private func extractDomain(from urlString: String) -> String {
        if let url = URL(string: urlString), let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        // Fallback: naive extraction
        var s = urlString
        for prefix in ["https://", "http://", "ftp://"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return String(s.split(separator: "/").first ?? Substring(s))
    }

    /// Return a relevant emoji for well-known domains, generic globe otherwise
    private func faviconEmoji(for domain: String) -> String {
        let d = domain.lowercased()
        if d.contains("github")    { return "🐙" }
        if d.contains("google")    { return "🔍" }
        if d.contains("youtube")   { return "▶️" }
        if d.contains("twitter") || d.contains("x.com") { return "𝕏" }
        if d.contains("linkedin")  { return "💼" }
        if d.contains("apple")     { return "" }
        if d.contains("amazon")    { return "📦" }
        if d.contains("netflix")   { return "🎬" }
        if d.contains("spotify")   { return "🎵" }
        if d.contains("figma")     { return "🎨" }
        if d.contains("notion")    { return "📝" }
        if d.contains("slack")     { return "💬" }
        if d.contains("reddit")    { return "🤖" }
        if d.contains("wikipedia") { return "📖" }
        if d.contains("stackoverflow") { return "📚" }
        return "🌐"
    }

    /// Heuristic language detection from code content
    private func detectLanguage(from code: String) -> String? {
        let s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Swift
        if s.contains("import SwiftUI") || s.contains("import Foundation") || s.contains("func ") && s.contains(" -> ") && s.contains("{") {
            return "Swift"
        }
        // Python
        if s.hasPrefix("def ") || s.contains("\ndef ") || s.contains("import numpy") || s.contains("print(") || s.hasPrefix("#!/usr/bin/env python") {
            return "Python"
        }
        // JavaScript / TypeScript
        if s.contains("const ") && s.contains("=>") { return "JavaScript" }
        if s.contains("interface ") && s.contains(": string") { return "TypeScript" }
        if s.hasPrefix("function ") || s.contains("console.log") || s.contains("require(") { return "JavaScript" }
        // HTML
        if s.hasPrefix("<!DOCTYPE") || s.hasPrefix("<html") || (s.contains("<div") && s.contains("</div>")) { return "HTML" }
        // CSS
        if s.contains("{") && (s.contains("margin:") || s.contains("padding:") || s.contains("color:") || s.contains("font-size:")) { return "CSS" }
        // JSON
        if (s.hasPrefix("{") || s.hasPrefix("[")) && (s.contains("\":") || s.contains("\": ")) { return "JSON" }
        // SQL
        let upper = s.uppercased()
        if upper.hasPrefix("SELECT ") || upper.hasPrefix("INSERT ") || upper.hasPrefix("UPDATE ") || upper.hasPrefix("DELETE ") || upper.hasPrefix("CREATE TABLE") { return "SQL" }
        // Shell
        if s.hasPrefix("#!/bin/bash") || s.hasPrefix("#!/bin/sh") || (s.contains("$") && s.contains("echo ")) { return "Shell" }
        // Kotlin
        if s.contains("fun ") && s.contains(": ") && s.contains("{") && (s.contains("val ") || s.contains("var ")) { return "Kotlin" }
        // Java
        if s.contains("public class ") || s.contains("public static void main") { return "Java" }
        // Go
        if s.hasPrefix("package ") || (s.contains("func ") && s.contains("(") && !s.contains("->")) { return "Go" }
        // Rust
        if s.contains("fn ") && s.contains("let mut ") { return "Rust" }
        // Ruby
        if s.contains("def ") && s.contains("end") && !s.contains("{") { return "Ruby" }
        // YAML
        if s.contains(":\n") || s.contains(": |") || s.hasPrefix("---") { return "YAML" }
        // Markdown
        if s.hasPrefix("# ") || s.contains("\n## ") || (s.contains("**") && s.contains("```")) { return "Markdown" }

        return nil
    }
}

// MARK: - Metadata Row

struct MetadataRow: View {
    let label:      String
    let value:      String
    var valueColor: Color = .secondary
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(valueColor == .secondary ? palette.textSecondary : valueColor)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let icon:     String
    let label:    String
    let tint:     Color
    let isActive: Bool
    let action:   () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.lumaPalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(
                isActive
                    ? tint
                    : (isHovered ? palette.textPrimary : palette.textSecondary)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                    .fill(
                        isActive
                            ? tint.opacity(0.14)
                            : (isHovered
                               ? palette.hoverBg
                               : palette.borderSubtle.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaDesign.Radius.lg, style: .continuous)
                            .strokeBorder(
                                isActive
                                    ? tint.opacity(0.30)
                                    : palette.borderDefault.opacity(0.7),
                                lineWidth: 0.5
                            )
                    )
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(LumaDesign.Motion.quick, value: isActive)
        .animation(LumaDesign.Motion.quick, value: isHovered)
        .animation(LumaDesign.Motion.instant, value: isPressed)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(LumaDesign.Motion.instant) { isPressed = true }  }
                .onEnded   { _ in withAnimation(LumaDesign.Motion.instant) { isPressed = false } }
        )
    }
}

// MARK: - Quick Transform Bar

/// A horizontal scroll strip of one-tap transformations contextual to clip type.
/// Tapping a button applies the transform, copies the result to the system clipboard,
/// and fires `onResult` with a short description for the parent to show as a flash banner.
struct TransformBarView: View {
    let item: ClipboardItem
    let onResult: (String) -> Void

    var body: some View {
        let transforms = buildTransforms(for: item)
        if transforms.isEmpty { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 5) {
                Text("Quick Transforms".loc)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(transforms, id: \.label) { t in
                            TransformChip(label: t.label, icon: t.icon) {
                                let (copied, message) = t.apply(item.content)
                                if let text = copied {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(text, forType: .string)
                                }
                                onResult(message)
                            }
                        }
                    }
                }
            }
        )
    }

    // MARK: - Transform Definitions

    private struct TransformDef {
        let label: String
        let icon: String
        /// Returns (text to copy or nil if display-only, message to flash)
        let apply: (String) -> (String?, String)
    }

    private func buildTransforms(for item: ClipboardItem) -> [TransformDef] {
        switch item.contentType {

        case .text, .unknown:
            return [
                TransformDef(label: "UPPER".loc, icon: "textformat") { s in
                    let r = s.uppercased(); return (r, "Copied: \(r.prefix(30))")
                },
                TransformDef(label: "lower".loc, icon: "textformat") { s in
                    let r = s.lowercased(); return (r, "Copied: \(r.prefix(30))")
                },
                TransformDef(label: "Title Case".loc, icon: "textformat.abc") { s in
                    let r = s.capitalized; return (r, "Copied: \(r.prefix(30))")
                },
                TransformDef(label: "Trim".loc, icon: "scissors") { s in
                    let r = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (r, "Trimmed whitespace → copied")
                },
                TransformDef(label: "Word Count".loc, icon: "number") { s in
                    let wc = s.split(whereSeparator: { $0.isWhitespace }).count
                    let lc = s.components(separatedBy: "\n").count
                    return (nil, "\(wc) words, \(lc) lines")
                },
                TransformDef(label: "URL Encode".loc, icon: "link") { s in
                    let r = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
                    return (r, "URL-encoded → copied")
                },
                TransformDef(label: "URL Decode".loc, icon: "arrow.uturn.backward") { s in
                    let r = s.removingPercentEncoding ?? s
                    return (r, "URL-decoded → copied")
                },
                TransformDef(label: "Base64 Enc".loc, icon: "lock.doc") { s in
                    let r = Data(s.utf8).base64EncodedString()
                    return (r, "Base64-encoded → copied")
                },
                TransformDef(label: "Base64 Dec".loc, icon: "lock.open") { s in
                    if let d = Data(base64Encoded: s), let r = String(data: d, encoding: .utf8) {
                        return (r, "Base64-decoded → copied")
                    }
                    return (nil, "Not valid Base64")
                },
                TransformDef(label: "Remove Breaks".loc, icon: "arrow.left.and.right") { s in
                    let r = s.components(separatedBy: .newlines).joined(separator: " ")
                    return (r, "Line breaks removed → copied")
                },
            ]

        case .url:
            return [
                TransformDef(label: "Open".loc, icon: "arrow.up.right.square") { s in
                    if let url = URL(string: s) { NSWorkspace.shared.open(url) }
                    return (nil, "Opened in browser")
                },
                TransformDef(label: "Copy Domain".loc, icon: "globe") { s in
                    let domain = extractDomain(from: s)
                    return (domain, "Domain copied: \(domain)")
                },
                TransformDef(label: "URL Encode".loc, icon: "link") { s in
                    let r = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
                    return (r, "Encoded URL → copied")
                },
                TransformDef(label: "URL Decode".loc, icon: "arrow.left.arrow.right") { s in
                    let r = s.removingPercentEncoding ?? s
                    return (r, "Decoded URL → copied")
                },
                TransformDef(label: "Strip Params".loc, icon: "xmark.seal") { s in
                    if let url = URL(string: s),
                       var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        comps.query = nil
                        comps.fragment = nil
                        let r = comps.string ?? s
                        return (r, "Query params stripped → copied")
                    }
                    return (s, "Could not parse URL")
                },
                TransformDef(label: "Scheme Only".loc, icon: "arrow.up.left") { s in
                    if let url = URL(string: s), let scheme = url.scheme {
                        return (scheme, "Scheme: \(scheme)")
                    }
                    return (nil, "No scheme found")
                },
            ]

        case .email:
            return [
                TransformDef(label: "Compose".loc, icon: "square.and.pencil") { s in
                    if let url = URL(string: "mailto:\(s)") { NSWorkspace.shared.open(url) }
                    return (nil, "Mail app opened")
                },
                TransformDef(label: "Copy Username".loc, icon: "person") { s in
                    let username = s.components(separatedBy: "@").first ?? s
                    return (username, "Username copied: \(username)")
                },
                TransformDef(label: "Copy Domain".loc, icon: "globe") { s in
                    let domain = s.components(separatedBy: "@").last ?? s
                    return (domain, "Domain copied: \(domain)")
                },
                TransformDef(label: "UPPER".loc, icon: "textformat") { s in
                    let r = s.uppercased(); return (r, "Copied: \(r)")
                },
                TransformDef(label: "lower".loc, icon: "textformat") { s in
                    let r = s.lowercased(); return (r, "Copied: \(r)")
                },
            ]

        case .phone:
            return [
                TransformDef(label: "Dial".loc, icon: "phone") { s in
                    let digits = s.filter { $0.isNumber || $0 == "+" }
                    if let url = URL(string: "tel:\(digits)") { NSWorkspace.shared.open(url) }
                    return (nil, "Dialing \(digits)")
                },
                TransformDef(label: "Digits Only".loc, icon: "number") { s in
                    let r = String(s.filter { $0.isNumber })
                    return (r, "Digits copied: \(r)")
                },
                TransformDef(label: "Dashes".loc, icon: "minus") { s in
                    let d = s.filter { $0.isNumber }
                    let r = formatPhoneDashes(d)
                    return (r, "Formatted: \(r)")
                },
                TransformDef(label: "Dots".loc, icon: "circle.fill") { s in
                    let d = s.filter { $0.isNumber }
                    let r = formatPhoneDots(d)
                    return (r, "Formatted: \(r)")
                },
                TransformDef(label: "Intl (+1)".loc, icon: "phone.arrow.up.right") { s in
                    let d = s.filter { $0.isNumber }
                    let r = "+1 \(formatPhoneDashes(d))"
                    return (r, "International: \(r)")
                },
            ]

        case .color:
            return [
                TransformDef(label: "Copy RGB".loc, icon: "eyedropper") { s in
                    if let c = parseNSColor(from: s) {
                        let srgb = c.usingColorSpace(.sRGB) ?? c
                        let r = "rgb(\(Int(srgb.redComponent*255)), \(Int(srgb.greenComponent*255)), \(Int(srgb.blueComponent*255)))"
                        return (r, "RGB copied: \(r)")
                    }
                    return (nil, "Cannot parse color")
                },
                TransformDef(label: "Copy HSL".loc, icon: "dial.low") { s in
                    if let c = parseNSColor(from: s) {
                        let hsl = nsColorToHSL(c)
                        let r = "hsl(\(hsl.h)°, \(hsl.s)%, \(hsl.l)%)"
                        return (r, "HSL copied: \(r)")
                    }
                    return (nil, "Cannot parse color")
                },
                TransformDef(label: "Normalize".loc, icon: "textformat.size") { s in
                    let r = normalizeHexColor(s)
                    return (r, "Normalized: \(r)")
                },
                TransformDef(label: "No #".loc, icon: "number") { s in
                    let r = normalizeHexColor(s).replacingOccurrences(of: "#", with: "")
                    return (r, "No-hash copied: \(r)")
                },
                TransformDef(label: "Invert".loc, icon: "arrow.left.arrow.right") { s in
                    if let c = parseNSColor(from: s),
                       let srgb = c.usingColorSpace(.sRGB) {
                        let ri = Int((1 - srgb.redComponent) * 255)
                        let gi = Int((1 - srgb.greenComponent) * 255)
                        let bi = Int((1 - srgb.blueComponent) * 255)
                        let r = String(format: "#%02X%02X%02X", ri, gi, bi)
                        return (r, "Inverted: \(r)")
                    }
                    return (nil, "Cannot parse color")
                },
            ]

        case .code:
            return [
                TransformDef(label: "Format JSON".loc, icon: "chevron.left.forwardslash.chevron.right") { s in
                    if let data = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data),
                       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
                       let r = String(data: pretty, encoding: .utf8) {
                        return (r, "JSON formatted → copied")
                    }
                    return (nil, "Not valid JSON")
                },
                TransformDef(label: "Minify JSON".loc, icon: "arrow.down.right.and.arrow.up.left") { s in
                    if let data = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data),
                       let minData = try? JSONSerialization.data(withJSONObject: obj, options: []),
                       let r = String(data: minData, encoding: .utf8) {
                        return (r, "JSON minified → copied")
                    }
                    return (nil, "Not valid JSON")
                },
                TransformDef(label: "Line Count".loc, icon: "list.number") { s in
                    let count = s.components(separatedBy: "\n").count
                    return (nil, "\(count) lines")
                },
                TransformDef(label: "Remove Comments".loc, icon: "bubble.left.and.exclamationmark.bubble.right") { s in
                    // Strip single-line // and /* */ comments (best-effort)
                    var r = s.replacingOccurrences(of: "\\/\\/[^\n]*", with: "", options: .regularExpression)
                    r = r.replacingOccurrences(of: "\\/\\*[\\s\\S]*?\\*\\/", with: "", options: .regularExpression)
                    return (r, "Comments stripped → copied")
                },
                TransformDef(label: "UPPER".loc, icon: "textformat") { s in
                    return (s.uppercased(), "Uppercased → copied")
                },
            ]

        default:
            return []
        }
    }

    // MARK: - Transform Helpers

    private func extractDomain(from urlString: String) -> String {
        if let url = URL(string: urlString), let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        var s = urlString
        for pfx in ["https://", "http://"] { if s.hasPrefix(pfx) { s = String(s.dropFirst(pfx.count)); break } }
        return String(s.split(separator: "/").first ?? Substring(s))
    }

    private func parseNSColor(from s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private func normalizeHexColor(_ s: String) -> String {
        var hex = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !hex.hasPrefix("#") { hex = "#" + hex }
        if hex.count == 4 { hex = "#" + Array(hex.dropFirst()).map { "\($0)\($0)" }.joined() }
        return hex
    }

    private func nsColorToHSL(_ color: NSColor) -> (h: Int, s: Int, l: Int) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        var h: CGFloat = 0, s: CGFloat = 0
        if maxV != minV {
            let d = maxV - minV
            s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
            switch maxV {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        return (Int(h * 360), Int(s * 100), Int(l * 100))
    }

    private func formatPhoneDashes(_ digits: String) -> String {
        let d = Array(digits)
        if d.count == 10 {
            return "\(String(d[0..<3]))-\(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        return digits
    }

    private func formatPhoneDots(_ digits: String) -> String {
        let d = Array(digits)
        if d.count == 10 {
            return "\(String(d[0..<3])).\(String(d[3..<6])).\(String(d[6..<10]))"
        }
        return digits
    }
}

// MARK: - Transform Chip Button

private struct TransformChip: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isHovered ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered
                          ? Color.accentColor.opacity(0.12)
                          : .primary.opacity(0.05))
                    .overlay(Capsule()
                        .stroke(isHovered
                                ? Color.accentColor.opacity(0.3)
                                : .primary.opacity(0.07),
                                lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

// MARK: - Clip Editor Sheet

struct ClipEditorSheet: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editedContent: String = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Edit Clip".loc)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(item.contentType.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            // Text editor
            TextEditor(text: $editedContent)
                .font(.system(size: 12, design: item.contentType == .code ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .focused($editorFocused)
                .frame(minHeight: 150, maxHeight: 300)

            // Character count
            HStack {
                Text("\(editedContent.count) characters".loc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // Action buttons
            HStack {
                Button("Cancel".loc) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                Spacer()

                Button("Save".loc) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            editedContent = item.content
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                editorFocused = true
            }
        }
    }

    private func save() {
        let trimmed = editedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = item
        updated.content = trimmed
        // Re-classify content type based on edited content
        updated.contentType = ContentClassifier.classify(trimmed)
        viewModel.updateItem(updated)
        dismiss()
    }
}
