// ClipboardService.swift
// LumaClip - macOS Clipboard Manager
//
// Monitors NSPasteboard for changes using a polling timer.
// Detects new copied content, classifies its type, checks
// privacy rules, and persists to the database.

import Foundation
import AppKit
import Combine

// MARK: - Clipboard Service

final class ClipboardService: ObservableObject {
    static let shared = ClipboardService()

    // MARK: Published State
    @Published var isMonitoring: Bool = true
    @Published var lastCopiedItem: ClipboardItem?
    @Published var copyCount: Int = 0

    // MARK: Dependencies
    private let database = DatabaseService.shared
    private let settings = AppSettings.shared

    // MARK: Internal State
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0
    private var cancellables = Set<AnyCancellable>()
    private var cachedSourceApp: String = "Unknown"
    private var lastAppCheckTime: Date = .distantPast
    /// The user's explicit monitoring intent (flipped by start/stop/toggle).
    /// Kept distinct from `settings.isTrackingPaused` so that unpausing does
    /// not spuriously restart monitoring after the user has turned it off.
    private var userWantsMonitoring: Bool = true

    /// Polling interval in seconds
    private let pollInterval: TimeInterval = 0.5

    /// How often to refresh the source app name (reduces system queries)
    private let appCheckInterval: TimeInterval = 2.0

    /// Item IDs that should be deleted the next time the pasteboard
    /// changes (burn-after-paste). Using a set instead of a single ID
    /// handles the case where the user copies multiple flagged items in
    /// quick succession before any paste happens. Each entry carries a
    /// timestamp so a fallback timer can clean up clips that never get
    /// followed by another copy.
    private var pendingBurnItems: [UUID: Date] = [:]

    /// Background queue for dedup-hash backfill so startup isn't blocked
    /// by hashing thousands of legacy rows.
    private let backfillQueue = DispatchQueue(label: "com.lumaclip.hashBackfill", qos: .utility)

    /// Maximum wait before burn-after-paste clips are forcibly deleted
    /// even if the user hasn't copied anything else. Keeps a sensitive
    /// token from lingering indefinitely on a quiet clipboard.
    private let burnFallbackTimeout: TimeInterval = 120   // 2 minutes

