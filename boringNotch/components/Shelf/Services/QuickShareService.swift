//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

class QuickShareService: ObservableObject {
    static let shared = QuickShareService()
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    private var cachedServices: [String: NSSharingService] = [:]
    // Hold security-scoped URLs during sharing
    private var sharingAccessingURLs: [URL] = []
    private var lifecycleDelegate: SharingLifecycleDelegate?
   
    init() {
        Task {
            await discoverAvailableProviders()
        }
    }
    
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []
        var nextCached: [String: NSSharingService] = [:]

        for svc in services {
            let title = svc.title
            let imgData = svc.image.tiffRepresentation
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                nextCached[title] = svc
            }
        }
        cachedServices = nextCached
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        let zeroStIcon = NSImage(systemSymbolName: "link.icloud.fill", accessibilityDescription: "0x0.st")?.tiffRepresentation
        let gravityQuickshare = QuickShareProvider(id: "Gravity Quickshare (0x0.st)", imageData: zeroStIcon, supportsRawText: true)
        if !providers.contains(where: { $0.id == gravityQuickshare.id }) {
            providers.insert(gravityQuickshare, at: min(1, providers.count))
        }

        if !providers.contains(where: { $0.id == "System Share Menu" }) {
            providers.append(QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select Files for \(provider.id)"
        panel.message = "Choose files to share via \(provider.id)"

        let response = panel.runModal()
        isPickerOpen = false
        if response == .OK && !panel.urls.isEmpty {
            // Keep interaction open through shareFilesOrText handoff so the notch does not close before picker.show
            await shareFilesOrText(panel.urls, using: provider, from: view)
        }
        SharingStateManager.shared.endInteraction()
    }
    
    // MARK: - Sharing
    @MainActor
    func shareFilesOrText(
        _ items: [Any],
        using provider: QuickShareProvider,
        from view: NSView?,
        temporaryCleanupURLs: [URL] = []
    ) async {
        let cleanupTemps = {
            for tempURL in temporaryCleanupURLs {
                TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempURL)
            }
        }
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        if provider.id == "Gravity Quickshare (0x0.st)" {
            defer { cleanupTemps() }
            if !fileURLs.isEmpty {
                await uploadTo0x0(urls: fileURLs)
                return
            } else if let text = items.compactMap({ $0 as? String }).first,
                      let tempURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                await uploadTo0x0(urls: [tempURL])
                TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempURL)
                return
            }
        }

        let directService: NSSharingService? = {
            if let svc = cachedServices[provider.id], svc.canPerform(withItems: items) {
                return svc
            }
            if provider.id == "AirDrop",
               let airDrop = NSSharingService(named: .sendViaAirDrop),
               airDrop.canPerform(withItems: items) {
                return airDrop
            }
            return nil
        }()

        // Guard view attachment BEFORE opening security scopes or preventNotchClose for picker fallback
        if directService == nil {
            guard let view, view.window != nil else {
                cleanupTemps()
                return
            }
        }

        // Stop any previous sharing access
        stopSharingAccessingURLs()
        // Start security-scoped access for all file URLs
        let accessed = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
        sharingAccessingURLs = accessed

        // Setup lifecycle delegate to keep notch open during picker/service and clean temp files only when done
        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in
            for url in accessed {
                url.stopAccessingSecurityScopedResource()
            }
            if let self {
                self.sharingAccessingURLs.removeAll { accessed.contains($0) }
                self.lifecycleDelegate = nil
            }
            cleanupTemps()
        }
        lifecycleDelegate = delegate

        if let svc = directService {
            delegate.markServiceBegan()
            svc.delegate = delegate
            svc.perform(withItems: items)
        } else if let view, view.window != nil {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    private func stopSharingAccessingURLs() {
        NSLog("Stopping sharing access to URLs")
        for url in sharingAccessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        sharingAccessingURLs.removeAll()
    }
// MARK: - SharingServiceDelegate

private class SharingServiceDelegate: NSObject {}
    
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        var itemsToShare: [Any] = []
        var tempCleanupURLs: [URL] = []

        for provider in providers {
            // Check file URLs BEFORE generic web URLs (UTType.fileURL conforms to UTType.url)
            let extractedFileURL: URL?
            if let url = await provider.extractFileURL() {
                extractedFileURL = url
            } else {
                extractedFileURL = await provider.extractItem()
            }
            if let itemFileURL = extractedFileURL {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            } else if let webURL = await provider.extractURL() {
                if webURL.isFileURL {
                    let resolvedURL = await resolveShelfItemBookmark(for: webURL) ?? webURL
                    itemsToShare.append(resolvedURL)
                } else {
                    itemsToShare.append(webURL)
                }
            } else if let text = await provider.extractText() {
                if shareProvider.supportsRawText {
                    itemsToShare.append(text)
                } else if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    itemsToShare.append(tempTextURL)
                    tempCleanupURLs.append(tempTextURL)
                } else {
                    itemsToShare.append(text)
                }
            } else if let rawData = await provider.loadData(),
                      let tempURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(rawData, suggestedName: provider.suggestedName)) {
                itemsToShare.append(tempURL)
                tempCleanupURLs.append(tempURL)
            }
        }

        if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view, temporaryCleanupURLs: tempCleanupURLs)
        } else {
            for tempURL in tempCleanupURLs {
                TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempURL)
            }
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }

    // MARK: - Gravity Quickshare (0x0.st Cloud Link Upload)

    @MainActor
    func uploadTo0x0(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        SharingStateManager.shared.beginInteraction()
        defer { SharingStateManager.shared.endInteraction() }

        do {
            let singleIsDirectory: Bool = {
                guard urls.count == 1 else { return false }
                return urls[0].accessSecurityScopedResource { scoped in
                    (try? scoped.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }
            }()
            let targetURL: URL
            var tempZipURL: URL?
            if urls.count > 1 || singleIsDirectory {
                guard let zipped = await urls.accessSecurityScopedResources(accessor: { accessible in
                    await TemporaryFileStorageService.shared.createZip(from: accessible)
                }) else {
                    throw NSError(domain: "QuickShare", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to archive selection before upload"])
                }
                targetURL = zipped
                tempZipURL = zipped
            } else {
                targetURL = urls[0]
            }

            defer {
                if let tempZipURL {
                    TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempZipURL)
                }
            }

            let rawFilename = targetURL.lastPathComponent
            let safeFilename = rawFilename
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let boundary = "Boundary-\(UUID().uuidString)"
            let maxUploadBytes: Int64 = 512 * 1024 * 1024

            // Stream file into a temporary multipart body file off @MainActor to avoid doubling memory on the main thread
            let multipartFileURL: URL = try await Task.detached(priority: .userInitiated) {
                try targetURL.accessSecurityScopedResource { scoped in
                    let attrs = try FileManager.default.attributesOfItem(atPath: scoped.path)
                    if let fileSize = attrs[.size] as? Int64, fileSize > maxUploadBytes {
                        throw NSError(domain: "QuickShare", code: -3, userInfo: [NSLocalizedDescriptionKey: "File exceeds 0x0.st 512 MiB limit"])
                    }
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("quickshare_upload_\(UUID().uuidString).tmp")
                    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                    do {
                        let outHandle = try FileHandle(forWritingTo: tempURL)
                        defer { try? outHandle.close() }
                        let inHandle = try FileHandle(forReadingFrom: scoped)
                        defer { try? inHandle.close() }

                        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                        try outHandle.write(contentsOf: Data(header.utf8))
                        while let chunk = try inHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                            try outHandle.write(contentsOf: chunk)
                        }
                        try outHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
                        return tempURL
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        throw error
                    }
                }
            }.value

            defer { try? FileManager.default.removeItem(at: multipartFileURL) }

            var request = URLRequest(url: URL(string: "https://0x0.st")!)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("BoringNotch/1.0 (GravityQuickshare)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: multipartFileURL)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode),
                  let link = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  link.hasPrefix("http") else {
                throw NSError(domain: "QuickShare", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload rejected by 0x0.st"])
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)

            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quickshare Link Copied!"
            alert.informativeText = "\(rawFilename) uploaded to:\n\(link)\n\nThe link has been copied to your clipboard."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open in Browser")
            if alert.runModal() == .alertSecondButtonReturn, let webURL = URL(string: link) {
                NSWorkspace.shared.open(webURL)
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quickshare Upload Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        let svc = QuickShareService.shared

        if let airdrop = svc.availableProviders.first(where: { $0.id == "AirDrop" }) {
            return airdrop
        }
        return svc.availableProviders.first ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }
}
