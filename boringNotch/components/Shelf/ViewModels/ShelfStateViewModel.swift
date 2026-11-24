//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { ShelfPersistenceService.shared.save(items) }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    private var resolvedURLCache: [ShelfItem.ID: URL] = [:]

    private init() {
        items = ShelfPersistenceService.shared.load()
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem, deferTempFileCleanup: Bool = false) {
        remove([item], deferTempFileCleanup: deferTempFileCleanup)
    }

    func remove(_ toRemove: [ShelfItem], deferTempFileCleanup: Bool = false) {
        guard !toRemove.isEmpty else { return }
        let removeIDs = Set(toRemove.map(\.id))
        var urlsToEvict: [URL] = []
        for item in toRemove {
            if let cached = resolvedURLCache.removeValue(forKey: item.id) ?? item.fileURL {
                urlsToEvict.append(cached)
            }
            if deferTempFileCleanup && item.isTemporary {
                let captured = item
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    captured.cleanupStoredData()
                }
            } else {
                item.cleanupStoredData()
            }
        }
        ShelfSelectionModel.shared.deselect(removeIDs)
        if !urlsToEvict.isEmpty {
            Task {
                for url in urlsToEvict {
                    await ThumbnailService.shared.clearCache(for: url)
                }
            }
        }
        items.removeAll { removeIDs.contains($0.id) }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let oldURL = resolvedURLCache.removeValue(forKey: item.id) {
            Task { await ThumbnailService.shared.clearCache(for: oldURL) }
        }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self, !self.pendingBookmarkUpdates.isEmpty else { return }
            
            var updated = self.items
            var didChange = false
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                self.resolvedURLCache.removeValue(forKey: itemID)
                if let idx = updated.firstIndex(where: { $0.id == itemID }),
                   case .file = updated[idx].kind {
                    updated[idx].kind = .file(bookmark: bookmarkData)
                    didChange = true
                }
            }
            self.pendingBookmarkUpdates.removeAll()
            if didChange {
                self.items = updated
            }
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        let snapshot = self.items
        Task { [weak self] in
            guard let self else { return }
            var invalidIDs: Set<ShelfItem.ID> = []
            for item in snapshot {
                if case .file(let data) = item.kind {
                    let bookmark = Bookmark(data: data)
                    if !(await bookmark.validate()) {
                        invalidIDs.insert(item.id)
                    }
                }
            }
            guard !invalidIDs.isEmpty else { return }
            await MainActor.run {
                let toDrop = self.items.filter { invalidIDs.contains($0.id) }
                guard !toDrop.isEmpty else { return }
                self.remove(toDrop)
            }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        if let cached = resolvedURLCache[item.id] {
            return cached
        }
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        if let url = result.url {
            resolvedURLCache[item.id] = url
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        if let url = result.url {
            resolvedURLCache[item.id] = url
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