    // MARK: - Initialization

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        setupSettingsObservers()
        scheduleContentHashBackfill()
        // Sweep vault folders orphaned by bulk deletes in a prior session.
        FileVaultService.shared.garbageCollect()
    }

    // MARK: - Start / Stop

    /// Begin monitoring the system clipboard. Records user intent; the
    /// timer only actually runs when not paused.
    func startMonitoring() {
        userWantsMonitoring = true
        // Honor pause: intent is recorded, but don't start polling until resumed.
        guard !settings.isTrackingPaused else {
            isMonitoring = false
            return
        }
        guard pollTimer == nil else {
            isMonitoring = true
            return
        }

        isMonitoring = true
        lastChangeCount = NSPasteboard.general.changeCount

        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkClipboard()
        }

        // Ensure timer runs even during UI tracking
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Stop monitoring the system clipboard. Clears user intent so that
    /// an unrelated pause/unpause cycle does not resurrect monitoring.
    func stopMonitoring() {
        userWantsMonitoring = false
        pollTimer?.invalidate()
        pollTimer = nil
        isMonitoring = false
    }

    /// Toggle monitoring state
    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    // MARK: - Clipboard Polling

    /// Check for clipboard changes and process new content
    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        // No change detected
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        // Burn-after-paste runs at the *start* of the change-detected path,
        // before we decide whether to persist the new content. Any clip
        // marked for burn that was staged before this pasteboard change is
        // now assumed pasted (or at least superseded) and gets soft-deleted.
        processPendingBurns()

        // Respect pause setting
        if settings.isTrackingPaused {
            print("[LumaClip] Clipboard change detected but tracking is paused")
            return
        }

        // Check privacy: skip if from blacklisted app
        let sourceApp = getActiveAppName()
        if settings.blacklistedApps.contains(sourceApp) {
            print("[LumaClip] Skipped — source app '\(sourceApp)' is blacklisted")
            return
        }

        // ── Try image capture first ──────────────────────────────
        if settings.captureImages,
           let imgData = imageDataFromPasteboard(pasteboard) {
            let nsImage = NSImage(data: imgData)
            let w = Int(nsImage?.size.width ?? 0)
            let h = Int(nsImage?.size.height ?? 0)
            let description = "Image \(w)×\(h)"

            // Dedup against prior captures of the exact same image bytes.
            let imageHash = ContentHasher.hash(imageData: imgData)
            if let existing = database.findByContentHash(imageHash) {
                database.promoteItemToTop(id: existing.id)
                print("[LumaClip] Deduped image capture → promoted \(existing.id)")
                lastCopiedItem = existing
                copyCount += 1
                NotificationCenter.default.post(
                    name: .clipboardDidChange,
                    object: nil,
                    userInfo: ["item": existing]
                )
                return
            }

            let expiresAt = calculateExpiry(for: .image, sourceApp: sourceApp)
            let autoCatId = autoCategoryId(for: .image, content: description)

            let item = ClipboardItem(
                content: description,
                contentType: .image,
                sourceApp: sourceApp,
                expiresAt: expiresAt,
                categoryId: autoCatId,
                imageData: imgData,
                contentHash: imageHash
            )

            database.insertItem(item)
            print("[LumaClip] Saved: [image] \(description) (\(imgData.count) bytes) from \(sourceApp)")

            // Kick off OCR in the background so the capture loop stays
            // snappy. When recognition finishes, setOCRText updates the
            // row and re-indexes FTS so the extracted text is searchable.
            if let image = nsImage {
                OCRService.recognizeText(in: image) { [weak self] text in
                    guard let self, !text.isEmpty else { return }
                    self.database.setOCRText(id: item.id, text: text)
                    print("[LumaClip] OCR captured \(text.count) chars for \(item.id)")
                }
            }

            database.trimHistory(maxCount: settings.maxHistoryCount)
            lastCopiedItem = item
            copyCount += 1

            NotificationCenter.default.post(
                name: .clipboardDidChange,
                object: nil,
                userInfo: ["item": item]
            )
            return
        }

        // ── File capture (Finder copy → file URLs) ───────────────
        // Runs before text so that copying a file in Finder (which also
        // puts the path on the board as a string in some apps) is saved
        // as a proper file clip rather than a path string.
        if settings.captureFiles,
           let fileURLs = fileURLsFromPasteboard(pasteboard) {
            let entries = FileVaultService.shared.ingest(urls: fileURLs)
            if !entries.isEmpty {
                let contentSig = FileVaultService.contentSignature(for: entries)
                let pathSig    = FileVaultService.pathSignature(for: entries)
                let names      = entries.map { $0.name }.joined(separator: ", ")
                let expiresAt  = calculateExpiry(for: .file, sourceApp: sourceApp)

                // 1) Exact duplicate — identical file(s) copied again
                //    (even from another folder). Promote, never store twice.
                if !contentSig.isEmpty,
                   let dup = database.findByContentHash(contentSig),
                   dup.contentType == .file {
                    database.promoteItemToTop(id: dup.id)
                    print("[LumaClip] Duplicate file capture → promoted \(dup.id)")
                    lastCopiedItem = dup
                    copyCount += 1
                    NotificationCenter.default.post(
                        name: .clipboardDidChange, object: nil, userInfo: ["item": dup]
                    )
                    return
                }

                // 2) Same file path(s) but changed content — the file was
                //    edited since last copy. Replace the old clip in place
                //    (same id) so the list never holds two versions, then
                //    reclaim the previous version's vault files.
                if let old = database.findFileClipByPathSignature(pathSig) {
                    let updated = ClipboardItem(
                        id: old.id,
                        content: names,
                        contentType: .file,
                        sourceApp: sourceApp,
                        createdAt: Date(),
                        expiresAt: expiresAt,
                        isFavorite: old.isFavorite,
                        isPinned: old.isPinned,
                        categoryId: old.categoryId ?? fileCategoryId(for: entries),
                        contentHash: contentSig,
                        fileEntries: entries
                    )
                    database.insertItem(updated)            // INSERT OR REPLACE on id
                    FileVaultService.shared.garbageCollect() // drop old version's bytes
                    print("[LumaClip] Updated file → replaced existing clip \(old.id)")
                    lastCopiedItem = updated
                    copyCount += 1
                    NotificationCenter.default.post(
                        name: .clipboardDidChange, object: nil, userInfo: ["item": updated]
                    )
                    return
                }

                // 3) Brand-new file clip.
                let autoCatId = fileCategoryId(for: entries)
                let item = ClipboardItem(
                    content: names,
                    contentType: .file,
                    sourceApp: sourceApp,
                    expiresAt: expiresAt,
                    categoryId: autoCatId,
                    contentHash: contentSig,
                    fileEntries: entries
                )
                database.insertItem(item)
                database.trimHistory(maxCount: settings.maxHistoryCount)
                let stored = entries.filter { $0.stored }.count
                print("[LumaClip] Saved: [file] \(names) — \(entries.count) file(s), \(stored) in vault, from \(sourceApp)")
                lastCopiedItem = item
                copyCount += 1
                NotificationCenter.default.post(
                    name: .clipboardDidChange, object: nil, userInfo: ["item": item]
                )
                return
            }
        }

        // ── Text capture ─────────────────────────────────────────
        guard let content = pasteboard.string(forType: .string),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            print("[LumaClip] Clipboard change: no usable content (empty or unsupported type)")
            return
        }

        let preview = String(content.prefix(60)).replacingOccurrences(of: "\n", with: "↵")
        print("[LumaClip] Clipboard change detected: \"\(preview)\"")

        // Check privacy: skip potential passwords
        if settings.detectAndSkipPasswords && looksLikePassword(content) {
            print("[LumaClip] Skipped — content looks like a password (detectAndSkipPasswords is on)")
            return
        }

        // Dedup via content hash — exact (normalized) re-copies promote
        // the existing row to the top instead of creating a duplicate.
        // Runs unconditionally so even users who turn off `skipDuplicates`
        // don't see their history flooded by repeat copies.
        let hash = ContentHasher.hash(content)
        if !hash.isEmpty, let existing = database.findByContentHash(hash) {
            database.promoteItemToTop(id: existing.id)
            print("[LumaClip] Deduped text capture → promoted \(existing.id)")
            lastCopiedItem = existing
            copyCount += 1
            NotificationCenter.default.post(
                name: .clipboardDidChange,
                object: nil,
                userInfo: ["item": existing]
            )
            return
        }

        // Legacy LIKE-based dup check — kept for users who have a pre-v3
        // row without a populated hash yet. Can retire once backfill has
        // swept the history.
        if settings.skipDuplicates && database.contentExists(content) {
            print("[LumaClip] Skipped — duplicate content already exists (skipDuplicates is on)")
            return
        }

        // Classify content type
        let contentType = ContentClassifier.classify(content)

        // Calculate expiry if retention rules apply
        let expiresAt = calculateExpiry(for: contentType, sourceApp: sourceApp)

        // Auto-categorize based on content type
        let autoCatId = autoCategoryId(for: contentType, content: content)

        // Detect sensitive content (credit cards, JWT, API keys, …).
        let isSensitive = SensitivityDetector.detect(content)

        // Create and save item
        let item = ClipboardItem(
            content: content,
            contentType: contentType,
            sourceApp: sourceApp,
            expiresAt: expiresAt,
            categoryId: autoCatId,
            contentHash: hash,
            isSensitive: isSensitive
        )

        database.insertItem(item)
        if isSensitive {
            print("[LumaClip] Saved (SENSITIVE): [\(contentType.rawValue)] from \(sourceApp)")
        } else if let catId = autoCatId {
            print("[LumaClip] Saved: [\(contentType.rawValue)] from \(sourceApp) → auto-category \(catId)")
        } else {
            print("[LumaClip] Saved: [\(contentType.rawValue)] from \(sourceApp)")
        }

        // Trim history if needed
        database.trimHistory(maxCount: settings.maxHistoryCount)

        // Update published state
        lastCopiedItem = item
        copyCount += 1

        // Post notification for UI updates
        NotificationCenter.default.post(
            name: .clipboardDidChange,
            object: nil,
            userInfo: ["item": item]
        )
    }

    // MARK: - Burn-After-Paste

    /// Delete any clips staged for burn that are now either:
    ///   - followed by a new clipboard change (the assumed paste), or
    ///   - older than `burnFallbackTimeout` (safety net for clips the
    ///     user never pasted onto anything).
    private func processPendingBurns() {
        guard !pendingBurnItems.isEmpty else { return }
        let now = Date()
        let toDelete = pendingBurnItems.keys
        for id in toDelete {
            database.softDeleteItem(id: id)
            print("[LumaClip] Burn-after-paste fired for \(id)")
        }
        pendingBurnItems.removeAll()
        // Surface the deletions so the UI refreshes.
        NotificationCenter.default.post(
            name: .clipboardDidChange,
            object: nil,
            userInfo: ["burned": true]
        )
        _ = now     // silence unused warning; reserved for future metrics
    }

    /// Stage an item for deletion after its next paste. The actual delete
    /// runs the next time `checkClipboard` observes a pasteboard change.
    /// A fallback timer catches clips that never get copied over.
    private func stageForBurn(_ id: UUID) {
        pendingBurnItems[id] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + burnFallbackTimeout) { [weak self] in
            guard let self else { return }
            // Still pending? Force-burn.
            guard self.pendingBurnItems.keys.contains(id) else { return }
            self.database.softDeleteItem(id: id)
            self.pendingBurnItems.removeValue(forKey: id)
            print("[LumaClip] Burn-after-paste fallback fired for \(id)")
            NotificationCenter.default.post(
                name: .clipboardDidChange,
                object: nil,
                userInfo: ["burned": true]
            )
        }
    }

    // MARK: - Content-Hash Backfill

    /// On first launch after upgrading to schema v3, walk rows missing a
    /// `content_hash` and populate them so dedup works against historic
    /// clips. Batched and dispatched off the main queue.
    private func scheduleContentHashBackfill() {
        backfillQueue.async { [database] in
            let rows = database.fetchItemsMissingHash(limit: 5_000)
            guard !rows.isEmpty else { return }
            print("[LumaClip] Backfilling content_hash for \(rows.count) legacy rows…")
            for (id, content) in rows {
                let hash = ContentHasher.hash(content)
                if !hash.isEmpty {
                    database.backfillContentHash(id: id, hash: hash)
                }
            }
            print("[LumaClip] content_hash backfill complete")
        }
    }

    // MARK: - Helpers

    /// Get the name of the currently active (frontmost) application
    /// Note: May return "Unknown" due to macOS security restrictions
    /// Cached to reduce system queries and console warnings
    private func getActiveAppName() -> String {
        // Only check every appCheckInterval seconds to reduce warnings
        let now = Date()
        if now.timeIntervalSince(lastAppCheckTime) > appCheckInterval {
            lastAppCheckTime = now
            if let app = NSWorkspace.shared.frontmostApplication {
                cachedSourceApp = app.localizedName ?? "Unknown"
            }
        }
        return cachedSourceApp
    }

    /// Conservative heuristic to detect password-like strings.
    /// Only triggers on strings that look like randomly generated credentials —
    /// NOT normal code, URLs, version strings, or camelCase identifiers.
    private func looksLikePassword(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must be a single line with no spaces
        guard !trimmed.contains("\n"),
              !trimmed.contains(" "),
              trimmed.count >= 12,   // raised from 8 — short strings rarely passwords
              trimmed.count <= 128
        else { return false }

        // Skip anything that looks like a URL or file path
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return false }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return false }
        if trimmed.contains(".") && !trimmed.contains("@") { return false } // domain/version-like

        // Must have ALL 4 character classes to be considered a password:
        // uppercase + lowercase + digit + special character
        let hasUpper   = trimmed.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasLower   = trimmed.range(of: "[a-z]", options: .regularExpression) != nil
        let hasDigit   = trimmed.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSpecial = trimmed.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil

        // Require all 4 classes — catches real password managers but not code identifiers
        return hasUpper && hasLower && hasDigit && hasSpecial
    }

    /// Calculate expiry date based on retention rules.
    ///
    /// Precedence (most specific first, most general last):
    ///   1. `.sourceApp` — matches the item's sourceApp
    ///   2. `.contentType` — matches the item's contentType
    ///   3. `.all` — global catch-all rule
    ///   4. `AppSettings.defaultRetentionDays` — no rule matched
    ///
    /// The first matching rule wins; ties between rules of the same precedence
    /// go to insertion order (how `fetchRetentionRules` returns them).
    private func calculateExpiry(for contentType: ContentType, sourceApp: String) -> Date? {
        let rules = database.fetchRetentionRules()

        // 1. Per-app rule (most specific — e.g. "keep Slack pastes 1 day")
        for rule in rules where rule.isEnabled {
            if case .sourceApp(let app) = rule.target,
               !app.isEmpty,
               app.caseInsensitiveCompare(sourceApp) == .orderedSame {
                return rule.duration > 0
                    ? Date().addingTimeInterval(rule.duration)
                    : nil
            }
        }

        // 2. Per-content-type rule
        for rule in rules where rule.isEnabled {
            if case .contentType(let ct) = rule.target, ct == contentType {
                return rule.duration > 0
                    ? Date().addingTimeInterval(rule.duration)
                    : nil
            }
        }

        // 3. Global rule
        for rule in rules where rule.isEnabled {
            if case .all = rule.target {
                return rule.duration > 0
                    ? Date().addingTimeInterval(rule.duration)
                    : nil
            }
        }

        // 4. Fallback: default retention from settings
        let defaultDays = settings.defaultRetentionDays
        if defaultDays > 0 {
            return Date().addingTimeInterval(Double(defaultDays) * 86400)
        }

        return nil
    }

    /// Auto-categorize an item by matching its content type to an existing category.
    /// Matches category names case-insensitively against content type labels and common aliases.
    private func autoCategoryId(for contentType: ContentType, content: String) -> UUID? {
        guard settings.autoCategory else { return nil }
        let categories = database.fetchCategories()
        guard !categories.isEmpty else { return nil }

        // Build a mapping of content type → category name keywords
        let typeKeywords: [ContentType: [String]] = [
            .url:    ["url", "urls", "link", "links", "网址", "链接"],
            .email:  ["email", "emails", "mail", "邮件", "邮箱"],
            .phone:  ["phone", "phones", "tel", "telephone", "电话", "手机"],
            .code:   ["code", "codes", "coding", "dev", "development", "代码", "编程"],
            .text:   ["text", "texts", "note", "notes", "笔记", "文本"],
            .image:  ["image", "images", "photo", "photos", "screenshot", "screenshots", "图片", "截图", "照片"],
        ]

        let keywords = typeKeywords[contentType] ?? []

        for category in categories {
            let catName = category.name.lowercased()
            // Match if category name contains any of the type keywords
            for keyword in keywords {
                if catName.contains(keyword) {
                    return category.id
                }
            }
        }

        return nil
    }

    /// Auto-categorize a file clip by the file extension of its primary
    /// (first) file, mapping PDF / Word / Excel / PowerPoint documents
    /// straight onto the corresponding default category by its stable ID.
    ///
    /// Direct-ID mapping (rather than fuzzy name matching) means routing
    /// can't be hijacked by a same-named user category and keeps working
    /// even if the user renames the category. The default categories are
    /// re-seeded on every launch (see AppDelegate), so the target row is
    /// guaranteed to exist. Returns nil for other file types.
    private func fileCategoryId(for entries: [FileEntry]) -> UUID? {
        guard settings.autoCategory, let first = entries.first else { return nil }
        let ext = (first.name as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf":
            return Category.pdfCategoryId
        case "doc", "docx", "rtf", "odt", "pages", "dot", "dotx":
            return Category.wordCategoryId
        case "xls", "xlsx", "xlsm", "csv", "numbers", "ods":
            return Category.excelCategoryId
        case "ppt", "pptx", "pps", "ppsx", "key", "odp":
            return Category.powerPointCategoryId
        default:
            return nil
        }
    }

    /// Setup observers for settings changes
    private func setupSettingsObservers() {
        // React to pause/resume by actually stopping or resuming the timer,
        // so `isMonitoring` stays in sync with `pollTimer`. Resume only if
        // the user hadn't explicitly stopped monitoring beforehand.
        settings.$isTrackingPaused
            .dropFirst()                       // ignore replay of initial value
            .removeDuplicates()
            .sink { [weak self] paused in
                guard let self else { return }
                if paused {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    self.isMonitoring = false
                } else if self.userWantsMonitoring {
                    self.startMonitoring()
                }
            }
            .store(in: &cancellables)
    }

    /// Copy text back to clipboard (for paste-on-select)
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    /// Copy image data back to clipboard.
    ///
    /// `imageDataFromPasteboard` stores images as JPEG (and in principle the
    /// source data could be PNG too). Writing those bytes back under
    /// `.tiff` mislabels them and forces every receiving app to round-trip
    /// through TIFF — which can triple the payload size. Inspect the magic
    /// bytes and write under the actual UTI instead.
    func copyImageToClipboard(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.pasteboardType(forImageData: data))
        lastChangeCount = pasteboard.changeCount
    }

    /// Detect an image blob's format from its first few bytes and return the
    /// matching `NSPasteboard.PasteboardType`. Falls back to `.tiff` for
    /// unknown data (the historical behavior).
    private static func pasteboardType(forImageData data: Data) -> NSPasteboard.PasteboardType {
        guard data.count >= 4 else { return .tiff }
        let b = [UInt8](data.prefix(4))
        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return NSPasteboard.PasteboardType("public.jpeg")
        }
        // PNG: 89 50 4E 47
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            return .png
        }
        // TIFF: 49 49 2A 00 (little-endian) or 4D 4D 00 2A (big-endian)
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
           (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) {
            return .tiff
        }
        return .tiff
    }

    /// Copy a ClipboardItem — dispatches to file, image, or text path.
    /// If the item is flagged `isBurnAfterPaste`, it's staged for
    /// deletion on the next pasteboard change (the assumed paste).
    func copyItem(_ item: ClipboardItem) {
        if item.contentType == .file, !item.fileEntries.isEmpty {
            copyFilesToClipboard(item.fileEntries)
        } else if item.contentType == .image, let data = item.imageData {
            copyImageToClipboard(data)
        } else {
            copyToClipboard(item.content)
        }
        if item.isBurnAfterPaste {
            stageForBurn(item.id)
        }
    }

    /// Write file URLs back to the pasteboard so a subsequent Cmd+V in
    /// Finder (or any app accepting files) pastes the actual files.
    /// Resolves each entry to its vault copy or surviving original; if
    /// none can be found, falls back to writing the file names as text.
    func copyFilesToClipboard(_ entries: [FileEntry]) {
        let urls = FileVaultService.shared.resolveURLs(for: entries)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if urls.isEmpty {
            let names = entries.map { $0.name }.joined(separator: "\n")
            pasteboard.setString(names, forType: .string)
            print("[LumaClip] File paste-back: no files resolvable, wrote names as text")
        } else {
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - File Extraction

    /// Read file URLs from the pasteboard (Finder copy, drag, etc.).
    /// Restricted to file URLs and filtered to ones that still exist on
    /// disk. Returns nil when there are none.
    private func fileURLsFromPasteboard(_ pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let objs = pasteboard.readObjects(
                forClasses: [NSURL.self], options: options
              ) as? [URL] else { return nil }

        let fm = FileManager.default
        let existing = objs.filter { $0.isFileURL && fm.fileExists(atPath: $0.path) }
        return existing.isEmpty ? nil : existing
    }

    // MARK: - Image Extraction

    /// Extracts image data from the pasteboard and compresses to JPEG.
    /// Returns nil if no image is present or the result exceeds 2 MB.
    /// Checks for .tiff and .png pasteboard types.
    private func imageDataFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        // Only proceed if the pasteboard actually has image data
        // (avoid capturing screenshots of text as images)
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        guard pasteboard.availableType(from: imageTypes) != nil else { return nil }

        // If there's also plain text alongside the image, prefer text
        // (e.g., copying a cell in Excel puts both text and image on the board).
        // Exception: if the text is empty/whitespace, keep the image.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Both text and image exist — prefer text to avoid double-capture
            return nil
        }

        guard let rawData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
              let nsImage = NSImage(data: rawData),
              let tiffRep = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffRep)
        else { return nil }

        // Compress to JPEG, adjusting quality to stay under 2 MB
        let maxBytes = 2 * 1024 * 1024  // 2 MB
        for quality in stride(from: 0.85, through: 0.3, by: -0.15) {
            if let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpegData.count <= maxBytes {
                return jpegData
            }
        }

        // Last resort: lowest quality
        if let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.2]),
           jpegData.count <= maxBytes {
            return jpegData
        }

        print("[LumaClip] Image too large even at lowest quality, skipping")
        return nil
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let clipboardDidChange = Notification.Name("com.lumaclip.clipboardDidChange")
}
