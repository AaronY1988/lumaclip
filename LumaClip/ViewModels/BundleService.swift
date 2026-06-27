// BundleService.swift
// LumaClip - macOS Clipboard Manager
//
// Service for managing clipboard bundles - creating, editing,
// deleting, and persisting bundle collections.

import Foundation
import Combine

// MARK: - Bundle Service

@MainActor
final class BundleService: ObservableObject {
    static let shared = BundleService()
    
    // MARK: - Published State
    
    /// All saved bundles
    @Published private(set) var bundles: [ClipBundle] = []
    
    // MARK: - Private Properties
    
    private let bundlesKey = "com.lumaclip.bundles"
    private let fileManager = FileManager.default
    private var bundlesFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("LumaClip", isDirectory: true)
        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent("bundles.json")
    }
    
    // MARK: - Initialization
    
    private init() {
        loadBundles()
    }
    
    // MARK: - Persistence
    
    /// Load bundles from disk
    private func loadBundles() {
        guard fileManager.fileExists(atPath: bundlesFileURL.path) else {
            bundles = []
            return
        }
        
        do {
            let data = try Data(contentsOf: bundlesFileURL)
            let decoder = JSONDecoder()
            bundles = try decoder.decode([ClipBundle].self, from: data)
        } catch {
            print("[BundleService] Error loading bundles: \(error.localizedDescription)")
            bundles = []
        }
    }
    
    /// Save bundles to disk
    private func saveBundles() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(bundles)
            try data.write(to: bundlesFileURL, options: .atomic)
        } catch {
            print("[BundleService] Error saving bundles: \(error.localizedDescription)")
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Save a new or updated bundle
    func save(_ bundle: ClipBundle) {
        if let index = bundles.firstIndex(where: { $0.id == bundle.id }) {
            // Update existing bundle
            var updated = bundle
            updated.modifiedAt = Date()
            bundles[index] = updated
        } else {
            // Add new bundle
            bundles.append(bundle)
        }
        saveBundles()
    }
    
    /// Delete a bundle
    func delete(_ bundle: ClipBundle) {
        bundles.removeAll { $0.id == bundle.id }
        saveBundles()
    }
    
    /// Get a bundle by ID
    func bundle(withID id: UUID) -> ClipBundle? {
        bundles.first { $0.id == id }
    }
    
    /// Update bundle name
    func updateName(_ name: String, for bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        bundles[index].name = name
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    /// Update bundle icon
    func updateIcon(_ icon: String, for bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        bundles[index].icon = icon
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    /// Update bundle color
    func updateColor(_ colorName: String, for bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        bundles[index].colorName = colorName
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    // MARK: - Item Management
    
    /// Append an item to a bundle
    func appendItem(_ itemID: UUID, to bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        guard !bundles[index].itemIDs.contains(itemID) else { return }
        bundles[index].itemIDs.append(itemID)
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    /// Remove an item from a bundle
    func removeItem(_ itemID: UUID, from bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        bundles[index].itemIDs.removeAll { $0 == itemID }
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    /// Reorder items in a bundle
    func reorderItems(_ itemIDs: [UUID], in bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        bundles[index].itemIDs = itemIDs
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    /// Replace all items in a bundle
    func setItems(_ itemIDs: [UUID], for bundleID: UUID) {
        guard let index = bundles.firstIndex(where: { $0.id == bundleID }) else { return }
        bundles[index].itemIDs = itemIDs
        bundles[index].modifiedAt = Date()
        saveBundles()
    }
    
    /// Import bundles from a backup archive, skipping any whose ID
    /// already exists (merge semantics — nothing is overwritten).
    /// Returns the number of bundles actually added.
    func importBundles(_ incoming: [ClipBundle]) -> Int {
        let existingIDs = Set(bundles.map(\.id))
        let newBundles = incoming.filter { !existingIDs.contains($0.id) }
        guard !newBundles.isEmpty else { return 0 }
        bundles.append(contentsOf: newBundles)
        saveBundles()
        return newBundles.count
    }

    // MARK: - Validation
    
    /// Check if a bundle name already exists
    func nameExists(_ name: String, excluding bundleID: UUID? = nil) -> Bool {
        bundles.contains { bundle in
            bundle.name.lowercased() == name.lowercased() && bundle.id != bundleID
        }
    }
    
    /// Clean up item IDs that no longer exist in the database
    func cleanupInvalidItems(validItemIDs: Set<UUID>) {
        var didChange = false
        
        for index in bundles.indices {
            let originalCount = bundles[index].itemIDs.count
            bundles[index].itemIDs = bundles[index].itemIDs.filter { validItemIDs.contains($0) }
            
            if bundles[index].itemIDs.count != originalCount {
                bundles[index].modifiedAt = Date()
                didChange = true
            }
        }
        
        if didChange {
            saveBundles()
        }
    }
}
