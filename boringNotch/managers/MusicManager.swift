//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    /// Drift offset absorbed smoothly by `smoothedPlaybackPosition(at:)` so periodic player resyncs never
    /// make word-timed lyrics jump backwards or snap forward
    private var lyricsClockOffset: TimeInterval = 0
    private var lyricsClockAnchor: Date = .distantPast
    private var lyricsClockTau: TimeInterval = 0.4
    private var explicitSeekUntil: Date = .distantPast
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    /// Lyrics with the real begin and end of every line and word: Apple Music, or an LRCLIB entry timed word by
    /// word. Empty when only lines are timed.
    @Published var timedLyrics: [TimedLyricLine] = []
    private var timedLyricsCache: [String: [TimedLyricLine]] = [:]
    /// "Written by" credits of the song (Apple Music lyrics only), shown after the last line
    @Published var lyricsSongwriters: [String] = []
    private var songwritersCache: [String: [String]] = [:]
    /// Skipping tracks starts overlapping lookups: only the latest one may publish its result.
    private var lyricsRequestID = 0
    /// Track whose lyrics are loaded or being looked up, so the same track is never searched twice.
    private var lyricsTrackKey: String?
    /// Finished lookups, including the ones that found nothing, so going back to a track is instant.
    private var lyricsCache: [String: (plain: String, synced: [(time: Double, text: String)])] = [:]
    /// Set when LRCLIB could not be reached: that outcome is not cached, the next lookup tries again.
    private var lyricsLookupFailed = false
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?
    /// Outgoing cover held briefly during an Apple Music AutoMix pivot so the two covers crossfade smoothly
    @Published var outgoingAutoMixArt: NSImage? = nil
    @Published var outgoingAutoMixArtOpacity: Double = 0
    private var autoMixArtFadeTask: Task<Void, Never>?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // A new lyrics source (or signing in to Apple Music) reloads the current track's lyrics
        Defaults.publisher(.lyricsSource, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadLyricsForNewSource() }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        let now = Date()
        let wasPlaying = self.isPlaying
        let previousTimestamp = self.timestampDate
        let previousSmooth = smoothedPlaybackPosition(at: now)

        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.artworkGeneration &+= 1
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            // Always record the track, even when its cover is byte-identical to the previous one (same
            // album, radio stations). Otherwise every later update, like the forced refresh on each notch
            // open, counts as a new track again: flip animation, sneak peek and a fresh lyrics lookup.
            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist)

            // Look the animated artwork up now, so it is ready by the time the Mac locks
            let (title, artist, album) = (state.title, state.artist, state.album)
            Task { @MainActor in
                AnimatedArtworkService.shared.prefetch(title: title, artist: artist, album: album)
            }
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime.isFinite ? max(0, state.currentTime) : 0
        }

        if durationChanged {
            self.songDuration = state.duration.isFinite ? max(0, state.duration) : 0
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // NowPlaying follows whichever app plays: what it supports changes with that app
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
            self.canFavoriteTrack = activeController?.supportsFavorite ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
        AppleMusicAutoMixMonitor.shared.playbackUpdated(
            title: self.songTitle,
            isPlaying: self.isPlaying,
            bundleIdentifier: self.bundleIdentifier
        )

        if hasContentChange || !state.isPlaying || !wasPlaying || now < self.explicitSeekUntil {
            self.lyricsClockOffset = 0
        } else if timeChanged || state.lastUpdated != previousTimestamp || playbackRateChanged {
            let newRaw = estimatedPlaybackPosition(at: now)
            let delta = previousSmooth - newRaw
            if abs(delta) > 2.0 {
                // Intentional scrub or restart in the player: snap immediately
                self.lyricsClockOffset = 0
            } else if abs(delta) > 0.004 {
                self.lyricsClockOffset = delta
                self.lyricsClockAnchor = now
                let rate = max(0.1, state.playbackRate)
                // When raw jumped backwards (delta > 0), stretch tau so d(smooth)/dt >= 0.25 * rate > 0:
                // the lyrics clock never goes backwards and glides smoothly back into sync.
                self.lyricsClockTau = delta > 0 ? max(0.45, delta / (0.75 * rate)) : 0.35
            }
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }
        // The player can take a moment to confirm, the heart answers the click right away
        isFavoriteTrack = favorite

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private static let placeholderTitles: Set<String> = ["", "I'm Handsome", "Not Playing", "Unknown"]

    func refreshLyrics() {
        let trimmed = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.placeholderTitles.contains(trimmed) else { return }
        fetchLyricsIfAvailable(bundleIdentifier: bundleIdentifier, title: songTitle, artist: artistName)
    }

    /// Cached lookups came from the previous source: forget them and look the current track up again
    func reloadLyricsForNewSource() {
        lyricsCache.removeAll()
        timedLyricsCache.removeAll()
        songwritersCache.removeAll()
        lyricsTrackKey = nil
        refreshLyrics()
    }

    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.placeholderTitles.contains(trimmed) else {
            // Same executor as the lookup below, so a reset and the next track's lookup keep their order
            Task { @MainActor in
                self.lyricsTask?.cancel()
                self.lyricsRequestID &+= 1
                self.lyricsTrackKey = nil
                self.isFetchingLyrics = false
                self.currentLyrics = ""
                self.syncedLyrics = []
                self.timedLyrics = []
                self.lyricsSongwriters = []
            }
            return
        }

        let key = "\(trimmed.lowercased())|\(artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"

        Task { @MainActor in
            guard key != self.lyricsTrackKey else { return }
            self.lyricsTask?.cancel()
            self.lyricsRequestID &+= 1
            let requestID = self.lyricsRequestID
            self.lyricsTrackKey = key
            self.lyricsTask = Task { @MainActor in
                await self.lookUpLyrics(
                    key: key, requestID: requestID, bundleIdentifier: bundleIdentifier, title: title, artist: artist)
            }
        }
    }

    /// Skipping tracks used to leave every previous lookup running: only the current one stays alive.
    private var lyricsTask: Task<Void, Never>?

    @MainActor
    private func lookUpLyrics(key: String, requestID: Int, bundleIdentifier: String?, title: String, artist: String) async {
        if let cached = lyricsCache[key] {
            currentLyrics = cached.plain
            syncedLyrics = cached.synced
            timedLyrics = timedLyricsCache[key] ?? []
            lyricsSongwriters = songwritersCache[key] ?? []
            isFetchingLyrics = false
            return
        }

        isFetchingLyrics = true
        currentLyrics = ""
        syncedLyrics = []
        timedLyrics = []
        lyricsSongwriters = []
        lyricsLookupFailed = false

        // 0. Apple Music lyrics when chosen in the settings: the real timing of every word
        let catalogID = bundleIdentifier == "com.apple.Music" && Defaults[.lyricsSource] == .appleMusic
            ? await NowPlayingController.fetchMusicCatalogID(title: title)
            : nil
        guard requestID == lyricsRequestID else { return }
        if let apple = await AppleMusicLyricsService.shared.lyrics(
            title: title, artist: artist, album: album, duration: songDuration, catalogID: catalogID) {
            guard requestID == lyricsRequestID else { return }
            let timed = apple.lines
            lyricsSongwriters = apple.songwriters
            if TimedLyricLine.areUntimed(timed) {
                // Apple only has the text of this song: LRCLIB may still have it synced
                await fetchLyricsFromWeb(title: title, artist: artist, requestID: requestID)
                guard requestID == lyricsRequestID else { return }
                if syncedLyrics.isEmpty {
                    currentLyrics = TimedLyricLine.plainText(timed)
                    lyricsLookupFailed = false
                }
                storeLyricsLookup(key: key)
                isFetchingLyrics = false
                return
            }
            timedLyrics = timed
            syncedLyrics = timed.map { (time: $0.begin, text: $0.text) }
            currentLyrics = timed.map(\.text).joined(separator: "\n")
            storeLyricsLookup(key: key)
            isFetchingLyrics = false
            return
        }
        guard requestID == lyricsRequestID else { return }

        // 1. Try LRCLIB web lookup first to obtain time-synced lyrics ([mm:ss.xx])
        await fetchLyricsFromWeb(title: title, artist: artist, requestID: requestID)
        guard requestID == lyricsRequestID else { return }
        if !syncedLyrics.isEmpty || !currentLyrics.isEmpty {
            storeLyricsLookup(key: key)
            isFetchingLyrics = false
            return
        }

        // 2. Lyrics embedded in the track, only when Music is what plays: a track paused in Music must not
        // lend its lyrics to a Spotify or browser track, and the title is checked against a skip meanwhile
        if bundleIdentifier == "com.apple.Music",
           !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty {
            let script = """
            tell application \"Music\"
                if it is running then
                    if player state is playing or player state is paused then
                        try
                            set l to lyrics of current track
                            if l is missing value then set l to \"\"
                            return {name of current track, l}
                        on error
                            return {\"\", \"\"}
                        end try
                    end if
                end if
                return {\"\", \"\"}
            end tell
            """
            let result = try? await AppleScriptHelper.execute(script)
            guard requestID == lyricsRequestID else { return }
            if let result, result.numberOfItems >= 2,
               result.atIndex(1)?.stringValue == title,
               let lyricsString = result.atIndex(2)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !lyricsString.isEmpty {
                currentLyrics = lyricsString
            }
        }
        storeLyricsLookup(key: key)
        isFetchingLyrics = false
    }

    @MainActor
    private func storeLyricsLookup(key: String) {
        guard !lyricsLookupFailed else {
            lyricsTrackKey = nil
            return
        }
        if lyricsCache.count >= 200 {
            lyricsCache.removeAll()
            timedLyricsCache.removeAll()
            songwritersCache.removeAll()
        }
        lyricsCache[key] = (currentLyrics, syncedLyrics)
        timedLyricsCache[key] = timedLyrics.isEmpty ? nil : timedLyrics
        songwritersCache[key] = lyricsSongwriters.isEmpty ? nil : lyricsSongwriters
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    private func strippedSongTitle(_ title: String) -> String {
        let pattern = #"\s*[\(\[][^\)\]]*(?:slowed|sped up|reverb|remix|edit|feat\.|ft\.|version|live)[^\)\]]*[\)\]]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return title
        }
        let range = NSRange(location: 0, length: (title as NSString).length)
        return regex.stringByReplacingMatches(in: title, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Song (Slowed) - Artist" and "song" give the same key: the base title, without case, accents,
    /// punctuation, bracketed tags or a trailing " - ..." part
    static func lyricsTitleKey(_ title: String) -> String {
        var base = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = base.range(of: " - ") { base = String(base[..<dash.lowerBound]) }
        return base
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @MainActor
    private func fetchLyricsFromWeb(title: String, artist: String, requestID: Int) async {
        if await queryLRCLib(title: title, artist: artist, requestID: requestID) {
            return
        }
        guard requestID == lyricsRequestID else { return }
        let cleaned = strippedSongTitle(title)
        if !cleaned.isEmpty && cleaned.lowercased() != title.lowercased() {
            _ = await queryLRCLib(title: cleaned, artist: artist, requestID: requestID)
        }
    }

    @MainActor
    private func queryLRCLib(title: String, artist: String, requestID: Int) async -> Bool {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        // .urlQueryAllowed keeps "&", "=" and "+": "Bigflo & Oli" split the query and found nothing
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return false
        }

        let urlString = "https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        guard let url = URL(string: urlString) else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard requestID == lyricsRequestID else { return false }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lyricsLookupFailed = true
                return false
            }
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return false
            }
            // The search is fuzzy ("PERTO" also returns "SEMPRE PERTO", same length, other lyrics): keep the
            // same title, and the same length when known so a slowed or sped up edit is not taken either
            let wantedTitle = Self.lyricsTitleKey(title)
            let wantedDuration = songDuration
            let jsonArray = results.filter { entry in
                guard Self.lyricsTitleKey(entry["trackName"] as? String ?? "") == wantedTitle else { return false }
                if wantedDuration > 0, let duration = entry["duration"] as? Double, abs(duration - wantedDuration) > 4 {
                    return false
                }
                return true
            }
            guard !jsonArray.isEmpty else { return false }
            // Prefer an entry timed word by word, then one with syncedLyrics
            let hasSynced: ([String: Any]) -> Bool = {
                guard let s = $0["syncedLyrics"] as? String else { return false }
                return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            var wordTimed: [TimedLyricLine] = []
            var bestMatch = jsonArray.first(where: hasSynced) ?? jsonArray.first!
            for entry in jsonArray where entry["hasWordSync"] as? Bool == true && hasSynced(entry) {
                let parsed = LRCLibLyricsFileParser.parse(entry["lyricsfile"] as? String ?? "")
                if !parsed.isEmpty {
                    wordTimed = parsed
                    bestMatch = entry
                    break
                }
            }

            let plain = (bestMatch["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let synced = (bestMatch["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolved = plain.isEmpty ? synced : plain
            guard !resolved.isEmpty else { return false }

            self.currentLyrics = resolved
            self.timedLyrics = wordTimed
            if !wordTimed.isEmpty {
                self.syncedLyrics = wordTimed.map { (time: $0.begin, text: $0.text) }
            } else if !synced.isEmpty {
                self.syncedLyrics = self.parseLRC(synced)
            } else {
                self.syncedLyrics = []
            }
            return true
        } catch {
            if requestID == lyricsRequestID { lyricsLookupFailed = true }
            return false
        }
    }

    // MARK: - Synced lyrics helpers
    // [mm:ss], [mm:ss.x], [mm:ss.xx] or [mm:ss.xxx]
    private static let lrcTimestamp = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\]"#)

    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(Double, String)] = []
        guard let regex = Self.lrcTimestamp else { return [] }
        lrc.split(separator: "\n").forEach { lineSub in
            let line = String(lineSub)
            let nsLine = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                let csRange = match.range(at: 3)
                // ".5" is half a second, not 5 hundredths
                let fraction = csRange.location != NSNotFound
                    ? Double("0." + nsLine.substring(with: csRange)) ?? 0 : 0
                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                let time = minutes * 60 + seconds + fraction
                let textStart = match.range.location + match.range.length
                let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    result.append((time, text))
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()
        // During an Apple Music AutoMix transition the cover crossfades smoothly instead of flipping
        guard !AppleMusicAutoMixMonitor.shared.isMixing else {
            isFlipping = false
            return
        }

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // Covers decode off the main thread: on a quick skip, a slow decode of the previous cover must not
    // land after the current one.
    private var artworkGeneration = 0

    private func updateArtwork(_ artworkData: Data) {
        artworkGeneration &+= 1
        let generation = artworkGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil, let artworkImage = NSImage(data: artworkData) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkGeneration == generation else { return }
                self.usingAppIconForArtwork = false
                self.updateAlbumArt(newAlbumArt: artworkImage)
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                // A cancelled sleep returns at once: without this, resuming playback hid the player
                guard !Task.isCancelled, let self else { return }
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        autoMixArtFadeTask?.cancel()
        if AppleMusicAutoMixMonitor.shared.isMixing, newAlbumArt !== self.albumArt {
            self.outgoingAutoMixArt = self.albumArt
            self.outgoingAutoMixArtOpacity = 1.0
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
            withAnimation(.easeInOut(duration: 1.6)) {
                self.outgoingAutoMixArtOpacity = 0
            }
            autoMixArtFadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1700))
                guard !Task.isCancelled, let self else { return }
                self.outgoingAutoMixArt = nil
            }
            return
        }
        self.outgoingAutoMixArt = nil
        self.outgoingAutoMixArtOpacity = 0
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    /// Monotonic, drift-smoothed playback clock for full-screen karaoke lyrics: absorbs periodic resyncs
    /// progressively without ever stepping backwards, while still snapping on explicit seeks or track changes.
    public func smoothedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        let raw = estimatedPlaybackPosition(at: date)
        guard isPlaying, lyricsClockOffset != 0 else { return raw }
        let dt = max(0, date.timeIntervalSince(lyricsClockAnchor))
        let decayed = lyricsClockOffset * exp(-dt / lyricsClockTau)
        if abs(decayed) < 0.001 { return raw }
        return min(max(0, raw + decayed), songDuration)
    }

    func calculateAverageColor() {
        let image = albumArt
        image.averageColor { [weak self] color in
            DispatchQueue.main.async {
                // A slower computation for the previous cover must not tint the current one
                guard let self, self.albumArt === image else { return }
                withAnimation(.smooth) {
                    self.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        let clamped = songDuration > 0 ? min(max(0, position), songDuration) : max(0, position)
        let now = Date()
        explicitSeekUntil = now.addingTimeInterval(0.8)
        lyricsClockOffset = 0
        elapsedTime = clamped
        timestampDate = now
        Task {
            await activeController?.seek(to: clamped)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, estimatedPlaybackPosition() + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
