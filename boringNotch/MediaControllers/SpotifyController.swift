//
//  SpotifyController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class SpotifyController: MediaControllerProtocol {
    func setFavorite(_ favorite: Bool) async {
        //Placeholder
    }
    
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.spotify.client"
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool { false }

    private var notificationTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    
    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    
    init() {
        setupPlaybackStateChangeObserver()
        setupTerminationObserver()
        Task { @MainActor [weak self] in
            guard let self, self.isActive() else { return }
            await self.updatePlaybackInfo()
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @MainActor [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            
            for await notification in notifications {
                guard let self else { return }
                if (notification.userInfo?["Player State"] as? String) == "Stopped" || !self.isActive() {
                    self.resetToIdleState()
                    continue
                }
                await self.updatePlaybackInfo()
            }
        }
    }

    private func setupTerminationObserver() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.spotify.client" else { return }
            MainActor.assumeIsolated {
                self?.resetToIdleState()
            }
        }
    }

    // State and tasks are only touched on the main actor (concurrent mutation crashed the app).
    @MainActor
    private func resetToIdleState() {
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        lastArtworkURL = nil
        playbackState = .idle(bundleIdentifier: "com.spotify.client")
    }
    
    deinit {
        notificationTask?.cancel()
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        artworkFetchTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }
    
    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }
    
    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }
    
    func toggleRepeat() async {
        await executeAndRefresh("set repeating to not repeating")
    }
    
    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }
    
    @MainActor
    func updatePlaybackInfo() async {
        guard isActive() else {
            resetToIdleState()
            return
        }
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        // Spotify quit while the script ran: its answer would bring the closed player back as playing
        guard isActive(), descriptor.numberOfItems >= 10 else { return }
        
        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        let artworkURL = descriptor.atIndex(10)?.stringValue ?? ""
        
        var state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? .all : .off,
            lastUpdated: Date(),
            artwork: nil,
            volume: Double(volumePercentage) / 100.0
        )

        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

        playbackState = state

        if !artworkURL.isEmpty, let url = URL(string: artworkURL) {
            guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
            artworkFetchTask?.cancel()

            let title = state.title
            let artist = state.artist

            // Only the cover is filled in: replacing the whole state with the snapshot taken before the
            // download undid a pause, a seek or a quit that happened meanwhile
            artworkFetchTask = Task { @MainActor [weak self] in
                let data = try? await ImageService.shared.fetchImageData(from: url)
                guard !Task.isCancelled, let self else { return }
                self.artworkFetchTask = nil
                guard let data, self.playbackState.title == title, self.playbackState.artist == artist else { return }
                var updatedState = self.playbackState
                updatedState.artwork = data
                self.playbackState = updatedState
                self.lastArtworkURL = artworkURL
            }
        }
    }
    
// MARK: - Private Methods
    
    private func executeCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            if it is running then
                try
                    set playerState to player state is playing
                    set currentTrackName to name of current track
                    set currentTrackArtist to artist of current track
                    set currentTrackAlbum to album of current track
                    set trackPosition to player position
                    set trackDuration to duration of current track
                    set shuffleState to shuffling
                    set repeatState to repeating
                    set currentVolume to sound volume
                    set artworkURL to artwork url of current track
                    return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
                on error
                    return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, ""}
                end try
            end if
            return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, ""}
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
    
}
