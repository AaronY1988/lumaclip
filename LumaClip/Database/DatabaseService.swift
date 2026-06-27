// DatabaseService.swift
// LumaClip - macOS Clipboard Manager
//
// SQLite-backed persistence layer for clipboard items, categories,
// and retention rules. Provides full CRUD, soft-delete for Trash Bin,
// expiry cleanup, and full-text search support.
//
// Uses raw SQLite3 C API for maximum performance and zero dependencies.

import Foundation
import SQLite3

// MARK: - Pagination Cursor

/// Opaque cursor describing the last row of a previously returned page.
/// Pass into `fetchItems(after:)` to fetch the next page without using
/// OFFSET (which scales O(N) in SQLite).
///
/// The cursor captures both `created_at` and `id` so pagination stays stable
/// even if two clipboard items happen to share the same timestamp.
struct ItemsPageCursor: Equatable, Hashable {
    /// `timeIntervalSince1970` of the last item on the previous page.
    let createdAt: Double
    /// UUID string of the last item on the previous page — used as a
    /// deterministic tie-breaker when timestamps collide.
    let id: String

    init(createdAt: Double, id: String) {
        self.createdAt = createdAt
        self.id = id
    }

    /// Build a cursor from the last `ClipboardItem` of the previous page.
    /// Pass the result back into `fetchItems(after:)` to get the next page.
    init(after item: ClipboardItem) {
        self.createdAt = item.createdAt.timeIntervalSince1970
        self.id = item.id.uuidString
    }
}

// MARK: - Database Service

final class DatabaseService: ObservableObject {
    static let shared = DatabaseService()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.lumaclip.database", qos: .userInitiated)

    // MARK: - Initialization

    private init() {
        openDatabase()
        migrateDatabase()
        createTables()
        createIndexes()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Storage Footprint
    //
    // Surfaced for the sidebar's Storage card so the user can see
    // actual bytes consumed on disk rather than just clip count vs
    // cap. We sum every file in the LumaClip Application Support
    // directory — that captures:
    //
    //   • lumaclip.sqlite          — main DB, including image BLOBs
    //                                 stored as columns on the items
    //                                 table (so screenshots count too).
    //   • lumaclip.sqlite-wal      — WAL journal, can grow between
    //                                 checkpoints.
    //   • lumaclip.sqlite-shm      — shared-memory index for WAL.
    //   • Anything else future code drops in the same directory.
    //
    // Cheap (3–4 stat() calls in practice). Safe to call on the main
    // thread; the file enumerator is non-blocking.

    /// Filesystem location of LumaClip's data directory. Exposed so
    /// callers (e.g. a "Reveal in Finder" affordance) can open it
    /// without hard-coding the path.
    static var storageDirectoryURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport.appendingPathComponent("LumaClip", isDirectory: true)
    }

    /// Total bytes consumed by every file in the LumaClip data
    /// directory. Returns `0` if the directory doesn't exist yet
    /// (first-launch race) or can't be read for any reason.
    static func storageBytesUsed() -> Int64 {
        guard let dir = storageDirectoryURL else { return 0 }
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            // Only count regular files — directories report their own
            // metadata size, which would double-count.
            if values?.isRegularFile == true,
               let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Database Setup

    /// Opens or creates the SQLite database file in Application Support
    private func openDatabase() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupportURL.appendingPathComponent("LumaClip", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        let dbPath = appDirectory.appendingPathComponent("lumaclip.sqlite").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DatabaseService] Error opening database: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        // Enable WAL mode for better concurrent read performance
        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA foreign_keys=ON;")
    }

    /// Migrate database schema if needed
    private func migrateDatabase() {
        // Check current schema version
        let currentVersion = getUserVersion()
        
        // Version 0 -> 1: Fix FTS table configuration
        if currentVersion < 1 {
            print("[DatabaseService] Migrating to schema version 1...")
            migrateFTSTable()
            setUserVersion(1)
        }

        // Version 1 -> 2: Add image_data BLOB column
        if currentVersion < 2 {
            print("[DatabaseService] Migrating to schema version 2 (image support)...")
            execute("ALTER TABLE clipboard_items ADD COLUMN image_data BLOB;")
            setUserVersion(2)
        }

        // Version 2 -> 3: Dedup hash, OCR text, sensitivity, burn-after-paste.
        // All default-safe so existing rows remain valid; hashes are
        // backfilled lazily by ClipboardService on its next capture loop
        // rather than rewriting the whole table here.
        if currentVersion < 3 {
            print("[DatabaseService] Migrating to schema version 3 (dedup / OCR / sensitivity)...")
            execute("ALTER TABLE clipboard_items ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';")
            execute("ALTER TABLE clipboard_items ADD COLUMN ocr_text TEXT NOT NULL DEFAULT '';")
            execute("ALTER TABLE clipboard_items ADD COLUMN is_sensitive INTEGER NOT NULL DEFAULT 0;")
            execute("ALTER TABLE clipboard_items ADD COLUMN is_burn_after_paste INTEGER NOT NULL DEFAULT 0;")
            setUserVersion(3)
        }

        // Version 3 -> 4: Rebuild FTS with the `trigram` tokenizer so
        // queries match substrings anywhere in content (not just token
        // prefixes). "8182" → finds "CN8182"; "xEg" → finds "…xEgZp".
        // BM25 ranking still applies. Case-insensitive by default.
        if currentVersion < 4 {
            print("[DatabaseService] Migrating to schema version 4 (trigram FTS tokenizer)...")
            migrateToTrigramFTS()
            setUserVersion(4)
        }

        // Version 4 -> 5: File-clip support. `file_meta` stores a JSON
        // array of FileEntry describing the files held by a `.file` clip
        // (name, size, vault path, original path). Default-empty so all
        // existing rows stay valid; non-file clips simply carry "".
        if currentVersion < 5 {
            print("[DatabaseService] Migrating to schema version 5 (file clips)...")
            execute("ALTER TABLE clipboard_items ADD COLUMN file_meta TEXT NOT NULL DEFAULT '';")
            setUserVersion(5)
        }
    }

