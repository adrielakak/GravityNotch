//
//  AppleScriptHelper.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

class AppleScriptHelper {
    /// NSAppleScript is not thread-safe: two scripts running at the same time crash inside AppleEvents
    /// (seen when spamming next track). Every script of the app runs on this one serial queue.
    static let queue = DispatchQueue(label: "gravitynotch.applescript", qos: .userInitiated)

    @discardableResult
    class func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script = NSAppleScript(source: scriptText)
                var error: NSDictionary?
                if let descriptor = script?.executeAndReturnError(&error) {
                    continuation.resume(returning: descriptor)
                } else if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }

    class func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}
