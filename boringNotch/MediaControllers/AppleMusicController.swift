//
//  AppleMusicController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class AppleMusicController: MediaControllerProtocol {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.apple.Music",
        playbackRate: 1
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool {
        return true
    }

    private var notificationTask: Task<Void, Never>?
    private var positionResyncTask: Task<Void, Never>?
    private var periodicSyncTask: Task<Void, Never>?
    private var artworkRetryTask: Task<Void, Never>?
    
    // MARK: - Initialization
    init() {
        setupPlaybackStateChangeObserver()
        setupPeriodicSync()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.apple.Music.playerInfo")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
        positionResyncTask?.cancel()
        periodicSyncTask?.cancel()
        artworkRetryTask?.cancel()
    }

    // Music stays silent on seeks, restarts and some track changes (notably from the lock screen), so the
    // displayed position would keep running as if nothing happened. A light poll keeps it honest.
    private func setupPeriodicSync() {
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard self.isActive() else { continue }
                await self.syncWithPlayer()
            }
        }
    }

    // Compiling an AppleScript is far more expensive than running it, so the poll keeps one compiled
    // script and always runs it on the same serial queue.
    private let syncQueue = DispatchQueue(label: "gravitynotch.applemusic.sync", qos: .utility)
    private var compiledSyncScript: NSAppleScript?

    private func runSyncScript() async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { continuation in
            syncQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                if self.compiledSyncScript == nil {
                    let script = NSAppleScript(source: """
                    tell application "Music"
                        try
                            return {player position, name of current track, (player state is playing)}
                        on error
                            return {0, "", false}
                        end try
                    end tell
                    """)
                    var compileError: NSDictionary?
                    if script?.compileAndReturnError(&compileError) == true {
                        self.compiledSyncScript = script
                    }
                }
                var error: NSDictionary?
                continuation.resume(returning: self.compiledSyncScript?.executeAndReturnError(&error))
            }
        }
    }

    private func syncWithPlayer() async {
        guard let descriptor = await runSyncScript(),
              descriptor.numberOfItems >= 3 else { return }
        let actual = descriptor.atIndex(1)?.doubleValue ?? 0
        let title = descriptor.atIndex(2)?.stringValue ?? ""
        let isPlaying = descriptor.atIndex(3)?.booleanValue ?? false

        let state = self.playbackState
        if (!title.isEmpty && title != state.title) || isPlaying != state.isPlaying {
            await updatePlaybackInfo()
            return
        }
        guard isPlaying else { return }
        let expected = state.currentTime + state.playbackRate * Date().timeIntervalSince(state.lastUpdated)
        if abs(expected - actual) > 0.5 {
            var corrected = state
            corrected.currentTime = actual
            corrected.lastUpdated = Date()
            self.playbackState = corrected
        }
    }
    
    // MARK: - Protocol Implementation
    func play() async {
        await executeCommand("play")
    }
    
    func pause() async {
        await executeCommand("pause")
    }
    
    func togglePlay() async {
        await executeCommand("playpause")
    }
    
    func nextTrack() async {
        await executeCommand("next track")
        try? await Task.sleep(for: .milliseconds(200))
        await updatePlaybackInfo()
    }
    
    func previousTrack() async {
        // "back track" restarts the current song, or goes to the previous one when already at its start.
        // "previous track" does nothing on the first track of a playlist.
        await executeCommand("back track")
        try? await Task.sleep(for: .milliseconds(200))
        await updatePlaybackInfo()
    }
    
    func seek(to time: Double) async {
        await executeCommand("set player position to \(time)")
        await updatePlaybackInfo()
    }
    
    func toggleShuffle() async {
        await executeCommand("set shuffle enabled to not shuffle enabled")
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func toggleRepeat() async {
        await executeCommand("""
            if song repeat is off then
                set song repeat to all
            else if song repeat is all then
                set song repeat to one
            else
                set song repeat to off
            end if
            """)
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func isActive() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    func setFavorite(_ favorite: Bool) async {
        let script = """
        tell application \"Music\"
            try
                set favorited of current track to " + (favorite ? "true" : "false") + "
            end try
        end tell
        """
        try? await AppleScriptHelper.executeVoid(script)
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func updatePlaybackInfo() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 11 else { return }
        var updatedState = self.playbackState
        
        updatedState.isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        updatedState.title = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        updatedState.artist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        updatedState.album = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        updatedState.currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        updatedState.duration = descriptor.atIndex(6)?.doubleValue ?? 0
        updatedState.isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let repeatModeValue = descriptor.atIndex(8)?.int32Value ?? 0
        updatedState.repeatMode = RepeatMode(rawValue: Int(repeatModeValue)) ?? .off
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        updatedState.volume = Double(volumePercentage) / 100.0
        let sameTrack = updatedState.title == self.playbackState.title
            && updatedState.artist == self.playbackState.artist
            && updatedState.album == self.playbackState.album
        if let artwork = descriptor.atIndex(10)?.data, !artwork.isEmpty {
            updatedState.artwork = artwork
        } else if !sameTrack {
            updatedState.artwork = nil
        }
        let lovedState = descriptor.atIndex(11)?.booleanValue ?? false
        updatedState.isFavorite = lovedState
        updatedState.lastUpdated = Date()
        let needsPositionResync = updatedState.title != self.playbackState.title
            || updatedState.artist != self.playbackState.artist
            || (updatedState.isPlaying && !self.playbackState.isPlaying)
        self.playbackState = updatedState

        if needsPositionResync {
            schedulePositionResync()
        }
        if updatedState.artwork == nil {
            if !sameTrack || artworkRetryTask == nil {
                scheduleArtworkRetry()
            }
        } else {
            artworkRetryTask?.cancel()
            artworkRetryTask = nil
        }
    }

    // Streamed tracks are announced before Music has downloaded their cover, and nothing is sent once
    // it arrives. Ask again for a while until the artwork shows up. For some catalog tracks AppleScript
    // never exposes any artwork at all, while MediaRemote does have it, so ask both.
    private func scheduleArtworkRetry() {
        artworkRetryTask?.cancel()
        let title = playbackState.title
        let artist = playbackState.artist

        artworkRetryTask = Task { [weak self] in
            for delay in [0.3, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                guard self.playbackState.title == title, self.playbackState.artist == artist,
                      self.playbackState.artwork == nil else { return }
                guard self.isActive() else { continue }

                var artwork = await self.fetchArtworkFromMusic(title: title)
                if artwork == nil {
                    artwork = await Self.fetchArtworkFromMediaRemote(title: title)
                }
                guard let artwork else { continue }
                guard !Task.isCancelled, self.playbackState.title == title,
                      self.playbackState.artwork == nil else { return }

                var updated = self.playbackState
                updated.artwork = artwork
                self.playbackState = updated
                self.artworkRetryTask = nil
                return
            }
            if !Task.isCancelled { self?.artworkRetryTask = nil }
        }
    }

    private func fetchArtworkFromMusic(title: String) async -> Data? {
        guard let descriptor = try? await AppleScriptHelper.execute("""
                tell application "Music"
                    try
                        return {name of current track, data of artwork 1 of current track}
                    on error
                        return {"", ""}
                    end try
                end tell
                """),
              descriptor.numberOfItems >= 2,
              descriptor.atIndex(1)?.stringValue == title,
              let artwork = descriptor.atIndex(2)?.data, !artwork.isEmpty
        else { return nil }
        return artwork
    }

    private static func fetchArtworkFromMediaRemote(title: String) async -> Data? {
        guard let payload = await NowPlayingController.fetchCurrentPayload(),
              payload.title == title,
              (payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier) == "com.apple.Music",
              let artworkString = payload.artworkData,
              let artwork = Data(base64Encoded: artworkString.trimmingCharacters(in: .whitespacesAndNewlines)),
              !artwork.isEmpty
        else { return nil }
        return artwork
    }

    // Music announces a track as playing while it is still buffering, and sends nothing when the
    // audio really starts. Poll the player position for a few seconds and realign when it drifts.
    private func schedulePositionResync() {
        positionResyncTask?.cancel()
        let title = playbackState.title

        positionResyncTask = Task { [weak self] in
            for delay in [0.6, 0.8, 1.0, 1.5, 2.0, 3.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.playbackState.title == title else { return }
                guard self.playbackState.isPlaying, self.isActive(),
                      let descriptor = try? await AppleScriptHelper.execute(
                        "tell application \"Music\" to get player position")
                else { continue }
                guard !Task.isCancelled, self.playbackState.title == title else { return }

                let actual = descriptor.doubleValue
                let state = self.playbackState
                let expected = state.currentTime
                    + state.playbackRate * Date().timeIntervalSince(state.lastUpdated)
                if abs(expected - actual) > 0.3 {
                    var corrected = state
                    corrected.currentTime = actual
                    corrected.lastUpdated = Date()
                    self.playbackState = corrected
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func executeCommand(_ command: String) async {
        let script = "tell application \"Music\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Music"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffle enabled
                set repeatState to song repeat
                if repeatState is off then
                    set repeatValue to 1
                else if repeatState is one then
                    set repeatValue to 2
                else if repeatState is all then
                    set repeatValue to 3
                end if

                try
                    set artData to data of artwork 1 of current track
                on error
                    set artData to ""
                end try
                
                set currentVolume to sound volume
                set favoriteState to favorited of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatValue, currentVolume, artData, favoriteState}
            on error
                return {false, "Not Playing", "Unknown", "Unknown", 0, 0, false, 0, 50, "", false}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
    
}