    /// Rebuild `clipboard_fts` as a trigram-tokenised FTS5 table. The
    /// trigram tokenizer indexes every 3-char window, giving LIKE-style
    /// substring match at FTS speeds. FTS rebuild concatenates `content`
    /// with `ocr_text` so screenshot text captured by Vision is also
    /// covered by substring search.
    private func migrateToTrigramFTS() {
        execute("DROP TABLE IF EXISTS clipboard_fts;")

        // `tokenize='trigram'` requires SQLite 3.34+ (shipped with all
        // supported macOS versions). `case_sensitive=0` is the default
        // but spelled out here for clarity.
        let createSql = """
            CREATE VIRTUAL TABLE clipboard_fts USING fts5(
                content,
                content_id UNINDEXED,
                tokenize = "trigram case_sensitive 0"
            );
        """
        if !execute(createSql) {
            print("[DatabaseService] Warning: trigram FTS create failed")
            return
        }

        // Repopulate from clipboard_items, concatenating content + ocr_text
        // so the newly-searchable index reflects what updateFTSIndex now
        // writes on every insert.
        let rebuildSql = """
            INSERT INTO clipboard_fts (content, content_id)
            SELECT
                CASE WHEN ocr_text = '' THEN content ELSE content || ' ' || ocr_text END,
                id
            FROM clipboard_items
            WHERE is_deleted = 0;
        """
        if execute(rebuildSql) {
            print("[DatabaseService] FTS rebuilt with trigram tokenizer")
        } else {
            print("[DatabaseService] Warning: trigram FTS rebuild failed")
        }
    }
    
    /// Get current database schema version
    private func getUserVersion() -> Int {
        let sql = "PRAGMA user_version;"
        guard let stmt = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
    
    /// Set database schema version
    private func setUserVersion(_ version: Int) {
        execute("PRAGMA user_version = \(version);")
    }
    
    /// Migrate FTS table from external content to standalone
    private func migrateFTSTable() {
        // Check if FTS table exists
        let checkSql = "SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_fts';"
        guard let checkStmt = prepare(checkSql) else { return }
        
        var ftsExists = false
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            ftsExists = true
        }
        sqlite3_finalize(checkStmt)
        
        if !ftsExists {
            print("[DatabaseService] FTS table doesn't exist yet, skipping migration")
            return
        }
        
        print("[DatabaseService] Rebuilding FTS table...")
        
        // Drop old FTS table
        execute("DROP TABLE IF EXISTS clipboard_fts;")
        
        // Create new FTS table with correct schema
        execute("""
            CREATE VIRTUAL TABLE clipboard_fts USING fts5(
                content,
                content_id UNINDEXED
            );
        """)
        
        // Rebuild FTS index from existing clipboard items
        let rebuildSql = """
            INSERT INTO clipboard_fts (content, content_id)
            SELECT content, id FROM clipboard_items WHERE is_deleted = 0;
        """
        
        if execute(rebuildSql) {
            print("[DatabaseService] FTS table successfully rebuilt")
        } else {
            print("[DatabaseService] Warning: Failed to rebuild FTS index")
        }
    }

