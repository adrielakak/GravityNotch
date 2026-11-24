//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

// The state and the tasks are only touched on the main actor, like the other controllers: the adapter
// stream, the retries and the commands used to mutate them from several threads at once.
final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    @MainActor
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: "com.apple.Music"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    @MainActor
    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?
    private var positionResyncTask: Task<Void, Never>?
    private var artworkRetryTask: Task<Void, Never>?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()
        positionResyncTask?.cancel()
        artworkRetryTask?.cancel()
        
        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        // No waitUntilExit: deinit runs on the main thread, Process reaps the child on its own
        if let process = self.process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    @MainActor
    func toggleShuffle() async {
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }
    
    @MainActor
    func toggleRepeat() async {
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }
    
    @MainActor
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await self?.processJSONStream()
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    // MARK: - Async Stream Processing
    private func processJSONStream() async {
        guard let pipeHandler = self.pipeHandler else { return }
        
        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    // MediaRemote reports "playing" as soon as a track is requested, so while the player is still
    // buffering the estimated position runs ahead of the audio. The player's own position is the
    // ground truth: poll it for a few seconds after a track change and realign when it drifts.
    @MainActor
    private func schedulePositionResync() {
        positionResyncTask?.cancel()

        let appName: String
        switch playbackState.bundleIdentifier {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return
        }
        let title = playbackState.title

        positionResyncTask = Task { [weak self] in
            for delay in [0.6, 0.8, 1.0, 1.5, 2.0, 3.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.playbackState.title == title else { return }
                // An AppleEvent to a player that just quit would launch it again
                guard self.playbackState.isPlaying,
                      !NSRunningApplication.runningApplications(withBundleIdentifier: self.playbackState.bundleIdentifier).isEmpty,
                      let descriptor = try? await AppleScriptHelper.execute("""
                        tell application "\(appName)"
                            if it is running then return player position
                        end tell
                        """),
                      descriptor.descriptorType != typeNull
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

    // For streamed tracks, the player announces the track before its cover is downloaded, and the
    // adapter stream does not always push the cover once it arrives. MediaRemote does have it when
    // asked for the current state, so ask again for a while until it shows up.
    @MainActor
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
                guard let payload = await Self.fetchCurrentPayload(),
                      payload.title == title,
                      let artworkString = payload.artworkData,
                      let artwork = Data(
                        base64Encoded: artworkString.trimmingCharacters(in: .whitespacesAndNewlines)),
                      !artwork.isEmpty
                else { continue }
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

    // One-shot read of the current now playing state through the adapter ("get" instead of "stream").
    static func fetchCurrentPayload() async -> NowPlayingPayload? {
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [scriptURL.path, frameworkPath, "get"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: try? JSONDecoder().decode(NowPlayingPayload.self, from: data))
            }
        }
    }

    // MARK: - Update Methods
    @MainActor
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        
        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)
        
        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        
        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            newPlaybackState.artwork = nil
        }
        if newPlaybackState.artwork?.isEmpty == true {
            newPlaybackState.artwork = nil
        }
        let sameTrack = newPlaybackState.title == self.playbackState.title
            && newPlaybackState.artist == self.playbackState.artist
            && newPlaybackState.album == self.playbackState.album
        if newPlaybackState.artwork == nil && sameTrack {
            newPlaybackState.artwork = self.playbackState.artwork
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        newPlaybackState.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? self.playbackState.bundleIdentifier : "")
        )
        
        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)
        
        // Pause, seek and resume events carry no favorite state: keep it for the same track
        newPlaybackState.isFavorite = sameTrack ? self.playbackState.isFavorite : false

        let needsPositionResync = newPlaybackState.title != self.playbackState.title
            || newPlaybackState.artist != self.playbackState.artist
            || (newPlaybackState.isPlaying && !self.playbackState.isPlaying)

        self.playbackState = newPlaybackState

        if needsPositionResync {
            schedulePositionResync()
        }

        if newPlaybackState.artwork != nil {
            artworkRetryTask?.cancel()
            artworkRetryTask = nil
        } else if !newPlaybackState.title.isEmpty, !sameTrack || artworkRetryTask == nil {
            scheduleArtworkRetry()
        }
        
        if !sameTrack, !newPlaybackState.title.isEmpty, newPlaybackState.bundleIdentifier == "com.apple.Music" {
            let title = newPlaybackState.title
            Task { @MainActor [weak self] in
                guard let self, self.playbackState.title == title else { return }
                await self.fetchFavoriteStateIfSupported()
            }
        }
    }
    
     @MainActor
     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 if it is running then
                     try
                         return favorited of current track
                     on error
                         return false
                     end try
                 end if
                 return false
             end tell
             """
             let title = playbackState.title
             if let result = try? await AppleScriptHelper.execute(script), self.playbackState.title == title {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    /// Raw bytes: a read can end in the middle of a multi-byte character, so lines are cut on the
    /// newline byte and only complete lines are decoded
    private var buffer = Data()
    private var pendingRead: CheckedContinuation<Data, Never>?
    private var isClosed = false

    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }

    func getPipe() -> Pipe {
        return pipe
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        while true {
            let data = await readData()
            guard !data.isEmpty else { break }
            buffer.append(data)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty, let decoded = try? JSONDecoder().decode(T.self, from: Data(line)) else { continue }
                await onLine(decoded)
            }
        }
    }

    private func readData() async -> Data {
        guard !isClosed else { return Data() }
        return await withCheckedContinuation { continuation in
            pendingRead = continuation
            fileHandle.readabilityHandler = { [weak self] handle in
                handle.readabilityHandler = nil
                let data = (try? handle.read(upToCount: 65_536)) ?? Data()
                Task { await self?.deliver(data) }
            }
        }
    }

    private func deliver(_ data: Data) {
        guard let continuation = pendingRead else { return }
        pendingRead = nil
        continuation.resume(returning: data)
    }

    /// Ends the stream: a read still waiting is answered with no data instead of being left hanging
    func close() async {
        isClosed = true
        fileHandle.readabilityHandler = nil
        deliver(Data())
        do {
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}
