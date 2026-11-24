//
//  TemporaryFileStorageService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    
    // MARK: - Public Interface
    
    /// Creates a temporary file and tracks it for manual cleanup
    func createTempFile(for type: TempFileType) async -> URL? {
        return await withCheckedContinuation { continuation in
            let result = createTempFile(for: type)
            continuation.resume(returning: result)
        }
    }
    
    func removeTemporaryFileIfNeeded(at url: URL) {
        let normalizedTemp = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let normalizedURL = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let tempPrefix = normalizedTemp.path.hasSuffix("/") ? normalizedTemp.path : normalizedTemp.path + "/"

        guard normalizedURL.path.hasPrefix(tempPrefix) else {
            print("Attempted to remove temporary file outside temp directory: \(url.path)")
            return
        }

        let folderURL = normalizedURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL

        do {
            if FileManager.default.fileExists(atPath: normalizedURL.path) {
                try FileManager.default.removeItem(at: normalizedURL)
            }

            // Never delete NSTemporaryDirectory() itself; only remove dedicated UUID subdirectories when empty
            if folderURL != normalizedTemp {
                let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
                if contents.isEmpty {
                    try FileManager.default.removeItem(at: folderURL)
                }
            }
        } catch {
            print("Error removing temp file: \(error.localizedDescription)")
        }
    }

    private func sanitizedFilename(_ raw: String?, fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        let cleaned = URL(fileURLWithPath: raw).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return fallback
        }
        return cleaned
    }
    
    // MARK: - Private Implementation
    
    private func createTempFile(for type: TempFileType) -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let uuid = UUID().uuidString
        
        switch type {
        case .data(let data, let suggestedName):
            let filename = sanitizedFilename(suggestedName, fallback: "Item_\(uuid.prefix(8)).dat")
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                return nil
            }
            
        case .text(let string):
            let filename = "\(uuid).txt"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            guard let data = string.data(using: .utf8) else {
                print("❌ Failed to convert text to data")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                return nil
            }
            
        case .url(let url):
            let filename = "\(sanitizedFilename(url.host, fallback: uuid)).webloc"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            let weblocContent = createWeblocContent(for: url)
            guard let data = weblocContent.data(using: String.Encoding.utf8) else {
                print("❌ Failed to create webloc data")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                return nil
            }
        }
    }
    
    private func createFile(at url: URL, data: Data) -> URL? {
        do {
            try data.write(to: url)
            return url
        } catch {
            print("❌ Failed to create temp file at \(url.path): \(error)")
            return nil
        }
    }

    func createZip(from urls: [URL], suggestedName: String? = nil) async -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let uuid = UUID().uuidString
        let workingDir = tempDir.appendingPathComponent("zip_\(uuid)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create zip working directory: \(error)")
            return nil
        }

        // Run zip off the cooperative thread pool using terminationHandler
        func runZip(arguments: [String], currentDirectory: URL) async -> Bool {
            await withCheckedContinuation { continuation in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                proc.arguments = arguments
                proc.currentDirectoryURL = currentDirectory
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                proc.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus == 0)
                }
                do {
                    try proc.run()
                } catch {
                    print("❌ Failed to run zip: \(error)")
                    proc.terminationHandler = nil
                    continuation.resume(returning: false)
                }
            }
        }

        // Single-item optimization: do not copy contents into the working dir.
        if urls.count == 1, let src = urls.first {
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let baseName = src.lastPathComponent
            let archiveName = sanitizedFilename("\(baseName).zip", fallback: "Archive.zip")
            let archiveURL = workingDir.appendingPathComponent(archiveName)
            let parent = src.deletingLastPathComponent()
            // -y preserves symlinks (avoids infinite recursion on cyclic links); -- guards leading '-' filenames
            let args = isDir
                ? ["-r", "-y", "-q", archiveURL.path, "--", baseName]
                : ["-j", "-y", "-q", archiveURL.path, "--", baseName]
            let ok = await runZip(arguments: args, currentDirectory: parent)
            if ok {
                return archiveURL
            } else {
                try? FileManager.default.removeItem(at: workingDir)
                return nil
            }
        }

        // Multi-item: stage copies in a dedicated subfolder so the output Archive.zip never collides with an input
        let stagingDir = workingDir.appendingPathComponent("staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: workingDir)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        for src in urls {
            let dest = stagingDir.appendingPathComponent(src.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    let unique = "\(UUID().uuidString)_\(src.lastPathComponent)"
                    try FileManager.default.copyItem(at: src, to: stagingDir.appendingPathComponent(unique))
                } else {
                    try FileManager.default.copyItem(at: src, to: dest)
                }
            } catch {
                print("⚠️ Failed to copy \(src.path) to staging dir: \(error)")
            }
        }

        let archiveName = sanitizedFilename(suggestedName, fallback: "Archive.zip")
        let archiveURL = workingDir.appendingPathComponent(archiveName)
        let args = ["-r", "-y", "-q", archiveURL.path, "."]
        let ok = await runZip(arguments: args, currentDirectory: stagingDir)
        if ok {
            return archiveURL
        } else {
            try? FileManager.default.removeItem(at: workingDir)
            return nil
        }
    }
    
    // MARK: - Content Creation Helpers
    
    
    private func createWeblocContent(for url: URL) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>URL</key>
            <string>\(url.absoluteString)</string>
        </dict>
        </plist>
        """
    }
}