    /// Creates all required tables if they don't exist
    private func createTables() {
        // Clipboard Items
        execute("""
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                content_type TEXT NOT NULL DEFAULT 'text',
                source_app TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                expires_at REAL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                category_id TEXT,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL,
                image_data BLOB,
                content_hash TEXT NOT NULL DEFAULT '',
                ocr_text TEXT NOT NULL DEFAULT '',
                is_sensitive INTEGER NOT NULL DEFAULT 0,
                is_burn_after_paste INTEGER NOT NULL DEFAULT 0,
                file_meta TEXT NOT NULL DEFAULT ''
            );
        """)

        // Categories
        execute("""
            CREATE TABLE IF NOT EXISTS categories (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT 'tag',
                color TEXT NOT NULL DEFAULT 'blue'
            );
        """)

        // Retention Rules
        execute("""
            CREATE TABLE IF NOT EXISTS retention_rules (
                id TEXT PRIMARY KEY,
                target_type TEXT NOT NULL DEFAULT 'all',
                target_value TEXT NOT NULL DEFAULT '',
                duration REAL NOT NULL DEFAULT 604800,
                is_enabled INTEGER NOT NULL DEFAULT 1
            );
        """)

        // Full-Text Search virtual table. Trigram tokenizer gives
        // substring match at FTS speeds — typing "8182" matches "CN8182",
        // typing "xEg" matches "0010800002xEgZp", etc.
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
                content,
                content_id UNINDEXED,
                tokenize = "trigram case_sensitive 0"
            );
        """)
    }

    /// Creates indexes for common query patterns
    private func createIndexes() {
        execute("CREATE INDEX IF NOT EXISTS idx_items_created ON clipboard_items(created_at DESC);")
        execute("CREATE INDEX IF NOT EXISTS idx_items_deleted ON clipboard_items(is_deleted);")
        execute("CREATE INDEX IF NOT EXISTS idx_items_favorite ON clipboard_items(is_favorite);")
        execute("CREATE INDEX IF NOT EXISTS idx_items_type ON clipboard_items(content_type);")
        execute("CREATE INDEX IF NOT EXISTS idx_items_category ON clipboard_items(category_id);")
        execute("CREATE INDEX IF NOT EXISTS idx_items_expires ON clipboard_items(expires_at);")

        // Composite index covering the main list query:
        //   WHERE is_deleted = 0 ORDER BY is_pinned DESC, created_at DESC
        // SQLite can walk this index in order and avoid a filesort on every
        // reload of the clipboard panel. Covers cursor pagination queries too.
        execute("""
            CREATE INDEX IF NOT EXISTS idx_items_list
            ON clipboard_items(is_deleted, is_pinned DESC, created_at DESC, id DESC);
        """)

        // source_app is needed by per-app retention rules and `from:` filters.
        // Without this index those queries scan the full table.
        execute("CREATE INDEX IF NOT EXISTS idx_items_source_app ON clipboard_items(source_app);")

        // content_hash lookup for dedup-on-capture. Partial index on
        // non-empty hashes only — most of the backfill window will have
        // empty hashes which are meaningless for dedup.
        execute("""
            CREATE INDEX IF NOT EXISTS idx_items_hash
            ON clipboard_items(content_hash) WHERE content_hash != '';
        """)
    }

    // MARK: - Execute Helpers

    /// Execute a simple SQL statement
    @discardableResult
    private func execute(_ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            if let msg = errorMessage {
                print("[DatabaseService] SQL Error: \(String(cString: msg))")
                sqlite3_free(msg)
            }
            return false
        }
        return true
    }

    /// Prepare a statement for parameterized queries
    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            print("[DatabaseService] Prepare error: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return statement
    }

    // MARK: - Clipboard Item CRUD

    /// Insert a new clipboard item
    func insertItem(_ item: ClipboardItem) {
        dbQueue.sync {
            let sql = """
                INSERT OR REPLACE INTO clipboard_items
                (id, content, content_type, source_app, created_at, expires_at,
                 is_favorite, is_pinned, category_id, is_deleted, deleted_at, image_data,
                 content_hash, ocr_text, is_sensitive, is_burn_after_paste, file_meta)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, item.content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, item.contentType.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, item.sourceApp, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)

            if let expiresAt = item.expiresAt {
                sqlite3_bind_double(stmt, 6, expiresAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            sqlite3_bind_int(stmt, 7, item.isFavorite ? 1 : 0)
            sqlite3_bind_int(stmt, 8, item.isPinned ? 1 : 0)

            if let categoryId = item.categoryId {
                sqlite3_bind_text(stmt, 9, categoryId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 9)
            }

            sqlite3_bind_int(stmt, 10, item.isDeleted ? 1 : 0)

            if let deletedAt = item.deletedAt {
                sqlite3_bind_double(stmt, 11, deletedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 11)
            }

            // image_data BLOB (column 12)
            if let imgData = item.imageData {
                _ = imgData.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(stmt, 12, rawBuffer.baseAddress, Int32(rawBuffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 12)
            }

            sqlite3_bind_text(stmt, 13, item.contentHash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 14, item.ocrText, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 15, item.isSensitive ? 1 : 0)
            sqlite3_bind_int(stmt, 16, item.isBurnAfterPaste ? 1 : 0)

            // file_meta JSON (column 17) — empty string for non-file clips.
            let fileMetaJSON = Self.encodeFileEntries(item.fileEntries)
            sqlite3_bind_text(stmt, 17, fileMetaJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[DatabaseService] Insert error: \(String(cString: sqlite3_errmsg(db)))")
            }

            // Update FTS index
            updateFTSIndex(for: item)
        }
    }

    /// Update FTS index for an item. Indexes `content` joined with
    /// `ocrText` so screenshot text captured by Vision surfaces in
    /// search alongside the original clip description.
    private func updateFTSIndex(for item: ClipboardItem) {
        // Delete old entry
        let deleteSql = "DELETE FROM clipboard_fts WHERE content_id = ?;"
        if let stmt = prepare(deleteSql) {
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "updateFTSIndex (delete)")
            sqlite3_finalize(stmt)
        }

        // Insert new entry
        let indexText = item.ocrText.isEmpty
            ? item.content
            : item.content + " " + item.ocrText
        let insertSql = "INSERT INTO clipboard_fts (content, content_id) VALUES (?, ?);"
        if let stmt = prepare(insertSql) {
            sqlite3_bind_text(stmt, 1, indexText, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, item.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "updateFTSIndex (insert)")
            sqlite3_finalize(stmt)
        }
    }

    /// Fetch clipboard items, optionally filtered / searched / paginated.
    ///
    /// Three usage modes:
    /// 1. Plain list: pass only `filter` / `limit` / `offset`. Returns pinned
    ///    items first, then unpinned in reverse-chronological order.
    /// 2. Search: pass a non-empty `searchQuery` to run a BM25-ranked FTS5
    ///    match. Results are ordered by `is_pinned DESC, rank` (best match
    ///    first within each pin bucket). When searching, `after` is ignored
    ///    because rank-ordered cursor pagination would be unstable as the
    ///    query changes.
    /// 3. Cursor pagination: pass `after: ItemsPageCursor` to fetch the next
    ///    page of **unpinned** items after the given cursor. Intended for
    ///    infinite scroll: page 1 (with `after == nil`) renders the pins +
    ///    newest unpinned items; subsequent pages restrict to `is_pinned = 0`
    ///    and use a keyset predicate on `(created_at, id)` for stable
    ///    pagination under concurrent inserts.
    func fetchItems(
        filter: SidebarFilter = .all,
        searchQuery: String? = nil,
        limit: Int = 200,
        offset: Int = 0,
        after: ItemsPageCursor? = nil
    ) -> [ClipboardItem] {
        return dbQueue.sync {
            if let query = searchQuery, !query.isEmpty {
                return fetchItemsMatchingSearchLocked(
                    query, filter: filter, limit: limit, offset: offset
                )
            }
            return fetchItemsListLocked(
                filter: filter, limit: limit, offset: offset, after: after
            )
        }
    }

    // MARK: Non-search list path (with cursor pagination)

    private func fetchItemsListLocked(
        filter: SidebarFilter,
        limit: Int,
        offset: Int,
        after: ItemsPageCursor?
    ) -> [ClipboardItem] {
        var conditions: [String] = []
        var params: [Any] = []

        // Sidebar filter
        switch filter {
        case .all:
            conditions.append("is_deleted = 0")
        case .favorites:
            conditions.append("is_deleted = 0")
            conditions.append("is_favorite = 1")
        case .recent:
            conditions.append("is_deleted = 0")
            conditions.append("created_at > ?")
            params.append(Date().addingTimeInterval(-86400).timeIntervalSince1970)
        case .category(let id):
            conditions.append("is_deleted = 0")
            conditions.append("category_id = ?")
            params.append(id.uuidString)
        case .trash:
            conditions.append("is_deleted = 1")
        case .bundles, .settings:
            return []
        }

        // Cursor predicate (keyset pagination past page 1 — unpinned only)
        if let cursor = after {
            conditions.append("is_pinned = 0")
            conditions.append("(created_at < ? OR (created_at = ? AND id < ?))")
            params.append(cursor.createdAt)
            params.append(cursor.createdAt)
            params.append(cursor.id)
        }

        var sql = "SELECT * FROM clipboard_items"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        if after == nil {
            // Page 1 — pinned first, then chronological within each bucket.
            // id is included as a tie-breaker so pagination is stable when
            // multiple items happen to share the same created_at timestamp.
            sql += " ORDER BY is_pinned DESC, created_at DESC, id DESC LIMIT ? OFFSET ?"
        } else {
            // Subsequent page — cursor already excludes pins and rows at/above
            // the cursor row, so a simple chronological sort is sufficient.
            sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        }

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        for param in params {
            if let str = param as? String {
                sqlite3_bind_text(stmt, bindIndex, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let dbl = param as? Double {
                sqlite3_bind_double(stmt, bindIndex, dbl)
            }
            bindIndex += 1
        }

        sqlite3_bind_int(stmt, bindIndex, Int32(limit))
        bindIndex += 1
        if after == nil {
            sqlite3_bind_int(stmt, bindIndex, Int32(offset))
        }

        var items: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = parseClipboardItem(from: stmt) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: FTS5 search path (BM25 ranking, trigram tokenizer)

    /// Run a ranked FTS5 match with filter/limit/offset applied server-side.
    ///
    /// With the trigram tokenizer (schema v4+), `MATCH` behaves like a
    /// LIKE substring scan but indexed: typing "8182" matches "CN8182",
    /// "xEg" matches "…xEgZp". Queries of one or two characters still
    /// work but fall through to an unindexed scan at SQLite's level.
    ///
    /// Results are ordered by `is_pinned DESC, rank` so pinned items
    /// surface first within each BM25 bucket. A LIKE fallback fires
    /// only when the FTS call produces zero rows — rare with trigrams,
    /// but handy if the query contains characters the tokenizer
    /// declines to index (unlikely with unicode61 punctuation rules).
    private func fetchItemsMatchingSearchLocked(
        _ query: String,
        filter: SidebarFilter,
        limit: Int,
        offset: Int
    ) -> [ClipboardItem] {
        // Trigram tokenizer takes raw strings — no `*` prefix, no splitting.
        // Trim and pass straight through; FTS wraps it as a phrase query
        // automatically. Empty input short-circuits to the LIKE path so
        // the caller still gets deterministic behaviour.
        let ftsQuery = query.trimmingCharacters(in: .whitespaces)
        if ftsQuery.isEmpty {
            return fetchItemsMatchingLikeLocked(
                query, filter: filter, limit: limit, offset: offset
            )
        }

        var conditions: [String] = ["f.clipboard_fts MATCH ?"]
        // Wrap the query in double quotes so any embedded punctuation
        // (`-`, `:`, parens, …) is treated as literal text rather than
        // an FTS5 operator. Escape any existing quotes in the input.
        let escaped = ftsQuery.replacingOccurrences(of: "\"", with: "\"\"")
        var params: [Any] = ["\"\(escaped)\""]

        switch filter {
        case .all:
            conditions.append("i.is_deleted = 0")
        case .favorites:
            conditions.append("i.is_deleted = 0")
            conditions.append("i.is_favorite = 1")
        case .recent:
            conditions.append("i.is_deleted = 0")
            conditions.append("i.created_at > ?")
            params.append(Date().addingTimeInterval(-86400).timeIntervalSince1970)
        case .category(let id):
            conditions.append("i.is_deleted = 0")
            conditions.append("i.category_id = ?")
            params.append(id.uuidString)
        case .trash:
            conditions.append("i.is_deleted = 1")
        case .bundles, .settings:
            return []
        }

        // `i.*` preserves the 12-column layout `parseClipboardItem` expects.
        // FTS5 `rank` is ascending (lower is better), so ORDER BY f.rank
        // surfaces the best matches first within each pinned bucket.
        let sql = """
            SELECT i.* FROM clipboard_items i
            JOIN clipboard_fts f ON f.content_id = i.id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY i.is_pinned DESC, f.rank
            LIMIT ? OFFSET ?;
        """

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        for param in params {
            if let str = param as? String {
                sqlite3_bind_text(stmt, bindIndex, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let dbl = param as? Double {
                sqlite3_bind_double(stmt, bindIndex, dbl)
            }
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit)); bindIndex += 1
        sqlite3_bind_int(stmt, bindIndex, Int32(offset))

        var items: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = parseClipboardItem(from: stmt) {
                items.append(item)
            }
        }
        if items.isEmpty {
            return fetchItemsMatchingLikeLocked(
                query, filter: filter, limit: limit, offset: offset
            )
        }
        return items
    }

    /// Filter-aware LIKE scan used when FTS5 returns nothing. Matches the
    /// sidebar-filter branches of the FTS path so results stay scoped to
    /// what the user has selected. Scans the first 500 chars of content
    /// to keep very long clipboard entries (pages, transcripts) from
    /// dominating matches.
    private func fetchItemsMatchingLikeLocked(
        _ query: String,
        filter: SidebarFilter,
        limit: Int,
        offset: Int
    ) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }

        var conditions: [String] = ["LOWER(SUBSTR(content, 1, 500)) LIKE LOWER(?)"]
        var params: [Any] = ["%\(trimmed)%"]

        switch filter {
        case .all:
            conditions.append("is_deleted = 0")
        case .favorites:
            conditions.append("is_deleted = 0")
            conditions.append("is_favorite = 1")
        case .recent:
            conditions.append("is_deleted = 0")
            conditions.append("created_at > ?")
            params.append(Date().addingTimeInterval(-86400).timeIntervalSince1970)
        case .category(let id):
            conditions.append("is_deleted = 0")
            conditions.append("category_id = ?")
            params.append(id.uuidString)
        case .trash:
            conditions.append("is_deleted = 1")
        case .bundles, .settings:
            return []
        }

        let sql = """
            SELECT * FROM clipboard_items
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY is_pinned DESC, created_at DESC
            LIMIT ? OFFSET ?;
        """

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        for param in params {
            if let str = param as? String {
                sqlite3_bind_text(stmt, bindIndex, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let dbl = param as? Double {
                sqlite3_bind_double(stmt, bindIndex, dbl)
            }
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit)); bindIndex += 1
        sqlite3_bind_int(stmt, bindIndex, Int32(offset))

        var items: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = parseClipboardItem(from: stmt) {
                items.append(item)
            }
        }
        return items
    }

    /// Parse a ClipboardItem from a SQLite row
    private func parseClipboardItem(from stmt: OpaquePointer) -> ClipboardItem? {
        guard let idStr = sqlite3_column_text(stmt, 0),
              let contentStr = sqlite3_column_text(stmt, 1),
              let typeStr = sqlite3_column_text(stmt, 2),
              let sourceStr = sqlite3_column_text(stmt, 3)
        else { return nil }

        let id = UUID(uuidString: String(cString: idStr)) ?? UUID()
        let content = String(cString: contentStr)
        let contentType = ContentType(rawValue: String(cString: typeStr)) ?? .text
        let sourceApp = String(cString: sourceStr)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

        let expiresAt: Date? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            : nil

        let isFavorite = sqlite3_column_int(stmt, 6) != 0
        let isPinned = sqlite3_column_int(stmt, 7) != 0

        let categoryId: UUID? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? UUID(uuidString: String(cString: sqlite3_column_text(stmt, 8)))
            : nil

        let isDeleted = sqlite3_column_int(stmt, 9) != 0

        let deletedAt: Date? = sqlite3_column_type(stmt, 10) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
            : nil

        // image_data BLOB (column 11)
        var imageData: Data? = nil
        if sqlite3_column_type(stmt, 11) == SQLITE_BLOB,
           let blobPtr = sqlite3_column_blob(stmt, 11) {
            let blobLen = Int(sqlite3_column_bytes(stmt, 11))
            imageData = Data(bytes: blobPtr, count: blobLen)
        }

        // Columns 12–15 were added in schema v3. Pre-migration rows may
        // surface as NULL on very old installs — guard each read.
        let contentHash: String = {
            guard sqlite3_column_type(stmt, 12) != SQLITE_NULL,
                  let s = sqlite3_column_text(stmt, 12) else { return "" }
            return String(cString: s)
        }()
        let ocrText: String = {
            guard sqlite3_column_type(stmt, 13) != SQLITE_NULL,
                  let s = sqlite3_column_text(stmt, 13) else { return "" }
            return String(cString: s)
        }()
        let isSensitive = sqlite3_column_int(stmt, 14) != 0
        let isBurnAfterPaste = sqlite3_column_int(stmt, 15) != 0

        // file_meta JSON (column 16) — added in schema v5. Pre-v5 rows or
        // non-file clips surface as NULL/"" and decode to an empty array.
        let fileEntries: [FileEntry] = {
            guard sqlite3_column_type(stmt, 16) != SQLITE_NULL,
                  let s = sqlite3_column_text(stmt, 16) else { return [] }
            return Self.decodeFileEntries(String(cString: s))
        }()

        return ClipboardItem(
            id: id,
            content: content,
            contentType: contentType,
            sourceApp: sourceApp,
            createdAt: createdAt,
            expiresAt: expiresAt,
            isFavorite: isFavorite,
            isPinned: isPinned,
            categoryId: categoryId,
            isDeleted: isDeleted,
            deletedAt: deletedAt,
            imageData: imageData,
            contentHash: contentHash,
            ocrText: ocrText,
            isSensitive: isSensitive,
            isBurnAfterPaste: isBurnAfterPaste,
            fileEntries: fileEntries
        )
    }

    // MARK: - File Metadata JSON

    /// Encode a `[FileEntry]` to a compact JSON string for the
    /// `file_meta` column. Returns "" for empty input (non-file clips)
    /// or on the (practically impossible) encode failure.
    static func encodeFileEntries(_ entries: [FileEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    /// Decode the `file_meta` JSON string back into `[FileEntry]`.
    /// Tolerates empty/garbage input by returning an empty array.
    static func decodeFileEntries(_ json: String) -> [FileEntry] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FileEntry].self, from: data)) ?? []
    }

    // MARK: - Vault References

    /// All vault folder names referenced by any row in the database
    /// (including trashed items, whose files must survive until purge).
    /// `FileVaultService` uses this set to garbage-collect orphaned
    /// vault folders left behind by bulk deletes (trim / purge).
    func allReferencedVaultFolders() -> Set<String> {
        return dbQueue.sync {
            var folders = Set<String>()
            let sql = "SELECT file_meta FROM clipboard_items WHERE file_meta != '';"
            guard let stmt = prepare(sql) else { return folders }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let s = sqlite3_column_text(stmt, 0) else { continue }
                let entries = Self.decodeFileEntries(String(cString: s))
                for entry in entries where !entry.vaultFolder.isEmpty {
                    folders.insert(entry.vaultFolder)
                }
            }
            return folders
        }
    }

    /// Simple LIKE-based search across all non-deleted items.
    /// Searches the first 500 chars of `content` plus the full `ocr_text`
    /// column so image clips whose only searchable signal is recognised
    /// screenshot text are surfaced alongside text clips. Used by Quick
    /// Paste — bypasses FTS so results are always accurate.
    func searchItems(query: String, limit: Int = 50) -> [ClipboardItem] {
        return dbQueue.sync {
            let pattern = "%\(query)%"

            let sql = """
                SELECT * FROM clipboard_items
                WHERE is_deleted = 0
                  AND (
                        LOWER(SUBSTR(content, 1, 500)) LIKE LOWER(?)
                     OR LOWER(ocr_text)               LIKE LOWER(?)
                  )
                ORDER BY is_pinned DESC, created_at DESC
                LIMIT ?;
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var items: [ClipboardItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = parseClipboardItem(from: stmt) {
                    items.append(item)
                }
            }
            print("[LumaClip] searchItems → \(items.count) result(s)")
            return items
        }
    }

    // MARK: - Update Operations

    /// Update an entire clipboard item
    func updateItem(_ item: ClipboardItem) {
        dbQueue.sync {
            let sql = """
                UPDATE clipboard_items SET
                    content = ?,
                    content_type = ?,
                    source_app = ?,
                    expires_at = ?,
                    is_favorite = ?,
                    is_pinned = ?,
                    category_id = ?
                WHERE id = ?;
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, item.content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, item.contentType.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, item.sourceApp, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            
            if let exp = item.expiresAt {
                sqlite3_bind_double(stmt, 4, exp.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            
            sqlite3_bind_int(stmt, 5, item.isFavorite ? 1 : 0)
            sqlite3_bind_int(stmt, 6, item.isPinned ? 1 : 0)
            
            if let catId = item.categoryId {
                sqlite3_bind_text(stmt, 7, catId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            
            sqlite3_bind_text(stmt, 8, item.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[DatabaseService] Update error: \(String(cString: sqlite3_errmsg(db)))")
            }
            
            // Update FTS index with new content
            updateFTSIndex(for: item)
        }
    }

    /// Execute a prepared statement and log any non-DONE result, matching the
    /// error-reporting style used by `updateItem` / `insertItem`.
    @discardableResult
    private func stepChecked(_ stmt: OpaquePointer?, operation: String) -> Bool {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("[DatabaseService] \(operation) error: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    /// Soft-delete an item (move to Trash)
    func softDeleteItem(id: UUID) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET is_deleted = 1, deleted_at = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "softDeleteItem")
        }
    }

    /// Restore an item from Trash
    func restoreItem(id: UUID) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET is_deleted = 0, deleted_at = NULL WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "restoreItem")
        }
    }

    /// Permanently delete an item
    func permanentlyDeleteItem(id: UUID) {
        dbQueue.sync {
            // Remove from FTS
            let ftsSql = "DELETE FROM clipboard_fts WHERE content_id = ?;"
            if let stmt = prepare(ftsSql) {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                stepChecked(stmt, operation: "permanentlyDeleteItem (FTS)")
                sqlite3_finalize(stmt)
            }

            // Remove from main table
            let sql = "DELETE FROM clipboard_items WHERE id = ?;"
            if let stmt = prepare(sql) {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                stepChecked(stmt, operation: "permanentlyDeleteItem")
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Toggle favorite status
    func toggleFavorite(id: UUID, isFavorite: Bool) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET is_favorite = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "toggleFavorite")
        }
    }

    /// Toggle burn-after-paste flag
    func toggleBurnAfterPaste(id: UUID, isBurn: Bool) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET is_burn_after_paste = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isBurn ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "toggleBurnAfterPaste")
        }
    }

    /// Toggle sensitive flag (manual override)
    func toggleSensitive(id: UUID, isSensitive: Bool) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET is_sensitive = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isSensitive ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "toggleSensitive")
        }
    }

    /// Fetch a non-deleted item by its content_hash. Returns nil when
    /// no prior copy exists. Used by ClipboardService on capture to
    /// dedup exact-duplicate clips and promote the existing row to
    /// the top instead of storing a second copy.
    func findByContentHash(_ hash: String) -> ClipboardItem? {
        guard !hash.isEmpty else { return nil }
        return dbQueue.sync {
            let sql = """
                SELECT * FROM clipboard_items
                WHERE content_hash = ? AND is_deleted = 0
                LIMIT 1;
            """
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, hash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return parseClipboardItem(from: stmt)
        }
    }

    /// Find a non-deleted **file** clip whose set of original file paths
    /// matches `sig` (see `FileVaultService.pathSignature`). Used to
    /// replace an existing file clip in place when the same file is copied
    /// again after being edited — so the list never shows two versions of
    /// the same file. File clips are a small subset, so the linear scan is
    /// cheap; matching is done in Swift since the path set isn't a column.
    func findFileClipByPathSignature(_ sig: String) -> ClipboardItem? {
        guard !sig.isEmpty else { return nil }
        return dbQueue.sync {
            let sql = """
                SELECT * FROM clipboard_items
                WHERE content_type = 'file' AND is_deleted = 0
                ORDER BY created_at DESC;
            """
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let item = parseClipboardItem(from: stmt) else { continue }
                if FileVaultService.pathSignature(for: item.fileEntries) == sig {
                    return item
                }
            }
            return nil
        }
    }

    /// Promote an existing item to "just captured" by stamping `created_at`
    /// with the current time. Used in the dedup path so a re-copied clip
    /// rises to the top of the list without leaving a duplicate row.
    func promoteItemToTop(id: UUID, to date: Date = Date()) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET created_at = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "promoteItemToTop")
        }
    }

    /// Store OCR-extracted text for an image clip and rebuild the FTS
    /// entry so the recognized text is searchable. Called from the
    /// background OCR task after `VNRecognizeTextRequest` completes.
    func setOCRText(id: UUID, text: String) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET ocr_text = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "setOCRText")

            // Re-index FTS so newly-recognized text is searchable. Fetch
            // the updated row and replay through updateFTSIndex so the
            // stored content || ocr_text concatenation is rebuilt.
            if let refreshed = fetchItemByIdLocked(id) {
                updateFTSIndex(for: refreshed)
            }
        }
    }

    /// Back-fill `content_hash` for rows captured before the v3 migration.
    /// Invoked by ClipboardService at startup so the dedup path has a
    /// populated index to check against. No-op for rows that already
    /// carry a hash.
    func backfillContentHash(id: UUID, hash: String) {
        guard !hash.isEmpty else { return }
        dbQueue.sync {
            let sql = """
                UPDATE clipboard_items
                SET content_hash = ?
                WHERE id = ? AND content_hash = '';
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, hash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "backfillContentHash")
        }
    }

    /// Fetch one item by id from inside a dbQueue-held context.
    /// Intended only for callers already synchronised on `dbQueue`.
    private func fetchItemByIdLocked(_ id: UUID) -> ClipboardItem? {
        let sql = "SELECT * FROM clipboard_items WHERE id = ? LIMIT 1;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseClipboardItem(from: stmt)
    }

    /// Fetch one item by id (public, thread-safe).
    func fetchItem(id: UUID) -> ClipboardItem? {
        dbQueue.sync { fetchItemByIdLocked(id) }
    }

    /// Fetch all rows that still carry an empty content_hash (pre-v3 rows).
    /// Returns IDs only so the caller can stream them through the hasher
    /// without loading the full content into memory at once.
    func fetchItemsMissingHash(limit: Int = 5_000) -> [(id: UUID, content: String)] {
        dbQueue.sync {
            let sql = """
                SELECT id, content FROM clipboard_items
                WHERE content_hash = '' AND is_deleted = 0
                LIMIT ?;
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [(UUID, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(stmt, 0),
                      let contentStr = sqlite3_column_text(stmt, 1) else { continue }
                if let id = UUID(uuidString: String(cString: idStr)) {
                    rows.append((id, String(cString: contentStr)))
                }
            }
            return rows
        }
    }

    /// Toggle pin status
    func togglePinned(id: UUID, isPinned: Bool) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isPinned ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "togglePinned")
        }
    }

    /// Update item's category
    func updateCategory(itemId: UUID, categoryId: UUID?) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET category_id = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            if let catId = categoryId {
                sqlite3_bind_text(stmt, 1, catId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, itemId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "updateCategory")
        }
    }

    /// Set expiry date for an item
    func setExpiry(itemId: UUID, expiresAt: Date?) {
        dbQueue.sync {
            let sql = "UPDATE clipboard_items SET expires_at = ? WHERE id = ?;"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            if let exp = expiresAt {
                sqlite3_bind_double(stmt, 1, exp.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, itemId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "setExpiry")
        }
    }

    // MARK: - Cleanup Operations

    /// Delete all expired items (soft delete)
    func cleanupExpiredItems() {
        dbQueue.sync {
            let now = Date().timeIntervalSince1970
            let sql = """
                UPDATE clipboard_items
                SET is_deleted = 1, deleted_at = ?
                WHERE expires_at IS NOT NULL AND expires_at < ? AND is_deleted = 0;
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_double(stmt, 2, now)
            stepChecked(stmt, operation: "cleanupExpiredItems")
        }
    }

    /// Permanently remove items that have been in trash longer than the threshold
    func purgeOldTrashItems(olderThanDays days: Int) {
        dbQueue.sync {
            let threshold = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

            // First remove from FTS
            let ftsSql = """
                DELETE FROM clipboard_fts WHERE content_id IN (
                    SELECT id FROM clipboard_items WHERE is_deleted = 1 AND deleted_at < ?
                );
            """
            if let stmt = prepare(ftsSql) {
                sqlite3_bind_double(stmt, 1, threshold)
                stepChecked(stmt, operation: "purgeOldTrashItems (FTS)")
                sqlite3_finalize(stmt)
            }

            // Then remove from main table
            let sql = "DELETE FROM clipboard_items WHERE is_deleted = 1 AND deleted_at < ?;"
            if let stmt = prepare(sql) {
                sqlite3_bind_double(stmt, 1, threshold)
                stepChecked(stmt, operation: "purgeOldTrashItems")
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Trim history to maximum count, keeping favorites and pinned items
    func trimHistory(maxCount: Int) {
        dbQueue.sync {
            let sql = """
                DELETE FROM clipboard_items
                WHERE id IN (
                    SELECT id FROM clipboard_items
                    WHERE is_deleted = 0 AND is_favorite = 0 AND is_pinned = 0
                    ORDER BY created_at DESC
                    LIMIT -1 OFFSET ?
                );
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(maxCount))
            stepChecked(stmt, operation: "trimHistory")
        }
    }

    /// Check if content already exists (for duplicate detection)
    func contentExists(_ content: String) -> Bool {
        return dbQueue.sync {
            let sql = "SELECT COUNT(*) FROM clipboard_items WHERE content = ? AND is_deleted = 0 LIMIT 1;"
            guard let stmt = prepare(sql) else { return false }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqlite3_column_int(stmt, 0) > 0
            }
            return false
        }
    }

    /// Get total count of items
    func itemCount(filter: SidebarFilter = .all) -> Int {
        return dbQueue.sync {
            var sql = "SELECT COUNT(*) FROM clipboard_items WHERE "
            var params: [(Int32, Any)] = []

            switch filter {
            case .all:
                sql += "is_deleted = 0"
            case .favorites:
                sql += "is_deleted = 0 AND is_favorite = 1"
            case .recent:
                sql += "is_deleted = 0 AND created_at > ?"
                params.append((1, Date().addingTimeInterval(-86400).timeIntervalSince1970))
            case .category(let id):
                sql += "is_deleted = 0 AND category_id = ?"
                params.append((1, id.uuidString))
            case .trash:
                sql += "is_deleted = 1"
            case .bundles:
                // Bundles feature not yet implemented in database
                return 0
            case .settings:
                return 0
            }
            sql += ";"

            guard let stmt = prepare(sql) else { return 0 }
            defer { sqlite3_finalize(stmt) }

            for (index, value) in params {
                if let str = value as? String {
                    sqlite3_bind_text(stmt, index, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else if let dbl = value as? Double {
                    sqlite3_bind_double(stmt, index, dbl)
                }
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        }
    }

    // MARK: - Category CRUD

    /// Insert a new category
    func insertCategory(_ category: Category) {
        dbQueue.sync {
            let sql = "INSERT OR REPLACE INTO categories (id, name, icon, color) VALUES (?, ?, ?, ?);"
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, category.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, category.name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, category.icon, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, category.color.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            stepChecked(stmt, operation: "insertCategory")
        }
    }

    /// Fetch all categories
    func fetchCategories() -> [Category] {
        return dbQueue.sync {
            let sql = "SELECT id, name, icon, color FROM categories ORDER BY name;"
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }

            var categories: [Category] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(stmt, 0),
                      let nameStr = sqlite3_column_text(stmt, 1),
                      let iconStr = sqlite3_column_text(stmt, 2),
                      let colorStr = sqlite3_column_text(stmt, 3)
                else { continue }

                let category = Category(
                    id: UUID(uuidString: String(cString: idStr)) ?? UUID(),
                    name: String(cString: nameStr),
                    icon: String(cString: iconStr),
                    color: CategoryColor(rawValue: String(cString: colorStr)) ?? .blue
                )
                categories.append(category)
            }
            return categories
        }
    }

    /// Delete a category
    func deleteCategory(id: UUID) {
        dbQueue.sync {
            // Clear category from items first
            let clearSql = "UPDATE clipboard_items SET category_id = NULL WHERE category_id = ?;"
            if let stmt = prepare(clearSql) {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                stepChecked(stmt, operation: "deleteCategory (clear items)")
                sqlite3_finalize(stmt)
            }

            // Delete category
            let sql = "DELETE FROM categories WHERE id = ?;"
            if let stmt = prepare(sql) {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                stepChecked(stmt, operation: "deleteCategory")
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Retention Rules CRUD

    /// Insert or update a retention rule
    func insertRetentionRule(_ rule: RetentionRule) {
        dbQueue.sync {
            var targetType = "all"
            var targetValue = ""

            switch rule.target {
            case .contentType(let ct):
                targetType = "contentType"
                targetValue = ct.rawValue
            case .category(let id):
                targetType = "category"
                targetValue = id.uuidString
            case .all:
                targetType = "all"
            case .sourceApp(let name):
                targetType = "sourceApp"
                targetValue = name
            }

            let sql = """
                INSERT OR REPLACE INTO retention_rules
                (id, target_type, target_value, duration, is_enabled)
                VALUES (?, ?, ?, ?, ?);
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, rule.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, targetType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, targetValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 4, rule.duration)
            sqlite3_bind_int(stmt, 5, rule.isEnabled ? 1 : 0)
            stepChecked(stmt, operation: "insertRetentionRule")
        }
    }

    /// Fetch all retention rules
    func fetchRetentionRules() -> [RetentionRule] {
        return dbQueue.sync {
            let sql = "SELECT id, target_type, target_value, duration, is_enabled FROM retention_rules;"
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }

            var rules: [RetentionRule] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(stmt, 0),
                      let typeStr = sqlite3_column_text(stmt, 1),
                      let valueStr = sqlite3_column_text(stmt, 2)
                else { continue }

                let targetType = String(cString: typeStr)
                let targetValue = String(cString: valueStr)
                let duration = sqlite3_column_double(stmt, 3)
                let isEnabled = sqlite3_column_int(stmt, 4) != 0

                let target: RetentionTarget
                switch targetType {
                case "contentType":
                    target = .contentType(ContentType(rawValue: targetValue) ?? .text)
                case "category":
                    target = .category(UUID(uuidString: targetValue) ?? UUID())
                case "sourceApp":
                    target = .sourceApp(targetValue)
                default:
                    target = .all
                }

                let rule = RetentionRule(
                    id: UUID(uuidString: String(cString: idStr)) ?? UUID(),
                    target: target,
                    duration: duration,
                    isEnabled: isEnabled
                )
                rules.append(rule)
            }
            return rules
        }
    }

    /// Delete a retention rule
    func deleteRetentionRule(id: UUID) {
        dbQueue.sync {
            let sql = "DELETE FROM retention_rules WHERE id = ?;"
            if let stmt = prepare(sql) {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                stepChecked(stmt, operation: "deleteRetentionRule")
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Backup Support

    /// Fetch every clipboard item — including trashed rows — for a
    /// full backup export. Ordered oldest-first so a restore replays
    /// items in their original capture order.
    func fetchAllItemsForBackup() -> [ClipboardItem] {
        return dbQueue.sync {
            let sql = "SELECT * FROM clipboard_items ORDER BY created_at ASC, id ASC;"
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }

            var items: [ClipboardItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = parseClipboardItem(from: stmt) {
                    items.append(item)
                }
            }
            return items
        }
    }

    /// Set of every item UUID in the table (active and trashed).
    /// Used by restore-merge to skip rows that already exist without
    /// loading full item content into memory.
    func allItemIDs() -> Set<UUID> {
        return dbQueue.sync {
            let sql = "SELECT id FROM clipboard_items;"
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }

            var ids = Set<UUID>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = sqlite3_column_text(stmt, 0),
                   let id = UUID(uuidString: String(cString: idStr)) {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    // MARK: - Statistics

    /// Get item counts grouped by content type
    func itemCountsByType() -> [ContentType: Int] {
        return dbQueue.sync {
            let sql = "SELECT content_type, COUNT(*) FROM clipboard_items WHERE is_deleted = 0 GROUP BY content_type;"
            guard let stmt = prepare(sql) else { return [:] }
            defer { sqlite3_finalize(stmt) }

            var counts: [ContentType: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let typeStr = sqlite3_column_text(stmt, 0) {
                    let ct = ContentType(rawValue: String(cString: typeStr)) ?? .unknown
                    counts[ct] = Int(sqlite3_column_int(stmt, 1))
                }
            }
            return counts
        }
    }
}
