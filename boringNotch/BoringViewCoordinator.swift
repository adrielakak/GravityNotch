//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
    case bluetoothAudio
    case listeningMode
    case updateReady
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    /// While the session is locked the notch must not open: its tabs expose clipboard history,
    /// shelf files, agent sessions and calendar events to whoever is in front of the Mac.
    @Published var isScreenLocked: Bool = false
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = false
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { notification in
            let granted = (notification.userInfo?["granted"] as? Bool) ?? AXIsProcessTrusted()
            Task { @MainActor in
                if granted && Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch
            _ = BluetoothAudioLiveActivityManager.shared
            AirPodsListeningModeMonitor.shared.start()

            if Defaults[.hudReplacement] {
                await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            // One assignment: four field writes meant four didSet calls, each rescheduling the hide timer
            var next = self.sneakPeek
            next.show = status
            next.type = type
            next.value = value
            next.icon = icon
            withAnimation(self.sneakPeekAnimation(for: next)) {
                self.sneakPeek = next
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?
    private var lastLevelStepAt: Date = .distantPast

    /// A 0.5 s spring per key press nearly settles between spaced taps, so spamming made the bar stop and
    /// restart (holding the key repeats every ~90 ms and hid it). Level steps on a HUD already shown move
    /// linearly over the time since the previous step, so the bar keeps a constant speed at the tap rhythm.
    @MainActor private func sneakPeekAnimation(for next: sneakPeek) -> Animation {
        let isLevel = next.type == .volume || next.type == .brightness || next.type == .backlight
        guard isLevel, next.show, sneakPeek.show, sneakPeek.type == next.type else {
            if isLevel && next.show { lastLevelStepAt = Date() }
            return .smooth
        }
        let now = Date()
        let interval = now.timeIntervalSince(lastLevelStepAt)
        lastLevelStepAt = now
        return .linear(duration: min(max(interval, 0.08), 0.2))
    }

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    /// When the current sneak peek appeared: it widens the closed notch, which can slide under a resting cursor
    private(set) var sneakPeekShownAt: Date = .distantPast

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                if !oldValue.show { sneakPeekShownAt = Date() }
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            let anim: Animation = (type == .bluetoothAudio || type == .listeningMode)
                ? .spring(response: 0.40, dampingFraction: 0.84)
                : .smooth
            withAnimation(anim) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?
    private var isHoveringExpandingView = false

    func setExpandingViewHover(_ hovering: Bool) {
        isHoveringExpandingView = hovering
        guard expandingView.show else { return }
        if hovering {
            expandingViewTask?.cancel()
        } else {
            scheduleExpandingHide(after: expandingView.type == .bluetoothAudio ? 1.8 : 1.4, type: expandingView.type)
        }
    }

    private func scheduleExpandingHide(after duration: TimeInterval, type: SneakContentType) {
        expandingViewTask?.cancel()
        expandingViewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            self.toggleExpandingView(status: false, type: type)
        }
    }

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                if !isHoveringExpandingView {
                    let duration: TimeInterval
                    switch expandingView.type {
                    case .download:
                        duration = 2
                    case .bluetoothAudio:
                        duration = 4.2
                    case .listeningMode:
                        duration = 2.4
                    case .updateReady:
                        duration = 5
                    default:
                        duration = 3
                    }
                    scheduleExpandingHide(after: duration, type: expandingView.type)
                }
            } else {
                isHoveringExpandingView = false
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}
