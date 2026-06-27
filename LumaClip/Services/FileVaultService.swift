// FileVaultService.swift
// LumaClip - macOS Clipboard Manager
//
// Manages LumaClip's on-disk "file vault" — the place copied files are
// saved so they survive the original being moved or deleted. Lives at
//   Application Support/LumaClip/Files/<sha-prefix>/<original-name>
//
// Hybrid policy: files at or below `AppSettings.fileVaultMaxMB` are
// copied into the vault (stored = true); larger files and folders are
// kept as a reference to their original path only (stored = false), so
// the vault never balloons with multi-GB payloads.
//
// Content-hash folder names give cheap dedup: copying the same file
// twice reuses one vault folder. A garbage collector removes vault
// folders no longer referenced by any database row (the cleanup path
// for bulk deletes like history-trim and trash-purge, which don't
// enumerate individual rows).

import Foundation
import CryptoKit

final class FileVaultService {
    static let shared = FileVaultService()

    private let fm = FileManager.default
    private let settings = AppSettings.shared

    /// Serial queue so concurrent captures don't race on the same
    /// vault folder or on garbage collection.
    private let queue = DispatchQueue(label: "com.lumaclip.fileVault", qos: .utility)

    private init() {
        try? fm.createDirectory(at: vaultDirURL, withIntermediateDirectories: true)
    }

    // MARK: - Locations

    /// Root of the file vault: Application Support/LumaClip/Files/
    var vaultDirURL: URL {
        let base = DatabaseService.storageDirectoryURL
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LumaClip", isDirectory: true)
        return base.appendingPathComponent("Files", isDirectory: true)
    }

    // MARK: - Ingest

    /// Copy (or reference) the given file URLs and return the resulting
    /// `[FileEntry]`. Non-existent URLs are skipped. Regular files within
    /// the size threshold are copied into the vault; everything else
    /// (large files, directories, copy failures) is stored as a
    /// reference to its original path.
    func ingest(urls: [URL]) -> [FileEntry] {
        return queue.sync {
            var entries: [FileEntry] = []
            let thresholdBytes = Int64(max(0, settings.fileVaultMaxMB)) * 1024 * 1024

            for url in urls {
                let path = url.path
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }

                let name = url.lastPathComponent
                let size = isDir.boolValue ? 0 : fileSize(at: url)

                // Reference-only: folders, or files above the threshold.
                if isDir.boolValue || size > thresholdBytes {
                    entries.append(FileEntry(
                        name: name,
                        byteSize: size,
                        stored: false,
                        vaultPath: "",
                        originalPath: path
                    ))
                    continue
                }

                // Copy into the vault under a content-hash folder.
                if let vaultPath = copyIntoVault(url: url, name: name) {
                    entries.append(FileEntry(
                        name: name,
                        byteSize: size,
                        stored: true,
                        vaultPath: vaultPath,
                        originalPath: path
                    ))
                } else {
                    // Copy failed — fall back to a reference so the clip
                    // is still usable while the original exists.
                    entries.append(FileEntry(
                        name: name,
                        byteSize: size,
                        stored: false,
                        vaultPath: "",
                        originalPath: path
                    ))
                }
            }
            return entries
        }
    }

    /// Copy a single file into `Files/<hash-prefix>/<name>`, deduping
    /// when the exact same content+name already lives there. Returns the
    /// vault-relative path ("<folder>/<name>") or nil on failure.
    private func copyIntoVault(url: URL, name: String) -> String? {
        guard let hash = sha256Hex(of: url) else { return nil }
        let folder = String(hash.prefix(32))          // 128 bits — ample
        let folderURL = vaultDirURL.appendingPathComponent(folder, isDirectory: true)
        let destURL = folderURL.appendingPathComponent(name)
        let relativePath = "\(folder)/\(name)"

        // Dedup: identical content + name already present.
        if fm.fileExists(atPath: destURL.path) { return relativePath }

        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: destURL)
            return relativePath
        } catch {
            print("[FileVault] Copy failed for \(name): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Resolve (for paste-back / reveal)

    /// The best on-disk URL for an entry: its vault copy if present,
    /// otherwise the original path if it still exists. Returns nil when
    /// neither is available (vault GC'd a reference clip's missing file).
    func resolveURL(for entry: FileEntry) -> URL? {
        if entry.stored, !entry.vaultPath.isEmpty {
            let url = vaultDirURL.appendingPathComponent(entry.vaultPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if !entry.originalPath.isEmpty,
           fm.fileExists(atPath: entry.originalPath) {
            return URL(fileURLWithPath: entry.originalPath)
        }
        return nil
    }

    /// Resolve every entry of a clip to a usable URL, dropping any that
    /// can no longer be found.
    func resolveURLs(for entries: [FileEntry]) -> [URL] {
        entries.compactMap { resolveURL(for: $0) }
    }

    // MARK: - Dedup / replace signatures for a file clip

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// **Content identity** of a file clip: same file name(s) + same
    /// bytes → same value, regardless of where the files live. Stored as
    /// the clip's `content_hash` so re-copying the identical file (even
    /// from another folder) is detected as a duplicate and promoted
    /// instead of stored twice. For vaulted files the vault folder name
    /// *is* the content hash; reference-only files fall back to size.
    static func contentSignature(for entries: [FileEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let sig = entries.map { e -> String in
            if e.stored, !e.vaultFolder.isEmpty {
                return "h:\(e.vaultFolder):\(e.name)"
            }
            return "s:\(e.byteSize):\(e.name)"
        }.sorted().joined(separator: "\n")
        return sha(sig)
    }

    /// **Location identity** of a file clip: the set of original file
    /// paths, independent of content. Lets capture detect that the *same
    /// file* was copied again after being edited, so the previous clip is
    /// replaced in place rather than leaving two versions on the list.
    static func pathSignature(for entries: [FileEntry]) -> String {
        let paths = entries.map { $0.originalPath }.filter { !$0.isEmpty }.sorted()
        guard !paths.isEmpty else { return "" }
        return sha(paths.joined(separator: "\n"))
    }

    // MARK: - Garbage Collection

    /// Remove vault folders not referenced by any database row. Safe to
    /// call any time; it only deletes orphans. Runs off the main thread.
    func garbageCollect() {
        queue.async { [weak self] in
            guard let self else { return }
            let referenced = DatabaseService.shared.allReferencedVaultFolders()
            guard let contents = try? self.fm.contentsOfDirectory(
                at: self.vaultDirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            var removed = 0
            for folderURL in contents {
                let folderName = folderURL.lastPathComponent
                if referenced.contains(folderName) { continue }
                do {
                    try self.fm.removeItem(at: folderURL)
                    removed += 1
                } catch {
                    print("[FileVault] GC failed to remove \(folderName): \(error.localizedDescription)")
                }
            }
            if removed > 0 {
                print("[FileVault] GC removed \(removed) orphaned vault folder(s)")
            }
        }
    }

    // MARK: - Helpers

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Streaming SHA-256 of a file's contents so large files don't get
    /// loaded fully into memory. Returns nil if the file can't be read.
    private func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)   // 1 MB chunks
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
