//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    
    private var monitorTask: Task<Void, Never>?
    private var lastSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var cancellables: Set<AnyCancellable> = []
    
    private init() {
        Defaults.publisher(.hideNotchOption, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatus(with: self.lastSpaces)
            }
            .store(in: &cancellables)
        MusicManager.shared.$bundleIdentifier
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatus(with: self.lastSpaces)
            }
            .store(in: &cancellables)
        startMonitoring()
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                lastSpaces = spaces
                updateStatus(with: spaces)
            }
        }
    }
    
    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        var newStatus: [String: Bool] = [:]
        let option = Defaults[.hideNotchOption]
        let musicSourceBundle = MusicManager.shared.bundleIdentifier
        
        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                switch option {
                case .nowPlayingOnly:
                    shouldDetect = musicSourceBundle.map { space.runningApps.contains($0) } ?? false
                case .always:
                    shouldDetect = true
                case .never:
                    shouldDetect = false
                }
                newStatus[uuid] = shouldDetect
            }
        }
        
        if self.fullscreenStatus != newStatus {
            self.fullscreenStatus = newStatus
        }
    }
}

