//
//  ApplicationRelauncher.swift
//  boringNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

enum ApplicationRelauncher {
    static func restart() {
        let workspace = NSWorkspace.shared
        let appURL = Bundle.main.bundleURL

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)

        NSApplication.shared.terminate(nil)
    }
}
