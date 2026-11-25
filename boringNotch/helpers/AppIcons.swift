//
//  AppIcons.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 16/08/24.
//

import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreAudio
import Defaults
import IOKit.pwr_mgt
import OSLog
import Security
import Sparkle
import WebKit

struct AppIcons {
    
    func getIcon(file path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path)
        else { return nil }
        
        return NSWorkspace.shared.icon(forFile: path)
    }
    
    func getIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        )?.absoluteString
        else { return nil }
        
        return getIcon(file: path)
    }
    
        /// Easily read Info.plist as a Dictionary from any bundle by accessing .infoDictionary on Bundle
    func bundle(forBundleID: String) -> Bundle? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: forBundleID)
        else { return nil }
        
        return Bundle(url: url)
    }
    
}

func AppIcon(for bundleID: String) -> Image {
    let workspace = NSWorkspace.shared
    
    if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        return Image(nsImage: appIcon)
    }
    
    return Image(nsImage: workspace.icon(for: .applicationBundle))
}


func AppIconAsNSImage(for bundleID: String) -> NSImage? {
    let workspace = NSWorkspace.shared
    
    if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        appIcon.size = NSSize(width: 256, height: 256)
        return appIcon
    }
    return nil
}

// MARK: - CoreAudio Output Device Switcher (Gravity Audio Routing)

@MainActor
final class AudioOutputRoutingMenu: NSObject, ObservableObject {
    static let shared = AudioOutputRoutingMenu()

    struct OutputDevice {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
        var transportType: UInt32 = 0

        var symbolName: String {
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpod") { return "airpods" }
            if lower.contains("beats") || lower.contains("headphone") || lower.contains("casque") { return "headphones" }
            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
            default: return "hifispeaker.fill"
            }
        }
    }

    /// Shown in place of the calendar on the home tab, like the Playing Next queue
    @Published var showPanelInHome = false
    @Published private(set) var devices: [OutputDevice] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?

    func togglePanel() {
        withAnimation(.smooth(duration: 0.22)) {
            showPanelInHome.toggle()
            if showPanelInHome { PlayingNextManager.shared.showQueueInHome = false }
        }
    }

    func hidePanel() {
        guard showPanelInHome else { return }
        withAnimation(.smooth(duration: 0.22)) { showPanelInHome = false }
    }

    /// Keeps `devices` current while the panel is visible (AirPods connecting, output changed elsewhere)
    func startObservingDevices() {
        devices = availableOutputDevices()
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devices = self?.availableOutputDevices() ?? [] }
        }
        deviceListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func stopObservingDevices() {
        guard let listener = deviceListener else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListener = nil
    }

    func availableOutputDevices() -> [OutputDevice] {
        var defaultID = AudioDeviceID(0)
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &defSize, &defaultID)

        var propSize: UInt32 = 0
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &propSize) == noErr else {
            return []
        }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &propSize, &ids) == noErr else {
            return []
        }
        let actualCount = min(count, Int(propSize) / MemoryLayout<AudioDeviceID>.size)

        var outputs: [OutputDevice] = []
        for id in ids.prefix(actualCount) {
            var streamSize: UInt32 = 0
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            // Skips app-private virtual devices (Microsoft Teams Audio) and the AirPods hands-free twin:
            // macOS itself never offers them as the system output
            var canBeDefault: UInt32 = 1
            var canBeDefaultSize = UInt32(MemoryLayout<UInt32>.size)
            var canBeDefaultAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(id, &canBeDefaultAddr, 0, nil, &canBeDefaultSize, &canBeDefault) == noErr,
               canBeDefault == 0 {
                continue
            }
            if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 {
                var cfNameRef: Unmanaged<CFString>? = nil
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfNameRef)
                if status == noErr, let name = cfNameRef?.takeRetainedValue() as String? {
                    var transport: UInt32 = 0
                    var transportSize = UInt32(MemoryLayout<UInt32>.size)
                    var transportAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyTransportType,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &transportSize, &transport)
                    outputs.append(OutputDevice(id: id, name: name, isDefault: id == defaultID, transportType: transport))
                }
            }
        }
        return outputs
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
        if status != noErr {
            devices = availableOutputDevices()
        }
    }
}

// MARK: - Bluetooth / AirPods Live Activity Manager & Closed-Notch View

enum BluetoothAudioModelKind: Equatable {
    case airPods
    case airPodsGen3
    case airPodsGen4
    case airPodsPro
    case airPodsMax
    case beatsOverEar
    case beatsInEar
    case headphones
    case speaker

    private static let appleProductMap: [Int: BluetoothAudioModelKind] = [
        0x2002: .airPods,      // AirPods (1st gen)
        0x200F: .airPods,      // AirPods (2nd gen)
        0x2013: .airPodsGen3,  // AirPods (3rd gen)
        0x2019: .airPodsGen4,  // AirPods (4th gen)
        0x201B: .airPodsGen4,  // AirPods (4th gen ANC)
        0x200E: .airPodsPro,   // AirPods Pro (1st gen)
        0x2014: .airPodsPro,   // AirPods Pro (2nd gen Lightning)
        0x2024: .airPodsPro,   // AirPods Pro (2nd gen USB-C)
        0x2027: .airPodsPro,   // AirPods Pro (2nd/3rd gen USB-C revision)
        0x200A: .airPodsMax,   // AirPods Max (Lightning)
        0x201F: .airPodsMax,   // AirPods Max (USB-C)
        0x2006: .beatsOverEar, // Beats Solo3
        0x2009: .beatsOverEar, // Beats Studio3
        0x2010: .beatsOverEar, // Beats Solo Pro
        0x2017: .beatsOverEar, // Beats Studio Pro
        0x2026: .beatsOverEar, // Beats Solo 4
        0x200B: .beatsInEar,   // Powerbeats Pro
        0x200C: .beatsInEar,   // Beats Solo Buds / Flex
        0x200D: .beatsInEar,   // Beats Powerbeats
        0x2011: .beatsInEar,   // Beats Studio Buds
        0x2012: .beatsInEar,   // Beats Fit Pro
        0x2015: .beatsInEar,   // Beats Studio Buds+
        0x2016: .beatsInEar,   // Powerbeats Pro 2
        0x2018: .beatsInEar,   // Beats Fit Pro revision
        0x201D: .beatsInEar    // Beats Solo Buds
    ]

    static func resolve(vendorID: Int?, productID: Int?, minorType: String?, name: String) -> BluetoothAudioModelKind {
        if let productID, (vendorID == 0x004C || vendorID == 0x000A || vendorID == nil),
           let mapped = appleProductMap[productID] {
            return mapped
        }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return .airPodsMax }
        if lower.contains("airpods pro") { return .airPodsPro }
        if lower.contains("airpods 4") { return .airPodsGen4 }
        if lower.contains("airpods 3") { return .airPodsGen3 }
        if lower.contains("airpods") { return .airPods }
        if lower.contains("beats") {
            return (lower.contains("studio") || lower.contains("solo pro") || lower.contains("solo 4")) ? .beatsOverEar : .beatsInEar
        }
        if minorType?.lowercased().contains("loudspeaker") == true || lower.contains("speaker") || lower.contains("soundbar") || lower.contains("homepod") {
            return .speaker
        }
        return .headphones
    }

    var symbolName: String {
        switch self {
        case .airPods: return Self.availableSymbol("airpod.right", fallback: Self.availableSymbol("airpods", fallback: "headphones"))
        case .airPodsGen3: return Self.availableSymbol("airpod.gen3.right", fallback: Self.availableSymbol("airpod.right", fallback: "headphones"))
        case .airPodsGen4: return Self.availableSymbol("airpod.gen4.right", fallback: Self.availableSymbol("airpod.gen3.right", fallback: Self.availableSymbol("airpod.right", fallback: "headphones")))
        case .airPodsPro: return Self.availableSymbol("airpodpro.right", fallback: Self.availableSymbol("airpodspro", fallback: "headphones"))
        case .airPodsMax: return Self.availableSymbol("airpodsmax", fallback: "headphones")
        case .beatsOverEar: return Self.availableSymbol("beats.headphones", fallback: "headphones")
        case .beatsInEar: return Self.availableSymbol("beats.fit.pro", fallback: "headphones")
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker.fill"
        }
    }

    var caseSymbolName: String {
        switch self {
        case .airPodsPro:
            return Self.availableSymbol("airpodspro.chargingcase.wireless.fill", fallback: "battery.100percent")
        case .airPods, .airPodsGen3, .airPodsGen4:
            return Self.availableSymbol("airpods.chargingcase.fill", fallback: "battery.100percent")
        default:
            return "battery.100percent"
        }
    }

    var accentColor: Color {
        switch self {
        case .airPods, .airPodsGen3, .airPodsGen4, .airPodsPro, .airPodsMax:
            return Color(red: 0.35, green: 0.80, blue: 1.0)
        case .beatsOverEar, .beatsInEar:
            return Color(red: 0.98, green: 0.36, blue: 0.44)
        case .headphones, .speaker:
            return Color(red: 0.42, green: 0.72, blue: 1.0)
        }
    }

    private static func availableSymbol(_ name: String, fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }
}

struct BluetoothAudioDeviceInfo: Equatable {
    let uid: String
    let name: String
    let modelKind: BluetoothAudioModelKind
    var leftBattery: Int?
    var rightBattery: Int?
    var caseBattery: Int?
    var mainBattery: Int?

    var hasAnyBattery: Bool {
        leftBattery != nil || rightBattery != nil || caseBattery != nil || mainBattery != nil
    }

    var hasEarbudBatteries: Bool {
        leftBattery != nil || rightBattery != nil
    }

    var primaryBatteryPercentage: Int? {
        if let leftBattery, let rightBattery {
            return min(leftBattery, rightBattery)
        }
        return leftBattery ?? rightBattery ?? mainBattery
    }

    var hoverBreakdownText: String? {
        var parts: [String] = []
        if let leftBattery { parts.append("L \(leftBattery)%") }
        if let rightBattery { parts.append("R \(rightBattery)%") }
        if let caseBattery { parts.append("Case \(caseBattery)%") }
        if parts.isEmpty, let mainBattery {
            parts.append("Battery \(mainBattery)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

/// Hides macOS's "AirPods Connected" system banner as soon as ControlCenter creates it.
///
/// macOS converts the `com.apple.BTUserNotifications` "Connected" request into a Smart Routing
/// system banner drawn by ControlCenter (not NotificationCenter): an `AXSystemDialog` window hanging
/// from the menu bar, with no close button or dismiss action. Its only writable attribute is
/// `AXPosition`, so a matching window is moved off every screen until it fades out on its own.
///
/// A window is touched only when all of these hold: it belongs to ControlCenter, its subrole is
/// `AXSystemDialog`, it carries a Smart Routing device image (`Banner PID <productID>`), it shows the
/// exact localized "Connected" label, and it names a Bluetooth audio device. NotificationCenter is
/// never observed, so no app notification can be affected.
@MainActor
private final class BluetoothBannerSuppressor {
    static let shared = BluetoothBannerSuppressor()

    private static let logger = Logger(subsystem: "theboringteam.boringnotch", category: "BluetoothBannerSuppressor")
    private static let controlCenterBundleID = "com.apple.controlcenter"
    private static let controlCenterSoundTablePath = "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/Sound.loctable"
    private static let smartRoutingImagePrefix = "banner pid "
    private static let bluetoothAudioBrandTokens = ["airpods", "beats"]

    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var followUpTask: Task<Void, Never>?
    private var movedListeningWindows: [(window: AXUIElement, origin: CGPoint)] = []
    private var lastSuppressionAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()
    private lazy var connectedLabels: Set<String> = Self.loadConnectedLabels()

    private init() {
        Defaults.publisher(.showBluetoothAudioLiveActivity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMonitoringState() }
            .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.accessibility.api"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMonitoringState() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMonitoringState() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.controlCenterBundleID else { return }
                self?.teardownObserver()
                self?.refreshMonitoringState()
            }
            .store(in: &cancellables)

        refreshMonitoringState()
    }

    func refreshMonitoringState() {
        let trusted = AXIsProcessTrusted()
        // Deferred: this runs during BluetoothAudioLiveActivityManager.init, before `shared` is set.
        Task { @MainActor in
            BluetoothAudioLiveActivityManager.shared.syncBannerSuppressorTrust(trusted)
        }
        let enabled = Defaults[.showBluetoothAudioLiveActivity]
        guard enabled, trusted else {
            if axObserver != nil || !trusted {
                Self.logger.notice("Banner suppression inactive enabled=\(enabled, privacy: .public) trusted=\(trusted, privacy: .public)")
            }
            teardownObserver()
            return
        }
        installObserverIfNeeded()
    }

    /// Called when CoreAudio switches to a Bluetooth device, in case ControlCenter posts the banner
    /// before our observer is (re)installed.
    func scanSoon() {
        refreshMonitoringState()
        guard axObserver != nil else { return }
        scanControlCenterWindows()
        scheduleFollowUpScans()
    }

    private func handleControlCenterAXEvent() {
        guard Defaults[.showBluetoothAudioLiveActivity] else {
            teardownObserver()
            return
        }
        scanControlCenterWindows()
        scheduleFollowUpScans()
    }

    /// The banner is fully populated when `AXCreated` fires, but the device may reach CoreAudio a few
    /// milliseconds later, so re-check shortly after.
    private func scheduleFollowUpScans() {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            for delay in [60, 180, 450] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.scanControlCenterWindows()
            }
        }
    }

    private func installObserverIfNeeded() {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.controlCenterBundleID)
            .first?.processIdentifier else {
            return
        }
        if axObserver != nil && observedPID == pid { return }
        teardownObserver()

        var observer: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let suppressor = Unmanaged<BluetoothBannerSuppressor>.fromOpaque(refcon).takeUnretainedValue()
            // The run loop source is on the main run loop: handle synchronously so the banner is
            // moved before WindowServer composites its first frame.
            MainActor.assumeIsolated {
                suppressor.handleControlCenterAXEvent()
            }
        }, &observer)

        guard status == .success, let observer else {
            Self.logger.error("AXObserverCreate failed status=\(status.rawValue, privacy: .public) pid=\(pid, privacy: .public)")
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let statuses = [kAXWindowCreatedNotification, kAXMovedNotification].map {
            AXObserverAddNotification(observer, appElement, $0 as CFString, refcon).rawValue
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        axObserver = observer
        observedPID = pid
        Self.logger.notice("Observing ControlCenter pid=\(pid, privacy: .public) statuses=\(statuses, privacy: .public)")
    }

    private func teardownObserver() {
        followUpTask?.cancel()
        followUpTask = nil
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
        observedPID = 0
    }

    private func scanControlCenterWindows() {
        guard observedPID != 0 else { return }
        let appElement = AXUIElementCreateApplication(observedPID)
        guard let windows = Self.copyElementArray(appElement, attribute: kAXWindowsAttribute) else { return }

        for window in windows where Self.copyStringAttribute(window, attribute: kAXSubroleAttribute) == "AXSystemDialog" {
            guard let frame = Self.copyFrame(window), Self.isOnAnyScreen(frame) else { continue }
            guard let banner = matchSmartRoutingConnectedBanner(window) else { continue }
            hide(window, frame: frame, deviceName: banner.deviceName)
        }
    }

    private func matchSmartRoutingConnectedBanner(_ window: AXUIElement) -> (deviceName: String, battery: Int?)? {
        guard Self.copyStringAttribute(window, attribute: kAXRoleAttribute) == (kAXWindowRole as String) else { return nil }

        var imageDescriptions: [String] = []
        var texts: [String] = []
        Self.collectContent(from: window, depth: 0, imageDescriptions: &imageDescriptions, texts: &texts)

        guard imageDescriptions.contains(where: { Self.normalizeText($0).hasPrefix(Self.smartRoutingImagePrefix) }) else {
            return nil
        }
        let normalizedTexts = texts.map(Self.normalizeText)
        guard normalizedTexts.contains(where: { connectedLabels.contains($0) }) else { return nil }

        let knownNames = BluetoothAudioLiveActivityManager.bluetoothAudioDeviceNames().map(Self.normalizeText)
        let candidates = texts.filter { text in
            let norm = Self.normalizeText(text)
            return !connectedLabels.contains(norm) && Int(norm) == nil && !norm.isEmpty
        }
        guard let deviceName = candidates.first(where: { text in
            let norm = Self.normalizeText(text)
            return knownNames.contains(norm) || Self.bluetoothAudioBrandTokens.contains { norm.contains($0) }
        }) else {
            return nil
        }
        let battery = normalizedTexts.compactMap { Int($0) }.first { (0...100).contains($0) }
        return (deviceName, battery)
    }

    private func hide(_ window: AXUIElement, frame: CGRect, deviceName: String) {
        var target = CGPoint(x: frame.origin.x, y: Self.offscreenY(forHeight: frame.height))
        guard let value = AXValueCreate(.cgPoint, &target) else { return }
        let result = AXUIElementSetAttributeValue(Self.bounded(window), kAXPositionAttribute as CFString, value)
        guard result == .success else {
            Self.logger.error("Failed to move Smart Routing banner err=\(result.rawValue, privacy: .public)")
            return
        }
        Self.logger.notice("Hid macOS Smart Routing banner for \(deviceName, privacy: .private)")

        // ControlCenter may re-post the same banner (battery refresh); report one connection only.
        let now = Date()
        defer { lastSuppressionAt = now }
        guard now.timeIntervalSince(lastSuppressionAt) > 3 else { return }
        BluetoothAudioLiveActivityManager.shared.systemBannerSuppressed(deviceName: deviceName)
    }

    // MARK: Listening mode banner

    private var listeningBannerTask: Task<Void, Never>?

    /// ControlCenter's listening mode banner exposes no text through AX and reuses its window (no AXCreated),
    /// so it is matched by shape right after ControlCenter logged that it shows it: a small system dialog
    /// under the menu bar that is not the Smart Routing banner. The log line can precede the window by a few
    /// frames, hence the repeated scans. The window goes back to its place once the banner has faded, so a
    /// later banner reusing it is never hidden by mistake.
    func hideListeningModeBannerSoon() {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.controlCenterBundleID)
                .first?.processIdentifier else { return }
        listeningBannerTask?.cancel()
        listeningBannerTask = Task { [weak self] in
            for pause in [0, 30, 60, 120, 200, 350] {
                if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
                guard !Task.isCancelled, let self else { return }
                self.movedListeningWindows += self.moveListeningModeBannerOffscreen(pid: pid)
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            let toRestore = self.movedListeningWindows
            self.movedListeningWindows.removeAll()
            for entry in toRestore {
                var origin = entry.origin
                if let value = AXValueCreate(.cgPoint, &origin) {
                    AXUIElementSetAttributeValue(Self.bounded(entry.window), kAXPositionAttribute as CFString, value)
                }
            }
        }
    }

    private func moveListeningModeBannerOffscreen(pid: pid_t) -> [(window: AXUIElement, origin: CGPoint)] {
        let app = Self.bounded(AXUIElementCreateApplication(pid))
        guard let windows = Self.copyElementArray(app, attribute: kAXWindowsAttribute) else { return [] }
        var moved: [(window: AXUIElement, origin: CGPoint)] = []
        for window in windows where Self.copyStringAttribute(window, attribute: kAXSubroleAttribute) == "AXSystemDialog" {
            guard let frame = Self.copyFrame(window), Self.isOnAnyScreen(frame),
                  frame.width <= 420, frame.height <= 200,
                  matchSmartRoutingConnectedBanner(window) == nil else { continue }
            var target = CGPoint(x: frame.origin.x, y: Self.offscreenY(forHeight: frame.height))
            guard let value = AXValueCreate(.cgPoint, &target) else { continue }
            let result = AXUIElementSetAttributeValue(Self.bounded(window), kAXPositionAttribute as CFString, value)
            Self.logger.notice("Listening mode banner moved off screen result=\(result.rawValue, privacy: .public)")
            if result == .success { moved.append((window, frame.origin)) }
        }
        return moved
    }

    // MARK: AX helpers

    private static func collectContent(
        from element: AXUIElement,
        depth: Int,
        imageDescriptions: inout [String],
        texts: inout [String]
    ) {
        guard depth <= 4, texts.count + imageDescriptions.count < 24 else { return }
        switch copyStringAttribute(element, attribute: kAXRoleAttribute) {
        case kAXImageRole:
            if let desc = copyStringAttribute(element, attribute: kAXDescriptionAttribute) {
                imageDescriptions.append(desc)
            }
        case kAXStaticTextRole:
            if let value = copyStringAttribute(element, attribute: kAXValueAttribute), !value.isEmpty {
                texts.append(value)
            }
        default:
            break
        }
        guard let children = copyElementArray(element, attribute: kAXChildrenAttribute) else { return }
        for child in children {
            collectContent(from: child, depth: depth + 1, imageDescriptions: &imageDescriptions, texts: &texts)
        }
    }

    /// These calls run on the main thread. A busy ControlCenter (Space or app switches) would otherwise
    /// block it for the default 6 s AX timeout, freezing the notch: it could not even close on hover exit.
    private static let messagingTimeout: Float = 0.25

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var valueRef: CFTypeRef?
        _ = bounded(element)
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func copyElementArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var valueRef: CFTypeRef?
        _ = bounded(element)
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let list = valueRef as? [AnyObject] else {
            return nil
        }
        return list.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(item, to: AXUIElement.self)
        }
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        _ = bounded(element)
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// Screen frames in Accessibility coordinates (origin at the top-left of the primary display).
    private static func accessibilityScreenFrames() -> [CGRect] {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return [] }
        return NSScreen.screens.map { screen in
            CGRect(
                x: screen.frame.minX,
                y: primaryMaxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
        }
    }

    private static func isOnAnyScreen(_ frame: CGRect) -> Bool {
        accessibilityScreenFrames().contains { $0.intersects(frame) }
    }

    /// A y coordinate above every display, whatever the arrangement.
    private static func offscreenY(forHeight height: CGFloat) -> CGFloat {
        let topMost = accessibilityScreenFrames().map(\.minY).min() ?? 0
        return topMost - height - 2000
    }

    private static func loadConnectedLabels() -> Set<String> {
        var labels: Set<String> = ["connected", "connectes"]
        if let data = FileManager.default.contents(atPath: controlCenterSoundTablePath),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for case let strings as [String: Any] in table.values {
                if let label = strings["HEADPHONES_CONNECTED"] as? String {
                    let norm = normalizeText(label)
                    if !norm.isEmpty { labels.insert(norm) }
                }
            }
        }
        return labels
    }

    private static func normalizeText(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Observes CoreAudio default output changes and triggers a Dynamic Island Live Activity
/// whenever AirPods or Bluetooth audio devices connect.
@MainActor
final class BluetoothAudioLiveActivityManager: ObservableObject {
    static let shared = BluetoothAudioLiveActivityManager()

    @Published private(set) var currentDevice: BluetoothAudioDeviceInfo?
    @Published private(set) var animationNonce = UUID()
    @Published private(set) var canSuppressSystemBanner: Bool = AXIsProcessTrusted()
    @Published private(set) var axGrantedPendingRestart: Bool = false

    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var activeBluetoothUID: String?
    private var lastTriggerByUID: [String: Date] = [:]
    private var bannerTriggerByUID: [String: Date] = [:]
    private var telemetryTask: Task<Void, Never>?

    private init() {
        // Record initial device silently so launching the app does not flash a stale banner.
        if let initial = Self.currentBluetoothOutputDevice() {
            activeBluetoothUID = initial.uid
            currentDevice = initial
        }
        installDefaultOutputListener()
        refreshBannerSuppressorStatus()
    }

    func refreshBannerSuppressorStatus() {
        BluetoothBannerSuppressor.shared.refreshMonitoringState()
        let inProcessTrusted = AXIsProcessTrusted()
        syncBannerSuppressorTrust(inProcessTrusted)
        guard !inProcessTrusted else {
            if axGrantedPendingRestart { axGrantedPendingRestart = false }
            return
        }
        Task { [weak self] in
            let freshTrusted = await Self.checkAXTrustedViaSubprocess()
            guard let self else { return }
            if !AXIsProcessTrusted() {
                self.axGrantedPendingRestart = freshTrusted
            }
        }
    }

    func syncBannerSuppressorTrust(_ trusted: Bool) {
        if canSuppressSystemBanner != trusted {
            canSuppressSystemBanner = trusted
        }
        if trusted && axGrantedPendingRestart {
            axGrantedPendingRestart = false
        }
    }

    nonisolated private static func checkAXTrustedViaSubprocess() async -> Bool {
        guard let execURL = Bundle.main.executableURL else { return AXIsProcessTrusted() }
        return await withCheckedContinuation { continuation in
            final class OnceGuard: @unchecked Sendable {
                private let lock = NSLock()
                private var resolved = false
                func resolveOnce(_ action: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resolved else { return }
                    resolved = true
                    action()
                }
            }

            let guardBox = OnceGuard()
            let proc = Process()
            proc.executableURL = execURL
            proc.arguments = ["--check-ax"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { finished in
                guardBox.resolveOnce {
                    continuation.resume(returning: finished.terminationStatus == 0)
                }
            }

            do {
                try proc.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                    guardBox.resolveOnce {
                        if proc.isRunning { proc.terminate() }
                        continuation.resume(returning: false)
                    }
                }
            } catch {
                guardBox.resolveOnce {
                    continuation.resume(returning: AXIsProcessTrusted())
                }
            }
        }
    }

    deinit {
        telemetryTask?.cancel()
        if let block = defaultOutputListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
        }
    }

    /// Shows a demo (or the currently active Bluetooth device) Live Activity from Settings.
    func previewLiveActivity() {
        telemetryTask?.cancel()
        if let active = Self.currentBluetoothOutputDevice() {
            presentConnection(for: active, ignoreCooldown: true, suppressSystemBanner: false)
            return
        }
        let demo = BluetoothAudioDeviceInfo(
            uid: "preview-airpods-pro",
            name: "AirPods Pro",
            modelKind: .airPodsPro,
            leftBattery: 84,
            rightBattery: 80,
            caseBattery: 96,
            mainBattery: nil
        )
        currentDevice = demo
        animationNonce = UUID()
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .bluetoothAudio)
    }

    private func installDefaultOutputListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChanged()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        ) == noErr {
            defaultOutputListenerBlock = block
        }
    }

    private func handleDefaultOutputChanged() {
        guard let bluetoothDevice = Self.currentBluetoothOutputDevice() else {
            activeBluetoothUID = nil
            if BoringViewCoordinator.shared.expandingView.show,
               BoringViewCoordinator.shared.expandingView.type == .bluetoothAudio {
                BoringViewCoordinator.shared.toggleExpandingView(status: false, type: .bluetoothAudio)
            }
            return
        }

        // Ignore duplicate callbacks emitted while macOS negotiates HFP/A2DP profiles.
        if activeBluetoothUID == bluetoothDevice.uid {
            return
        }
        activeBluetoothUID = bluetoothDevice.uid

        guard Defaults[.showBluetoothAudioLiveActivity] else { return }
        // Already announced from the system banner (e.g. AirPods put in ear a few seconds later).
        if let announced = bannerTriggerByUID[bluetoothDevice.uid],
           Date().timeIntervalSince(announced) < 8 {
            BluetoothBannerSuppressor.shared.scanSoon()
            return
        }
        presentConnection(for: bluetoothDevice, ignoreCooldown: false, suppressSystemBanner: true)
    }

    /// macOS showed (and we hid) its Smart Routing "Connected" banner. CoreAudio does not always
    /// switch output at that moment (AirPods still out of ear), so announce the connection here.
    func systemBannerSuppressed(deviceName: String) {
        guard Defaults[.showBluetoothAudioLiveActivity] else { return }
        let target = Self.normalizeDeviceName(deviceName)
        let device = Self.bluetoothAudioOutputDevices().first { Self.normalizeDeviceName($0.name) == target }
            ?? BluetoothAudioDeviceInfo(
                uid: "smart-routing:\(deviceName)",
                name: deviceName,
                modelKind: BluetoothAudioModelKind.resolve(vendorID: nil, productID: nil, minorType: nil, name: deviceName)
            )
        if let last = lastTriggerByUID[device.uid], Date().timeIntervalSince(last) < 8 {
            return
        }
        bannerTriggerByUID[device.uid] = Date()
        presentConnection(for: device, ignoreCooldown: false, suppressSystemBanner: false)
    }

    static func bluetoothAudioDeviceNames() -> [String] {
        bluetoothAudioOutputDevices().map(\.name)
    }

    private static func bluetoothAudioOutputDevices() -> [BluetoothAudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            else { return nil }

            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr, streamsSize > 0 else {
                return nil
            }

            guard let name = copyStringProperty(deviceID: id, selector: kAudioObjectPropertyName) else { return nil }
            let uid = copyStringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? name
            let model = BluetoothAudioModelKind.resolve(vendorID: nil, productID: nil, minorType: nil, name: name)
            return BluetoothAudioDeviceInfo(uid: uid, name: name, modelKind: model)
        }
    }

    private func presentConnection(
        for device: BluetoothAudioDeviceInfo,
        ignoreCooldown: Bool,
        suppressSystemBanner: Bool
    ) {
        if !ignoreCooldown,
           let last = lastTriggerByUID[device.uid],
           Date().timeIntervalSince(last) < 2.0 {
            return
        }
        lastTriggerByUID[device.uid] = Date()

        currentDevice = device
        animationNonce = UUID()
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .bluetoothAudio)

        if suppressSystemBanner {
            BluetoothBannerSuppressor.shared.scanSoon()
        }

        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            let enriched = await Self.fetchBluetoothTelemetry(for: device)
            guard !Task.isCancelled, let self else { return }
            if self.currentDevice?.uid == device.uid {
                self.currentDevice = enriched
            }

            // macOS occasionally publishes Bluetooth battery levels slightly after CoreAudio switches.
            if !enriched.hasAnyBattery {
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
                let retried = await Self.fetchBluetoothTelemetry(for: enriched)
                guard !Task.isCancelled else { return }
                if self.currentDevice?.uid == device.uid, retried.hasAnyBattery {
                    self.currentDevice = retried
                }
            }
        }
    }

    private static func currentBluetoothOutputDevice() -> BluetoothAudioDeviceInfo? {
        var defaultID = kAudioObjectUnknown
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &defSize, &defaultID) == noErr,
              defaultID != kAudioObjectUnknown
        else { return nil }

        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(defaultID, &tAddr, 0, nil, &tSize, &transport) == noErr else {
            return nil
        }

        let isBluetooth = (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        guard isBluetooth else { return nil }

        let name = copyStringProperty(deviceID: defaultID, selector: kAudioObjectPropertyName) ?? "AirPods"
        let uid = copyStringProperty(deviceID: defaultID, selector: kAudioDevicePropertyDeviceUID) ?? name
        let model = BluetoothAudioModelKind.resolve(vendorID: nil, productID: nil, minorType: nil, name: name)
        return BluetoothAudioDeviceInfo(uid: uid, name: name, modelKind: model)
    }

    private static func copyStringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = unmanaged?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    nonisolated private static func fetchBluetoothTelemetry(for base: BluetoothAudioDeviceInfo) async -> BluetoothAudioDeviceInfo {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            proc.arguments = ["SPBluetoothDataType", "-json"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            let timeoutItem = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5, execute: timeoutItem)
            defer { timeoutItem.cancel() }

            do {
                try proc.run()
            } catch {
                return base
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let controllers = root["SPBluetoothDataType"] as? [[String: Any]],
                  let first = controllers.first,
                  let connectedEntries = first["device_connected"] as? [[String: Any]]
            else {
                return base
            }

            let targetNorm = normalizeDeviceName(base.name)
            var audioCandidates: [(name: String, details: [String: Any])] = []

            for entry in connectedEntries {
                for (devName, rawDetails) in entry {
                    guard let details = rawDetails as? [String: Any] else { continue }
                    let minor = (details["device_minorType"] as? String)?.lowercased() ?? ""
                    if minor.contains("headphone") || minor.contains("speaker") || minor.contains("audio")
                        || normalizeDeviceName(devName) == targetNorm {
                        audioCandidates.append((devName, details))
                    }
                }
            }

            let matched = audioCandidates.first(where: { normalizeDeviceName($0.name) == targetNorm })
                ?? audioCandidates.first(where: {
                    let cand = normalizeDeviceName($0.name)
                    return !cand.isEmpty && (targetNorm.contains(cand) || cand.contains(targetNorm))
                })
                ?? (audioCandidates.count == 1 ? audioCandidates.first : nil)

            guard let matched else { return base }
            let d = matched.details
            let vendorID = parseHexInt(d["device_vendorID"] as? String)
            let productID = parseHexInt(d["device_productID"] as? String)
            let minorType = d["device_minorType"] as? String
            let model = BluetoothAudioModelKind.resolve(
                vendorID: vendorID,
                productID: productID,
                minorType: minorType,
                name: matched.name
            )

            return BluetoothAudioDeviceInfo(
                uid: base.uid,
                name: matched.name.isEmpty ? base.name : matched.name,
                modelKind: model,
                leftBattery: parseBatteryPercent(d["device_batteryLevelLeft"] as? String),
                rightBattery: parseBatteryPercent(d["device_batteryLevelRight"] as? String),
                caseBattery: parseBatteryPercent(d["device_batteryLevelCase"] as? String),
                mainBattery: parseBatteryPercent(d["device_batteryLevelMain"] as? String)
            )
        }.value
    }

    nonisolated private static func normalizeDeviceName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func parseHexInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "0x", with: "")
        return Int(cleaned, radix: 16)
    }

    nonisolated private static func parseBatteryPercent(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = String(raw.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) })
        guard let val = Int(digits), (0...100).contains(val) else { return nil }
        return val
    }
}

private struct BluetoothBatteryRingView: View {
    let percentage: Int
    var size: CGFloat = 24
    var lineWidth: CGFloat = 2.5
    @State private var animatedFraction: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedFraction: CGFloat {
        CGFloat(max(0, min(100, percentage))) / 100.0
    }

    private var ringColor: Color {
        if percentage <= 15 { return Color(red: 1.0, green: 0.27, blue: 0.23) }
        if percentage <= 35 { return Color(red: 1.0, green: 0.78, blue: 0.14) }
        return Color(red: 0.16, green: 0.85, blue: 0.36)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: animatedFraction)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(percentage)")
                .font(.system(size: max(8.5, round(size * 0.38)), weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .foregroundStyle(ringColor)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion {
                animatedFraction = clampedFraction
            } else {
                animatedFraction = 0
                withAnimation(.spring(response: 0.58, dampingFraction: 0.84)) {
                    animatedFraction = clampedFraction
                }
            }
        }
        .onChange(of: percentage) { _, _ in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                animatedFraction = clampedFraction
            }
        }
    }
}

struct BluetoothAudioClosedNotchView: View {
    @ObservedObject var manager = BluetoothAudioLiveActivityManager.shared
    let closedHeight: CGFloat
    let centerSpacerWidth: CGFloat
    let isHovered: Bool

    static let expandedWingWidth: CGFloat = 112

    static func compactWingWidth(closedHeight: CGFloat) -> CGFloat {
        closedHeight > 0 ? max(24, closedHeight - 6) : 26
    }

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var earHeight: CGFloat {
        closedHeight > 0 ? max(28, closedHeight) : 32
    }

    var body: some View {
        let device = manager.currentDevice ?? BluetoothAudioDeviceInfo(
            uid: "fallback",
            name: "AirPods Pro",
            modelKind: .airPodsPro
        )
        let accent = device.modelKind.accentColor
        let breakdown = device.hoverBreakdownText
        let expanded = isHovered
        let wingWidth = expanded ? Self.expandedWingWidth : Self.compactWingWidth(closedHeight: closedHeight)

        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: device.modelKind.symbolName)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18, alignment: .center)
                    .conditionalModifier(!reduceMotion) { view in
                        view.symbolEffect(.bounce.up, value: manager.animationNonce)
                    }

                if expanded {
                    Text(device.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                        .transition(.opacity.combined(with: .offset(x: -4)))
                }
            }
            .padding(.leading, 4)
            .frame(width: wingWidth, height: earHeight, alignment: .leading)
            .clipped()
            .offset(x: appeared || reduceMotion ? 0 : 4)

            Rectangle()
                .fill(.black)
                .frame(width: closedHeight > 0 ? max(20, centerSpacerWidth) : 18)

            HStack(spacing: 6) {
                if expanded, let breakdown {
                    Text(breakdown)
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                        .transition(.opacity.combined(with: .offset(x: 4)))
                }

                if let primary = device.primaryBatteryPercentage {
                    BluetoothBatteryRingView(percentage: primary, size: min(20, max(17, earHeight - 12)), lineWidth: 2)
                } else {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .conditionalModifier(!reduceMotion) { view in
                            view.symbolEffect(.variableColor.iterative, value: appeared)
                        }
                }
            }
            .padding(.trailing, 3)
            .frame(width: wingWidth, height: earHeight, alignment: .trailing)
            .clipped()
            .offset(x: appeared || reduceMotion ? 0 : -4)
        }
        .frame(height: earHeight, alignment: .center)
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: expanded)
        .help(device.name)
        .id(manager.animationNonce)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                appeared = false
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    appeared = true
                }
            }
        }
    }
}

// MARK: - AirPods listening mode (noise cancellation, transparency, adaptive)

/// macOS gives an unentitled app no way to read the AirPods listening mode: the private IOBluetooth and
/// AVOutputDevice getters return nothing. System processes log every change publicly, so a filtered
/// `log stream` is the trigger. Three lines, each covering cases the others miss:
/// - ControlCenter `sound`: "listening mode active-noise-cancellation -> audio-transparency, in ear: …" (stem
///   presses, even when the AirPods are not the Mac's output and Apple shows no banner)
/// - heard: "Changed listening mode 3" (changes made from Control Center, including Adaptive)
/// - ControlCenter `system-banners`: "Showing listening mode banner with mode: …" (Apple's banner is up: hide it)
@MainActor
final class AirPodsListeningModeMonitor: ObservableObject {
    static let shared = AirPodsListeningModeMonitor()

    enum Mode: Equatable {
        case noiseCancellation
        case transparency
        case adaptive
        case off

        /// heard's numbering, the same as the private IOBluetooth / AVOutputDevice enums
        init?(heardNumber: Int) {
            switch heardNumber {
            case 1: self = .off
            case 2: self = .noiseCancellation
            case 3: self = .transparency
            case 4: self = .adaptive
            default: return nil
            }
        }

        init?(controlCenterName: String) {
            switch controlCenterName {
            case "active-noise-cancellation": self = .noiseCancellation
            case "audio-transparency": self = .transparency
            case "automatic", "adaptive": self = .adaptive
            case "normal", "off": self = .off
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .noiseCancellation: return String(localized: "Noise Cancellation")
            case .transparency: return String(localized: "Transparency")
            case .adaptive: return String(localized: "Adaptive")
            case .off: return String(localized: "Listening Mode Off")
            }
        }

        var symbolName: String {
            switch self {
            case .noiseCancellation: return "person.crop.circle.fill"
            case .transparency: return "person.wave.2.fill"
            case .adaptive: return "person.and.background.dotted"
            case .off: return "circle.dashed"
            }
        }

        var tint: Color {
            switch self {
            case .noiseCancellation: return Color(red: 0.45, green: 0.66, blue: 1.0)
            case .transparency: return Color(red: 1.0, green: 0.8, blue: 0.36)
            case .adaptive: return Color(red: 0.78, green: 0.62, blue: 1.0)
            case .off: return .white.opacity(0.7)
            }
        }
    }

    @Published private(set) var mode: Mode = .noiseCancellation
    @Published private(set) var animationNonce = UUID()

    private static let logger = Logger(subsystem: "theboringteam.boringnotch", category: "ListeningMode")
    private static let bannerMarker = "listening mode banner with mode: "
    private static let heardMarker = "Changed listening mode "
    private static let transition = try? NSRegularExpression(pattern: #"listening mode (\S+) -> ([A-Za-z-]+)"#)

    /// Every source reports the same change, a few hundred ms apart: only a new mode animates
    private var lastKnownMode: Mode?

    private var process: Process?
    private var pending = Data()
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var quickExits = 0
    private var launchedAt = Date.distantPast
    private var restartTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Defaults.publisher(.showListeningModeLiveActivity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue { self?.launchStream() } else { self?.stopStream() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stopStream() }
            .store(in: &cancellables)
    }

    func preview() {
        let next: Mode = mode == .noiseCancellation ? .transparency : .noiseCancellation
        present(next, hideSystemBanner: false)
    }

    private func launchStream() {
        guard process == nil else { return }
        restartTask?.cancel()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream", "--style", "ndjson", "--level", "default",
            "--predicate",
            #"(process == "ControlCenter" AND (category == "sound" OR category == "system-banners") AND eventMessage CONTAINS "listening mode") OR (process == "heard" AND eventMessage BEGINSWITH "Changed listening mode ")"#
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = (try? handle.read(upToCount: 65_536)) ?? Data()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // DispatchQueue.main.async guarantees strict FIFO chunk ordering for NDJSON framing
            DispatchQueue.main.async { [weak self, weak proc] in
                MainActor.assumeIsolated {
                    guard let self, let proc, self.process === proc else { return }
                    self.consume(data)
                }
            }
        }
        proc.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.streamEnded(ended)
                }
            }
        }
        do {
            try proc.run()
            process = proc
            launchedAt = Date()
        } catch {
            Self.logger.error("Could not start log stream: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopStream() {
        restartTask?.cancel()
        pending.removeAll()
        guard let proc = process else { return }
        process = nil
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
    }

    /// `log stream` can exit (logd restart, sleep): start it again, but give up if it keeps dying at launch,
    /// which is what happens on a non-admin account.
    private func streamEnded(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        pending.removeAll()
        guard Defaults[.showListeningModeLiveActivity] else { return }
        quickExits = Date().timeIntervalSince(launchedAt) < 5 ? quickExits + 1 : 0
        guard quickExits < 5 else {
            Self.logger.error("log stream keeps exiting (status \(ended.terminationStatus, privacy: .public)), listening mode detection disabled")
            return
        }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(2 << min(self?.quickExits ?? 0, 4))))
            guard !Task.isCancelled else { return }
            self?.launchStream()
        }
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let (mode, appleBannerShown) = Self.parse(message) else { continue }
            if appleBannerShown && BoringViewModel.openNotchCount == 0 && Defaults[.showListeningModeLiveActivity] {
                BluetoothBannerSuppressor.shared.hideListeningModeBannerSoon()
            }
            guard mode != lastKnownMode else { continue }
            lastKnownMode = mode
            present(mode, hideSystemBanner: false)
        }
    }

    private static func parse(_ message: String) -> (mode: Mode, appleBannerShown: Bool)? {
        if let range = message.range(of: bannerMarker) {
            let name = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Mode(controlCenterName: name).map { ($0, true) } ?? unknown(name)
        }
        if let range = message.range(of: heardMarker) {
            let digits = message[range.upperBound...].prefix { $0.isNumber }
            guard let number = Int(digits) else { return nil }
            return Mode(heardNumber: number).map { ($0, false) } ?? unknown("heard \(number)")
        }
        let ns = message as NSString
        if let match = transition?.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 2))
            return Mode(controlCenterName: name).map { ($0, false) } ?? unknown(name)
        }
        return nil
    }

    private static func unknown(_ name: String) -> (mode: Mode, appleBannerShown: Bool)? {
        logger.notice("Unknown listening mode \(name, privacy: .public)")
        return nil
    }

    private func present(_ newMode: Mode, hideSystemBanner: Bool) {
        guard Defaults[.showListeningModeLiveActivity] else { return }
        mode = newMode
        animationNonce = UUID()
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .listeningMode)
        // The animation only shows on a closed notch: with the notch open, Apple's banner stays the feedback
        if hideSystemBanner && BoringViewModel.openNotchCount == 0 {
            BluetoothBannerSuppressor.shared.hideListeningModeBannerSoon()
        }
    }
}

struct ListeningModeClosedNotchView: View {
    @ObservedObject var monitor = AirPodsListeningModeMonitor.shared
    @ObservedObject var bluetooth = BluetoothAudioLiveActivityManager.shared
    let closedHeight: CGFloat
    let centerSpacerWidth: CGFloat

    static let wingWidth: CGFloat = 122

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var earHeight: CGFloat {
        closedHeight > 0 ? max(28, closedHeight) : 32
    }

    var body: some View {
        let mode = monitor.mode
        HStack(spacing: 0) {
            Image(systemName: bluetooth.currentDevice?.modelKind.symbolName ?? "airpodspro")
                .font(.system(size: 16, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .padding(.leading, 6)
                .frame(width: Self.wingWidth, height: earHeight, alignment: .leading)
                .offset(x: appeared || reduceMotion ? 0 : 4)

            Rectangle()
                .fill(.black)
                .frame(width: closedHeight > 0 ? max(20, centerSpacerWidth) : 18)

            HStack(spacing: 6) {
                Text(mode.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(mode.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: mode.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(mode.tint)
                    .frame(width: 18, height: 18)
                    .contentTransition(.symbolEffect(.replace))
                    .conditionalModifier(!reduceMotion) { view in
                        view.symbolEffect(.bounce, value: monitor.animationNonce)
                    }
            }
            .padding(.trailing, 6)
            .frame(width: Self.wingWidth, height: earHeight, alignment: .trailing)
            .offset(x: appeared || reduceMotion ? 0 : -4)
        }
        .frame(height: earHeight, alignment: .center)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: mode)
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                appeared = true
            }
        }
    }
}

// MARK: - Notch Timer (Dynamic Island style countdown)

@MainActor
final class NotchTimerManager: ObservableObject {
    static let shared = NotchTimerManager()

    enum Phase: Equatable {
        case idle
        case running
        case paused
        case finished
    }

    static let accent = Color(red: 1.0, green: 0.62, blue: 0.04)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var endDate: Date?
    private var ticker: Timer?
    private var alarmTimer: Timer?
    private var alarmStartedAt: Date?
    private var finishedClearTask: Task<Void, Never>?

    private static let alarmRingDuration: TimeInterval = 30
    private static let finishedAutoClearDelay: TimeInterval = 60

    private init() {}

    var isActive: Bool { phase != .idle }

    var scheduledEndDate: Date? { endDate }

    var remainingText: String {
        Self.format(phase == .finished ? 0 : remaining)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    func start(minutes: Int) {
        start(duration: TimeInterval(minutes * 60))
    }

    func start(duration newDuration: TimeInterval) {
        guard newDuration > 0 else { return }
        stopAlarm()
        duration = newDuration
        remaining = newDuration
        endDate = Date().addingTimeInterval(newDuration)
        phase = .running
        startTicker()
    }

    func togglePause() {
        switch phase {
        case .running: pause()
        case .paused: resume()
        default: break
        }
    }

    func pause() {
        guard phase == .running, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        phase = .paused
        stopTicker()
    }

    func resume() {
        guard phase == .paused else { return }
        endDate = Date().addingTimeInterval(remaining)
        phase = .running
        startTicker()
    }

    func add(minutes: Int) {
        let extra = TimeInterval(minutes * 60)
        switch phase {
        case .running:
            endDate = endDate?.addingTimeInterval(extra)
            duration += extra
            remaining += extra
        case .paused:
            duration += extra
            remaining += extra
        case .finished, .idle:
            start(duration: extra)
        }
    }

    func repeatLast() {
        start(duration: duration > 0 ? duration : 300)
    }

    func cancel() {
        stopTicker()
        stopAlarm()
        endDate = nil
        remaining = 0
        duration = 0
        phase = .idle
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard phase == .running, let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            finish()
        } else if Int(left.rounded(.up)) != Int(remaining.rounded(.up)) {
            remaining = left
        }
    }

    private func finish() {
        stopTicker()
        endDate = nil
        remaining = 0
        phase = .finished
        startAlarm()
        finishedClearTask?.cancel()
        finishedClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedAutoClearDelay))
            guard !Task.isCancelled, let self, self.phase == .finished else { return }
            self.cancel()
        }
    }

    private func startAlarm() {
        stopAlarm(keepClearTask: true)
        alarmStartedAt = Date()
        playAlarmSound()
        let timer = Timer(timeInterval: 2.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.alarmStartedAt else { return }
                if Date().timeIntervalSince(started) >= Self.alarmRingDuration {
                    self.stopAlarm(keepClearTask: true)
                } else {
                    self.playAlarmSound()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        alarmTimer = timer
    }

    private func stopAlarm(keepClearTask: Bool = false) {
        alarmTimer?.invalidate()
        alarmTimer = nil
        alarmStartedAt = nil
        if !keepClearTask {
            finishedClearTask?.cancel()
            finishedClearTask = nil
        }
    }

    private func playAlarmSound() {
        guard Defaults[.timerSoundEnabled] else { return }
        let sound = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Ping"))
        sound?.stop()
        sound?.play()
    }
}

private struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct NotchRoundIconButton: View {
    let systemName: String
    let foreground: Color
    let background: Color
    var size: CGFloat = 34
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(background).brightness(isHovering ? 0.06 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(NotchPressStyle())
        .help(help)
        .onHover { isHovering = $0 }
    }
}

private struct NotchPillButton: View {
    let title: String
    var systemImage: String? = nil
    let accent: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(Capsule().fill(accent.opacity(isHovering ? 0.28 : 0.2)))
            .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .onHover { isHovering = $0 }
    }
}

private struct NotchChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? accent : .white.opacity(0.5))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(isSelected ? accent.opacity(0.22) : .white.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct NotchRulerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Catches trackpad / mouse wheel scrolls while the pointer is over the ruler.
@MainActor
private final class NotchScrollWheelMonitor: ObservableObject {
    var isHovering = false
    var handler: ((NSEvent) -> Bool)?
    nonisolated(unsafe) private var monitor: Any?

    deinit {
        if let monitor {
            nonisolated(unsafe) let token = monitor
            DispatchQueue.main.async {
                NSEvent.removeMonitor(token)
            }
        }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isHovering, let handler = self.handler else { return event }
            return handler(event) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

private struct NotchRulerCanvas: View, Animatable {
    var value: Double
    let range: ClosedRange<Int>
    let labelEvery: Int
    let label: (Int) -> String
    let accent: Color
    let tickSpacing: CGFloat

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let labelY: CGFloat = 7
            let tickTop: CGFloat = 18
            let tickBottom = size.height
            let halfCount = Int(ceil(Double(centerX / tickSpacing))) + 1
            let lower = max(range.lowerBound, Int(floor(value)) - halfCount)
            let upper = min(range.upperBound, Int(ceil(value)) + halfCount)
            guard lower <= upper else { return }
            let selected = Int(value.rounded())
            let highlight = Color(white: 0.97)

            for tick in lower...upper {
                let x = centerX + CGFloat(Double(tick) - value) * tickSpacing
                let distance = abs(Double(tick) - value)
                let isPast = Double(tick) <= value + 0.001
                let opacity = isPast ? max(0.3, 1.0 - distance * 0.04) : 0.2
                let isSelected = tick == selected
                let isMajor = tick % labelEvery == 0

                var path = Path()
                path.move(to: CGPoint(x: x, y: isMajor || isSelected ? tickTop : tickTop + 5))
                path.addLine(to: CGPoint(x: x, y: tickBottom))
                context.stroke(
                    path,
                    with: .color(isSelected ? highlight : accent.opacity(opacity)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )

                if isMajor {
                    let text = Text(label(tick))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isSelected ? highlight : accent.opacity(isPast ? max(0.45, opacity) : 0.32))
                    context.draw(text, at: CGPoint(x: x, y: labelY), anchor: .center)
                }
            }
        }
    }
}

/// Horizontal tick ruler used to pick a duration (timer, caffeine). `value` is in ticks.
private struct NotchDurationRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Int>
    let labelEvery: Int
    let label: (Int) -> String
    let accent: Color
    var interactive: Bool = true
    var tickSpacing: CGFloat = 10

    @State private var dragStartValue: Double?
    @State private var holdsNotchOpen = false
    @State private var snapTask: Task<Void, Never>?
    @StateObject private var wheel = NotchScrollWheelMonitor()

    var body: some View {
        VStack(spacing: 3) {
            NotchRulerCanvas(
                value: value,
                range: range,
                labelEvery: labelEvery,
                label: label,
                accent: accent,
                tickSpacing: tickSpacing
            )
            .frame(height: 42)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.14),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            NotchRulerTriangle()
                .fill(accent)
                .frame(width: 10, height: 6)
                .opacity(interactive ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture, including: interactive ? .all : .none)
        .onHover { wheel.isHovering = $0 }
        .onAppear {
            installWheelHandler()
            wheel.start()
        }
        .onDisappear {
            wheel.stop()
            snapTask?.cancel()
            releaseNotchHold()
        }
        .onChange(of: interactive) { _, isNowInteractive in
            installWheelHandler()
            if !isNowInteractive {
                dragStartValue = nil
                releaseNotchHold()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            dragStartValue = nil
            releaseNotchHold()
        }
        .onChange(of: Int(value.rounded())) { _, _ in
            guard interactive else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                snapTask?.cancel()
                let start = dragStartValue ?? value
                if dragStartValue == nil { dragStartValue = start }
                if !holdsNotchOpen {
                    holdsNotchOpen = true
                    SharingStateManager.shared.beginInteraction()
                }
                value = clamp(start - Double(drag.translation.width / tickSpacing))
            }
            .onEnded { drag in
                let start = dragStartValue ?? value
                dragStartValue = nil
                let projected = clamp(start - Double(drag.predictedEndTranslation.width / tickSpacing))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    value = projected.rounded()
                }
                releaseNotchHold()
            }
    }

    /// Keeps the notch open while the ruler is dragged, even if the pointer overshoots the notch.
    /// Releasing posts `.sharingDidFinish`, which closes the notch only if the pointer is outside.
    private func releaseNotchHold() {
        guard holdsNotchOpen else { return }
        holdsNotchOpen = false
        SharingStateManager.shared.endInteraction()
    }

    private func installWheelHandler() {
        let binding = $value
        let isInteractive = interactive
        let spacing = tickSpacing
        let bounds = range
        wheel.handler = { event in
            guard isInteractive else { return false }
            let clampValue: (Double) -> Double = { min(Double(bounds.upperBound), max(Double(bounds.lowerBound), $0)) }
            if event.hasPreciseScrollingDeltas {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
                binding.wrappedValue = clampValue(binding.wrappedValue - Double(event.scrollingDeltaX / spacing))
            } else {
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                guard delta != 0 else { return false }
                binding.wrappedValue = clampValue(binding.wrappedValue.rounded() + (delta > 0 ? -1 : 1))
            }
            scheduleSnap(binding)
            return true
        }
    }

    private func scheduleSnap(_ binding: Binding<Double>) {
        snapTask?.cancel()
        snapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                binding.wrappedValue = binding.wrappedValue.rounded()
            }
        }
    }

    private func clamp(_ raw: Double) -> Double {
        min(Double(range.upperBound), max(Double(range.lowerBound), raw))
    }
}

// MARK: Closed notch (compact, notch height)

struct TimerClosedNotchView: View {
    @ObservedObject var timer = NotchTimerManager.shared
    let closedHeight: CGFloat
    let centerSpacerWidth: CGFloat

    static let wingWidth: CGFloat = 64

    @State private var appeared = false
    @State private var finishedBlink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var earHeight: CGFloat {
        closedHeight > 0 ? max(28, closedHeight) : 32
    }

    var body: some View {
        let accent = NotchTimerManager.accent
        let isFinished = timer.phase == .finished
        let isPaused = timer.phase == .paused
        let buttonSize = min(21, max(18, earHeight - 11))

        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if isFinished {
                    NotchRoundIconButton(
                        systemName: "arrow.clockwise",
                        foreground: accent,
                        background: accent.opacity(0.24),
                        size: buttonSize,
                        help: String(localized: "Repeat Timer")
                    ) {
                        timer.repeatLast()
                    }
                } else {
                    NotchRoundIconButton(
                        systemName: isPaused ? "play.fill" : "pause.fill",
                        foreground: accent,
                        background: accent.opacity(0.24),
                        size: buttonSize,
                        help: isPaused ? String(localized: "Resume") : String(localized: "Pause")
                    ) {
                        timer.togglePause()
                    }
                }

                NotchRoundIconButton(
                    systemName: "xmark",
                    foreground: .white.opacity(0.85),
                    background: .white.opacity(0.15),
                    size: buttonSize,
                    help: isFinished ? String(localized: "Stop") : String(localized: "Cancel Timer")
                ) {
                    timer.cancel()
                }
            }
            .padding(.leading, 4)
            .frame(width: Self.wingWidth, height: earHeight, alignment: .leading)
            .offset(x: appeared || reduceMotion ? 0 : 6)

            Rectangle()
                .fill(.black)
                .frame(width: closedHeight > 0 ? max(20, centerSpacerWidth) : 18)

            Text(timer.remainingText)
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accent.opacity(isPaused ? 0.55 : 1.0))
                .opacity(isFinished && finishedBlink ? 0.35 : 1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText(countsDown: true))
                .animation(.smooth(duration: 0.3), value: timer.remainingText)
                .animation(.easeInOut(duration: 0.2), value: isPaused)
                .padding(.trailing, 4)
                .frame(width: Self.wingWidth, height: earHeight, alignment: .trailing)
                .offset(x: appeared || reduceMotion ? 0 : -6)
        }
        .frame(height: earHeight, alignment: .center)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    appeared = true
                }
            }
            updateBlink(isFinished: isFinished)
        }
        .onChange(of: isFinished) { _, finished in
            updateBlink(isFinished: finished)
        }
    }

    private func updateBlink(isFinished: Bool) {
        guard isFinished, !reduceMotion else {
            finishedBlink = false
            return
        }
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            finishedBlink = true
        }
    }
}

// MARK: Open notch pickers

struct TimerPickerView: View {
    @ObservedObject var timer = NotchTimerManager.shared
    @Default(.timerLastMinutes) private var lastMinutes
    @Default(.timerSoundEnabled) private var soundEnabled
    @State private var selection: Double = 25

    private static let focusMinutes = 25
    private static let breakMinutes = 5

    var body: some View {
        let accent = NotchTimerManager.accent
        let active = timer.isActive
        let selectedMinutes = Int(selection.rounded())

        VStack(spacing: 6) {
            HStack {
                if active {
                    NotchChip(title: statusTitle, isSelected: true, accent: accent) {}
                        .allowsHitTesting(false)
                } else {
                    NotchChip(title: String(localized: "Focus"), isSelected: selectedMinutes == Self.focusMinutes, accent: accent) {
                        select(Self.focusMinutes)
                    }
                }
                Spacer()
                if active {
                    if let end = timer.scheduledEndDate {
                        Text(String(localized: "Ends at \(end.formatted(date: .omitted, time: .shortened))"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                } else {
                    NotchChip(title: String(localized: "Break"), isSelected: selectedMinutes == Self.breakMinutes, accent: accent) {
                        select(Self.breakMinutes)
                    }
                }
            }

            NotchDurationRuler(
                value: active ? .constant(timer.remaining / 60) : $selection,
                range: 1...120,
                labelEvery: 5,
                label: { "\($0)" },
                accent: accent,
                interactive: !active
            )
            .animation(active ? .linear(duration: 0.9) : nil, value: timer.remaining)

            HStack(spacing: 10) {
                switch timer.phase {
                case .idle:
                    NotchPillButton(title: String(localized: "Start Timer"), accent: accent) {
                        lastMinutes = selectedMinutes
                        timer.start(minutes: selectedMinutes)
                    }
                case .running, .paused:
                    let paused = timer.phase == .paused
                    NotchPillButton(
                        title: paused ? String(localized: "Resume") : String(localized: "Pause"),
                        systemImage: paused ? "play.fill" : "pause.fill",
                        accent: accent
                    ) {
                        timer.togglePause()
                    }
                    NotchRoundIconButton(systemName: "plus", foreground: accent, background: accent.opacity(0.2), help: String(localized: "Add 1 Minute")) {
                        timer.add(minutes: 1)
                    }
                    NotchRoundIconButton(systemName: "xmark", foreground: .white.opacity(0.85), background: .white.opacity(0.14), help: String(localized: "Cancel Timer")) {
                        timer.cancel()
                    }
                case .finished:
                    NotchPillButton(title: String(localized: "Restart Timer"), systemImage: "arrow.clockwise", accent: accent) {
                        timer.repeatLast()
                    }
                    NotchRoundIconButton(systemName: "xmark", foreground: .white.opacity(0.85), background: .white.opacity(0.14), help: String(localized: "Stop")) {
                        timer.cancel()
                    }
                }

                NotchRoundIconButton(
                    systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    foreground: soundEnabled ? accent : .white.opacity(0.5),
                    background: soundEnabled ? accent.opacity(0.2) : .white.opacity(0.1),
                    help: soundEnabled ? String(localized: "Sound On") : String(localized: "Sound Off")
                ) {
                    soundEnabled.toggle()
                }

                Spacer(minLength: 8)

                Text(active ? timer.remainingText : NotchTimerManager.format(Double(selectedMinutes * 60)))
                    .font(.system(size: 36, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(accent.opacity(timer.phase == .paused ? 0.55 : 1))
                    .lineLimit(1)
                    .contentTransition(.numericText(countsDown: active))
                    .animation(.smooth(duration: 0.25), value: active ? timer.remainingText : "\(selectedMinutes)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .onAppear {
            selection = Double(min(120, max(1, lastMinutes)))
        }
    }

    private var statusTitle: String {
        switch timer.phase {
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Done")
        default: return String(localized: "In Progress")
        }
    }

    private func select(_ minutes: Int) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            selection = Double(minutes)
        }
    }
}

struct CaffeinePickerView: View {
    @ObservedObject var caffeine = CaffeineManager.shared
    @Default(.caffeineLastMinutes) private var lastMinutes
    @State private var selection: Double = 12

    static let accent = Color(red: 0.93, green: 0.69, blue: 0.43)
    private static let minutesPerTick = 5
    private static let tickRange = 1...96

    static func durationText(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0, paused: caffeine.expiresAt == nil)) { context in
            content(now: context.date)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .onAppear {
            let ticks = max(1, lastMinutes / Self.minutesPerTick)
            selection = Double(min(Self.tickRange.upperBound, ticks))
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let accent = Self.accent
        let active = caffeine.isActive
        let indefinite = active && caffeine.expiresAt == nil
        let remainingMinutes = caffeine.expiresAt.map { max(0, $0.timeIntervalSince(now) / 60) }
        let selectedMinutes = Int(selection.rounded()) * Self.minutesPerTick

        VStack(spacing: 6) {
            HStack {
                NotchChip(title: String(localized: "Indefinitely ∞"), isSelected: indefinite, accent: accent) {
                    if indefinite {
                        caffeine.deactivate()
                    } else {
                        caffeine.activate(durationMinutes: nil)
                    }
                }
                Spacer()
                Text(active ? String(localized: "Mac stays awake") : String(localized: "Keep your Mac awake"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? accent.opacity(0.8) : .white.opacity(0.45))
            }

            NotchDurationRuler(
                value: remainingMinutes.map { .constant($0 / Double(Self.minutesPerTick)) } ?? $selection,
                range: Self.tickRange,
                labelEvery: 6,
                label: { Self.durationText(minutes: $0 * Self.minutesPerTick) },
                accent: accent,
                interactive: !active
            )
            .opacity(indefinite ? 0.4 : 1)
            .animation(remainingMinutes != nil ? .linear(duration: 0.9) : nil, value: remainingMinutes ?? 0)

            HStack(spacing: 10) {
                if active {
                    NotchPillButton(title: String(localized: "Turn Off"), systemImage: "cup.and.saucer", accent: accent) {
                        caffeine.deactivate()
                    }
                } else {
                    NotchPillButton(title: String(localized: "Keep Awake"), systemImage: "cup.and.saucer.fill", accent: accent) {
                        lastMinutes = selectedMinutes
                        caffeine.activate(durationMinutes: selectedMinutes)
                    }
                }

                Spacer(minLength: 8)

                Text(bigText(indefinite: indefinite, remainingMinutes: remainingMinutes, selectedMinutes: selectedMinutes))
                    .font(.system(size: 36, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: selectedMinutes)
            }
        }
    }

    private func bigText(indefinite: Bool, remainingMinutes: Double?, selectedMinutes: Int) -> String {
        if indefinite { return "∞" }
        if let remainingMinutes { return Self.durationText(minutes: max(1, Int(remainingMinutes.rounded(.up)))) }
        return Self.durationText(minutes: selectedMinutes)
    }
}

// MARK: - Caffeine Manager (Gravity Keep-Mac-Awake Extension)

@MainActor
final class CaffeineManager: ObservableObject {
    static let shared = CaffeineManager()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var expiresAt: Date? = nil
    @Published private(set) var remainingText: String = ""

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var expiryTimer: Timer?

    private init() {}

    func toggle(durationMinutes: Int? = nil) {
        if isActive && durationMinutes == nil {
            deactivate()
        } else {
            activate(durationMinutes: durationMinutes)
        }
    }

    func activate(durationMinutes: Int? = nil) {
        deactivate()
        let reason = "BoringNotch Caffeine Mode (Prevent Sleep)" as CFString
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
            if let mins = durationMinutes, mins > 0 {
                let target = Date().addingTimeInterval(TimeInterval(mins * 60))
                expiresAt = target
                updateRemainingText()
                let refreshTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.tick()
                    }
                }
                refreshTimer.tolerance = 1.0
                RunLoop.main.add(refreshTimer, forMode: .common)
                timer = refreshTimer

                let exactExpiry = Timer(fire: target, interval: 0, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.tick()
                    }
                }
                RunLoop.main.add(exactExpiry, forMode: .common)
                expiryTimer = exactExpiry
            } else {
                expiresAt = nil
                remainingText = "∞"
            }
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        if isActive && assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
        expiresAt = nil
        remainingText = ""
    }

    private func tick() {
        guard let expiresAt else { return }
        if Date() >= expiresAt {
            deactivate()
        } else {
            updateRemainingText()
        }
    }

    private func updateRemainingText() {
        guard let expiresAt else {
            remainingText = isActive ? "∞" : ""
            return
        }
        let mins = max(1, Int(ceil(expiresAt.timeIntervalSinceNow / 60.0)))
        remainingText = mins >= 60 ? "\(mins / 60)h\(mins % 60 > 0 ? "\(mins % 60)m" : "")" : "\(mins)m"
    }
}

// MARK: - Gravity Clipboard History Manager & Notch View

struct ClipboardHistoryItem: Identifiable, Equatable, Codable {
    enum Kind: String, Equatable, Codable {
        case text
        case url
        case color
        case file

        var localizedBadge: String {
            switch self {
            case .text: return String(localized: "TEXT")
            case .url: return String(localized: "URL")
            case .color: return String(localized: "COLOR")
            case .file: return String(localized: "FILE")
            }
        }
    }

    let id: UUID
    let kind: Kind
    let content: String
    let fileURL: URL?
    let sourceAppBundleID: String?
    let timestamp: Date
    var isPinned: Bool = false

    var displayTitle: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        return String(content.prefix(240))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var iconName: String {
        switch kind {
        case .text: return "doc.text.fill"
        case .url: return "link"
        case .color: return "paintpalette.fill"
        case .file: return "doc.fill"
        }
    }
}

@MainActor
final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()

    static let historyLimitOptions = [20, 40, 100, 200]

    @Published private(set) var items: [ClipboardHistoryItem] = [] {
        didSet { scheduleSave() }
    }
    @Published var searchQuery: String = ""
    @Published var onlyPinned: Bool = false
    @Published var recentlyCopiedID: UUID? = nil

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var deactivationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var settingsCancellables = Set<AnyCancellable>()
    private var pendingSave: DispatchWorkItem?
    private var isRestoring = false
    private nonisolated static let saveQueue = DispatchQueue(label: "theboringteam.boringnotch.clipboard-history", qos: .utility)

    private nonisolated static let historyFileURL: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("Clips", isDirectory: true)
            .appendingPathComponent("history.json")
    }()

    private init() {
        CapsLockHUDMonitor.shared.start()
        if Defaults[.showClipboardTab] {
            restoreHistory()
            captureCurrentPasteboard(initial: true)
        }
        Defaults.publisher(.clipboardHistoryLimit, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.items = Self.trimmed(self.items)
            }
            .store(in: &settingsCancellables)
        Defaults.publisher(.persistClipboardHistory, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue {
                    self.saveNow()
                } else {
                    self.pendingSave?.cancel()
                    Self.saveQueue.async { try? FileManager.default.removeItem(at: Self.historyFileURL) }
                }
            }
            .store(in: &settingsCancellables)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingSave()
            }
        }
        Defaults.publisher(.showClipboardTab, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if change.newValue && self.items.isEmpty {
                        self.restoreHistory()
                    }
                    self.updatePasteboardPolling()
                }
            }
            .store(in: &settingsCancellables)
        updatePasteboardPolling()
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            // Synchronously update lastChangeCount on the main queue before the poll timer can read concealed secrets
            MainActor.assumeIsolated {
                self?.handleApplicationDidDeactivate(bundleID: bundleID)
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private func restoreHistory() {
        guard Defaults[.persistClipboardHistory] else { return }
        Self.saveQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: Self.historyFileURL),
                  let saved = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else { return }
            let fm = FileManager.default
            let existing = saved.filter { item in
                guard item.kind == .file else { return true }
                guard let fileURL = item.fileURL else { return false }
                return fm.fileExists(atPath: fileURL.path)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.items.isEmpty else { return }
                    self.isRestoring = true
                    self.items = Self.trimmed(existing)
                    self.isRestoring = false
                }
            }
        }
    }

    private func scheduleSave() {
        guard !isRestoring, Defaults[.persistClipboardHistory] else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func flushPendingSave() {
        guard let pendingSave, !pendingSave.isCancelled else {
            Self.saveQueue.sync {}
            return
        }
        pendingSave.cancel()
        self.pendingSave = nil
        guard Defaults[.persistClipboardHistory] else { return }
        let snapshot = items
        Self.saveQueue.sync {
            if let data = try? JSONEncoder().encode(snapshot) {
                Self.write(data)
            }
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard Defaults[.persistClipboardHistory] else { return }
        let snapshot = items
        Self.saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                Self.write(data)
            }
        }
    }

    private nonisolated static func write(_ data: Data) {
        let fm = FileManager.default
        let dir = historyFileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: historyFileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFileURL.path)
        } catch {
            Logger(subsystem: "theboringteam.boringnotch", category: "Clips")
                .error("Failed to save clipboard history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func trimmed(_ list: [ClipboardHistoryItem]) -> [ClipboardHistoryItem] {
        let limit = max(1, Defaults[.clipboardHistoryLimit])
        guard list.count > limit else { return list }
        var result = list
        while result.count > limit, let lastUnpinned = result.lastIndex(where: { !$0.isPinned }) {
            result.remove(at: lastUnpinned)
        }
        return result
    }

    private func handleApplicationDidDeactivate(bundleID: String?) {
        guard Self.shouldIgnoreSourceBundle(bundleID) else { return }
        let current = NSPasteboard.general.changeCount
        if current != lastChangeCount {
            lastChangeCount = current
        }
    }

    private func updatePasteboardPolling() {
        timer?.invalidate()
        timer = nil
        guard Defaults[.showClipboardTab] else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPasteboard()
            }
        }
        pollTimer.tolerance = 0.2
        timer = pollTimer
    }

    private func pollPasteboard() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        captureCurrentPasteboard(initial: false)
    }

    private static let ignoredPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
        NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
        NSPasteboard.PasteboardType("com.typeit4me.clipping"),
        NSPasteboard.PasteboardType("PasteboardgeneratorType"),
        NSPasteboard.PasteboardType("ConfidentialType")
    ]

    private static let sourcePasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    private static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.passwords",
        "com.apple.passwords.menubarextra",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword-osx-helper",
        "2bua8c4s2c.com.agilebits.onepassword-osx-helper",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.keepassx.keepassx",
        "com.dashlane.dashlane",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.lastpass",
        "in.sinew.enpass-desktop",
        "com.callpod.keepermac",
        "me.proton.pass.electron",
        "ch.protonmail.pass",
        "com.roboform.roboform",
        "com.authy.authy-mac"
    ]

    private static let ignoredBundlePrefixes: [String] = [
        "com.apple.passwords.",
        "com.1password.",
        "com.agilebits.onepassword"
    ]

    private static func shouldIgnoreSourceBundle(_ bundleID: String?) -> Bool {
        guard let normalized = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }
        if ignoredBundleIdentifiers.contains(normalized) {
            return true
        }
        return ignoredBundlePrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func shouldIgnorePasteboard(_ pasteboard: NSPasteboard, activeBundleID: String? = nil) -> Bool {
        if let types = pasteboard.types, types.contains(where: ignoredPasteboardTypes.contains) {
            return true
        }
        if let items = pasteboard.pasteboardItems,
           items.contains(where: { $0.types.contains(where: ignoredPasteboardTypes.contains) }) {
            return true
        }
        if let sourceBundle = pasteboard.string(forType: sourcePasteboardType),
           shouldIgnoreSourceBundle(sourceBundle) {
            return true
        }
        if shouldIgnoreSourceBundle(activeBundleID) {
            return true
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.isActive && shouldIgnoreSourceBundle($0.bundleIdentifier) }) {
            return true
        }
        return false
    }

    func captureCurrentPasteboard(initial: Bool = false) {
        let pb = NSPasteboard.general
        let activeBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if Self.shouldIgnorePasteboard(pb, activeBundleID: activeBundle) {
            return
        }
        let frontBundle = initial ? nil : activeBundle

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let firstFile = urls.first {
            insertItem(kind: .file, content: firstFile.path, fileURL: firstFile, bundleID: frontBundle)
            return
        }

        if let full = pb.string(forType: .string) {
            let maxClipChars = 512_000
            let bounded = full.count > maxClipChars ? String(full.prefix(maxClipChars)) : full
            let raw = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            let kind: ClipboardHistoryItem.Kind
            if Self.isValidHexColor(raw) {
                kind = .color
            } else if let u = URL(string: raw), let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                kind = .url
            } else {
                kind = .text
            }
            insertItem(kind: kind, content: raw, fileURL: nil, bundleID: frontBundle)
        }
    }

    private func insertItem(kind: ClipboardHistoryItem.Kind, content: String, fileURL: URL?, bundleID: String?) {
        if let existingIdx = items.firstIndex(where: { $0.content == content && $0.kind == kind }) {
            let pinned = items[existingIdx].isPinned
            items.remove(at: existingIdx)
            let updated = ClipboardHistoryItem(
                id: UUID(),
                kind: kind,
                content: content,
                fileURL: fileURL,
                sourceAppBundleID: bundleID,
                timestamp: Date(),
                isPinned: pinned
            )
            items.insert(updated, at: 0)
            return
        }

        let newItem = ClipboardHistoryItem(
            id: UUID(),
            kind: kind,
            content: content,
            fileURL: fileURL,
            sourceAppBundleID: bundleID,
            timestamp: Date()
        )
        var updated = items
        updated.insert(newItem, at: 0)
        items = Self.trimmed(updated)
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let fileURL = item.fileURL {
            pb.writeObjects([fileURL as NSURL])
        } else {
            pb.setString(item.content, forType: .string)
        }
        lastChangeCount = pb.changeCount
        recentlyCopiedID = item.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if self.recentlyCopiedID == item.id {
                self.recentlyCopiedID = nil
            }
        }
    }

    func togglePin(_ item: ClipboardHistoryItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
    }

    func remove(_ item: ClipboardHistoryItem) {
        items.removeAll { $0.id == item.id }
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
    }

    func clearAll() {
        items.removeAll()
    }

    func sendToShelf(_ item: ClipboardHistoryItem) {
        if let fileURL = item.fileURL, let bookmark = try? Bookmark(url: fileURL) {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data))])
        } else if item.kind == .url, let url = URL(string: item.content) {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .link(url: url))])
        } else {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: item.content))])
        }
        BoringViewCoordinator.shared.currentView = .shelf
    }

    var filteredItems: [ClipboardHistoryItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if onlyPinned && !item.isPinned { return false }
            guard !q.isEmpty else { return true }
            return item.content.lowercased().contains(q)
        }
    }

    static func isValidHexColor(_ str: String) -> Bool {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") && (s.count == 7 || s.count == 4) else { return false }
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        return s.dropFirst().unicodeScalars.allSatisfy { hexChars.contains($0) }
    }

    static func color(fromHex hex: String) -> Color? {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if clean.count == 3 {
            clean = clean.map { "\($0)\($0)" }.joined()
        }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        return Color(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

struct ClipboardNotchView: View {
    @ObservedObject private var manager = ClipboardHistoryManager.shared
    @State private var isSelecting: Bool = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingClearOptions: Bool = false

    var body: some View {
        let filtered = manager.filteredItems
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5))
            .overlay {
                VStack(spacing: 8) {
                    headerToolbar(filtered: filtered)
                    if filtered.isEmpty {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.gray)
                            Text("No clipboard items found")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(filtered) { item in
                                    clipCard(for: item)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: manager.items) { _, newItems in
                let validIDs = Set(newItems.map(\.id))
                selectedIDs = selectedIDs.intersection(validIDs)
                if newItems.isEmpty {
                    isSelecting = false
                    showingClearOptions = false
                    selectedIDs.removeAll()
                }
            }
    }

    private func headerToolbar(filtered: [ClipboardHistoryItem]) -> some View {
        let filteredIDs = Set(filtered.map(\.id))
        let allFilteredSelected = !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedIDs)
        return HStack(spacing: 8) {
            if isSelecting {
                headerPillButton(
                    icon: allFilteredSelected ? "checkmark.circle.fill" : "checkmark.circle",
                    title: allFilteredSelected ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All")
                ) {
                    if allFilteredSelected {
                        selectedIDs.subtract(filteredIDs)
                    } else {
                        selectedIDs.formUnion(filteredIDs)
                    }
                }

                Text("\(selectedIDs.count) selected")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)

                Spacer()

                headerPillButton(
                    icon: "trash",
                    title: LocalizedStringKey("Delete (\(selectedIDs.count))"),
                    isDestructive: true,
                    isDisabled: selectedIDs.isEmpty
                ) {
                    manager.remove(ids: selectedIDs)
                    selectedIDs.removeAll()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSelecting = false
                    }
                }

                headerPillButton(title: LocalizedStringKey("Cancel")) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSelecting = false
                        selectedIDs.removeAll()
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    TextField("Search clipboard…", text: $manager.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                    if !manager.searchQuery.isEmpty {
                        Button {
                            manager.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .frame(maxWidth: showingClearOptions ? 160 : 220)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.onlyPinned.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: manager.onlyPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10))
                        Text("Pinned")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(manager.onlyPinned ? Color.yellow : Color.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(manager.onlyPinned ? Color.yellow.opacity(0.18) : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Spacer()

                if !manager.items.isEmpty {
                    if showingClearOptions {
                        headerPillButton(icon: "checkmark.circle", title: LocalizedStringKey("Select")) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showingClearOptions = false
                                selectedIDs.removeAll()
                                isSelecting = true
                            }
                        }

                        if manager.items.contains(where: \.isPinned) && manager.items.contains(where: { !$0.isPinned }) {
                            headerPillButton(title: LocalizedStringKey("Unpinned"), isDestructive: true) {
                                manager.clearUnpinned()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showingClearOptions = false
                                }
                            }
                        }

                        headerPillButton(icon: "trash", title: LocalizedStringKey("Clear all"), isDestructive: true) {
                            manager.clearAll()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showingClearOptions = false
                            }
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showingClearOptions = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.gray)
                                .padding(5)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("\(manager.items.count) clips")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.gray)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showingClearOptions = true
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
            }
        }
    }

    private func headerPillButton(
        icon: String? = nil,
        title: LocalizedStringKey,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isDestructive ? Color.red.opacity(0.92) : Color.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isDestructive ? Color.red.opacity(0.14) : Color.white.opacity(0.08))
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func clipCard(for item: ClipboardHistoryItem) -> some View {
        let isCopied = manager.recentlyCopiedID == item.id
        let isSelected = isSelecting && selectedIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 5) {
            clipCardHeader(for: item, isSelected: isSelected)

            Text(item.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Text(isCopied ? String(localized: "Copied ✓") : String(localized: "Click to copy"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isCopied ? .green : .gray)
                Spacer()
                if item.kind == .url, let url = URL(string: item.content), !isSelecting {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .frame(width: 145, height: 82)
        .background(clipCardBackground(isSelected: isSelected, isCopied: isCopied))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            handleClipTap(item)
        }
        .contextMenu {
            clipContextMenu(for: item)
        }
        .onDrag {
            dragProvider(for: item)
        }
    }

    @ViewBuilder
    private func clipCardHeader(for item: ClipboardHistoryItem, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            if item.kind == .color, let swatch = ClipboardHistoryManager.color(fromHex: item.content) {
                Circle()
                    .fill(swatch)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
            } else {
                Image(systemName: item.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(item.kind.localizedBadge)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.gray)

            Spacer()

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.red : Color.white.opacity(0.45))
            } else {
                Button {
                    manager.togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(item.isPinned ? .yellow : .gray.opacity(0.7))
                }
                .buttonStyle(.plain)

                Button {
                    manager.sendToShelf(item)
                } label: {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Send to Shelf")
            }
        }
    }

    private func clipCardBackground(isSelected: Bool, isCopied: Bool) -> some View {
        let fillColor: Color = isSelected
            ? Color.red.opacity(0.18)
            : (isCopied ? Color.green.opacity(0.16) : Color.white.opacity(0.07))
        let strokeColor: Color = isSelected
            ? Color.red.opacity(0.75)
            : (isCopied ? Color.green.opacity(0.6) : Color.white.opacity(0.1))
        let lineWidth: CGFloat = isSelected ? 1.5 : 1

        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: lineWidth)
            )
    }

    private func handleClipTap(_ item: ClipboardHistoryItem) {
        if isSelecting {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } else {
            manager.copyToPasteboard(item)
        }
    }

    @ViewBuilder
    private func clipContextMenu(for item: ClipboardHistoryItem) -> some View {
        Button("Copy") {
            manager.copyToPasteboard(item)
        }
        Button(item.isPinned ? "Unpin" : "Pin") {
            manager.togglePin(item)
        }
        Button("Send to Shelf") {
            manager.sendToShelf(item)
        }
        Divider()
        Button("Select items…") {
            withAnimation(.easeInOut(duration: 0.15)) {
                showingClearOptions = false
                isSelecting = true
                selectedIDs = [item.id]
            }
        }
        Button("Delete", role: .destructive) {
            manager.remove(item)
        }
    }

    private func dragProvider(for item: ClipboardHistoryItem) -> NSItemProvider {
        if let fileURL = item.fileURL {
            return NSItemProvider(object: fileURL as NSURL)
        }
        return NSItemProvider(object: item.content as NSString)
    }
}

// MARK: - Caps Lock HUD Monitor (Gravity Feature)

@MainActor
final class CapsLockHUDMonitor {
    static let shared = CapsLockHUDMonitor()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isCapsLockOn: Bool = NSEvent.modifierFlags.contains(.capsLock)

    func start() {
        guard globalMonitor == nil else { return }
        isCapsLockOn = NSEvent.modifierFlags.contains(.capsLock)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let newState = event.modifierFlags.contains(.capsLock)
        guard newState != isCapsLockOn else { return }
        isCapsLockOn = newState
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .backlight,
            value: newState ? 1.0 : 0.0,
            icon: newState ? "capslock.fill" : "capslock"
        )
    }
}

// MARK: - Playing Next Queue Manager & View (Gravity Playing Next Feature)

/// Reads the real Up Next queue (user "Play Next" items + Autoplay) from Music's queue panel through
/// Accessibility. AppleScript and MediaRemote only expose the current playlist, never Autoplay.
/// Music builds that table only while the queue panel is shown, hence the `panelHidden` result.
enum MusicQueuePanelReader {
    struct Track {
        let title: String
        let artist: String
    }

    enum Result {
        case queue([Track])
        /// Music answered but shows no queue panel
        case panelHidden
        /// Music did not answer in time (busy while switching tracks): try again rather than guess
        case failed
    }

    /// Section titles of the played-tracks list, taken from Music's own strings so any language works
    private static let historyTitles: Set<String> = {
        var titles: Set<String> = ["History", "Historique"]
        if let bundle = Bundle(path: "/System/Applications/Music.app") {
            for key in ["vxxu3gurm3", "akewa5jr45", "vt9ur4r256"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                if value != key { titles.insert(value) }
            }
        }
        return titles
    }()

    /// Subtrees that never hold the queue: sidebar, album grids, toolbars
    private static let skippedRoles: Set<String> = [
        kAXListRole, kAXOutlineRole, kAXToolbarRole, kAXMenuBarRole, "AXWebArea"
    ]

    static func upcomingTracks(limit: Int = 10) -> Result {
        guard AXIsProcessTrusted(),
              let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
        else { return .panelHidden }
        let app = AXUIElementCreateApplication(music.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var reader = Walker()
        guard let windows = reader.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return reader.failed ? .failed : .panelHidden
        }
        for window in windows {
            if let table = reader.findQueueTable(in: window) {
                let tracks = reader.parse(table, limit: limit)
                return reader.failed ? .failed : .queue(tracks)
            }
        }
        return reader.failed ? .failed : .panelHidden
    }

    private struct Walker {
        var failed = false

        mutating func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if error == .cannotComplete { failed = true }
            return error == .success ? value : nil
        }

        mutating func children(_ element: AXUIElement) -> [AXUIElement] {
            attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }

        mutating func rows(_ table: AXUIElement) -> [AXUIElement] {
            attribute(table, kAXRowsAttribute) as? [AXUIElement] ?? children(table)
        }

        mutating func role(_ element: AXUIElement) -> String {
            attribute(element, kAXRoleAttribute) as? String ?? ""
        }

        /// Breadth first, the queue sits a few levels under the window. It starts with section header rows
        /// (a "Clear" button identified as "action", or a "title" text for Autoplay); only the first rows are checked
        mutating func findQueueTable(in window: AXUIElement) -> AXUIElement? {
            var level = children(window)
            for _ in 0..<10 where !level.isEmpty && !failed {
                var next: [AXUIElement] = []
                for element in level {
                    let elementRole = role(element)
                    if elementRole == kAXTableRole {
                        if rows(element).prefix(3).contains(where: { parseRow($0).isHeader }) { return element }
                    } else if !skippedRoles.contains(elementRole) {
                        next.append(contentsOf: children(element))
                    }
                }
                level = next
            }
            return nil
        }

        mutating func parseRow(_ row: AXUIElement) -> (texts: [String], isHeader: Bool) {
            var texts: [String] = []
            var isHeader = false
            for cell in children(row) {
                for element in children(cell) {
                    switch role(element) {
                    case kAXStaticTextRole:
                        if let text = attribute(element, kAXValueAttribute) as? String, !text.isEmpty {
                            texts.append(text)
                        }
                        // The Autoplay header has no Clear button, only "title"/"subtitle" texts; track rows have no identifiers
                        if attribute(element, kAXIdentifierAttribute) as? String == "title" { isHeader = true }
                    case kAXButtonRole:
                        if attribute(element, kAXIdentifierAttribute) as? String == "action" { isHeader = true }
                    default:
                        break
                    }
                }
            }
            return (texts, isHeader)
        }

        /// Upcoming sections follow History, so read from the bottom up to the History header
        /// instead of walking hundreds of played tracks
        /// Music keeps the queue scrolled so the played tracks sit above the visible area: the first visible
        /// section header gives the start of the upcoming tracks without reading the whole history
        /// (often 200+ rows, a few ms per Accessibility call)
        mutating func parse(_ table: AXUIElement, limit: Int) -> [Track] {
            let all = rows(table)
            guard let visible = attribute(table, kAXVisibleRowsAttribute) as? [AXUIElement],
                  let start = upcomingStart(in: all, visible: visible)
            else { return parseFromBottom(all, limit: limit) }
            var tracks: [Track] = []
            for row in all[start...] where tracks.count < limit {
                let (texts, isHeader) = parseRow(row)
                if !isHeader, let track = track(from: texts) { tracks.append(track) }
            }
            return tracks
        }

        private mutating func upcomingStart(in all: [AXUIElement], visible: [AXUIElement]) -> Int? {
            for row in visible {
                let (texts, isHeader) = parseRow(row)
                guard isHeader, let index = all.firstIndex(of: row) else { continue }
                guard let title = texts.first, historyTitles.contains(title) else { return index + 1 }
                // Scrolled up to the History header: the upcoming tracks start after the next header
                for next in (index + 1)..<all.count where parseRow(all[next]).isHeader {
                    return next + 1
                }
                return all.count
            }
            return nil
        }

        private func track(from texts: [String]) -> Track? {
            // Real tracks always carry a subtitle; a lone title is a placeholder ("AutoPlay" while Music reloads)
            guard texts.count > 1 else { return nil }
            let title = texts[0]
            // Subtitle reads "Artist <em dash> Album"
            let subtitle = texts[1]
            let artist = subtitle.components(separatedBy: " \u{2014} ").first ?? subtitle
            return Track(title: title, artist: artist)
        }

        private mutating func parseFromBottom(_ all: [AXUIElement], limit: Int) -> [Track] {
            // Walking backwards, a section's rows are read before its header
            var upcoming: [Track] = []
            var section: [Track] = []
            var reachedHistory = false
            for row in all.reversed() {
                let (texts, isHeader) = parseRow(row)
                if isHeader {
                    if let title = texts.first, historyTitles.contains(title) {
                        reachedHistory = true
                        break
                    }
                    upcoming = section.reversed() + upcoming
                    section = []
                    continue
                }
                if let track = track(from: texts) { section.append(track) }
            }
            // Rows above any header only count when there is no History section
            if !reachedHistory { upcoming = section.reversed() + upcoming }
            return Array(upcoming.prefix(limit))
        }
    }
}

struct UpNextTrackItem: Identifiable, Equatable {
    let id: String
    let playlistIndex: Int
    let title: String
    let artist: String
    let duration: Double

    var formattedDuration: String {
        guard duration > 0 else { return "" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
final class PlayingNextManager: ObservableObject {
    static let shared = PlayingNextManager()

    @Published var showQueueInHome: Bool = false
    @Published private(set) var tracks: [UpNextTrackItem] = []
    @Published private(set) var isLoading: Bool = false
    /// Music does not expose its shuffled Up Next order, so the playlist order is not the real queue while shuffling.
    /// Stays false when the list comes from Music's queue panel, which already shows the real order.
    @Published private(set) var isShuffleOn: Bool = false
    /// The list was read from Music's queue panel (Playing Next + Autoplay), in the real playback order.
    @Published private(set) var isLiveMusicQueue: Bool = false
    /// Music is the player but its queue panel is hidden, so Autoplay tracks cannot be read.
    @Published private(set) var musicQueuePanelHidden: Bool = false
    private var cancellable: AnyCancellable?
    private var shuffleCancellable: AnyCancellable?
    /// Overlapping refreshes (track change, shuffle, button) finish in any order: only the latest one applies
    private var refreshGeneration = 0
    private var settleTask: Task<Void, Never>?

    private init() {
        cancellable = MusicManager.shared.$songTitle
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.refreshQueue()
                    // Music updates its queue panel a moment after the track changes
                    self.settleTask?.cancel()
                    self.settleTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        await self?.refreshQueue()
                    }
                }
            }
        shuffleCancellable = MusicManager.shared.$isShuffled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshQueue()
                }
            }
        Task {
            await refreshQueue()
        }
    }

    /// Music fills its Autoplay list seconds after a track starts, or when the user edits the queue, without any
    /// notification: re-read it while the queue is on screen. Runs only for the lifetime of the visible view
    func watchMusicQueueWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, MusicManager.shared.bundleIdentifier == "com.apple.Music" else { continue }
            await refreshQueue(liveOnly: true)
        }
    }

    func toggleQueueView() {
        withAnimation(.smooth(duration: 0.22)) {
            showQueueInHome.toggle()
            if showQueueInHome { AudioOutputRoutingMenu.shared.showPanelInHome = false }
        }
        if showQueueInHome {
            Task { await refreshQueue() }
        }
    }

    func playTrack(_ item: UpNextTrackItem) {
        let targetIndex = item.playlistIndex
        // Negative index: reached by skipping forward, only reliable when the list is the real order
        if targetIndex < 0 && isShuffleOn && !isLiveMusicQueue { return }
        Task.detached(priority: .userInitiated) {
            let script = targetIndex < 0 ? """
            tell application "Music"
                if it is running then
                    repeat \(-targetIndex) times
                        next track
                        delay 0.15
                    end repeat
                end if
            end tell
            """ : """
            tell application "Music"
                if it is running then
                    play track \(targetIndex) of current playlist
                end if
            end tell
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run {
                MusicManager.shared.forceUpdate()
                Task { await PlayingNextManager.shared.refreshQueue() }
            }
        }
    }

    func turnOffShuffle() {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"Music\" to if it is running then set shuffle enabled to false"]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run {
                MusicManager.shared.forceUpdate()
                Task { await PlayingNextManager.shared.refreshQueue() }
            }
        }
    }

    /// `liveOnly`: only apply a successful read of Music's queue panel, never the AppleScript fallback
    func refreshQueue(liveOnly: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }

        if MusicManager.shared.bundleIdentifier == "com.apple.Music" {
            var result = await Task.detached(priority: .utility) {
                MusicQueuePanelReader.upcomingTracks()
            }.value
            // Music rebuilds the queue table on each track change: a hidden panel right after a live read
            // is usually that rebuild, not the user closing the panel
            var shouldRetry: Bool {
                switch result {
                case .failed: return true
                case .panelHidden: return isLiveMusicQueue
                case .queue: return false
                }
            }
            if shouldRetry {
                try? await Task.sleep(for: .milliseconds(800))
                guard generation == refreshGeneration else { return }
                result = await Task.detached(priority: .utility) {
                    MusicQueuePanelReader.upcomingTracks()
                }.value
            }
            guard generation == refreshGeneration else { return }
            if liveOnly {
                guard case .queue = result else { return }
            }
            switch result {
            case .queue(let live):
                musicQueuePanelHidden = false
                isLiveMusicQueue = true
                isShuffleOn = false
                let items = live.enumerated().map { offset, track in
                    UpNextTrackItem(
                        id: "live-\(offset)-\(track.title)",
                        playlistIndex: -(offset + 1),
                        title: track.title,
                        artist: track.artist,
                        duration: 0
                    )
                }
                if items != tracks { tracks = items }
                return
            case .failed where isLiveMusicQueue:
                // Music is still busy: keep the live list rather than fall back to a guessed album order
                return
            case .failed, .panelHidden:
                musicQueuePanelHidden = true
            }
        } else {
            musicQueuePanelHidden = false
        }
        isLiveMusicQueue = false

        let (fetched, shuffleOn): ([UpNextTrackItem], Bool) = await Task.detached(priority: .utility) {
            let script = """
            tell application "Music"
                if it is running and player state is not stopped then
                    set outList to "SHUFFLE|" & (shuffle enabled as text) & "\\n"
                    try
                        set pl to current playlist
                        set totalCnt to count of tracks of pl
                    on error
                        set t to current track
                        return outList & "CATALOG|" & (name of t) & "|" & (artist of t) & "|" & (album of t) & "\\n"
                    end try
                    set curIdx to index of current track
                    repeat with i from (curIdx + 1) to (curIdx + 10)
                        if i <= totalCnt then
                            set t to track i of pl
                            set outList to outList & i & "|" & (name of t) & "|" & (artist of t) & "|" & (duration of t) & "\\n"
                        end if
                    end repeat
                    if (curIdx + 1) > totalCnt and totalCnt > 1 then
                        repeat with i from 1 to 6
                            if i < curIdx and i <= totalCnt then
                                set t to track i of pl
                                set outList to outList & i & "|" & (name of t) & "|" & (artist of t) & "|" & (duration of t) & "\\n"
                            end if
                        end repeat
                    end if
                    return outList
                end if
            end tell
            """
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else { return ([], false) }
                let shuffleOn = output.contains("SHUFFLE|true")
                var items: [UpNextTrackItem] = []
                for line in output.components(separatedBy: .newlines) {
                    let parts = line.components(separatedBy: "|")
                    if parts.first == "CATALOG", parts.count >= 4 {
                        // Streaming from the Apple Music catalog: Music exposes no playlist, read the album page instead
                        let upcoming = await AppleMusicWebCatalog.shared.upcomingTracks(
                            title: parts[1], artist: parts[2], album: parts[3...].joined(separator: "|")
                        )
                        for (offset, track) in upcoming.enumerated() {
                            items.append(UpNextTrackItem(
                                id: "catalog-\(offset)-\(track.title)",
                                playlistIndex: -(offset + 1),
                                title: track.title,
                                artist: track.artist,
                                duration: track.duration
                            ))
                        }
                        return (items, shuffleOn)
                    }
                    guard parts.count >= 4, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let durStr = parts[3].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                    let dur = Double(durStr) ?? 0
                    items.append(UpNextTrackItem(id: "\(idx)-\(title)", playlistIndex: idx, title: title, artist: artist, duration: dur))
                }
                return (items, shuffleOn)
            } catch {
                return ([], false)
            }
        }.value

        guard generation == refreshGeneration else { return }
        self.isShuffleOn = shuffleOn
        self.tracks = fetched
    }
}

/// Home tab panel (in place of the calendar): system volume and every output device, one tap to switch
struct AudioOutputPanelView: View {
    @ObservedObject var routing = AudioOutputRoutingMenu.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var dragVolume: Float?
    @State private var holdsNotchOpen: Bool = false

    private var volume: Float {
        dragVolume ?? (volumeManager.isMuted ? 0 : volumeManager.rawVolume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Audio Output")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    routing.togglePanel()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text("Calendar")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            volumeRow

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(routing.devices, id: \.id) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .onAppear {
            routing.startObservingDevices()
            volumeManager.refresh()
        }
        .onDisappear {
            routing.stopObservingDevices()
            if holdsNotchOpen {
                holdsNotchOpen = false
                SharingStateManager.shared.endInteraction()
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 7) {
            Button {
                volumeManager.toggleMuteAction()
            } label: {
                Image(systemName: volume <= 0.01 ? "speaker.slash.fill" : (volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(5, width * CGFloat(volume)))
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !holdsNotchOpen {
                                holdsNotchOpen = true
                                SharingStateManager.shared.beginInteraction()
                            }
                            let ratio = Float(min(1, max(0, value.location.x / width)))
                            dragVolume = ratio
                            volumeManager.setAbsolute(ratio)
                        }
                        .onEnded { _ in
                            dragVolume = nil
                            if holdsNotchOpen {
                                holdsNotchOpen = false
                                SharingStateManager.shared.endInteraction()
                            }
                        }
                )
            }
            .frame(height: 14)

            Text("\(Int(round(volume * 100)))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.gray)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func deviceRow(_ device: AudioOutputRoutingMenu.OutputDevice) -> some View {
        HStack(spacing: 7) {
            Image(systemName: device.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(device.isDefault ? Color.accentColor : .white.opacity(0.75))
                .frame(width: 16)
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 2)
            if device.isDefault {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(device.isDefault ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.05))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            guard !device.isDefault else { return }
            routing.setOutputDevice(device.id)
            volumeManager.refresh()
        }
    }
}

struct PlayingNextView: View {
    @ObservedObject var manager = PlayingNextManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(manager.isShuffleOn ? String(localized: "In This Playlist") : String(localized: "Playing Next"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await manager.refreshQueue() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Refresh Queue")

                Button {
                    manager.toggleQueueView()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text("Calendar")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            if manager.isShuffleOn {
                HStack(spacing: 5) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Shuffle is on: Music hides its real order")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Button {
                        manager.turnOffShuffle()
                    } label: {
                        Text("Turn off")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("Turn off shuffle to see the real upcoming tracks")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }

            if manager.tracks.isEmpty {
                Spacer()
                VStack(spacing: 4) {
                    Text(manager.isLoading ? String(localized: "Loading queue…") : String(localized: "No upcoming tracks"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                    Text(manager.musicQueuePanelHidden
                        ? String(localized: "Show the queue in Music to see Autoplay tracks")
                        : String(localized: "Start a playlist or album in Music"))
                        .font(.system(size: 9))
                        .foregroundStyle(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(Array(manager.tracks.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 6) {
                                Text(manager.isShuffleOn ? "·" : "\(index + 1)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.gray)
                                    .frame(width: 14, alignment: .leading)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.gray)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 2)

                                Text(track.formattedDuration)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.gray.opacity(0.8))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .onTapGesture {
                                manager.playTrack(track)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .task { await manager.watchMusicQueueWhileVisible() }
    }
}

// MARK: - Element Capture & Screen Text Capture / OCR (Gravity Capture Feature)

@MainActor
final class ScreenCaptureOCRService {
    static let shared = ScreenCaptureOCRService()

    enum CaptureMode {
        case ocrText
        case areaToShelf
        case windowToShelf
    }

    private var isCapturing: Bool = false

    func capture(mode: CaptureMode) {
        guard !isCapturing else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "Screen Recording Permission Required")
            alert.informativeText = String(localized: "Allow GravityNotch in System Settings -> Privacy & Security -> Screen & System Audio Recording to capture screen content.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        isCapturing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }
            // Allow the notch to close cleanly before interactive crosshair
            try? await Task.sleep(for: .milliseconds(180))
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("GravityCapture-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFile = tempDir.appendingPathComponent("gravity_capture.png")
            var keepTempFile = false
            defer {
                if !keepTempFile {
                    try? FileManager.default.removeItem(at: tempDir)
                }
            }

            let args: [String]
            switch mode {
            case .ocrText, .areaToShelf:
                args = ["-i", "-x", tempFile.path]
            case .windowToShelf:
                args = ["-i", "-w", "-x", tempFile.path]
            }

            let didCapture: Bool = await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = args
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempFile.path)
                } catch {
                    return false
                }
            }.value

            guard didCapture else { return }

            switch mode {
            case .ocrText:
                do {
                    let extracted = try await ImageProcessingService.shared.extractText(from: tempFile)
                    ImageProcessingService.shared.presentOCRResultModal(
                        text: extracted,
                        sourceName: String(localized: "Screen Capture")
                    )
                } catch {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = String(localized: "OCR Failed")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            case .areaToShelf, .windowToShelf:
                if let bookmark = try? Bookmark(url: tempFile) {
                    keepTempFile = true
                    let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                    ShelfStateViewModel.shared.add([item])
                    if Defaults[.boringShelf] {
                        BoringViewCoordinator.shared.currentView = .shelf
                    }
                }
            }
        }
    }
}

// MARK: - Coding Agents Live Monitor & Gravity Agents UI (Claude Code / Antigravity / Codex)

enum AgentKind: String, Equatable, CaseIterable {
    case claudeCode = "Claude Code"
    case antigravity = "Antigravity"
    case codex = "Codex CLI"

    var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .antigravity: return "AGY"
        case .codex: return "Codex"
        }
    }

    var badgeIcon: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .antigravity: return "atom"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var accentColor: Color {
        switch self {
        case .claudeCode: return Color(red: 0.91, green: 0.49, blue: 0.34) // Claude coral-amber
        case .antigravity: return Color(red: 0.32, green: 0.80, blue: 0.98) // Antigravity sky-cyan
        case .codex: return Color(red: 0.16, green: 0.78, blue: 0.56) // Codex emerald
        }
    }

    var secondaryAccentColor: Color {
        switch self {
        case .claudeCode: return Color(red: 0.98, green: 0.67, blue: 0.42)
        case .antigravity: return Color(red: 0.62, green: 0.44, blue: 0.98)
        case .codex: return Color(red: 0.32, green: 0.90, blue: 0.72)
        }
    }
}

enum AgentWorkPhase: String, Equatable {
    case thinking = "Thinking"
    case editing = "Editing"
    case running = "Running"
    case reading = "Reading"
    case searching = "Searching"
    case deleting = "Deleting"
    case waiting = "Ready"
    case idle = "Idle"

    var localizedTitle: String {
        switch self {
        case .thinking: return String(localized: "Thinking")
        case .editing: return String(localized: "Editing")
        case .running: return String(localized: "In Progress")
        case .reading: return String(localized: "Reading")
        case .searching: return String(localized: "Searching")
        case .deleting: return String(localized: "Deleting")
        case .waiting: return String(localized: "Ready")
        case .idle: return String(localized: "Idle")
        }
    }

    var shortBadge: String {
        switch self {
        case .thinking: return "THINK"
        case .editing: return "EDIT"
        case .running: return "RUN"
        case .reading: return "READ"
        case .searching: return "FIND"
        case .deleting: return "DEL"
        case .waiting: return "DONE"
        case .idle: return "IDLE"
        }
    }

    var iconName: String {
        switch self {
        case .thinking: return "brain.head.profile"
        case .editing: return "pencil.and.outline"
        case .running: return "terminal.fill"
        case .reading: return "doc.text.magnifyingglass"
        case .searching: return "magnifyingglass"
        case .deleting: return "trash.fill"
        case .waiting: return "checkmark.circle.fill"
        case .idle: return "cpu.fill"
        }
    }

    var color: Color {
        switch self {
        case .thinking: return Color(red: 0.68, green: 0.52, blue: 0.98)
        case .editing: return Color(red: 0.30, green: 0.85, blue: 0.58)
        case .running: return Color(red: 0.98, green: 0.65, blue: 0.25)
        case .reading: return Color(red: 0.36, green: 0.78, blue: 0.98)
        case .searching: return Color(red: 0.48, green: 0.64, blue: 0.98)
        case .deleting: return Color(red: 0.98, green: 0.45, blue: 0.42)
        case .waiting: return Color.white.opacity(0.65)
        case .idle: return Color.gray
        }
    }

    static func classify(toolName: String) -> AgentWorkPhase {
        let lower = toolName.lowercased()
        if lower.contains("edit") || lower.contains("write") || lower.contains("replace") || lower.contains("patch") {
            return .editing
        }
        if lower.contains("bash") || lower.contains("command") || lower.contains("shell") || lower.contains("exec") || lower.contains("terminal") {
            return .running
        }
        if lower.contains("read") || lower.contains("view") || lower.contains("list") {
            return .reading
        }
        if lower.contains("search") || lower.contains("grep") || lower.contains("glob") || lower.contains("find") || lower.contains("web") || lower.contains("fetch") {
            return .searching
        }
        return .thinking
    }
}

/// Finds what a shell command deletes (rm, rmdir, unlink, trash, git rm), so a deletion an agent runs in its
/// terminal shows in the notch like an edit does. A deletion leaves no patch in the transcript, only the command,
/// so the paths are read from the command itself: quotes, escapes and chained commands (&&, ;, |) are honored,
/// and a quoted "rm" inside another command (echo "rm x") is never taken for one.
enum AgentDeletionParser {
    struct Deletion: Equatable {
        let name: String
        let count: Int
    }

    static func deletion(in command: String) -> Deletion? {
        let targets = targets(in: command)
        guard let first = targets.first else { return nil }
        let name = (first as NSString).lastPathComponent
        return Deletion(name: name.isEmpty ? first : name, count: targets.count)
    }

    static func targets(in command: String) -> [String] {
        var result: [String] = []
        for segment in segments(of: command) {
            var tokens = segment[...]
            // Leading "VAR=value" assignments and wrappers that run the next command
            while let first = tokens.first,
                  (first.contains("=") && !first.hasPrefix("-") && !first.contains("/"))
                    || ["sudo", "command", "nohup", "time", "exec"].contains(first) {
                tokens = tokens.dropFirst()
            }
            guard let head = tokens.first else { continue }
            let args: ArraySlice<String>
            switch (head as NSString).lastPathComponent {
            case "rm", "rmdir", "unlink", "trash", "srm":
                args = tokens.dropFirst()
            case "git" where tokens.dropFirst().first == "rm":
                args = tokens.dropFirst(2)
            default:
                continue
            }
            var optionsEnded = false
            for arg in args where !arg.isEmpty && !arg.contains(">") && !arg.contains("<") {
                if !optionsEnded {
                    if arg == "--" { optionsEnded = true; continue }
                    if arg.hasPrefix("-") { continue }
                }
                result.append(arg)
            }
        }
        return result
    }

    /// Splits a command line into simple commands, each as its list of words
    private static func segments(of command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        for ch in command {
            if escaped {
                word.append(ch)
                inWord = true
                escaped = false
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else {
                    word.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
                inWord = true
            case "'", "\"":
                quote = ch
                inWord = true
            case " ", "\t":
                endWord()
            case "\n", ";", "&", "|", "(", ")":
                endSegment()
            default:
                word.append(ch)
                inWord = true
            }
        }
        endSegment()
        return segments
    }
}

struct AgentToolEvent: Identifiable, Equatable {
    let id: String
    let stepIndex: Int
    let toolName: String
    let phase: AgentWorkPhase
    let summary: String
    let targetFile: String?
    let timestamp: Date

    var iconName: String {
        phase == .thinking || phase == .waiting || phase == .idle ? "cpu.fill" : phase.iconName
    }

    var tintColor: Color {
        phase.color
    }
}

/// Lines added and removed per file, read incrementally from the session transcript so large rows never fall
/// out of the tail parser. Supports Claude Code (`structuredPatch`) and Antigravity (`edit_file` / `write_file`).
struct AgentDiffTally: Sendable {
    struct FileDiff: Sendable, Equatable {
        var added = 0
        var removed = 0
    }

    struct PendingAntigravityTool: Sendable {
        let fileName: String?
        let added: Int
        let removed: Int
        let isEdit: Bool
    }

    private(set) var offset: UInt64 = 0
    private(set) var added = 0
    private(set) var removed = 0
    private(set) var perFile: [String: FileDiff] = [:]
    private(set) var editCount = 0
    private(set) var lastEditedFile: String? = nil

    private var pendingBatch: [PendingAntigravityTool] = []
    private var pendingConsumed: Int = 0

    private static let maxInitialBytes: UInt64 = 48 * 1024 * 1024
    private static let needle = Data("\"structuredPatch\"".utf8)
    private static let plannerNeedle = Data("\"PLANNER_RESPONSE\"".utf8)
    private static let userInputNeedle = Data("\"USER_INPUT\"".utf8)
    private static let toolCallsNeedle = Data("\"tool_calls\"".utf8)
    private static let antigravityEditNeedles: [Data] = [
        Data("\"edit_file\"".utf8),
        Data("\"write_file\"".utf8),
        Data("\"replace_file_content\"".utf8),
        Data("\"multi_replace_file_content\"".utf8),
        Data("\"write_to_file\"".utf8)
    ]

    /// When Antigravity is mid-batch and the next uncompleted tool call is a file edit, surface it immediately
    /// so the focus card switches to that file and animates its green/red diff bar in real time.
    var inFlightEdit: PendingAntigravityTool? {
        guard pendingConsumed < pendingBatch.count else { return nil }
        let next = pendingBatch[pendingConsumed]
        return (next.isEdit && next.fileName != nil) ? next : nil
    }

    var liveEditSerial: Int {
        editCount + (inFlightEdit != nil ? 1 : 0)
    }

    func liveFileDiff(for fileName: String) -> FileDiff? {
        var base = perFile[fileName] ?? FileDiff()
        if let live = inFlightEdit, live.fileName == fileName {
            base.added += live.added
            base.removed += live.removed
        }
        return (base.added > 0 || base.removed > 0) ? base : nil
    }

    mutating func advance(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset { self = AgentDiffTally() }
        var start = offset
        var skipFirstLine = false
        if offset == 0 && size > Self.maxInitialBytes {
            start = size - Self.maxInitialBytes
            skipFirstLine = true
        }
        guard size > start else { return }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty,
              // No newline yet: the row is still being written, read it whole next time
              let lastNewline = data.lastIndex(of: 0x0A) else { return }
        offset = start + UInt64(lastNewline - data.startIndex + 1)
        var slice = data[data.startIndex..<lastNewline]
        if skipFirstLine, let firstNewline = slice.firstIndex(of: 0x0A) {
            slice = slice[slice.index(after: firstNewline)...]
        }
        let lines = slice.split(separator: 0x0A)
        for line in lines where line.range(of: Self.needle) != nil {
            record(line)
        }
    }

    mutating func advanceAntigravity(url: URL, isCompactTranscript: Bool = false) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset { self = AgentDiffTally() }
        var start = offset
        var skipFirstLine = false
        if offset == 0 && size > Self.maxInitialBytes {
            start = size - Self.maxInitialBytes
            skipFirstLine = true
        }
        guard size > start else { return }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return }
        offset = start + UInt64(lastNewline - data.startIndex + 1)
        var slice = data[data.startIndex..<lastNewline]
        if skipFirstLine, let firstNewline = slice.firstIndex(of: 0x0A) {
            slice = slice[slice.index(after: firstNewline)...]
        }
        for line in slice.split(separator: 0x0A) {
            // In Antigravity JSONL logs, `"type"` is always in the opening header (< 64 bytes),
            // so inspecting only the prefix avoids false matches on file contents inside GENERIC rows.
            let head = line.prefix(192)
            if head.range(of: Self.plannerNeedle) != nil {
                pendingBatch.removeAll(keepingCapacity: true)
                pendingConsumed = 0
                guard line.range(of: Self.toolCallsNeedle) != nil,
                      Self.antigravityEditNeedles.contains(where: { line.range(of: $0) != nil }) else {
                    continue
                }
                recordAntigravityPlannerLine(line, isCompactTranscript: isCompactTranscript)
            } else if head.range(of: Self.userInputNeedle) != nil {
                pendingBatch.removeAll(keepingCapacity: true)
                pendingConsumed = 0
            } else if pendingConsumed < pendingBatch.count {
                recordAntigravityResultLine(line)
            }
        }
    }

    private mutating func recordAntigravityPlannerLine(_ line: Data, isCompactTranscript: Bool) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "PLANNER_RESPONSE",
              let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else { return }

        var batch: [PendingAntigravityTool] = []
        batch.reserveCapacity(toolCalls.count)
        for tc in toolCalls {
            let name = (tc["name"] as? String) ?? ""
            let args = (tc["args"] as? [String: Any]) ?? [:]
            if let edit = Self.parseAntigravityEdit(name: name, args: args, isCompact: isCompactTranscript) {
                batch.append(edit)
            } else {
                batch.append(PendingAntigravityTool(fileName: nil, added: 0, removed: 0, isEdit: false))
            }
        }
        pendingBatch = batch
        pendingConsumed = 0
    }

    private mutating func recordAntigravityResultLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let recordType = obj["type"] as? String else { return }
        if recordType == "GENERIC" {
            let item = pendingBatch[pendingConsumed]
            pendingConsumed += 1
            if item.isEdit, let name = item.fileName, item.added > 0 || item.removed > 0 {
                perFile[name, default: FileDiff()].added += item.added
                perFile[name, default: FileDiff()].removed += item.removed
                added += item.added
                removed += item.removed
                editCount += 1
                lastEditedFile = name
            }
        } else if recordType == "ERROR_MESSAGE" {
            pendingConsumed += 1
        }
    }

    private static func unwrapArg(_ raw: Any?, isCompact: Bool) -> String? {
        guard let s = raw as? String else { return nil }
        if isCompact, s.count >= 2, s.first == "\"", s.last == "\"",
           let data = s.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return s
    }

    private static func parseAntigravityEdit(
        name: String,
        args: [String: Any],
        isCompact: Bool
    ) -> PendingAntigravityTool? {
        let rawPath = unwrapArg(args["Path"], isCompact: isCompact)
            ?? unwrapArg(args["TargetFile"], isCompact: isCompact)
            ?? unwrapArg(args["AbsolutePath"], isCompact: isCompact)
            ?? unwrapArg(args["file_path"], isCompact: isCompact)
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let fileName = URL(fileURLWithPath: rawPath).lastPathComponent
        guard !fileName.isEmpty else { return nil }

        switch name {
        case "edit_file":
            let target = unwrapArg(args["Target"], isCompact: isCompact) ?? ""
            let replacement = unwrapArg(args["Replacement"], isCompact: isCompact) ?? ""
            let (add, rem) = lineDiffCounts(old: target, new: replacement)
            return PendingAntigravityTool(fileName: fileName, added: add, removed: rem, isEdit: true)
        case "replace_file_content":
            let target = unwrapArg(args["TargetContent"], isCompact: isCompact) ?? ""
            let replacement = unwrapArg(args["ReplacementContent"], isCompact: isCompact) ?? ""
            let (add, rem) = lineDiffCounts(old: target, new: replacement)
            return PendingAntigravityTool(fileName: fileName, added: add, removed: rem, isEdit: true)
        case "multi_replace_file_content":
            var totalAdd = 0
            var totalRem = 0
            if let chunks = args["ReplacementChunks"] as? [[String: Any]] {
                for chunk in chunks {
                    let target = unwrapArg(chunk["TargetContent"], isCompact: isCompact) ?? ""
                    let replacement = unwrapArg(chunk["ReplacementContent"], isCompact: isCompact) ?? ""
                    let (add, rem) = lineDiffCounts(old: target, new: replacement)
                    totalAdd += add
                    totalRem += rem
                }
            }
            return PendingAntigravityTool(fileName: fileName, added: totalAdd, removed: totalRem, isEdit: true)
        case "write_file", "write_to_file":
            let content = unwrapArg(args["Content"], isCompact: isCompact)
                ?? unwrapArg(args["CodeContent"], isCompact: isCompact)
                ?? ""
            let add = lineCount(content)
            return PendingAntigravityTool(fileName: fileName, added: add, removed: 0, isEdit: true)
        default:
            return nil
        }
    }

    private static func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        return lines
    }

    private static func lineCount(_ text: String) -> Int {
        splitLines(text).count
    }

    private static func lineDiffCounts(old: String, new: String) -> (added: Int, removed: Int) {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        if oldLines == newLines { return (0, 0) }

        var prefix = 0
        let minCount = min(oldLines.count, newLines.count)
        while prefix < minCount && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > prefix && newEnd > prefix && oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        let oldSlice = Array(oldLines[prefix..<oldEnd])
        let newSlice = Array(newLines[prefix..<newEnd])
        if oldSlice.isEmpty { return (newSlice.count, 0) }
        if newSlice.isEmpty { return (0, oldSlice.count) }
        if oldSlice.count + newSlice.count <= 2000 {
            let diff = newSlice.difference(from: oldSlice)
            return (diff.insertions.count, diff.removals.count)
        }
        var freq: [Substring: Int] = [:]
        for line in oldSlice { freq[line, default: 0] += 1 }
        var common = 0
        for line in newSlice {
            if let count = freq[line], count > 0 {
                common += 1
                freq[line] = count - 1
            }
        }
        return (newSlice.count - common, oldSlice.count - common)
    }

    private mutating func record(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let result = obj["toolUseResult"] as? [String: Any],
              let path = result["filePath"] as? String, !path.isEmpty else { return }
        var add = 0
        var rem = 0
        if let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            for hunk in hunks {
                for patchLine in (hunk["lines"] as? [String]) ?? [] {
                    if patchLine.hasPrefix("+") { add += 1 } else if patchLine.hasPrefix("-") { rem += 1 }
                }
            }
        } else if (result["type"] as? String) == "create", let content = result["content"] as? String, !content.isEmpty {
            add = content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
        }
        guard add > 0 || rem > 0 else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        perFile[name, default: FileDiff()].added += add
        perFile[name, default: FileDiff()].removed += rem
        added += add
        removed += rem
        editCount += 1
    }
}

struct AgentSessionSnapshot: Identifiable, Equatable {
    let id: String
    let kind: AgentKind
    let projectName: String
    let sessionTitle: String
    let modelName: String?
    let phase: AgentWorkPhase
    let isActive: Bool
    let isWorkingNow: Bool
    let lastUpdated: Date
    let stepCount: Int
    let contextTokens: Int
    let maxContextWindow: Double
    let cacheReadTokens: Int
    let outputTokens: Int
    let filesModifiedCount: Int
    let linesAdded: Int
    let linesRemoved: Int
    let currentFile: String?
    let currentActionTitle: String
    let currentActionDetail: String
    let recentEvents: [AgentToolEvent]
    /// Diff of `currentFile` alone, and a counter bumped by every edit (drives the edit flash)
    var fileLinesAdded: Int = 0
    var fileLinesRemoved: Int = 0
    var editSerial: Int = 0
    /// The last thing an agent deleted from its terminal, until it edits a file again
    var deletedName: String? = nil
    var deletedCount: Int = 0
    var deletionSerial: Int = 0
    /// Working directory of the session, used to find the app the agent runs in
    var projectPath: String? = nil

    var contextPercentage: Double {
        guard maxContextWindow > 0 else { return 0 }
        return min(100.0, (Double(contextTokens) / maxContextWindow) * 100.0)
    }

    var cacheHitPercentage: Double {
        guard contextTokens > 0 else { return 0 }
        return min(100.0, (Double(cacheReadTokens) / Double(contextTokens)) * 100.0)
    }

    var formattedContextTokens: String { Self.formatCompactTokens(contextTokens) }
    var formattedMaxContext: String { Self.formatCompactTokens(Int(maxContextWindow)) }
    var formattedOutputTokens: String { Self.formatCompactTokens(outputTokens) }

    static func formatCompactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000.0
            return m == floor(m) ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000.0)
        }
        return "\(value)"
    }
}

@MainActor
final class AntigravityAgentMonitor: ObservableObject {
    static let shared = AntigravityAgentMonitor()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var isWorkingNow: Bool = false
    @Published private(set) var activeAgentCount: Int = 0
    @Published private(set) var sessions: [AgentSessionSnapshot] = []
    @Published var selectedSessionID: String? = nil
    @Published private(set) var completedPulseSessionID: String? = nil
    @Published private(set) var completedPulseNonce = UUID()

    private var completionPulseResetTask: Task<Void, Never>?

    // Backwards-compatible summary properties bound to selected (or latest) session
    @Published private(set) var conversationID: String = ""
    @Published private(set) var stepCount: Int = 0
    @Published private(set) var contextTokens: Int = 0
    @Published private(set) var cacheReadTokens: Int = 0
    @Published private(set) var totalOutputTokens: Int = 0
    @Published private(set) var filesModifiedCount: Int = 0
    @Published private(set) var currentActionTitle: String = String(localized: "Idle")
    @Published private(set) var currentActionDetail: String = String(localized: "Waiting for prompt…")
    @Published private(set) var recentEvents: [AgentToolEvent] = []

    private struct CachedSessionEntry: Sendable {
        let modDate: Date
        let fileSize: Int
        let lastEventDate: Date
        let snapshot: AgentSessionSnapshot
        let rawPhase: AgentWorkPhase
        let turnComplete: Bool
        var hasPendingTool: Bool = true
        var diff: AgentDiffTally? = nil
        /// The transcript ends on a prompt the model never answered (no record after the USER_INPUT)
        var awaitingFirstResponse: Bool = false
        var firstEventDate: Date = .distantPast
    }

    private struct ISODateParser {
        let frac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let basic: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parse(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            return frac.date(from: raw) ?? basic.date(from: raw)
        }
    }

    private var timer: Timer?
    private var currentPollInterval: TimeInterval = 0
    private var settingsCancellable: AnyCancellable?
    private var maxContextWindow: Double = 1_000_000.0
    private var sessionCache: [String: CachedSessionEntry] = [:]
    private var isRefreshing: Bool = false
    private var lastProcessCheckDate: Date = .distantPast
    private var cachedRunningProcesses: (claude: Bool, codex: Bool) = (true, true)
    /// A session picked by hand stays selected for a while, then the notch follows the live agent again
    private var selectionPinnedUntil: Date = .distantPast

    var activeSession: AgentSessionSnapshot? {
        if let selectedSessionID, let match = sessions.first(where: { $0.id == selectedSessionID }) {
            return match
        }
        return sessions.first(where: { $0.isActive }) ?? sessions.first
    }

    var activeKind: AgentKind {
        activeSession?.kind ?? .antigravity
    }

    var activePhase: AgentWorkPhase {
        activeSession?.phase ?? .idle
    }

    var activeBrandColor: Color {
        activeKind.accentColor
    }

    var contextPercentage: Double {
        activeSession?.contextPercentage ?? min(100.0, (Double(contextTokens) / max(1.0, maxContextWindow)) * 100.0)
    }

    var cacheHitPercentage: Double {
        if let activeSession { return activeSession.cacheHitPercentage }
        guard contextTokens > 0 else { return 0 }
        return min(100.0, (Double(cacheReadTokens) / Double(contextTokens)) * 100.0)
    }

    var formattedContextTokens: String {
        AgentSessionSnapshot.formatCompactTokens(contextTokens)
    }

    var formattedOutputTokens: String {
        AgentSessionSnapshot.formatCompactTokens(totalOutputTokens)
    }

    private var isMonitoringEnabled: Bool {
        Defaults[.showAgentsTab] || Defaults[.enableAgentLiveActivity] || Defaults[.agentSpeechBubbles]
    }

    private func schedulePolling() {
        guard isMonitoringEnabled else {
            timer?.invalidate()
            timer = nil
            currentPollInterval = 0
            completionPulseResetTask?.cancel()
            completionPulseResetTask = nil
            sessionCache.removeAll()
            if !sessions.isEmpty { sessions = [] }
            if isActive { isActive = false }
            if isWorkingNow { isWorkingNow = false }
            if activeAgentCount != 0 { activeAgentCount = 0 }
            if completedPulseSessionID != nil { completedPulseSessionID = nil }
            if selectedSessionID != nil { selectedSessionID = nil }
            syncSummaryProperties()
            return
        }
        // Keep 0.75 s responsiveness while actively working (so sequential file edits show one by one),
        // 1.5 s while an agent session lingers active, and 5 s when idle.
        let desired: TimeInterval = isWorkingNow ? 0.75 : (isActive ? 1.5 : 5.0)
        guard desired != currentPollInterval || timer == nil else { return }
        timer?.invalidate()
        currentPollInterval = desired
        let pollTimer = Timer.scheduledTimer(withTimeInterval: desired, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        pollTimer.tolerance = isWorkingNow ? 0.1 : (isActive ? 0.2 : 1.0)
        timer = pollTimer
    }

    private init() {
        settingsCancellable = Defaults.publisher(keys: .showAgentsTab, .enableAgentLiveActivity, .agentSpeechBubbles)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.schedulePolling()
                    if self.isMonitoringEnabled { self.refresh() }
                }
            }
        if isMonitoringEnabled {
            refresh()
            schedulePolling()
        }
    }

    func selectSession(_ id: String) {
        selectedSessionID = id
        selectionPinnedUntil = Date().addingTimeInterval(120)
        syncSummaryProperties()
    }

    private func updateCompletionPulse(from previous: [AgentSessionSnapshot], to current: [AgentSessionSnapshot]) {
        guard !previous.isEmpty else { return }

        if let pulsedID = completedPulseSessionID,
           let activeMatch = current.first(where: { $0.id == pulsedID }),
           activeMatch.isWorkingNow {
            completionPulseResetTask?.cancel()
            completedPulseSessionID = nil
        }

        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in current {
            guard let before = previousByID[session.id],
                  before.isWorkingNow, !session.isWorkingNow,
                  session.isActive, session.phase == .waiting else { continue }

            completedPulseSessionID = session.id
            completedPulseNonce = UUID()
            completionPulseResetTask?.cancel()
            completionPulseResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4.0))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    if self.completedPulseSessionID == session.id {
                        self.completedPulseSessionID = nil
                    }
                }
            }
            return
        }
    }

    private func syncSummaryProperties() {
        guard let session = activeSession else {
            if !conversationID.isEmpty { conversationID = "" }
            if stepCount != 0 { stepCount = 0 }
            if contextTokens != 0 { contextTokens = 0 }
            if cacheReadTokens != 0 { cacheReadTokens = 0 }
            if totalOutputTokens != 0 { totalOutputTokens = 0 }
            if filesModifiedCount != 0 { filesModifiedCount = 0 }
            let idleTitle = String(localized: "Idle")
            let waitingDetail = String(localized: "Waiting for prompt…")
            if currentActionTitle != idleTitle { currentActionTitle = idleTitle }
            if currentActionDetail != waitingDetail { currentActionDetail = waitingDetail }
            if !recentEvents.isEmpty { recentEvents = [] }
            maxContextWindow = 1_000_000.0
            return
        }
        let nextConvID = String(session.id.suffix(8))
        if conversationID != nextConvID { conversationID = nextConvID }
        if stepCount != session.stepCount { stepCount = session.stepCount }
        if contextTokens != session.contextTokens { contextTokens = session.contextTokens }
        if cacheReadTokens != session.cacheReadTokens { cacheReadTokens = session.cacheReadTokens }
        if totalOutputTokens != session.outputTokens { totalOutputTokens = session.outputTokens }
        if filesModifiedCount != session.filesModifiedCount { filesModifiedCount = session.filesModifiedCount }
        if currentActionTitle != session.currentActionTitle { currentActionTitle = session.currentActionTitle }
        if currentActionDetail != session.currentActionDetail { currentActionDetail = session.currentActionDetail }
        if recentEvents != session.recentEvents { recentEvents = session.recentEvents }
        maxContextWindow = session.maxContextWindow
    }

    private nonisolated static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private nonisolated static func readTailLines(from url: URL, maxBytes: UInt64 = 196_608) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        // A single transcript line can be bigger than the window (an image an agent read is stored
        // as base64, 300 KB and more). The window then held no complete line, the session was
        // skipped and its live indicator vanished until the next line came in, so widen it instead.
        var window = maxBytes
        while true {
            let offset = fileSize > window ? fileSize - window : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
            // Advance past the first newline on raw bytes when seeking mid-file so we never fail UTF-8
            // decoding on a split multibyte sequence (e.g. emoji or accented paths).
            var slice = data[data.startIndex..<data.endIndex]
            if offset > 0, let firstNewline = slice.firstIndex(of: 0x0A) {
                slice = slice[slice.index(after: firstNewline)...]
            } else if offset > 0 {
                slice = slice[slice.endIndex...]
            }
            let lines: [String] = slice.split(separator: 0x0A).compactMap { lineBytes in
                guard !lineBytes.isEmpty else { return nil }
                let trimmed = lineBytes.last == 0x0D ? lineBytes.dropLast() : lineBytes
                guard !trimmed.isEmpty else { return nil }
                return String(decoding: trimmed, as: UTF8.self)
            }
            if lines.count >= 2 || offset == 0 || window >= 3_145_728 {
                return lines
            }
            window *= 4
        }
    }

    nonisolated static func isUserPromptTool(_ toolName: String) -> Bool {
        let lower = toolName.lowercased().replacingOccurrences(of: "task", with: "")
        return lower.contains("exit_plan_mode")
            || lower.contains("exitplan")
            || lower.contains("ask")
            || lower.contains("question")
            || lower.contains("notify_user")
            || lower.contains("confirm")
    }

    private nonisolated static func detectRunningAgentProcesses() -> (claude: Bool, codex: Bool) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return (true, true)
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
            return (true, true)
        }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        var claudeRunning = false
        var codexRunning = false

        for i in 0..<actual {
            if claudeRunning && codexRunning { break }
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }
            let match = agentProcessMatch(pid: pid, comm: procs[i].kp_proc.p_comm)
            if match.claude { claudeRunning = true }
            if match.codex { codexRunning = true }
        }
        return (claudeRunning, codexRunning)
    }

    /// Whether a process is a Claude Code or Codex CLI. The process name alone is not enough: the native
    /// Claude Code installer runs ~/.local/share/claude/versions/<version>, so its name is "2.1.330".
    nonisolated static func agentProcessMatch(
        pid: pid_t,
        comm rawComm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                       CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    ) -> (claude: Bool, codex: Bool) {
        let comm = withUnsafeBytes(of: rawComm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!).lowercased()
        }
        var claude = comm == "claude"
        var codex = comm == "codex"
        if claude || codex { return (claude, codex) }

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return (false, false) }
        let path = String(cString: pathBuf).lowercased()
        claude = path.contains("/claude/") || path.hasSuffix("/claude")
        codex = path.contains("/codex/") || path.hasSuffix("/codex") || path.contains("codex.app")
        guard !claude, !codex, path.hasSuffix("/node") || path.hasSuffix("/bun") else { return (claude, codex) }

        var argsMib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var argsSize: Int = 0
        guard sysctl(&argsMib, 3, nil, &argsSize, nil, 0) == 0, argsSize > 4, argsSize < 65_536 else {
            return (false, false)
        }
        var argsBuf = [UInt8](repeating: 0, count: argsSize)
        guard sysctl(&argsMib, 3, &argsBuf, &argsSize, nil, 0) == 0 else { return (false, false) }
        let args = argsBuf.dropFirst(4).split(separator: 0).prefix(6).compactMap {
            String(bytes: $0, encoding: .utf8)?.lowercased()
        }
        claude = args.contains { $0.hasSuffix("/claude") || $0.contains("/claude/") || $0 == "claude" }
        codex = args.contains { $0.hasSuffix("/codex") || $0.contains("/codex/") || $0 == "codex" }
        return (claude, codex)
    }

    private nonisolated static func resolveSnapshot(
        from entry: CachedSessionEntry,
        now: Date,
        processRunning: Bool = true,
        promptSuperseded: Bool = false,
        turnAborted: Bool = false
    ) -> AgentSessionSnapshot {
        let s = entry.snapshot
        let age = max(0, now.timeIntervalSince(entry.lastEventDate))

        // Antigravity sometimes leaves a duplicate conversation holding only the prompt, while the real
        // run happens in a newer one. An unanswered prompt is dead once superseded or silent for 90 s.
        let abandonedPrompt = entry.awaitingFirstResponse && (promptSuperseded || age > 90.0)

        // Mid-turn the transcript stays silent while a command, a search or a long thought runs,
        // so silence alone does not mean the agent stopped. Edits and questions are the exception:
        // there, silence means the agent is blocked on the user.
        let midTurn = !entry.turnComplete && !abandonedPrompt && !turnAborted
        let pendingTool = entry.hasPendingTool ? (s.recentEvents.first?.toolName ?? "") : ""
        let blockedOnUser = entry.hasPendingTool && (entry.rawPhase == .editing || isUserPromptTool(pendingTool))
        // A finished turn lingers only for the completion check (4 s), not as a ring that looks like work.
        // A turn killed by an error ends at once, without the green check of a finished task.
        let isActive = !turnAborted && age < (midTurn ? (processRunning ? 600.0 : 45.0) : 8.0)
        let isWorkingNow = processRunning && midTurn && age < (blockedOnUser ? 22.0 : 600.0)
        let workingPhase: AgentWorkPhase = entry.rawPhase == .waiting ? .thinking : entry.rawPhase
        let effectivePhase: AgentWorkPhase = (!midTurn || !isActive || !processRunning) ? .waiting : workingPhase

        return AgentSessionSnapshot(
            id: s.id,
            kind: s.kind,
            projectName: s.projectName,
            sessionTitle: s.sessionTitle,
            modelName: s.modelName,
            phase: effectivePhase,
            isActive: isActive,
            isWorkingNow: isWorkingNow,
            lastUpdated: s.lastUpdated,
            stepCount: s.stepCount,
            contextTokens: s.contextTokens,
            maxContextWindow: s.maxContextWindow,
            cacheReadTokens: s.cacheReadTokens,
            outputTokens: s.outputTokens,
            filesModifiedCount: s.filesModifiedCount,
            linesAdded: s.linesAdded,
            linesRemoved: s.linesRemoved,
            currentFile: s.currentFile,
            currentActionTitle: s.currentActionTitle,
            currentActionDetail: s.currentActionDetail,
            recentEvents: s.recentEvents,
            fileLinesAdded: s.fileLinesAdded,
            fileLinesRemoved: s.fileLinesRemoved,
            editSerial: s.editSerial,
            deletedName: s.deletedName,
            deletedCount: s.deletedCount,
            deletionSerial: s.deletionSerial,
            projectPath: s.projectPath
        )
    }

    /// Antigravity stores tool arguments as JSON string literals inside the JSON record
    /// ("CommandLine": "\"git status\""), so decode that inner literal once more
    nonisolated static func decodeAntigravityArgument(_ raw: String) -> String {
        guard raw.hasPrefix("\""),
              let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) as? String
        else { return raw }
        return decoded
    }

    private nonisolated static func inferProjectName(fromPath path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        if let idx = components.firstIndex(where: { $0.contains("Développement") || $0.lowercased() == "projects" || $0.lowercased() == "repos" }),
           idx + 1 < components.count {
            return components[idx + 1]
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty || parent == "/" ? URL(fileURLWithPath: path).lastPathComponent : parent
    }

    private nonisolated static func parseAntigravitySessions(
        home: String,
        now: Date,
        dateParser: ISODateParser,
        cache: inout [String: CachedSessionEntry]
    ) -> [AgentSessionSnapshot] {
        let brainDir = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity/brain")
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, diffURL: URL, isCompactDiff: Bool, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)
        for dir in subdirs {
            let logsDir = dir.appendingPathComponent(".system_generated/logs")
            let transcript = logsDir.appendingPathComponent("transcript.jsonl")
            if let vals = try? transcript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let modDate = vals.contentModificationDate,
               modDate > cutoff {
                let fullTranscript = logsDir.appendingPathComponent("transcript_full.jsonl")
                let fullVals = try? fullTranscript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let hasFull = fullVals?.contentModificationDate != nil
                let effectiveMod = max(modDate, fullVals?.contentModificationDate ?? .distantPast)
                let effectiveSize = (vals.fileSize ?? 0) &+ (fullVals?.fileSize ?? 0)
                candidates.append((
                    url: transcript,
                    diffURL: hasFull ? fullTranscript : transcript,
                    isCompactDiff: !hasFull,
                    id: dir.lastPathComponent,
                    modDate: effectiveMod,
                    fileSize: effectiveSize
                ))
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var entries: [CachedSessionEntry] = []
        for candidate in candidates.prefix(3) {
            let key = "ag:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                entries.append(cached)
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

            struct ParsedBatchTool {
                let name: String
                let phase: AgentWorkPhase
                let detail: String
                let targetFile: String?
                let stepIdx: Int
                var date: Date
            }

            var lastStep = 0
            var lastContext = 0
            var lastCache = 0
            var sumOutput = 0
            var editCount = 0
            var latestTitle = String(localized: "Antigravity Ready")
            var latestDetail = String(localized: "Session active")
            var latestPhase: AgentWorkPhase = .waiting
            var latestFile: String? = nil
            var inferredProject = "Antigravity"
            var events: [AgentToolEvent] = []
            var lastStepDate: Date = candidate.modDate
            var firstEventDate: Date? = nil
            var lastRecordType = ""
            var lastTurnComplete = false
            var pendingToolCalls = 0
            var activeBatch: [ParsedBatchTool] = []
            var activeBatchDone = 0
            var deletion: AgentDeletionParser.Deletion? = nil
            var deletionSerial = 0

            func emitBatch(upTo count: Int) {
                guard !activeBatch.isEmpty else { return }
                let limit = min(count, activeBatch.count)
                for i in 0..<limit {
                    let tool = activeBatch[i]
                    if tool.phase == .editing { editCount += 1 }
                    latestTitle = tool.name
                    latestDetail = tool.detail
                    latestPhase = tool.phase
                    if let targetFile = tool.targetFile { latestFile = targetFile }
                    events.append(
                        AgentToolEvent(
                            id: "ag-\(candidate.id.prefix(6))-\(tool.stepIdx)-\(events.count)",
                            stepIndex: tool.stepIdx,
                            toolName: tool.name,
                            phase: tool.phase,
                            summary: tool.detail,
                            targetFile: tool.targetFile,
                            timestamp: tool.date
                        )
                    )
                }
            }

            for line in lines.suffix(160) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let stepIdx = (obj["step_index"] as? Int) ?? lastStep
                lastStep = max(lastStep, stepIdx)
                let recordType = (obj["type"] as? String) ?? ""
                if !recordType.isEmpty {
                    lastRecordType = recordType
                }
                let recordStatus = (obj["status"] as? String) ?? "DONE"

                if let d = dateParser.parse(obj["created_at"] as? String) {
                    lastStepDate = d
                    if firstEventDate == nil { firstEventDate = d }
                }

                let inTok = (obj["input_tokens"] as? Int) ?? 0
                let cacheTok = (obj["cache_read_tokens"] as? Int) ?? 0
                let outTok = (obj["output_tokens"] as? Int) ?? 0
                if inTok + cacheTok > 0 {
                    lastContext = inTok + cacheTok
                    lastCache = cacheTok
                }
                sumOutput += outTok

                if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    if !activeBatch.isEmpty {
                        emitBatch(upTo: activeBatch.count)
                        activeBatch.removeAll(keepingCapacity: true)
                        activeBatchDone = 0
                    }
                    lastTurnComplete = false
                    pendingToolCalls = toolCalls.count
                    for tc in toolCalls {
                        let name = (tc["name"] as? String) ?? "tool"
                        let args = (tc["args"] as? [String: Any]) ?? [:]
                        var phase = AgentWorkPhase.classify(toolName: name)
                        if phase == .editing {
                            deletion = nil
                        } else if phase == .running,
                                  let command = (args["CommandLine"] as? String).map(Self.decodeAntigravityArgument),
                                  let found = AgentDeletionParser.deletion(in: command) {
                            phase = .deleting
                            deletion = found
                            deletionSerial += 1
                        }

                        var targetFile: String? = nil
                        if let path = (args["Path"] as? String)
                            ?? (args["TargetFile"] as? String)
                            ?? (args["AbsolutePath"] as? String)
                            ?? (args["file_path"] as? String) {
                            let clean = path.replacingOccurrences(of: "\"", with: "")
                            targetFile = URL(fileURLWithPath: clean).lastPathComponent
                            let isWorkspacePath = clean.contains("Développement")
                                || clean.localizedCaseInsensitiveContains("/projects/")
                                || clean.localizedCaseInsensitiveContains("/repos/")
                            let proj = inferProjectName(fromPath: clean)
                            if !proj.isEmpty && proj != "/" && (inferredProject == "Antigravity" || isWorkspacePath) {
                                inferredProject = proj
                            }
                        }

                        let detail: String
                        if let summary = args["toolSummary"] as? String, !summary.isEmpty {
                            detail = summary.replacingOccurrences(of: "\"", with: "")
                        } else if let targetFile {
                            detail = targetFile
                        } else if let cmd = args["CommandLine"] as? String {
                            detail = String(cmd.prefix(64))
                        } else {
                            detail = name
                        }

                        activeBatch.append(
                            ParsedBatchTool(
                                name: name,
                                phase: phase,
                                detail: detail,
                                targetFile: targetFile,
                                stepIdx: stepIdx,
                                date: lastStepDate
                            )
                        )
                    }
                } else if recordType == "PLANNER_RESPONSE" {
                    if !activeBatch.isEmpty {
                        emitBatch(upTo: activeBatch.count)
                        activeBatch.removeAll(keepingCapacity: true)
                        activeBatchDone = 0
                    }
                    pendingToolCalls = 0
                    lastTurnComplete = (recordStatus == "DONE")
                    if !lastTurnComplete && latestPhase == .waiting {
                        latestPhase = .thinking
                    }
                } else if recordType == "USER_INPUT" {
                    if !activeBatch.isEmpty {
                        emitBatch(upTo: activeBatch.count)
                        activeBatch.removeAll(keepingCapacity: true)
                        activeBatchDone = 0
                    }
                    lastTurnComplete = false
                    pendingToolCalls = 0
                    latestPhase = .thinking
                    latestTitle = String(localized: "Processing prompt")
                    latestDetail = String(localized: "Analyzing context…")
                } else if !recordType.isEmpty {
                    lastTurnComplete = false
                    if recordType == "SYSTEM_MESSAGE" {
                        if !activeBatch.isEmpty {
                            emitBatch(upTo: activeBatch.count)
                            activeBatch.removeAll(keepingCapacity: true)
                            activeBatchDone = 0
                        }
                        pendingToolCalls = 0
                    } else if recordType == "GENERIC" || recordType == "ERROR_MESSAGE" {
                        if activeBatchDone < activeBatch.count {
                            activeBatch[activeBatchDone].date = lastStepDate
                            activeBatchDone += 1
                        }
                        if pendingToolCalls > 0 {
                            pendingToolCalls -= 1
                        }
                        if activeBatchDone >= activeBatch.count && !activeBatch.isEmpty {
                            emitBatch(upTo: activeBatch.count)
                            activeBatch.removeAll(keepingCapacity: true)
                            activeBatchDone = 0
                        }
                    } else if pendingToolCalls > 0 {
                        pendingToolCalls -= 1
                    }
                    if pendingToolCalls == 0 && (latestPhase == .waiting || latestPhase == .editing) {
                        latestPhase = .thinking
                    }
                }

                if recordStatus != "DONE" {
                    lastTurnComplete = false
                    if latestPhase == .waiting {
                        latestPhase = .thinking
                    }
                }
            }

            if !activeBatch.isEmpty {
                // Show completed tools in the current batch plus the ONE tool executing right now
                // so multi-file edit batches step through each file one by one in real time.
                let visibleCount = activeBatchDone < activeBatch.count ? (activeBatchDone + 1) : activeBatch.count
                emitBatch(upTo: visibleCount)
            }

            var tally = cache[key]?.diff ?? AgentDiffTally()
            tally.advanceAntigravity(url: candidate.diffURL, isCompactTranscript: candidate.isCompactDiff)
            // Keep the focus card anchored on an edited file whenever Antigravity has active diffs in this
            // session, so intermediate read_file/run_command steps or 1 ms flush races never drop the bar
            // back to the indeterminate blue activity bar.
            let inFlightName = tally.inFlightEdit?.fileName
            let focusFile: String? = {
                if let inFlightName, tally.liveFileDiff(for: inFlightName) != nil {
                    return inFlightName
                }
                if let latestFile, tally.liveFileDiff(for: latestFile) != nil {
                    return latestFile
                }
                if let lastEdited = tally.lastEditedFile, tally.liveFileDiff(for: lastEdited) != nil {
                    return lastEdited
                }
                return latestFile
            }()
            let fileDiff = focusFile.flatMap { tally.liveFileDiff(for: $0) }
            let liveAdded = tally.added + (tally.inFlightEdit?.added ?? 0)
            let liveRemoved = tally.removed + (tally.inFlightEdit?.removed ?? 0)

            let baseSnapshot = AgentSessionSnapshot(
                id: key,
                kind: .antigravity,
                projectName: inferredProject,
                sessionTitle: String(localized: "Step #\(lastStep)"),
                modelName: "Gemini",
                phase: latestPhase,
                isActive: false,
                isWorkingNow: false,
                lastUpdated: candidate.modDate,
                stepCount: lastStep,
                contextTokens: lastContext,
                maxContextWindow: 1_000_000.0,
                cacheReadTokens: lastCache,
                outputTokens: sumOutput,
                filesModifiedCount: max(editCount, tally.perFile.count),
                linesAdded: liveAdded,
                linesRemoved: liveRemoved,
                currentFile: focusFile,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed()),
                fileLinesAdded: fileDiff?.added ?? 0,
                fileLinesRemoved: fileDiff?.removed ?? 0,
                editSerial: tally.liveEditSerial,
                deletedName: deletion?.name,
                deletedCount: deletion?.count ?? 0,
                deletionSerial: deletionSerial
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                lastEventDate: max(lastStepDate, candidate.modDate),
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: lastTurnComplete,
                hasPendingTool: pendingToolCalls > 0,
                diff: tally,
                awaitingFirstResponse: lastRecordType == "USER_INPUT",
                firstEventDate: firstEventDate ?? candidate.modDate
            )
            cache[key] = entry
            entries.append(entry)
        }

        // A run killed by an error (no credits left, quota, network) writes nothing more to its
        // transcript, which then looks mid-turn for 10 minutes; the error only lands in the agent's log.
        let executorError = entries.contains { !$0.turnComplete }
            ? latestAntigravityExecutorError(home: home, now: now)
            : nil

        return entries.map { entry in
            let superseded = entry.awaitingFirstResponse && entries.contains {
                $0.snapshot.id != entry.snapshot.id && $0.firstEventDate > entry.lastEventDate
            }
            let aborted = !entry.turnComplete && (executorError.map { $0 > entry.lastEventDate } ?? false)
            return resolveSnapshot(from: entry, now: now, promptSuperseded: superseded, turnAborted: aborted)
        }
    }

    /// Time of the last fatal "agent executor error" in the Antigravity agent logs written in the last
    /// 15 minutes. Lines are glog formatted: "E1125 01:44:02.942183   86195 errorreport.go:282] agent executor error: ..."
    private nonisolated static func latestAntigravityExecutorError(home: String, now: Date) -> Date? {
        let logDir = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity/log")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        var latest: Date?
        for file in files where file.lastPathComponent.hasPrefix("cli-") && file.pathExtension == "log" {
            guard let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mod) < 900 else { continue }
            for line in readTailLines(from: file, maxBytes: 32_768).reversed()
            where line.hasPrefix("E") && line.contains("agent executor error") {
                // "E1125 01:44:02.942183": month, day, then the local time
                let chars = Array(line.prefix(21))
                guard chars.count == 21,
                      let month = Int(String(chars[1...2])), let day = Int(String(chars[3...4])),
                      let hour = Int(String(chars[6...7])), let minute = Int(String(chars[9...10])),
                      let second = Double(String(chars[12...20])) else { break }
                var parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
                parts.second = Int(second)
                parts.nanosecond = Int((second - Double(Int(second))) * 1_000_000_000)
                guard var date = calendar.date(from: parts) else { break }
                // The log carries no year: a date ahead of now belongs to last year (31 Dec -> 1 Jan)
                if date > now.addingTimeInterval(86_400), let previous = calendar.date(byAdding: .year, value: -1, to: date) {
                    date = previous
                }
                if latest == nil || date > latest! { latest = date }
                break
            }
        }
        return latest
    }

    private nonisolated static func parseClaudeSessions(
        home: String,
        now: Date,
        dateParser: ISODateParser,
        processRunning: Bool,
        cache: inout [String: CachedSessionEntry]
    ) -> [AgentSessionSnapshot] {
        let projectsDir = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        guard let projectFolders = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)

        for folder in projectFolders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let modDate = vals.contentModificationDate,
                   modDate > cutoff {
                    candidates.append((file, file.deletingPathExtension().lastPathComponent, modDate, vals.fileSize ?? 0))
                }
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var snapshots: [AgentSessionSnapshot] = []
        for candidate in candidates.prefix(6) {
            let key = "cc:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                snapshots.append(resolveSnapshot(from: cached, now: now, processRunning: processRunning))
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

            var projectName = "Claude Code"
            var projectPath: String? = nil
            var sessionTitle = ""
            var modelDisplay: String? = nil
            var contextTokens = 0
            var cacheRead = 0
            var sumOutput = 0
            var stepCounter = 0
            var editCount = 0
            var linesAdded = 0
            var linesRemoved = 0
            var latestTitle = String(localized: "Claude Ready")
            var latestDetail = String(localized: "Session active")
            var latestPhase: AgentWorkPhase = .waiting
            var latestFile: String? = nil
            var events: [AgentToolEvent] = []
            var lastEventDate: Date = .distantPast
            var lastTurnComplete = false
            var justSawCompactBoundary = false
            var hasPendingTool = false
            var deletion: AgentDeletionParser.Deletion? = nil
            var deletionSerial = 0

            for line in lines.suffix(180) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let rowType = (obj["type"] as? String) ?? ""
                let parsedTimestamp = dateParser.parse(obj["timestamp"] as? String)
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                    projectPath = cwd
                }

                if rowType == "ai-title", let title = obj["aiTitle"] as? String, !title.isEmpty {
                    sessionTitle = title
                    continue
                }
                if rowType == "cost-state" {
                    linesAdded = max(linesAdded, (obj["totalLinesAdded"] as? Int) ?? 0)
                    linesRemoved = max(linesRemoved, (obj["totalLinesRemoved"] as? Int) ?? 0)
                    continue
                }
                if rowType == "system" {
                    let subtype = (obj["subtype"] as? String) ?? ""
                    if subtype == "compact_boundary" {
                        justSawCompactBoundary = true
                        lastTurnComplete = true
                        hasPendingTool = false
                    } else if subtype == "turn_duration" || subtype == "stop_hook_summary" {
                        justSawCompactBoundary = false
                        lastTurnComplete = true
                        hasPendingTool = false
                        if let d = parsedTimestamp, d > lastEventDate {
                            lastEventDate = d
                        }
                    }
                    continue
                }

                if rowType == "user" {
                    let isMeta = (obj["isMeta"] as? Bool) == true
                    let isCompactSummary = (obj["isCompactSummary"] as? Bool) == true
                    let isVisibleInTranscriptOnly = (obj["isVisibleInTranscriptOnly"] as? Bool) == true
                    let followsCompact = justSawCompactBoundary
                    justSawCompactBoundary = false

                    if isMeta || isCompactSummary || isVisibleInTranscriptOnly || followsCompact {
                        continue
                    }

                    let userMessage = obj["message"] as? [String: Any]
                    let userText = (userMessage?["content"] as? String)
                        ?? ((userMessage?["content"] as? [[String: Any]])?.first?["text"] as? String)
                        ?? ""
                    // Local slash commands (/clear, /model, /mcp, /compact...) are logged as
                    // "<command-name>..." and never reach the model. Commands that do prompt it
                    // (skills, /init) are logged as "<command-message>..." and still start a turn.
                    if userText.hasPrefix("<command-name>") || userText.hasPrefix("<local-command-") {
                        continue
                    }

                    if let d = parsedTimestamp, d > lastEventDate {
                        lastEventDate = d
                    }
                    hasPendingTool = false
                    if userText.hasPrefix("[Request interrupted by user") {
                        lastTurnComplete = true
                        continue
                    }
                    lastTurnComplete = false
                    latestPhase = .thinking
                    latestTitle = String(localized: "Thinking")
                    latestDetail = sessionTitle.isEmpty ? String(localized: "Analyzing context…") : sessionTitle
                    continue
                }

                guard rowType == "assistant", let message = obj["message"] as? [String: Any] else {
                    continue
                }

                justSawCompactBoundary = false
                if let d = parsedTimestamp, d > lastEventDate {
                    lastEventDate = d
                }
                let eventTime = parsedTimestamp ?? (lastEventDate == .distantPast ? candidate.modDate : lastEventDate)
                lastTurnComplete = false
                hasPendingTool = false
                stepCounter += 1

                if let model = message["model"] as? String, !model.isEmpty {
                    modelDisplay = formatClaudeModelName(model)
                }

                if let usage = message["usage"] as? [String: Any] {
                    let inTok = (usage["input_tokens"] as? Int) ?? 0
                    let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let cRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let outTok = (usage["output_tokens"] as? Int) ?? 0
                    let totalIn = inTok + cacheCreate + cRead
                    if totalIn > 0 {
                        contextTokens = totalIn
                        cacheRead = cRead
                    }
                    sumOutput += outTok
                }

                if let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        let cType = (item["type"] as? String) ?? ""
                        if cType == "thinking" {
                            latestPhase = .thinking
                            latestTitle = String(localized: "Thinking")
                            latestDetail = sessionTitle.isEmpty ? String(localized: "Reasoning…") : sessionTitle
                        } else if cType == "tool_use" {
                            hasPendingTool = true
                            let name = (item["name"] as? String) ?? "Tool"
                            let input = (item["input"] as? [String: Any]) ?? [:]
                            var phase = AgentWorkPhase.classify(toolName: name)
                            if phase == .editing {
                                editCount += 1
                                deletion = nil
                            } else if phase == .running,
                                      let command = input["command"] as? String,
                                      let found = AgentDeletionParser.deletion(in: command) {
                                phase = .deleting
                                deletion = found
                                deletionSerial += 1
                            }

                            var targetFile: String? = nil
                            if let fp = input["file_path"] as? String, !fp.isEmpty {
                                targetFile = URL(fileURLWithPath: fp).lastPathComponent
                            }

                            let detail: String
                            if let desc = input["description"] as? String, !desc.isEmpty {
                                detail = desc
                            } else if let targetFile {
                                detail = targetFile
                            } else if let cmd = input["command"] as? String, !cmd.isEmpty {
                                detail = String(cmd.prefix(64))
                            } else if let pattern = input["pattern"] as? String, !pattern.isEmpty {
                                detail = pattern
                            } else {
                                detail = name
                            }

                            latestTitle = name
                            latestDetail = detail
                            latestPhase = phase
                            if let targetFile { latestFile = targetFile }

                            events.append(
                                AgentToolEvent(
                                    id: "cc-\(candidate.id.prefix(6))-\(stepCounter)-\(events.count)",
                                    stepIndex: stepCounter,
                                    toolName: name,
                                    phase: phase,
                                    summary: detail,
                                    targetFile: targetFile,
                                    timestamp: eventTime
                                )
                            )
                        }
                    }
                }
            }

            var tally = cache[key]?.diff ?? AgentDiffTally()
            tally.advance(url: candidate.url)
            let fileDiff = latestFile.flatMap { tally.perFile[$0] }

            let windowSize: Double = contextTokens > 200_000 ? 1_000_000.0 : 200_000.0
            let baseSnapshot = AgentSessionSnapshot(
                id: key,
                kind: .claudeCode,
                projectName: projectName,
                sessionTitle: sessionTitle,
                modelName: modelDisplay,
                phase: latestPhase,
                isActive: false,
                isWorkingNow: false,
                lastUpdated: lastEventDate,
                stepCount: stepCounter,
                contextTokens: contextTokens,
                maxContextWindow: windowSize,
                cacheReadTokens: cacheRead,
                outputTokens: sumOutput,
                filesModifiedCount: editCount,
                linesAdded: max(linesAdded, tally.added),
                linesRemoved: max(linesRemoved, tally.removed),
                currentFile: latestFile,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed()),
                fileLinesAdded: fileDiff?.added ?? 0,
                fileLinesRemoved: fileDiff?.removed ?? 0,
                editSerial: tally.editCount,
                deletedName: deletion?.name,
                deletedCount: deletion?.count ?? 0,
                deletionSerial: deletionSerial,
                projectPath: projectPath
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                lastEventDate: lastEventDate,
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: lastTurnComplete,
                hasPendingTool: hasPendingTool,
                diff: tally
            )
            cache[key] = entry
            snapshots.append(resolveSnapshot(from: entry, now: now, processRunning: processRunning))
        }
        return snapshots
    }

    private nonisolated static func parseCodexSessions(
        home: String,
        now: Date,
        dateParser: ISODateParser,
        processRunning: Bool,
        cache: inout [String: CachedSessionEntry]
    ) -> [AgentSessionSnapshot] {
        let sessionsRoot = URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot.path) else { return [] }

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)
        // Codex organizes sessions under YYYY/MM/DD: scan today and yesterday first instead of walking history
        let cal = Calendar(identifier: .gregorian)
        var scannedDateDirs = false
        for dayOffset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dayDir = sessionsRoot
                .appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d), isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            scannedDateDirs = true
            for fileURL in files where fileURL.pathExtension == "jsonl" {
                if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let modDate = vals.contentModificationDate,
                   modDate > cutoff {
                    candidates.append((fileURL, fileURL.deletingPathExtension().lastPathComponent, modDate, vals.fileSize ?? 0))
                }
            }
        }
        if !scannedDateDirs,
           let enumerator = fm.enumerator(
               at: sessionsRoot,
               includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let modDate = vals.contentModificationDate,
                   modDate > cutoff {
                    candidates.append((fileURL, fileURL.deletingPathExtension().lastPathComponent, modDate, vals.fileSize ?? 0))
                }
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var snapshots: [AgentSessionSnapshot] = []
        for candidate in candidates.prefix(2) {
            let key = "cx:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                snapshots.append(resolveSnapshot(from: cached, now: now, processRunning: processRunning))
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

            var projectName = "Codex"
            var windowSize: Double = 200_000.0
            var contextTokens = 0
            var cacheRead = 0
            var sumOutput = 0
            var stepCounter = 0
            var editCount = 0
            var projectPath: String? = nil
            var latestTitle = String(localized: "Codex Ready")
            var latestDetail = String(localized: "Session active")
            var latestPhase: AgentWorkPhase = .waiting
            var events: [AgentToolEvent] = []
            var lastEventDate: Date = .distantPast
            var taskComplete = false
            var hasPendingTool = false

            for line in lines.suffix(150) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let rowType = (obj["type"] as? String) ?? ""
                let parsedTimestamp = dateParser.parse(obj["timestamp"] as? String)

                let payload = obj["payload"] as? [String: Any]
                if rowType == "session_meta", let cwd = payload?["cwd"] as? String, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                    projectPath = cwd
                } else if rowType == "event_msg", let payload {
                    let pType = (payload["type"] as? String) ?? ""
                    if pType == "task_started" {
                        if let d = parsedTimestamp, d > lastEventDate { lastEventDate = d }
                        taskComplete = false
                        hasPendingTool = false
                        if let win = payload["model_context_window"] as? Int, win > 0 {
                            windowSize = Double(win)
                        }
                        latestPhase = .thinking
                    } else if pType == "task_complete" {
                        if let d = parsedTimestamp, d > lastEventDate { lastEventDate = d }
                        taskComplete = true
                        hasPendingTool = false
                        latestPhase = .waiting
                    } else if pType == "item_completed" {
                        if let d = parsedTimestamp, d > lastEventDate { lastEventDate = d }
                    } else if pType == "token_count", let info = payload["info"] as? [String: Any] {
                        if let last = info["last_token_usage"] as? [String: Any] {
                            let inTok = (last["input_tokens"] as? Int) ?? 0
                            let cached = (last["cached_input_tokens"] as? Int) ?? 0
                            let outTok = (last["output_tokens"] as? Int) ?? 0
                            if inTok > 0 { contextTokens = inTok; cacheRead = cached }
                            sumOutput = max(sumOutput, outTok)
                        }
                        if let win = info["model_context_window"] as? Int, win > 0 {
                            windowSize = Double(win)
                        }
                    }
                } else if rowType == "response_item", let payload {
                    let pType = (payload["type"] as? String) ?? ""
                    let role = (payload["role"] as? String) ?? ""
                    let isModelOrUserEvent = pType == "function_call"
                        || pType == "custom_tool_call"
                        || pType == "function_call_output"
                        || pType == "custom_tool_call_output"
                        || pType == "tool_search_call"
                        || pType == "tool_search_output"
                        || pType == "web_search_call"
                        || pType == "agent_message"
                        || pType == "reasoning"
                        || (pType == "message" && (role == "user" || role == "assistant"))
                    if isModelOrUserEvent, let d = parsedTimestamp, d > lastEventDate {
                        lastEventDate = d
                    }
                    if pType == "function_call" || pType == "custom_tool_call" {
                        hasPendingTool = true
                        stepCounter += 1
                        let name = (payload["name"] as? String) ?? "tool"
                        let phase = AgentWorkPhase.classify(toolName: name)
                        if phase == .editing { editCount += 1 }
                        latestTitle = name
                        latestDetail = projectName
                        latestPhase = phase
                        let eventTime = parsedTimestamp ?? (lastEventDate == .distantPast ? candidate.modDate : lastEventDate)
                        events.append(
                            AgentToolEvent(
                                id: "cx-\(candidate.id.prefix(6))-\(stepCounter)-\(events.count)",
                                stepIndex: stepCounter,
                                toolName: name,
                                phase: phase,
                                summary: name,
                                targetFile: nil,
                                timestamp: eventTime
                            )
                        )
                    } else if pType == "function_call_output" || pType == "custom_tool_call_output" {
                        hasPendingTool = false
                        if latestPhase == .editing || latestPhase == .waiting {
                            latestPhase = .thinking
                        }
                    }
                }
            }

            let baseSnapshot = AgentSessionSnapshot(
                id: key,
                kind: .codex,
                projectName: projectName,
                sessionTitle: "",
                modelName: "Codex",
                phase: latestPhase,
                isActive: false,
                isWorkingNow: false,
                lastUpdated: lastEventDate,
                stepCount: stepCounter,
                contextTokens: contextTokens,
                maxContextWindow: windowSize,
                cacheReadTokens: cacheRead,
                outputTokens: sumOutput,
                filesModifiedCount: editCount,
                linesAdded: 0,
                linesRemoved: 0,
                currentFile: nil,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed()),
                projectPath: projectPath
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                lastEventDate: lastEventDate,
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: taskComplete,
                hasPendingTool: hasPendingTool
            )
            cache[key] = entry
            snapshots.append(resolveSnapshot(from: entry, now: now, processRunning: processRunning))
        }
        return snapshots
    }

    private nonisolated static func formatClaudeModelName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("opus-4-6") { return "Opus 4.6" }
        if lower.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if lower.contains("haiku-4-5") { return "Haiku 4.5" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("haiku") { return "Haiku" }
        return raw
    }

    func refresh() {
        guard isMonitoringEnabled, !isRefreshing else { return }
        isRefreshing = true
        let initialCache = sessionCache
        let prevProcessCheckDate = lastProcessCheckDate
        let prevRunningProcesses = cachedRunningProcesses
        let processCheckInterval: TimeInterval = isActive ? 4.0 : 10.0

        Task.detached(priority: .utility) {
            let home = Self.realHomeDirectory()
            let now = Date()
            let dateParser = ISODateParser()
            var nextCache = initialCache

            let runningProcesses: (claude: Bool, codex: Bool)
            let processCheckDate: Date
            if now.timeIntervalSince(prevProcessCheckDate) >= processCheckInterval {
                runningProcesses = Self.detectRunningAgentProcesses()
                processCheckDate = now
            } else {
                runningProcesses = prevRunningProcesses
                processCheckDate = prevProcessCheckDate
            }

            var combined: [AgentSessionSnapshot] = []
            combined.append(contentsOf: Self.parseClaudeSessions(home: home, now: now, dateParser: dateParser, processRunning: runningProcesses.claude, cache: &nextCache))
            combined.append(contentsOf: Self.parseAntigravitySessions(home: home, now: now, dateParser: dateParser, cache: &nextCache))
            combined.append(contentsOf: Self.parseCodexSessions(home: home, now: now, dateParser: dateParser, processRunning: runningProcesses.codex, cache: &nextCache))

            combined.sort { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                if lhs.isWorkingNow != rhs.isWorkingNow { return lhs.isWorkingNow && !rhs.isWorkingNow }
                return lhs.lastUpdated > rhs.lastUpdated
            }

            let trimmed = Array(combined.prefix(6))
            let validKeys = Set(trimmed.map { $0.id })
            nextCache = nextCache.filter { validKeys.contains($0.key) }

            let activeSessions = trimmed.filter { $0.isActive }
            let anyActive = !activeSessions.isEmpty
            let anyWorking = activeSessions.contains { $0.isWorkingNow }
            let updatedCache = nextCache

            await MainActor.run {
                let mon = AntigravityAgentMonitor.shared
                mon.isRefreshing = false
                guard mon.isMonitoringEnabled else { return }
                mon.sessionCache = updatedCache
                mon.lastProcessCheckDate = processCheckDate
                mon.cachedRunningProcesses = runningProcesses

                AgentSpeechBubbleController.shared.announceTransitions(from: mon.sessions, to: trimmed)
                mon.updateCompletionPulse(from: mon.sessions, to: trimmed)
                if mon.sessions != trimmed { mon.sessions = trimmed }
                if mon.isActive != anyActive { mon.isActive = anyActive }
                if mon.isWorkingNow != anyWorking { mon.isWorkingNow = anyWorking }
                if mon.activeAgentCount != activeSessions.count { mon.activeAgentCount = activeSessions.count }
                mon.schedulePolling()

                // Auto-follow newest active session unless the user explicitly clicked a session
                if let currentSelected = mon.selectedSessionID,
                   !trimmed.contains(where: { $0.id == currentSelected }) {
                    mon.selectedSessionID = nil
                }
                if let currentSelected = mon.selectedSessionID,
                   mon.selectionPinnedUntil < Date(),
                   let live = activeSessions.first,
                   !activeSessions.contains(where: { $0.id == currentSelected }) {
                    // The selected session went quiet while another agent is live: follow the live one
                    mon.selectedSessionID = live.id
                }
                if mon.selectedSessionID == nil,
                   let nextSelected = activeSessions.first?.id ?? trimmed.first?.id {
                    mon.selectedSessionID = nextSelected
                }
                mon.syncSummaryProperties()
            }
        }
    }
}

// MARK: - Closed-Notch Gravity Agent Wing Live Activity

struct AgentCompactWaveform: View {
    let isWorking: Bool
    let color: Color
    let secondaryColor: Color

    var body: some View {
        Group {
            if isWorking {
                TimelineView(.periodic(from: .now, by: 0.34)) { context in
                    let tick = Int(context.date.timeIntervalSince1970 * 3)
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { index in
                            let height: CGFloat = [6, 11, 8, 13, 7, 10][(tick + index * 2) % 6]
                            Capsule()
                                .fill(index == 1 ? secondaryColor : color)
                                .frame(width: 2.2, height: height)
                                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: tick)
                        }
                    }
                    .frame(height: 14, alignment: .center)
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill((index == 1 ? secondaryColor : color).opacity(0.65))
                            .frame(width: 2.2, height: 4)
                    }
                }
                .frame(height: 14, alignment: .center)
            }
        }
    }
}

struct AgentClosedNotchView: View {
    @ObservedObject var monitor = AntigravityAgentMonitor.shared
    let closedHeight: CGFloat
    let centerSpacerWidth: CGFloat

    private var wingSpan: CGFloat {
        closedHeight > 0 ? max(18, closedHeight - 12) : 20
    }

    private var brandColor: Color {
        monitor.activeBrandColor
    }

    private var secondaryColor: Color {
        monitor.activeKind.secondaryAccentColor
    }

    var body: some View {
        let session = monitor.activeSession
        let phase = session?.phase ?? .thinking
        let working = session?.isWorkingNow ?? monitor.isWorkingNow
        let rawPct = max(0, min(100, monitor.contextPercentage))
        let ringFraction = min(working ? 0.80 : 1.0, max(working ? 0.28 : 0.16, rawPct / 100.0))
        let showCompletedCheck = !working && monitor.completedPulseSessionID != nil
        let rightBadgeSize = min(16.5, max(13.5, wingSpan - 3.5))

        HStack(spacing: 0) {
            AgentPixelMascot(
                kind: monitor.activeKind,
                isWorking: working,
                isActive: session?.isActive ?? monitor.isActive,
                pixel: 1.4
            )
            .frame(width: wingSpan, height: wingSpan, alignment: .center)

            Rectangle()
                .fill(.black)
                .frame(width: max(20, centerSpacerWidth))

            ZStack {
                if showCompletedCheck {
                    AgentCompletionCheckBadge(
                        size: rightBadgeSize,
                        initialFraction: ringFraction,
                        fromColor: brandColor,
                        pulseNonce: monitor.completedPulseNonce
                    )
                    .transition(.identity)
                } else {
                    AgentClosedRingView(
                        fraction: ringFraction,
                        color: brandColor,
                        secondaryColor: secondaryColor,
                        isWorking: working,
                        size: rightBadgeSize
                    )
                    .transition(.opacity.animation(.easeOut(duration: 0.20)))
                }
            }
            .frame(width: wingSpan, height: wingSpan, alignment: .center)
        }
        .frame(height: closedHeight > 0 ? closedHeight : wingSpan + 8, alignment: .center)
        .help(String(localized: "\(monitor.activeKind.rawValue) (\(phase.localizedTitle)) · \(Int(round(rawPct)))% - Click to inspect Agents"))
    }
}

private struct AgentClosedRingView: View {
    let fraction: Double
    let color: Color
    let secondaryColor: Color
    let isWorking: Bool
    let size: CGFloat

    @State private var rotationAngle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 1.9)

            Circle()
                .trim(from: 0, to: CGFloat(max(0.14, min(1.0, fraction))))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            color.opacity(0.45),
                            color,
                            secondaryColor
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
                )
                .rotationEffect(.degrees(-90 + (isWorking && !reduceMotion ? rotationAngle : 0)))
                .shadow(color: color.opacity(isWorking ? 0.48 : 0.18), radius: isWorking ? 2.5 : 1.0)

            if isWorking {
                // Distinct Gravity orbital node gliding along the ring while active
                Circle()
                    .fill(secondaryColor)
                    .frame(width: 2.8, height: 2.8)
                    .shadow(color: secondaryColor.opacity(0.9), radius: 2)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(reduceMotion ? 0 : rotationAngle))
            } else {
                // Calm Gravity core node when waiting/ready
                Circle()
                    .fill(color.opacity(0.85))
                    .frame(width: max(3.0, size * 0.22), height: max(3.0, size * 0.22))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            updateSpin(working: isWorking)
        }
        .onChange(of: isWorking) { _, working in
            updateSpin(working: working)
        }
    }

    private func updateSpin(working: Bool) {
        if working && !reduceMotion {
            rotationAngle = 0
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotationAngle = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                rotationAngle = 0
            }
        }
    }
}

private struct AgentCompletionCheckBadge: View {
    let size: CGFloat
    let initialFraction: Double
    let fromColor: Color
    let pulseNonce: UUID

    @State private var ringTrim: CGFloat = 0.30
    @State private var ringRotation: Double = -90
    @State private var isRingGreen: Bool = false
    @State private var rippleScale: CGFloat = 1.0
    @State private var rippleOpacity: Double = 0
    @State private var checkProgress: CGFloat = 0
    @State private var badgeScale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Apple Face ID neon mint-emerald on dark background
    private let faceIDMint = Color(red: 0.06, green: 0.92, blue: 0.67)

    var body: some View {
        let activeColor = isRingGreen ? faceIDMint : fromColor

        ZStack {
            Circle()
                .stroke(faceIDMint.opacity(0.50), lineWidth: 1.4)
                .scaleEffect(rippleScale)
                .opacity(rippleOpacity)

            Circle()
                .stroke(activeColor.opacity(0.16), lineWidth: max(1.7, size * 0.115))

            // Rotating hollow ring that spins and closes before the Face ID check draws
            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(
                    activeColor,
                    style: StrokeStyle(lineWidth: max(1.85, size * 0.125), lineCap: .round)
                )
                .rotationEffect(.degrees(ringRotation))
                .shadow(color: faceIDMint.opacity(isRingGreen ? 0.45 : 0.15), radius: isRingGreen ? 2.5 : 1.0)

            FaceIDCheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(
                    faceIDMint,
                    style: StrokeStyle(
                        lineWidth: max(1.9, size * 0.135),
                        lineCap: .square,
                        lineJoin: .miter
                    )
                )
                .shadow(color: faceIDMint.opacity(0.38), radius: 2)
        }
        .frame(width: size, height: size)
        .scaleEffect(badgeScale)
        .task(id: pulseNonce) {
            if reduceMotion {
                ringTrim = 1.0
                ringRotation = 270
                isRingGreen = true
                checkProgress = 1.0
                badgeScale = 1.0
                rippleOpacity = 0
                return
            }

            ringTrim = CGFloat(max(0.28, min(0.65, initialFraction)))
            ringRotation = -90
            isRingGreen = false
            rippleScale = 1.0
            rippleOpacity = 0
            checkProgress = 0
            badgeScale = 1.0

            // Phase 1: Spin and seal the hollow mint ring
            withAnimation(.timingCurve(0.35, 0.0, 0.20, 1.0, duration: 0.28)) {
                ringTrim = 1.0
                ringRotation = 270
                isRingGreen = true
            }

            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled else { return }

            // Phase 2: Outward ripple + Face ID checkmark strokes in
            rippleOpacity = 0.48
            withAnimation(.easeOut(duration: 0.38)) {
                rippleScale = 1.44
                rippleOpacity = 0
            }
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)) {
                checkProgress = 1.0
            }

            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled else { return }

            // Phase 3: Crisp tactile "tic" settle
            withAnimation(.spring(response: 0.17, dampingFraction: 0.52)) {
                badgeScale = 1.15
            }

            try? await Task.sleep(for: .milliseconds(105))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) {
                badgeScale = 1.0
            }
        }
    }
}

private struct FaceIDCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.28, y: h * 0.54))
        path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.70))
        path.addLine(to: CGPoint(x: w * 0.73, y: h * 0.35))
        return path
    }
}

struct AgentPulsingOrb: View {
    let color: Color
    let isWorking: Bool
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isWorking {
                Circle()
                    .fill(color.opacity(pulse ? 0.08 : 0.45))
                    .frame(width: size * (pulse ? 2.1 : 1.3), height: size * (pulse ? 2.1 : 1.3))
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(isWorking ? 0.85 : 0.35), radius: isWorking ? 4 : 1)
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .onAppear {
            if isWorking {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .onChange(of: isWorking) { _, working in
            if working {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    pulse = false
                }
            }
        }
    }
}

// MARK: - Expanded Notch Agent Hub (Gravity Agents Droplet)

struct AgentsNotchView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var monitor = AntigravityAgentMonitor.shared

    var body: some View {
        Group {
            if let session = monitor.activeSession {
                VStack(alignment: .leading, spacing: 8) {
                    if monitor.sessions.count > 1 {
                        AgentSessionSwitcherBar(
                            sessions: monitor.sessions,
                            selectedID: session.id,
                            activeCount: monitor.activeAgentCount,
                            onSelect: { monitor.selectSession($0) }
                        )
                        .frame(height: 20)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        AgentTimelineColumn(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .onHover { vm.isHoveringCalendar = $0 }
                            .onDisappear { vm.isHoveringCalendar = false }

                        AgentFocusColumn(session: session)
                            .frame(width: 240)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                AgentsEmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AgentSessionSwitcherBar: View {
    let sessions: [AgentSessionSnapshot]
    let selectedID: String
    let activeCount: Int
    let onSelect: (String) -> Void

    /// Sessions of one project all read "BoringNotch": their titles are what tells them apart
    private var labelsUseTitles: Bool { Set(sessions.map(\.projectName)).count == 1 }

    private func label(for session: AgentSessionSnapshot) -> String {
        if labelsUseTitles && !session.sessionTitle.isEmpty { return session.sessionTitle }
        return session.projectName
    }

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessions) { session in
                        let isSelected = session.id == selectedID
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                onSelect(session.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(session.isActive ? session.kind.accentColor : Color.white.opacity(0.25))
                                    .frame(width: 5, height: 5)
                                Text(label(for: session))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.42))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 130, alignment: .leading)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.white.opacity(isSelected ? 0.10 : 0)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if activeCount > 0 {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 0.36, green: 0.86, blue: 0.56))
                        .frame(width: 5, height: 5)
                    Text("\(activeCount) running")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize()
                }
            }
        }
    }
}

private struct AgentTimelineColumn: View {
    let session: AgentSessionSnapshot

    private var accent: Color { session.kind.accentColor }

    private var subtitle: String {
        session.sessionTitle.isEmpty ? session.projectName : "\(session.projectName) · \(session.sessionTitle)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentPixelMascot(
                    kind: session.kind,
                    isWorking: session.isWorkingNow,
                    isActive: session.isActive,
                    pixel: 2
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.kind.shortLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        if let model = session.modelName {
                            Text(model)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                    .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
            }

            if session.recentEvents.isEmpty {
                Text("Waiting for agent tool calls…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 2)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(session.recentEvents.enumerated()), id: \.element.id) { index, ev in
                            eventRow(ev, isCurrent: index == 0 && session.isWorkingNow)
                                .opacity(max(0.4, 1 - Double(index) * 0.14))
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.leading, 2)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: session.recentEvents.first?.id)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.78),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }

    private func eventRow(_ ev: AgentToolEvent, isCurrent: Bool) -> some View {
        let detail = ev.targetFile ?? (ev.summary != ev.toolName ? ev.summary : "")
        return HStack(spacing: 8) {
            AgentStepMarker(isCurrent: isCurrent, color: accent)
                .frame(width: 12)

            (Text(ev.toolName).foregroundColor(.white)
                + Text(detail.isEmpty ? "" : "  \(detail)").foregroundColor(.white.opacity(0.5)))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text(relativeAgeText(ev.timestamp))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func relativeAgeText(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h"
    }
}

private struct AgentFocusColumn: View {
    let session: AgentSessionSnapshot

    private var accent: Color { session.kind.accentColor }

    /// A deletion is shown until the agent edits a file again (the parsers clear it then)
    private var isDeletion: Bool { session.deletedName != nil }

    private var focusTitle: String { session.deletedName ?? session.currentFile ?? session.currentActionTitle }

    private var deletionRed: Color { Color(red: 0.98, green: 0.45, blue: 0.42) }

    private var statusLine: String {
        let detail = session.currentActionDetail
        if detail.isEmpty || detail == focusTitle || detail == session.currentActionTitle {
            return session.phase.localizedTitle
        }
        return detail
    }

    private var hasDiff: Bool { session.fileLinesAdded > 0 || session.fileLinesRemoved > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: isDeletion ? "trash.fill" : (session.currentFile != nil ? "doc.text.fill" : session.phase.iconName))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isDeletion ? deletionRed : accent)
                        .contentTransition(.symbolEffect(.replace))
                    Text(focusTitle)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isDeletion ? deletionRed : accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: focusTitle)
                    Spacer(minLength: 4)
                    if isDeletion {
                        Text(String(localized: "\(max(1, session.deletedCount)) deleted"))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(deletionRed)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: session.deletedCount)
                            .fixedSize()
                    } else if hasDiff {
                        HStack(spacing: 4) {
                            if session.fileLinesAdded > 0 || session.fileLinesRemoved == 0 {
                                Text("+\(session.fileLinesAdded)")
                                    .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.56))
                            }
                            if session.fileLinesRemoved > 0 {
                                Text("-\(session.fileLinesRemoved)")
                                    .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.42))
                            }
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: session.fileLinesAdded)
                        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: session.fileLinesRemoved)
                        .fixedSize()
                    }
                }

                HStack(spacing: 5) {
                    if session.isWorkingNow {
                        AgentCompactWaveform(isWorking: true, color: accent, secondaryColor: session.kind.secondaryAccentColor)
                    } else {
                        Circle()
                            .fill(session.isActive ? session.phase.color : Color.gray)
                            .frame(width: 5, height: 5)
                    }
                    Text(statusLine)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                ZStack {
                    if isDeletion {
                        // All red: what was removed, sized like an edit of ~30 lines per deleted item
                        AgentDiffBar(
                            added: 0,
                            removed: min(150, 30 * max(1, session.deletedCount)),
                            editSerial: session.deletionSerial,
                            color: accent
                        )
                        .id("deletion-\(session.id)")
                        .transition(.opacity)
                    } else if hasDiff {
                        AgentDiffBar(
                            added: session.fileLinesAdded,
                            removed: session.fileLinesRemoved,
                            editSerial: session.editSerial,
                            color: session.kind == .antigravity
                                ? Color(red: 0.36, green: 0.86, blue: 0.56)
                                : accent
                        )
                        // Antigravity keeps one continuous morphing bar across edits and file switches;
                        // Claude Code preserves its original per-file bar identity.
                        .id(session.kind == .antigravity ? session.id : (session.currentFile ?? session.id))
                        .transition(.opacity)
                    } else if session.isWorkingNow {
                        AgentActivityBar(color: accent)
                            .transition(.opacity)
                    } else {
                        Capsule().fill(Color.white.opacity(0.10))
                    }
                }
                .frame(height: 3)
                .clipShape(Capsule())
                .padding(.top, 1)
                .animation(.easeInOut(duration: 0.25), value: hasDiff)
                .animation(.easeInOut(duration: 0.25), value: isDeletion)
                .animation(.easeInOut(duration: 0.25), value: session.isWorkingNow)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )

            HStack(alignment: .top, spacing: 0) {
                stat(
                    String(localized: "Context"),
                    String(format: "%.0f%%", session.contextPercentage),
                    color: session.contextPercentage > 80 ? .orange : .white
                )
                stat(String(localized: "Cache"), String(format: "%.0f%%", session.cacheHitPercentage), color: .white)
                stat(String(localized: "Out"), session.formattedOutputTokens, color: .white)
            }
            .padding(.horizontal, 4)
        }
    }

    private func stat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(color.opacity(0.9))
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The current file's diff as a bar that grows with every edit: its length follows the lines changed (easing
/// toward full width, so a big rewrite never overflows), the accent part is what was added, the red part what
/// was removed. It starts empty and springs to each new length, then flashes, so edits read live.
private struct AgentDiffBar: View {
    let added: Int
    let removed: Int
    let editSerial: Int
    let color: Color

    private struct TargetMetrics: Equatable {
        let fill: CGFloat
        let addedShare: CGFloat
        let gap: CGFloat
    }

    @State private var shownFill: CGFloat = 0
    @State private var shownAddedShare: CGFloat = 1
    @State private var shownGap: CGFloat = 0
    @State private var flashOpacity: Double = 0
    @State private var flashTask: Task<Void, Never>?

    /// ~30 lines fill 40%, ~60 lines 63%, ~150 lines 92%
    private var targetMetrics: TargetMetrics {
        let total = CGFloat(added + removed)
        let fill: CGFloat = total > 0 ? max(0.04, 1 - exp(-total / 60)) : 0
        let share: CGFloat = total > 0 ? CGFloat(added) / total : 1
        let gap: CGFloat = (added > 0 && removed > 0) ? 2 : 0
        return TargetMetrics(fill: fill, addedShare: share, gap: gap)
    }

    private static let growth = Animation.spring(response: 0.52, dampingFraction: 0.88)

    var body: some View {
        GeometryReader { geo in
            let filled = max(0, geo.size.width * shownFill)
            let activeGap = filled > 8 ? shownGap : 0
            let usable = max(0, filled - activeGap)
            let greenWidth = usable * shownAddedShare
            let redWidth = usable * (1 - shownAddedShare)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(color)
                    .frame(width: greenWidth)
                    .opacity(greenWidth > 0.01 ? 1 : 0)
                Capsule()
                    .fill(Color(red: 0.98, green: 0.45, blue: 0.42))
                    .frame(width: redWidth)
                    .offset(x: greenWidth + activeGap)
                    .opacity(redWidth > 0.01 ? 1 : 0)
                Capsule()
                    .fill(Color.white)
                    .frame(width: filled)
                    .opacity(flashOpacity)
            }
        }
        .onAppear {
            let metrics = targetMetrics
            shownAddedShare = metrics.addedShare
            shownGap = metrics.gap
            withAnimation(Self.growth) {
                shownFill = metrics.fill
            }
        }
        .onChange(of: targetMetrics) { _, metrics in
            withAnimation(Self.growth) {
                shownFill = metrics.fill
                shownAddedShare = metrics.addedShare
                shownGap = metrics.gap
            }
        }
        .onChange(of: editSerial) { _, _ in
            flashTask?.cancel()
            withAnimation(.easeOut(duration: 0.12)) {
                flashOpacity = 0.34
            }
            flashTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(130))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.50)) {
                    flashOpacity = 0
                }
            }
        }
        .onDisappear {
            flashTask?.cancel()
            flashTask = nil
        }
    }
}

private struct AgentsEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text("No Coding Agents Running")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Claude Code, Antigravity & Codex sessions appear here live")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lock Screen Music Player Panel via SkyLightWindow (Gravity Lock Screen Music UI)

@MainActor
final class LockScreenMediaPanelManager: ObservableObject {
    static let shared = LockScreenMediaPanelManager()

    private var panelWindow: BoringNotchSkyLightWindow?
    private var panelScreen: NSScreen?
    private var wallpaperTransitionID: Int = 0
    private var isLockScreenActive: Bool = false
    private var lockScreenMediaObserver: AnyCancellable?
    @Published private(set) var isPreviewVisible: Bool = false
    /// The animated artwork fills the whole screen behind the player. Only ever true for tracks that have one.
    @Published private(set) var isWallpaperMode: Bool = false
    /// Motion artwork of the current track, nil when it only has a still cover.
    @Published private(set) var animatedArtworkURL: URL?
    /// Video shown by the wallpaper (kept briefly across track changes so the wallpaper does not flash).
    @Published private(set) var wallpaperVideoURL: URL?
    private var wallpaperWanted: Bool = false
    /// The panel window currently covers the whole screen (stays true while the wallpaper fades out).
    @Published private(set) var isWindowExpanded: Bool = false
    @Published private(set) var cardBottomInset: CGFloat = 0
    @Published private(set) var cardHorizontalOffset: CGFloat = 0
    /// Skipping tracks quickly makes the player report no media for a split second. Closing and
    /// recreating the SkyLight window on each of those blips left the notch in an inconsistent state.
    private var pendingDismissTask: Task<Void, Never>?
    private var positionObserver: AnyCancellable?
    private var styleObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?
    private var screensSleepObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    /// Full screen lyrics layout (player on the left, lyrics on the right) instead of the compact card
    @Published private(set) var isLyricsLayout: Bool = false
    private var isPresentedOnSkyLight: Bool = false

    private init() {
        positionObserver = Defaults.publisher(keys: .lockScreenMediaHorizontalPosition, .lockScreenMediaVerticalPosition)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyPanelPosition()
                }
            }
        styleObserver = Defaults.publisher(.lockScreenPlayerStyle, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panelWindow?.isVisible == true else { return }
                    self.presentPanel(delegateToSkyLight: self.isPresentedOnSkyLight)
                }
            }
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChanged()
            }
        }
        screensSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLockScreenActive, !self.isPreviewVisible else { return }
                // Tear down the lock screen video & high-rate timelines while the display is off
                self.dismissPanelWindow()
            }
        }
        screensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLockScreenActive, !self.isPreviewVisible,
                      Defaults[.showOnLockScreen], Defaults[.lockScreenMediaPlayer],
                      Self.hasActiveMedia(), self.panelWindow?.isVisible != true else { return }
                self.presentPanel(delegateToSkyLight: true)
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screen(withUUID: BoringViewCoordinator.shared.selectedScreenUUID)
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func handleScreenParametersChanged() {
        guard let window = panelWindow, window.isVisible else { return }
        guard let screen = targetScreen() else {
            dismissPanelWindow()
            return
        }
        panelScreen = screen
        if isWindowExpanded || isLyricsLayout {
            updateExpandedCardPlacement(on: screen)
            window.setFrame(screen.frame, display: true)
        } else {
            window.setFrame(compactFrame(on: screen), display: true)
        }
        keepNotchAbovePanel()
    }

    /// Both settings go from 0 to 1 across the whole area the player can occupy on the screen.
    private func compactFrame(on screen: NSScreen) -> NSRect {
        let envelopeWidth: CGFloat = 436
        let envelopeHeight: CGFloat = 390
        let sideMargin: CGFloat = 20
        let bottomMargin: CGFloat = 20
        let topMargin: CGFloat = 40
        let horizontal = min(max(Defaults[.lockScreenMediaHorizontalPosition], 0), 1)
        let vertical = min(max(Defaults[.lockScreenMediaVerticalPosition], 0), 1)
        let horizontalRange = max(0, screen.frame.width - envelopeWidth - 2 * sideMargin)
        let verticalRange = max(0, screen.frame.height - envelopeHeight - bottomMargin - topMargin)
        let originX = screen.frame.minX + sideMargin + horizontalRange * horizontal
        let originY = screen.frame.minY + bottomMargin + verticalRange * vertical
        return NSRect(x: originX, y: originY, width: envelopeWidth, height: envelopeHeight)
    }

    private func updateExpandedCardPlacement(on screen: NSScreen) {
        let frame = compactFrame(on: screen)
        cardBottomInset = frame.minY - screen.frame.minY
        cardHorizontalOffset = frame.midX - screen.frame.midX
    }

    private func applyPanelPosition() {
        guard let window = panelWindow, window.isVisible, let screen = targetScreen() ?? panelScreen else { return }
        panelScreen = screen
        if isWindowExpanded || isLyricsLayout {
            updateExpandedCardPlacement(on: screen)
        } else {
            window.setFrame(compactFrame(on: screen), display: true)
        }
    }

    func toggleWallpaperMode() {
        guard !isLyricsLayout, isWallpaperMode || animatedArtworkURL != nil else { return }
        wallpaperWanted = !isWallpaperMode
        if wallpaperWanted {
            enterWallpaperMode()
        } else {
            exitWallpaperMode()
        }
    }

    /// Called whenever the current track gains or loses an animated artwork.
    func setAnimatedArtwork(_ url: URL?) {
        animatedArtworkURL = url
        wallpaperTransitionID += 1
        let transitionID = wallpaperTransitionID
        if let url {
            wallpaperVideoURL = url
            if wallpaperWanted { enterWallpaperMode() }
        } else if isWallpaperMode {
            // Short grace period: the next track may share the same animated cover
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.wallpaperTransitionID == transitionID, self.animatedArtworkURL == nil else { return }
                self.exitWallpaperMode()
            }
        }
    }

    private func enterWallpaperMode() {
        // The lyrics layout already fills the screen and draws the animated artwork itself
        guard !isLyricsLayout, !isWallpaperMode, let window = panelWindow, let screen = targetScreen() ?? panelScreen else { return }
        panelScreen = screen
        wallpaperTransitionID += 1
        updateExpandedCardPlacement(on: screen)
        isWindowExpanded = true
        window.setFrame(screen.frame, display: true)
        keepNotchAbovePanel()
        withAnimation(.easeInOut(duration: 0.45)) {
            isWallpaperMode = true
        }
    }

    private func exitWallpaperMode() {
        guard isWallpaperMode, let window = panelWindow else { return }
        wallpaperTransitionID += 1
        let transitionID = wallpaperTransitionID
        withAnimation(.easeInOut(duration: 0.35)) {
            isWallpaperMode = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.wallpaperTransitionID == transitionID, !self.isWallpaperMode else { return }
            self.isWindowExpanded = false
            if let screen = self.targetScreen() ?? self.panelScreen {
                self.panelScreen = screen
                window.setFrame(self.compactFrame(on: screen), display: true)
            }
        }
    }

    private func resetWallpaperMode() {
        wallpaperTransitionID += 1
        isWallpaperMode = false
        isWindowExpanded = false
        animatedArtworkURL = nil
        wallpaperVideoURL = nil
    }

    private static let desktopPlayerBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.github.th-ch.youtube-music"
    ]

    static func hasActiveMedia(_ music: MusicManager? = nil) -> Bool {
        let music = music ?? MusicManager.shared
        if music.isPlaying { return true }

        let title = music.songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "I'm Handsome" || title == "Not Playing" || title == "Unknown" {
            return false
        }
        if music.songDuration <= 0 {
            return false
        }
        if let bundleID = music.bundleIdentifier,
           desktopPlayerBundleIDs.contains(bundleID),
           !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            return false
        }
        return true
    }

    func showOnLockScreen() {
        isPreviewVisible = false
        isLockScreenActive = true
        guard Defaults[.showOnLockScreen], Defaults[.lockScreenMediaPlayer] else { return }
        startObservingMediaForLockScreen()
        guard Self.hasActiveMedia() else {
            dismissPanelWindow()
            return
        }
        presentPanel(delegateToSkyLight: true)
    }

    func hideFromLockScreen() {
        isPreviewVisible = false
        isLockScreenActive = false
        lockScreenMediaObserver?.cancel()
        lockScreenMediaObserver = nil
        dismissPanelWindow()
    }

    private func dismissPanelWindow() {
        pendingDismissTask?.cancel()
        pendingDismissTask = nil
        resetWallpaperMode()
        isLyricsLayout = false
        guard let window = panelWindow else { return }
        window.disableSkyLight()
        window.orderOut(nil)
        // Drop the SwiftUI tree so a looping artwork video stops playing while hidden
        window.contentView = nil
    }

    private func startObservingMediaForLockScreen() {
        lockScreenMediaObserver?.cancel()
        let music = MusicManager.shared
        lockScreenMediaObserver = Publishers.CombineLatest4(
            music.$isPlaying,
            music.$songTitle,
            music.$songDuration,
            music.$bundleIdentifier
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            guard let self, self.isLockScreenActive, !self.isPreviewVisible else { return }
            guard Defaults[.showOnLockScreen], Defaults[.lockScreenMediaPlayer] else {
                self.dismissPanelWindow()
                return
            }
            if Self.hasActiveMedia() {
                self.pendingDismissTask?.cancel()
                self.pendingDismissTask = nil
                if self.panelWindow?.isVisible != true {
                    self.presentPanel(delegateToSkyLight: true)
                }
            } else if self.panelWindow?.isVisible == true, self.pendingDismissTask == nil {
                self.pendingDismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    self.pendingDismissTask = nil
                    guard self.isLockScreenActive, !self.isPreviewVisible, !Self.hasActiveMedia() else { return }
                    self.dismissPanelWindow()
                }
            }
        }
    }

    func togglePreviewOnDesktop() {
        if isPreviewVisible {
            hideFromLockScreen()
        } else {
            isLockScreenActive = false
            lockScreenMediaObserver?.cancel()
            lockScreenMediaObserver = nil
            isPreviewVisible = true
            presentPanel(delegateToSkyLight: false)
        }
    }

    private func presentPanel(delegateToSkyLight: Bool) {
        guard let screen = targetScreen() else { return }
        pendingDismissTask?.cancel()
        pendingDismissTask = nil
        resetWallpaperMode()
        let lyricsLayout = Defaults[.lockScreenPlayerStyle] == .lyrics
        isLyricsLayout = lyricsLayout
        isPresentedOnSkyLight = delegateToSkyLight
        // On every lock the wallpaper comes back by itself as soon as a track has an animated artwork;
        // tapping it away only lasts until the next lock
        wallpaperWanted = delegateToSkyLight && !lyricsLayout
        panelScreen = screen
        let frame: NSRect
        if lyricsLayout {
            // Without lyrics the layout falls back to the compact card, placed where the sliders say
            updateExpandedCardPlacement(on: screen)
            isWindowExpanded = true
            frame = screen.frame
        } else {
            frame = compactFrame(on: screen)
        }

        if Self.hasActiveMedia()
            && MusicManager.shared.currentLyrics.isEmpty
            && MusicManager.shared.syncedLyrics.isEmpty
            && !MusicManager.shared.isFetchingLyrics {
            MusicManager.shared.refreshLyrics()
        }

        let window: BoringNotchSkyLightWindow
        if let existing = panelWindow {
            window = existing
        } else {
            window = BoringNotchSkyLightWindow(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            panelWindow = window
        }

        window.setFrame(frame, display: true)
        let rootView = LockScreenPanelRootView(
            onClosePreview: delegateToSkyLight ? nil : { [weak self] in
                self?.hideFromLockScreen()
            }
        )
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        if delegateToSkyLight {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }
        window.orderFrontRegardless()
        keepNotchAbovePanel()
    }

    /// The panel and the notch windows share the same window class and level, so the panel (shown last)
    /// used to cover the notch. Once the animated artwork fills the screen, volume and brightness HUDs
    /// became invisible on the lock screen. Keep the panel one level below and re-raise the notch.
    private func keepNotchAbovePanel() {
        guard let panelWindow else { return }
        panelWindow.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        for notchWindow in NotchSpaceManager.shared.notchSpace.windows where notchWindow !== panelWindow {
            notchWindow.orderFrontRegardless()
        }
    }
}

struct LockScreenMediaPanelView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.lockScreenShowLyrics) private var lockScreenShowLyrics
    @State private var isArtworkExpanded: Bool = false
    @State private var showAudioDrawer: Bool = false
    @State private var showRemainingTime: Bool = true
    var onClosePreview: (() -> Void)? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !musicManager.isPlaying)) { context in
            LockScreenMediaCardContainer(
                currentDate: context.date,
                showLyricsCard: lockScreenShowLyrics,
                onToggleLyrics: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        lockScreenShowLyrics.toggle()
                    }
                    if LockScreenMediaPanelManager.hasActiveMedia(musicManager)
                        && musicManager.currentLyrics.isEmpty
                        && musicManager.syncedLyrics.isEmpty {
                        musicManager.refreshLyrics()
                    }
                },
                isArtworkExpanded: $isArtworkExpanded,
                showAudioDrawer: $showAudioDrawer,
                showRemainingTime: $showRemainingTime,
                onClosePreview: onClosePreview
            )
        }
        .frame(width: 436, height: 390, alignment: Alignment(horizontal: .center, vertical: .lockScreenTransportControls))
        .onAppear {
            if LockScreenMediaPanelManager.hasActiveMedia(musicManager)
                && musicManager.currentLyrics.isEmpty
                && musicManager.syncedLyrics.isEmpty
                && !musicManager.isFetchingLyrics {
                musicManager.refreshLyrics()
            }
        }
    }
}

/// Pins the transport row at a fixed height in the panel envelope, so the card grows or shrinks around it
/// (lyrics card above, audio drawer below) and the buttons stay under the cursor when skipping tracks.
/// 115 pt leaves room below for the open audio drawer; the tallest stack above (expanded artwork + lyrics)
/// still fits in the remaining 275 pt.
private extension VerticalAlignment {
    enum LockScreenTransportControls: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context.height - 115
        }
    }

    static let lockScreenTransportControls = VerticalAlignment(LockScreenTransportControls.self)
}

private struct LockScreenMediaCardContainer: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject private var panelManager = LockScreenMediaPanelManager.shared
    @Default(.lockScreenMediaAmbientGlow) private var ambientGlowEnabled
    @Default(.lockScreenHideMissingLyrics) private var hideMissingLyrics
    /// Outcome of the last finished lookup. While the next track's lyrics load, the card keeps that
    /// state instead of opening on "Loading" and closing again when nothing is found.
    @State private var lastLookupFoundLyrics = false

    let currentDate: Date
    let showLyricsCard: Bool
    let onToggleLyrics: () -> Void
    @Binding var isArtworkExpanded: Bool
    @Binding var showAudioDrawer: Bool
    @Binding var showRemainingTime: Bool
    let onClosePreview: (() -> Void)?

    private var hasMediaTrack: Bool {
        LockScreenMediaPanelManager.hasActiveMedia(musicManager)
    }

    /// Only synced lyrics count: text alone cannot follow the song, so the lyrics stay closed
    private var lyricsFound: Bool {
        !musicManager.syncedLyrics.isEmpty
    }

    private var showsLyricsCard: Bool {
        guard hasMediaTrack && showLyricsCard else { return false }
        guard hideMissingLyrics else { return true }
        return musicManager.isFetchingLyrics ? lastLookupFoundLyrics : lyricsFound
    }

    private var albumAccent: Color {
        Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.65)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)

            if ambientGlowEnabled && hasMediaTrack {
                Circle()
                    .fill(albumAccent.opacity(musicManager.isPlaying ? 0.30 : 0.14))
                    .frame(width: 300, height: 180)
                    .blur(radius: 52)
                    .animation(.easeInOut(duration: 0.6), value: musicManager.isPlaying)
            }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(panelManager.isWallpaperMode ? 0 : 1)
    }

    var body: some View {
        let elapsed = musicManager.estimatedPlaybackPosition(at: currentDate)

        VStack(spacing: 10) {
            LockScreenArtworkHeader(
                hasMediaTrack: hasMediaTrack,
                albumAccent: albumAccent,
                showLyricsCard: showLyricsCard,
                onToggleLyrics: onToggleLyrics,
                isArtworkExpanded: $isArtworkExpanded,
                onExpandCollapseDrawer: {
                    if $0 { showAudioDrawer = false }
                },
                onClosePreview: onClosePreview
            )

            if showsLyricsCard {
                LockScreenSyncedLyricsCard(
                    elapsed: elapsed,
                    duration: musicManager.songDuration,
                    albumAccent: albumAccent
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if hasMediaTrack {
                LockScreenScrubBar(
                    elapsed: elapsed,
                    duration: musicManager.songDuration,
                    accentColor: albumAccent,
                    showRemainingTime: $showRemainingTime
                )
            }

            LockScreenTransportControls(
                hasMediaTrack: hasMediaTrack,
                albumAccent: albumAccent,
                showAudioDrawer: $showAudioDrawer,
                onOpenAudioDrawer: {
                    if $0 { isArtworkExpanded = false }
                }
            )
            .alignmentGuide(.lockScreenTransportControls) { $0[.bottom] }

            if showAudioDrawer {
                LockScreenAudioDrawer(accentColor: albumAccent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 396)
        .background(cardBackground)
        .shadow(
            color: panelManager.isWallpaperMode
                ? .clear
                : ((ambientGlowEnabled && musicManager.isPlaying && hasMediaTrack)
                    ? albumAccent.opacity(0.18)
                    : .black.opacity(0.32)),
            radius: 18,
            y: 8
        )
        .shadow(color: panelManager.isWallpaperMode ? .clear : .black.opacity(0.34), radius: 12, y: 6)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: showsLyricsCard)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: isArtworkExpanded)
        .onChange(of: "\(musicManager.isFetchingLyrics)|\(lyricsFound)", initial: true) {
            if !musicManager.isFetchingLyrics {
                lastLookupFoundLyrics = lyricsFound
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showAudioDrawer)
    }
}

private struct LockScreenArtworkHeader: View {
    @ObservedObject var musicManager = MusicManager.shared
    let hasMediaTrack: Bool
    let albumAccent: Color
    let showLyricsCard: Bool
    let onToggleLyrics: () -> Void
    @Binding var isArtworkExpanded: Bool
    var onExpandCollapseDrawer: (Bool) -> Void
    var onClosePreview: (() -> Void)?

    var body: some View {
        VStack(spacing: isArtworkExpanded ? 10 : 0) {
            if isArtworkExpanded && hasMediaTrack {
                HStack(alignment: .top, spacing: 14) {
                    artworkView(size: 86, radius: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(musicManager.songTitle)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            topRightUtilityCluster
                        }

                        Text(musicManager.artistName.isEmpty ? String(localized: "Music") : musicManager.artistName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)

                        if !musicManager.album.isEmpty {
                            Text(musicManager.album)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.50))
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    if hasMediaTrack {
                        artworkView(size: 50, radius: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.09))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasMediaTrack ? musicManager.songTitle : String(localized: "Nothing Playing"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(hasMediaTrack ? (musicManager.artistName.isEmpty ? "Apple Music" : musicManager.artistName) : String(localized: "Press Play to start listening"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(hasMediaTrack ? .white.opacity(0.65) : .white.opacity(0.48))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    topRightUtilityCluster
                }
            }
        }
    }

    private func artworkView(size: CGFloat, radius: CGFloat) -> some View {
        Button {
            let manager = LockScreenMediaPanelManager.shared
            if manager.isWallpaperMode || manager.animatedArtworkURL != nil {
                manager.toggleWallpaperMode()
            } else {
                // Still cover: it would look poor stretched full screen, so enlarge it inside the player instead
                isArtworkExpanded.toggle()
                onExpandCollapseDrawer(isArtworkExpanded)
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.35), radius: musicManager.isPlaying ? 6 : 3, y: 2)

                if let bundleID = musicManager.bundleIdentifier, !musicManager.usingAppIconForArtwork {
                    AppIcon(for: bundleID)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size > 75 ? 20 : 15, height: size > 75 ? 20 : 15)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 2.5)
                        .offset(x: 2.5, y: 2.5)
                }
            }
            .scaleEffect(musicManager.isPlaying ? 1.0 : 0.90)
            .opacity(musicManager.isPlaying ? 1.0 : 0.82)
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: musicManager.isPlaying)
        }
        .buttonStyle(.plain)
        .help("Toggle large artwork")
    }

    private var topRightUtilityCluster: some View {
        HStack(spacing: 6) {
            if hasMediaTrack {
                Rectangle()
                    .fill(albumAccent.gradient)
                    .frame(width: 16, height: 12)
                    .mask {
                        AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                            .frame(width: 14, height: 11)
                    }
                    .opacity(musicManager.isPlaying ? 0.9 : 0.38)

                Button(action: onToggleLyrics) {
                    Image(systemName: showLyricsCard ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(showLyricsCard ? .white : .white.opacity(0.55))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(showLyricsCard ? 0.22 : 0.08)))
                }
                .buttonStyle(.plain)
                .help("Synced lyrics")
            }

            if let onClosePreview {
                Button(action: onClosePreview) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Close preview")
            }
        }
    }
}

private struct LockScreenSyncedLyricsCard: View {
    @ObservedObject var musicManager = MusicManager.shared
    let elapsed: Double
    let duration: Double
    let albumAccent: Color

    @State private var hoveredLine: Int? = nil

    private struct LyricDisplayTriple: Equatable {
        let prevText: String?
        let prevTime: Double?
        let currText: String
        let nextText: String?
        let nextTime: Double?
    }

    private func computeTriple() -> LyricDisplayTriple {
        if musicManager.isFetchingLyrics {
            return LyricDisplayTriple(prevText: nil, prevTime: nil, currText: String(localized: "Loading lyrics…"), nextText: nil, nextTime: nil)
        }
        if !musicManager.syncedLyrics.isEmpty {
            let synced = musicManager.syncedLyrics
            var low = 0
            var high = synced.count - 1
            var idx = 0
            while low <= high {
                let mid = (low + high) / 2
                if synced[mid].time <= elapsed {
                    idx = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            let prev = idx > 0 ? synced[idx - 1] : nil
            let curr = synced[idx]
            let next = (idx + 1) < synced.count ? synced[idx + 1] : nil
            return LyricDisplayTriple(
                prevText: prev?.text,
                prevTime: prev?.time,
                currText: curr.text,
                nextText: next?.text,
                nextTime: next?.time
            )
        }

        let plainLines = musicManager.currentLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !plainLines.isEmpty else {
            return LyricDisplayTriple(prevText: nil, prevTime: nil, currText: String(localized: "♪ Instrumental / No lyrics found"), nextText: nil, nextTime: nil)
        }
        let ratio = duration > 0 ? min(0.999, max(0, elapsed / duration)) : 0
        let idx = min(plainLines.count - 1, max(0, Int(Double(plainLines.count) * ratio)))
        let prev = idx > 0 ? plainLines[idx - 1] : nil
        let curr = plainLines[idx]
        let next = (idx + 1) < plainLines.count ? plainLines[idx + 1] : nil
        return LyricDisplayTriple(prevText: prev, prevTime: nil, currText: curr, nextText: next, nextTime: nil)
    }

    var body: some View {
        let triple = computeTriple()

        // A long current line wraps on two lines: drop the previous line so the card keeps its fixed size.
        VStack(spacing: 3) {
            if triple.currText.count <= 34, let prev = triple.prevText, !prev.isEmpty {
                lyricRow(text: prev, seekTime: triple.prevTime, slot: 0, isCurrent: false, baseOpacity: 0.35)
            }
            lyricRow(text: triple.currText, seekTime: nil, slot: 1, isCurrent: true, baseOpacity: 1.0)
                .id(triple.currText)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .layoutPriority(1)
            if let next = triple.nextText, !next.isEmpty {
                lyricRow(text: next, seekTime: triple.nextTime, slot: 2, isCurrent: false, baseOpacity: 0.45)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .clipped()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )
        )
        .animation(.easeInOut(duration: 0.22), value: triple.currText)
    }

    @ViewBuilder
    private func lyricRow(text: String, seekTime: Double?, slot: Int, isCurrent: Bool, baseOpacity: Double) -> some View {
        let isRTL = text.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
        let hovered = hoveredLine == slot && seekTime != nil
        let font = isRTL
            ? Font.custom("Vazirmatn-Regular", size: isCurrent ? 13.5 : 11)
            : Font.system(size: isCurrent ? 13.5 : 11, weight: isCurrent ? .bold : .medium, design: .rounded)

        Text(text)
            .font(font)
            .foregroundStyle(isCurrent ? Color.white : (hovered ? albumAccent : Color.white.opacity(baseOpacity)))
            .multilineTextAlignment(.center)
            .lineLimit(isCurrent ? 2 : 1)
            .minimumScaleFactor(isCurrent ? 0.75 : 0.85)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .shadow(color: isCurrent ? .white.opacity(0.25) : .clear, radius: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if seekTime != nil {
                    hoveredLine = inside ? slot : (hoveredLine == slot ? nil : hoveredLine)
                }
            }
            .onTapGesture {
                if let seekTime {
                    musicManager.seek(to: seekTime)
                }
            }
    }
}

private struct LockScreenScrubBar: View {
    @ObservedObject var musicManager = MusicManager.shared
    let elapsed: Double
    let duration: Double
    let accentColor: Color
    @Binding var showRemainingTime: Bool

    @State private var isDragging: Bool = false
    @State private var isHovering: Bool = false
    @State private var dragProgress: Double = 0
    @State private var optimisticTarget: Double? = nil
    @State private var lastSeekDate: Date = .distantPast

    private var effectiveProgress: Double {
        guard duration > 0 else { return 0 }
        if isDragging { return dragProgress }
        if let optimisticTarget, Date().timeIntervalSince(lastSeekDate) < 0.75 {
            return min(1, max(0, optimisticTarget / duration))
        }
        return min(1, max(0, elapsed / duration))
    }

    private var displayedElapsed: Double {
        guard duration > 0 else { return 0 }
        return effectiveProgress * duration
    }

    var body: some View {
        let activeHeight: CGFloat = (isDragging || isHovering) ? 7 : 5

        HStack(spacing: 8) {
            Text(formatTime(displayedElapsed))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(isDragging ? 0.95 : 0.65))
                .frame(width: 34, alignment: .leading)
                .contentTransition(.numericText())

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let filled = max(4, width * CGFloat(effectiveProgress))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: activeHeight)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: min(width, filled), height: activeHeight)
                        .shadow(color: isDragging ? accentColor.opacity(0.45) : .clear, radius: 5)
                }
                .frame(height: 14, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragProgress = min(1, max(0, Double(value.location.x / width)))
                        }
                        .onEnded { value in
                            let finalRatio = min(1, max(0, Double(value.location.x / width)))
                            let target = finalRatio * max(0, duration)
                            optimisticTarget = target
                            lastSeekDate = Date()
                            isDragging = false
                            musicManager.seek(to: target)
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isDragging)

            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    showRemainingTime.toggle()
                }
            } label: {
                let rightText = showRemainingTime && duration > 0
                    ? "-\(formatTime(max(0, duration - displayedElapsed)))"
                    : formatTime(duration)
                Text(rightText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 38, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .help("Click to toggle remaining / total time")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct LockScreenTransportControls: View {
    @ObservedObject var musicManager = MusicManager.shared
    let hasMediaTrack: Bool
    let albumAccent: Color
    @Binding var showAudioDrawer: Bool
    var onOpenAudioDrawer: (Bool) -> Void

    @State private var playPressed: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Left secondary cluster: Favorite + Shuffle
            HStack(spacing: 12) {
                Button {
                    musicManager.toggleFavoriteTrack()
                } label: {
                    Image(systemName: musicManager.isFavoriteTrack ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(musicManager.isFavoriteTrack ? Color.pink : Color.white.opacity(musicManager.canFavoriteTrack ? 0.58 : 0.22))
                }
                .buttonStyle(.plain)
                .disabled(!musicManager.canFavoriteTrack || !hasMediaTrack)

                Button {
                    musicManager.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(musicManager.isShuffled ? albumAccent : .white.opacity(hasMediaTrack ? 0.58 : 0.25))
                }
                .buttonStyle(.plain)
                .disabled(!hasMediaTrack)
            }

            Spacer(minLength: 0)

            // Center classic naked luminous white transport controls
            HStack(spacing: 32) {
                Button {
                    musicManager.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(hasMediaTrack ? 0.95 : 0.45))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.20, dampingFraction: 0.65)) {
                        playPressed = true
                    }
                    musicManager.togglePlay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.75)) {
                            playPressed = false
                        }
                    }
                } label: {
                    Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .scaleEffect(playPressed ? 0.88 : 1.0)
                }
                .buttonStyle(.plain)

                Button {
                    musicManager.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(hasMediaTrack ? 0.95 : 0.45))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            // Right secondary cluster: Repeat + Inline Audio/Volume Drawer
            HStack(spacing: 12) {
                Button {
                    musicManager.toggleRepeat()
                } label: {
                    Image(systemName: musicManager.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(musicManager.repeatMode != .off ? albumAccent : .white.opacity(hasMediaTrack ? 0.58 : 0.25))
                }
                .buttonStyle(.plain)
                .disabled(!hasMediaTrack)

                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        showAudioDrawer.toggle()
                        onOpenAudioDrawer(showAudioDrawer)
                    }
                } label: {
                    Image(systemName: showAudioDrawer ? "airplayaudio.circle.fill" : "airplayaudio")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(showAudioDrawer ? albumAccent : .white.opacity(0.62))
                }
                .buttonStyle(.plain)
                .help("Volume & Audio Output")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct LockScreenAudioDrawer: View {
    @ObservedObject var volumeManager = VolumeManager.shared
    let accentColor: Color

    @State private var devices: [AudioOutputRoutingMenu.OutputDevice] = []
    @State private var localVolume: Float? = nil

    private var effectiveVolume: Float {
        localVolume ?? (volumeManager.isMuted ? 0 : volumeManager.rawVolume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inline CoreAudio System Volume Slider
            HStack(spacing: 8) {
                Button {
                    volumeManager.toggleMuteAction()
                } label: {
                    Image(systemName: effectiveVolume <= 0.01 ? "speaker.slash.fill" : (effectiveVolume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)

                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .frame(height: 5)
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: max(5, w * CGFloat(effectiveVolume)), height: 5)
                    }
                    .frame(height: 14, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let ratio = Float(min(1, max(0, value.location.x / w)))
                                localVolume = ratio
                                volumeManager.setAbsolute(ratio)
                            }
                            .onEnded { value in
                                let ratio = Float(min(1, max(0, value.location.x / w)))
                                volumeManager.setAbsolute(ratio)
                                localVolume = nil
                            }
                    )
                }
                .frame(height: 14)

                Text("\(Int(round(effectiveVolume * 100)))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 30, alignment: .trailing)
            }

            // Inline CoreAudio Output Device Switcher (SkyLight-safe!)
            if !devices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(devices, id: \.id) { dev in
                            Button {
                                AudioOutputRoutingMenu.shared.setOutputDevice(dev.id)
                                devices = AudioOutputRoutingMenu.shared.availableOutputDevices()
                                volumeManager.refresh()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: dev.symbolName)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(dev.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(dev.isDefault ? .white : .white.opacity(0.65))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(
                                    Capsule()
                                        .fill(dev.isDefault ? accentColor.opacity(0.28) : Color.white.opacity(0.08))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(dev.isDefault ? accentColor.opacity(0.55) : Color.white.opacity(0.1), lineWidth: 0.75)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )
        )
        .onAppear {
            devices = AudioOutputRoutingMenu.shared.availableOutputDevices()
            volumeManager.refresh()
        }
    }

}



// MARK: - Lock Screen Full Screen Artwork Wallpaper (animated Apple Music covers)

struct LockScreenPanelRootView: View {
    @ObservedObject private var manager = LockScreenMediaPanelManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var artworkService = AnimatedArtworkService.shared
    @Default(.lockScreenAnimatedArtwork) private var animatedArtworkEnabled
    var onClosePreview: (() -> Void)? = nil

    private var trackKey: String {
        "\(musicManager.songTitle)|\(musicManager.artistName)|\(musicManager.album)"
    }

    private var albumKey: String? {
        musicManager.album.isEmpty ? nil : "\(musicManager.artistName)|\(musicManager.album)"
    }

    private var hasActiveMedia: Bool {
        LockScreenMediaPanelManager.hasActiveMedia(musicManager)
    }

    private var animatedArtworkURL: URL? {
        guard animatedArtworkEnabled, hasActiveMedia else { return nil }
        return artworkService.videoURL(for: trackKey, albumKey: albumKey)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if manager.isLyricsLayout {
                LockScreenLyricsLayoutView(
                    trackKey: trackKey,
                    onClosePreview: onClosePreview
                )
            } else {
                if manager.isWallpaperMode {
                    LockScreenArtworkWallpaperView(
                        videoURL: manager.wallpaperVideoURL,
                        highResCover: artworkService.stillImage(for: trackKey),
                        onDismiss: { manager.toggleWallpaperMode() }
                    )
                    .transition(.opacity)
                }

                LockScreenMediaPanelView(onClosePreview: onClosePreview)
                    .padding(.bottom, manager.isWindowExpanded ? manager.cardBottomInset : 0)
                    .offset(x: manager.isWindowExpanded ? manager.cardHorizontalOffset : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: animatedArtworkURL, initial: true) { _, url in
            manager.setAnimatedArtwork(url)
        }
        .task(id: "\(trackKey)|\(animatedArtworkEnabled)") {
            guard animatedArtworkEnabled, hasActiveMedia else { return }
            await artworkService.load(
                title: musicManager.songTitle,
                artist: musicManager.artistName,
                album: musicManager.album,
                key: trackKey,
                albumKey: albumKey,
                fallbackCover: musicManager.albumArt,
                isAppleMusic: musicManager.bundleIdentifier == "com.apple.Music"
            )
        }
    }
}

struct LockScreenArtworkWallpaperView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    let videoURL: URL?
    let highResCover: NSImage?
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if let highResCover {
                    Image(nsImage: highResCover)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }

                if let videoURL {
                    LoopingArtworkVideoView(url: videoURL)
                        .id(videoURL)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0.0),
                        .init(color: .clear, location: 0.18),
                        .init(color: .clear, location: 0.40),
                        .init(color: .black.opacity(0.62), location: 0.72),
                        .init(color: .black.opacity(0.88), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    }
                    .padding(.top, 58)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}

// MARK: - Word timed lyrics (Apple Music catalog, or LRCLIB entries with word sync)

struct TimedLyricWord: Equatable {
    let begin: Double
    let end: Double
    /// A word or a syllable: syllables of one word are not followed by a space
    let text: String
    var followedBySpace: Bool
}

struct AppleMusicLyrics {
    let lines: [TimedLyricLine]
    let songwriters: [String]
}

struct TimedLyricLine: Equatable {
    let begin: Double
    let end: Double
    let text: String
    /// Empty when the lyrics are timed by line only
    let words: [TimedLyricWord]
    /// First line of a verse or chorus, kept to lay out lyrics Apple only has as text
    var startsStanza = false

    /// Lines without any timing: Apple has only the text of the song
    static func areUntimed(_ lines: [TimedLyricLine]) -> Bool {
        !lines.contains { $0.begin > 0 || $0.end > 0 }
    }

    /// The text with a blank line between stanzas, as Apple Music shows it
    static func plainText(_ lines: [TimedLyricLine]) -> String {
        lines.enumerated().map { index, line in
            (index > 0 && line.startsStanza ? "\n" : "") + line.text
        }.joined(separator: "\n")
    }
}

/// Reads Apple Music's TTML lyrics: one `<p begin end>` per line, holding either the line text or one
/// `<span begin end>` per word or syllable. Words are separated by whitespace between spans. Background
/// vocals, translations and transliterations are left out.
final class AppleLyricsTTMLParser: NSObject, XMLParserDelegate {
    private var lines: [TimedLyricLine] = []
    private var inParagraph = false
    private var paragraphBegin = 0.0
    private var paragraphEnd = 0.0
    private var paragraphText = ""
    private var words: [TimedLyricWord] = []
    private var spans: [(begin: Double?, end: Double?, skip: Bool)] = []
    private var spanText = ""
    private var skippedDepth = 0
    private var nextStartsStanza = false

    static func parse(_ ttml: String) -> [TimedLyricLine] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let delegate = AppleLyricsTTMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return [] }
        // Stable, so lyrics without timing (every line at 0) keep their order
        return delegate.lines.enumerated()
            .sorted { ($0.element.begin, $0.offset) < ($1.element.begin, $1.offset) }
            .map(\.element)
    }

    /// "1:02.345", "0:01:02.345", "62.345" or "62.345s"
    static func seconds(_ value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("s") { text.removeLast() }
        var total = 0.0
        for part in text.split(separator: ":") {
            guard let number = Double(part) else { return nil }
            total = total * 60 + number
        }
        return total
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let role = attributeDict["ttm:role"] ?? attributeDict["role"] ?? ""
        let hidden = role == "x-bg" || role == "x-translation" || role == "x-roman"

        if skippedDepth > 0 || (hidden && name != "p") {
            skippedDepth += 1
            return
        }
        switch name {
        case "div":
            nextStartsStanza = true
        case "p":
            inParagraph = true
            paragraphBegin = Self.seconds(attributeDict["begin"]) ?? 0
            paragraphEnd = Self.seconds(attributeDict["end"]) ?? paragraphBegin
            paragraphText = ""
            words = []
            spans = []
        case "span" where inParagraph:
            spans.append((Self.seconds(attributeDict["begin"]), Self.seconds(attributeDict["end"]), false))
            spanText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inParagraph, skippedDepth == 0 else { return }
        if spans.isEmpty {
            paragraphText += string
            if !words.isEmpty, string.contains(where: \.isWhitespace) {
                words[words.count - 1].followedBySpace = true
            }
        } else {
            spanText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if skippedDepth > 0 {
            skippedDepth -= 1
            return
        }
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "span" where inParagraph && !spans.isEmpty:
            let span = spans.removeLast()
            let text = spanText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let begin = span.begin {
                words.append(TimedLyricWord(
                    begin: begin,
                    end: span.end ?? begin,
                    text: text,
                    followedBySpace: spanText.last?.isWhitespace ?? false
                ))
            }
            spanText = ""
        case "p" where inParagraph:
            inParagraph = false
            let text: String
            if words.isEmpty {
                text = paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = words.enumerated().map { index, word in
                    word.text + (word.followedBySpace && index < words.count - 1 ? " " : "")
                }.joined()
            }
            guard !text.isEmpty else { return }
            lines.append(TimedLyricLine(begin: paragraphBegin, end: max(paragraphEnd, paragraphBegin), text: text,
                                        words: words, startsStanza: nextStartsStanza))
            nextStartsStanza = false
        default:
            break
        }
    }
}

/// Reads LRCLIB's `lyricsfile`, a YAML document whose `lines` list holds `text`, `start_ms`, `end_ms` and, on
/// entries marked `hasWordSync`, a `words` list where each word only has a `start_ms`: a word ends when the
/// next one starts, the last one with its line. Returns nothing unless at least one line is timed by word.
enum LRCLibLyricsFileParser {
    static func parse(_ yaml: String) -> [TimedLyricLine] {
        struct Line {
            var text = ""
            var start: Double?
            var end: Double?
            var words: [(text: String, start: Double?)] = []
        }
        var lines: [Line] = []
        var inLines = false

        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(raw)
            if let first = row.first, first != " ", first != "-" {
                inLines = row.hasPrefix("lines:")
                continue
            }
            guard inLines else { continue }
            if let value = Self.value(row, key: "- text:", indent: 0) {
                lines.append(Line(text: unquoted(value)))
            } else if lines.isEmpty {
                continue
            } else if let value = Self.value(row, key: "start_ms:", indent: 2) {
                lines[lines.count - 1].start = milliseconds(value)
            } else if let value = Self.value(row, key: "end_ms:", indent: 2) {
                lines[lines.count - 1].end = milliseconds(value)
            } else if let value = Self.value(row, key: "- text:", indent: 2) {
                lines[lines.count - 1].words.append((unquoted(value), nil))
            } else if let value = Self.value(row, key: "start_ms:", indent: 4), !lines[lines.count - 1].words.isEmpty {
                let last = lines[lines.count - 1].words.count - 1
                lines[lines.count - 1].words[last].start = milliseconds(value)
            }
        }

        var result: [TimedLyricLine] = []
        for (index, line) in lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let begin = line.start else { continue }
            let nextStart = lines[(index + 1)...].lazy.compactMap(\.start).first ?? .infinity

            let timed = line.words.compactMap { word in word.start.map { (text: word.text, start: $0) } }
            var starts = timed.map(\.start)
            // end_ms often lands right on the last word's start: give that word at least a typical word length
            let spans = zip(starts, starts.dropFirst()).map { $1 - $0 }.sorted()
            let typical = min(1, max(0.3, spans.isEmpty ? 0.5 : spans[spans.count / 2]))
            let sungEnd = min(nextStart, max(line.end ?? begin, (starts.last ?? begin) + typical))
            starts.append(sungEnd)

            var words: [TimedLyricWord] = []
            for (position, word) in timed.enumerated() {
                let wordText = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wordText.isEmpty else { continue }
                words.append(TimedLyricWord(begin: word.start, end: max(word.start, starts[position + 1]),
                                            text: wordText, followedBySpace: word.text.last?.isWhitespace ?? false))
            }
            // A held note is not an instrumental break: the line runs on to the next one unless 5 s of
            // silence remain once the last word is given time to ring out
            let end = nextStart - (sungEnd + 1.5) >= 5 ? sungEnd + 1.5 : nextStart
            result.append(TimedLyricLine(begin: begin, end: max(begin, end), text: text, words: words))
        }
        guard result.contains(where: { !$0.words.isEmpty }) else { return [] }
        return result.sorted { $0.begin < $1.begin }
    }

    /// The value after `key` when the row starts with exactly `indent` spaces then `key`
    private static func value(_ row: String, key: String, indent: Int) -> String? {
        let prefix = String(repeating: " ", count: indent) + key
        guard row.hasPrefix(prefix) else { return nil }
        return String(row.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func milliseconds(_ value: String) -> Double? {
        Double(unquoted(value)).map { $0 / 1000 }
    }

    /// YAML scalars as LRCLIB writes them: plain, 'single quoted' (with '' for a quote) or "double quoted"
    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return value
    }
}

/// Fetches lyrics the way the Apple Music web player does: its public web token for the catalog, plus the
/// signed in user's session token. Unofficial, so every failure falls back to LRCLIB.
@MainActor
final class AppleMusicLyricsService: ObservableObject {
    static let shared = AppleMusicLyricsService()

    @Published private(set) var isSignedIn: Bool

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let logger = Logger(subsystem: "theboringteam.boringnotch", category: "AppleMusicLyrics")
    private static let keychainService = "GravityNotch Apple Music lyrics"
    private static let keychainAccount = "media-user-token"
    private static let webTokenDefaultsKey = "appleMusicWebPlayerToken"

    private var webToken: String?
    private var storefront: String?
    /// Last session token Apple refused: the remembered web session may still hold it, so the sign in
    /// window must wait for a fresh one
    private(set) var rejectedUserToken: String?

    private enum ServiceError: Error {
        case unauthorized
        case notFound
        case http(Int)
        case noWebToken
    }

    /// The session token, read from disk at most once per launch (the one-time move out of the keychain is a
    /// password prompt). nil: not read yet; .some(nil): read, nothing stored.
    private var cachedUserToken: String??
    private var sourceObserver: AnyCancellable?

    private init() {
        webToken = UserDefaults.standard.string(forKey: Self.webTokenDefaultsKey)
        isSignedIn = false
        refreshSignInState()
        sourceObserver = Defaults.publisher(.lyricsSource, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshSignInState()
                }
            }
    }

    /// LRCLIB users never touch the session, nor the keychain of older versions
    func refreshSignInState() {
        isSignedIn = currentUserToken() != nil
    }

    private func currentUserToken() -> String? {
        guard Defaults[.lyricsSource] == .appleMusic else { return nil }
        if let cachedUserToken { return cachedUserToken }
        let token = Self.readUserToken()
        cachedUserToken = .some(token)
        return token
    }

    // MARK: Session

    func storeUserToken(_ token: String) {
        Self.writeUserToken(token)
        cachedUserToken = .some(token)
        storefront = nil
        isSignedIn = true
        Self.logger.notice("Signed in to Apple Music")
        MusicManager.shared.reloadLyricsForNewSource()
    }

    /// `forgetWebSession` is false when Apple rejected an expired token: the remembered web session then
    /// lets the next sign in skip the verification code
    func signOut(forgetWebSession: Bool = true) {
        Self.deleteUserToken()
        cachedUserToken = .some(nil)
        storefront = nil
        isSignedIn = false
        if forgetWebSession {
            AppleMusicSignInWindowController.removeWebSession()
        }
    }

    // MARK: Lyrics

    /// Lyrics of the catalog song matching the track, word timed when Apple has it, nil otherwise.
    /// `catalogID` is the exact song Music plays (from MediaRemote): the text search below can pick
    /// another version (remix, edit, live) or miss the song, then LRCLIB shows other lyrics.
    func lyrics(title: String, artist: String, album: String, duration: Double, catalogID: String? = nil) async -> AppleMusicLyrics? {
        guard let userToken = currentUserToken() else { return nil }
        do {
            let storefront = try await currentStorefront(userToken: userToken)
            if let catalogID, try await catalogSong(catalogID, isTitled: title, storefront: storefront) {
                if let lines = try await fetchLyrics(songID: catalogID, storefront: storefront, userToken: userToken) {
                    return lines
                }
                Self.logger.notice("Apple Music lyrics: none for the playing song, using LRCLIB")
                return nil
            }
            guard let songID = try await findSong(title: title, artist: artist, album: album, duration: duration, storefront: storefront) else {
                Self.logger.notice("Apple Music lyrics: no catalog match, using LRCLIB")
                return nil
            }
            return try await fetchLyrics(songID: songID, storefront: storefront, userToken: userToken)
        } catch ServiceError.unauthorized {
            Self.logger.error("Apple Music refused the session, signing out")
            rejectedUserToken = userToken
            signOut(forgetWebSession: false)
        } catch {
            Self.logger.error("Apple Music lyrics lookup failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    private func fetchLyrics(songID: String, storefront: String, userToken: String) async throws -> AppleMusicLyrics? {
        for kind in ["syllable-lyrics", "lyrics"] {
            do {
                let data = try await request("/v1/catalog/\(storefront)/songs/\(songID)/\(kind)", userToken: userToken)
                if let ttml = Self.ttml(in: data) {
                    let lines = AppleLyricsTTMLParser.parse(ttml)
                    if !lines.isEmpty {
                        let wordTimed = lines.contains { !$0.words.isEmpty }
                        let declared = Self.matches(of: #"itunes:timing="[A-Za-z]+""#, in: ttml).first ?? "no timing attribute"
                        let songwriters = Self.songwriters(in: ttml)
                        Self.logger.notice("Apple Music lyrics: \(lines.count, privacy: .public) lines, \(kind, privacy: .public), word timed: \(wordTimed, privacy: .public), \(declared, privacy: .public), \(songwriters.count, privacy: .public) songwriters")
                        return AppleMusicLyrics(lines: lines, songwriters: songwriters)
                    }
                }
            } catch ServiceError.notFound {
                continue
            }
        }
        return nil
    }

    /// Names listed in the TTML head (`<songwriters><songwriter>`), shown after the last line like Apple Music
    static func songwriters(in ttml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<(?:\w+:)?songwriter>([^<]+)</(?:\w+:)?songwriter>"#) else { return [] }
        var names: [String] = []
        for match in regex.matches(in: ttml, range: NSRange(ttml.startIndex..., in: ttml)) {
            guard let range = Range(match.range(at: 1), in: ttml) else { continue }
            let name = String(ttml[range])
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// A local file's identifier is not a catalog id: only trust the id when the catalog song has this title.
    private func catalogSong(_ id: String, isTitled title: String, storefront: String) async throws -> Bool {
        let data: Data
        do {
            data = try await request("/v1/catalog/\(storefront)/songs/\(id)", userToken: nil)
        } catch ServiceError.notFound {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attributes = (json["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any],
              let name = attributes["name"] as? String else { return false }
        let wanted = Self.normalized(title)
        let found = Self.normalized(name)
        return !found.isEmpty && (found == wanted || found.contains(wanted) || wanted.contains(found))
    }

    private static func ttml(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let attributes = items.first?["attributes"] as? [String: Any] else { return nil }
        return (attributes["ttml"] as? String) ?? (attributes["ttmlLocalizations"] as? String)
    }

    private func currentStorefront(userToken: String) async throws -> String {
        if let storefront { return storefront }
        let data = try await request("/v1/me/storefront", userToken: userToken)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (json["data"] as? [[String: Any]])?.first?["id"] as? String else {
            throw ServiceError.notFound
        }
        storefront = id
        return id
    }

    /// Catalog search is picky: in some storefronts "I'm Not Alone Calvin Harris" only finds a remix while
    /// "Im Not Alone Calvin Harris" finds every version. Several phrasings are tried until one finds the version
    /// playing, judged on the full title (edit, remix, live), the album and the duration.
    private func findSong(title: String, artist: String, album: String, duration: Double, storefront: String) async throws -> String? {
        let baseTitle = Self.searchable(title)
        let baseArtist = Self.searchable(artist)
        let terms = [
            "\(baseTitle) \(baseArtist)",
            "\(Self.withoutApostrophes(baseTitle)) \(Self.withoutApostrophes(baseArtist))",
            Self.withoutApostrophes(baseTitle)
        ]
        var best: (id: String, score: Double)?
        var searched: Set<String> = []
        for term in terms where searched.insert(term).inserted {
            let data = try await request(
                "/v1/catalog/\(storefront)/search",
                query: [
                    URLQueryItem(name: "term", value: term),
                    URLQueryItem(name: "types", value: "songs"),
                    URLQueryItem(name: "limit", value: "25")
                ],
                userToken: nil
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [String: Any],
                  let songs = (results["songs"] as? [String: Any])?["data"] as? [[String: Any]] else { continue }
            for song in songs {
                guard let id = song["id"] as? String,
                      let attributes = song["attributes"] as? [String: Any],
                      let score = Self.score(attributes, title: title, artist: artist, album: album, duration: duration)
                else { continue }
                if best == nil || score > best!.score { best = (id, score) }
            }
            // Same full title and close duration: this is the version playing, no need to search further
            if let best, best.score >= 4 { break }
        }
        return best?.id
    }

    private static func score(_ attributes: [String: Any], title: String, artist: String, album: String, duration: Double) -> Double? {
        guard attributes["hasLyrics"] as? Bool != false else { return nil }
        let rawName = attributes["name"] as? String ?? ""
        let name = normalized(rawName)
        let wantedTitle = normalized(title)
        let songArtist = normalized(attributes["artistName"] as? String ?? "")
        let wantedArtist = normalized(artist)
        let titleMatches = name == wantedTitle || name.contains(wantedTitle) || wantedTitle.contains(name)
        let artistMatches = wantedArtist.isEmpty || songArtist.contains(wantedArtist) || wantedArtist.contains(songArtist)
        guard titleMatches, artistMatches, !name.isEmpty else { return nil }

        var score = name == wantedTitle ? 1.0 : 0.0
        // "(2019 Edit)" against "(Tiesto Remix)": the same base title, another recording with other lyrics
        if fullyNormalized(rawName) == fullyNormalized(title) { score += 2 }
        let wantedAlbum = fullyNormalized(album)
        if !wantedAlbum.isEmpty, fullyNormalized(attributes["albumName"] as? String ?? "") == wantedAlbum { score += 1 }
        if attributes["hasTimeSyncedLyrics"] as? Bool == true { score += 1 }
        if duration > 0, let millis = attributes["durationInMillis"] as? Double {
            score -= min(4, abs(millis / 1000 - duration) / 3)
        }
        return score
    }

    private static func withoutApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
    }

    /// Like `normalized`, but keeps what is in brackets, so versions of a song stay apart
    private static func fullyNormalized(_ text: String) -> String {
        withoutApostrophes(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The title without "(feat. ...)" and similar, which catalog search handles poorly
    private static func searchable(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func normalized(_ text: String) -> String {
        searchable(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Requests

    private func request(_ path: String, query: [URLQueryItem] = [], userToken: String?, retryWithNewToken: Bool = true) async throws -> Data {
        let token = try await currentWebToken()
        guard var components = URLComponents(string: "https://amp-api.music.apple.com" + path) else { throw ServiceError.notFound }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ServiceError.notFound }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let userToken { request.setValue(userToken, forHTTPHeaderField: "Media-User-Token") }
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401 where retryWithNewToken:
            // The web token may have been rotated: fetch it again once before blaming the session
            webToken = nil
            UserDefaults.standard.removeObject(forKey: Self.webTokenDefaultsKey)
            return try await self.request(path, query: query, userToken: userToken, retryWithNewToken: false)
        case 401, 403:
            // The catalog search sends no session: a refusal there says nothing about the sign in
            throw userToken != nil ? ServiceError.unauthorized : ServiceError.http(status)
        case 404:
            throw ServiceError.notFound
        default:
            throw ServiceError.http(status)
        }
    }

    /// The web player's catalog token, read from the music.apple.com scripts and kept until it expires
    private func currentWebToken() async throws -> String {
        if let webToken, !Self.isExpired(webToken) { return webToken }
        let html = try await fetchText("https://music.apple.com/")
        let scripts = Self.matches(of: #"/assets/index[^"']*\.js"#, in: html)
        for script in Set(scripts) {
            guard let js = try? await fetchText("https://music.apple.com" + script),
                  let token = Self.webPlayerToken(in: js) else { continue }
            webToken = token
            UserDefaults.standard.set(token, forKey: Self.webTokenDefaultsKey)
            return token
        }
        throw ServiceError.noWebToken
    }

    private func fetchText(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw ServiceError.notFound }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func webPlayerToken(in js: String) -> String? {
        matches(of: #"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, in: js).first { token in
            guard let claims = claims(of: token) else { return false }
            return claims["iss"] as? String == "AMPWebPlay" && !isExpired(token)
        }
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func isExpired(_ token: String) -> Bool {
        guard let expiry = claims(of: token)?["exp"] as? Double else { return true }
        return Date(timeIntervalSince1970: expiry) < Date().addingTimeInterval(3600)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: Session storage

    /// The session token lives in a file other users of the Mac cannot read (folder 700, file 600), not in the
    /// keychain: a self-signed app gets a new identity with every update, so the keychain asked for the Mac
    /// password after each one. It is an Apple Music access token, never the Apple Account password, and
    /// Sign Out deletes it. Versions 1.3.0 and 1.3.1 kept it in the keychain: it is moved out once.
    private static var sessionFileURL: URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("AppleMusic", isDirectory: true)
            .appendingPathComponent("session")
    }

    private static func readUserToken() -> String? {
        if let data = try? Data(contentsOf: sessionFileURL),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        guard let legacyToken = readKeychainToken() else { return nil }
        writeUserToken(legacyToken)
        deleteKeychainToken()
        logger.notice("Moved the Apple Music session out of the keychain")
        return legacyToken
    }

    private static func writeUserToken(_ token: String) {
        let fm = FileManager.default
        let url = sessionFileURL
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? fm.removeItem(at: url)
        // Created with its final permissions, so the token is never readable by others, even briefly
        fm.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    private static func deleteUserToken() {
        try? FileManager.default.removeItem(at: sessionFileURL)
        deleteKeychainToken()
    }

    // MARK: Keychain (1.3.0 and 1.3.1 only, read once to migrate)

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func readKeychainToken() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    private static func deleteKeychainToken() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}

/// The real music.apple.com page in a window: once the user signs in, the session token it sets is kept
/// (in a file only the user can read) and the window closes. The page's cookies live in a data store of their own, so Apple
/// remembers this Mac and a later sign in skips the verification code; signing out deletes them.
/// Passkeys and iCloud Keychain AutoFill are reserved to browsers, hence the password.
@MainActor
final class AppleMusicSignInWindowController: NSObject, NSWindowDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    static let shared = AppleMusicSignInWindowController()

    private static let dataStoreID = UUID(uuidString: "6D1B5C7A-3E2F-4A8B-9C10-5F4E3D2C1B0A")!

    /// Signing out forgets the Apple Music web session too
    static func removeWebSession() {
        WKWebsiteDataStore.remove(forIdentifier: dataStoreID) { _ in }
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var popupWindows: [NSWindow] = []
    private var cookieStore: WKHTTPCookieStore?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        // Apple's sign in window opens once a script has loaded, not right on the click
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1060, height: 760), configuration: configuration)
        webView.customUserAgent = AppleMusicLyricsService.userAgent
        webView.uiDelegate = self
        let store = configuration.websiteDataStore.httpCookieStore
        store.add(self)
        cookieStore = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sign in to Apple Music")
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.webView = webView

        if let url = URL(string: "https://music.apple.com/") {
            webView.load(URLRequest(url: url))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// WebKit calls observers on the main thread
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated {
            cookieStore.getAllCookies { cookies in
                guard let token = cookies.first(where: { $0.name == "media-user-token" && !$0.value.isEmpty })?.value else { return }
                Task { @MainActor in
                    guard self.window != nil, token != AppleMusicLyricsService.shared.rejectedUserToken else { return }
                    AppleMusicLyricsService.shared.storeUserToken(token)
                    self.window?.close()
                }
            }
        }
    }

    /// Apple's sign in opens in a popup: give it a real window sharing the page's session
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = AppleMusicLyricsService.userAgent
        popup.uiDelegate = self
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = String(localized: "Sign in to Apple Music")
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        popupWindows.append(popupWindow)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let popupWindow = popupWindows.first(where: { $0.contentView === webView }) {
            popupWindow.close()
            popupWindows.removeAll { $0 === popupWindow }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        cookieStore?.remove(self)
        cookieStore = nil
        for popup in popupWindows { popup.close() }
        popupWindows.removeAll()
        webView = nil
        window = nil
    }
}

// MARK: - Lock Screen Full Screen Lyrics (player on the left, Apple Music style lyrics on the right)

private struct FullScreenLyricLine: Identifiable, Equatable {
    /// Index in the lyrics, so it doubles as the row position
    let id: Int
    let time: Double?
    let text: String
    /// An instrumental passage, drawn as Apple Music's three dots while it plays
    var isInterlude: Bool = false
    /// When the line stops, if known (an interlude, or a line followed by one)
    var end: Double? = nil
    /// Real word (or syllable) timing, from Apple Music or a word synced LRCLIB entry
    var words: [TimedLyricWord] = []

    /// Apple Music and word synced LRCLIB entries give the real end of every line, so the breaks are known exactly
    static func fromTimed(_ timed: [TimedLyricLine]) -> [FullScreenLyricLine] {
        var result: [FullScreenLyricLine] = []
        func add(_ line: FullScreenLyricLine) {
            var line = line
            line = FullScreenLyricLine(id: result.count, time: line.time, text: line.text,
                                       isInterlude: line.isInterlude, end: line.end, words: line.words)
            result.append(line)
        }
        if let first = timed.first, first.begin >= 3 {
            add(FullScreenLyricLine(id: 0, time: 0, text: "", isInterlude: true, end: first.begin))
        }
        for (index, line) in timed.enumerated() {
            add(FullScreenLyricLine(id: 0, time: line.begin, text: line.text, end: line.end, words: line.words))
            if index + 1 < timed.count, timed[index + 1].begin - line.end >= 3 {
                add(FullScreenLyricLine(id: 0, time: line.end, text: "", isInterlude: true, end: timed[index + 1].begin))
            }
        }
        return result
    }

    /// LRCLIB times only the start of each line. Interludes come from the intro before the first line, the
    /// empty lines LRCLIB uses to mark a break, and very long gaps (estimated: the line is assumed sung by
    /// then, so short gaps never show dots over a slow singer).
    static func withInterludes(_ synced: [(time: Double, text: String)]) -> [FullScreenLyricLine] {
        var result: [FullScreenLyricLine] = []
        func add(_ time: Double, _ text: String, interlude: Bool, end: Double?) {
            result.append(FullScreenLyricLine(id: result.count, time: time, text: text, isInterlude: interlude, end: end))
        }

        if let first = synced.first, first.time >= 4 {
            add(0, "", interlude: true, end: first.time)
        }
        for (index, line) in synced.enumerated() {
            let next = index + 1 < synced.count ? synced[index + 1].time : nil
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == "♪" {
                if let next, next - line.time >= 3 {
                    add(line.time, "", interlude: true, end: next)
                }
                continue
            }
            if let next, next - line.time >= 14 {
                let estimate = LockScreenKaraokeLine.sungDuration(text: text, gap: next - line.time)
                let interludeStart = line.time + max(estimate + 1.5, 6)
                if next - interludeStart >= 5 {
                    add(line.time, text, interlude: false, end: interludeStart)
                    add(interludeStart, "", interlude: true, end: next)
                    continue
                }
            }
            add(line.time, text, interlude: false, end: next)
        }
        return result
    }
}

struct LockScreenLyricsLayoutView: View {
    @ObservedObject private var manager = LockScreenMediaPanelManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var artworkService = AnimatedArtworkService.shared
    let trackKey: String
    var onClosePreview: (() -> Void)?

    @State private var showRemainingTime = true
    @State private var showAudioDrawer = false
    /// Outcome of the last finished lookup, kept while the next track's lyrics load so the player does not
    /// slide to the center and back on every track change. False at first: nothing is shown on the right
    /// until lyrics are actually there.
    @State private var lastLookupFoundLyrics = false
    @State private var playerSize: CGSize = .zero
    @Default(.lockScreenFullScreenShowLyrics) private var showLyricsPreference
    @Default(.lockScreenFullScreenHorizontalPosition) private var horizontalPosition
    @Default(.lockScreenFullScreenVerticalPosition) private var verticalPosition

    private var lines: [FullScreenLyricLine] {
        if !musicManager.timedLyrics.isEmpty {
            return FullScreenLyricLine.fromTimed(musicManager.timedLyrics)
        }
        if !musicManager.syncedLyrics.isEmpty {
            return FullScreenLyricLine.withInterludes(musicManager.syncedLyrics)
        }
        return musicManager.currentLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { FullScreenLyricLine(id: $0.offset, time: nil, text: $0.element) }
    }

    /// Only synced lyrics count: text alone cannot follow the song, so the lyrics stay closed
    private var lyricsFound: Bool {
        !musicManager.syncedLyrics.isEmpty
    }

    private var hasMedia: Bool {
        LockScreenMediaPanelManager.hasActiveMedia(musicManager)
    }

    /// Lyrics exist (or are loading for a track that follows one with lyrics), whether shown or not
    private var lyricsAvailable: Bool {
        guard hasMedia else { return false }
        if lyricsFound { return true }
        return musicManager.isFetchingLyrics && lastLookupFoundLyrics
    }

    private var showsLyrics: Bool {
        showLyricsPreference && lyricsAvailable
    }

    /// Over an animated artwork the player sits at the bottom so the artwork stays visible; hiding the
    /// lyrics then only slides it sideways
    private var hasMotionArtwork: Bool {
        manager.animatedArtworkURL != nil
    }

    /// Center of the player: the position settings span the left half next to the lyrics, the whole screen
    /// without them. Equal top and bottom margins, so the default 0.5 is the exact vertical middle.
    private func playerCenter(in size: CGSize) -> CGPoint {
        let areaWidth = showsLyrics ? size.width / 2 : size.width
        let sideMargin: CGFloat = 60
        let topMargin: CGFloat = 70
        let bottomMargin: CGFloat = 70
        let horizontalRange = max(0, areaWidth - playerSize.width - 2 * sideMargin)
        let verticalRange = max(0, size.height - playerSize.height - topMargin - bottomMargin)
        let horizontal = CGFloat(min(max(horizontalPosition, 0), 1))
        let vertical = CGFloat(min(max(verticalPosition, 0), 1))
        let x = sideMargin + horizontalRange * horizontal + playerSize.width / 2
        if hasMotionArtwork {
            // A little above the bottom edge, about where the regular player sits
            let lift = max(110, size.height * 0.11)
            return CGPoint(x: x, y: size.height - lift - playerSize.height / 2)
        }
        return CGPoint(x: x, y: size.height - bottomMargin - verticalRange * vertical - playerSize.height / 2)
    }

    private var accent: Color {
        Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.65)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LockScreenLyricsBackground(
                    videoURL: manager.animatedArtworkURL,
                    cover: artworkService.stillImage(for: trackKey) ?? musicManager.albumArt
                )

                // Without lyrics (none found, hidden, still loading, nothing playing) the same player moves
                // across the whole screen; it slides into the left half once lyrics show
                playerBlock(size: geo.size)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: LockScreenPlayerSizeKey.self, value: proxy.size)
                        }
                    )
                    .position(playerCenter(in: geo.size))

                if showsLyrics {
                    lyricsColumn(size: geo.size)
                        .frame(width: geo.size.width / 2, height: geo.size.height)
                        .position(x: geo.size.width * 0.75, y: geo.size.height / 2)
                        .transition(.opacity.combined(with: .offset(x: 40)))
                }

                topBar(size: geo.size)
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: showsLyrics)
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: hasMotionArtwork)
        }
        .ignoresSafeArea()
        .onPreferenceChange(LockScreenPlayerSizeKey.self) { playerSize = $0 }
        .onChange(of: "\(musicManager.isFetchingLyrics)|\(lyricsFound)", initial: true) {
            if !musicManager.isFetchingLyrics {
                lastLookupFoundLyrics = lyricsFound
            }
        }
    }

    private func playerBlock(size: CGSize) -> some View {
        let width = max(260, min(400, size.width / 2 - 120))
        let artworkSize = min(width, size.height * 0.36)

        return VStack(alignment: .leading, spacing: 16) {
            // A motion artwork already fills the background, a still cover gets its own card
            if manager.animatedArtworkURL == nil {
                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    .scaleEffect(musicManager.isPlaying ? 1 : 0.94, anchor: .bottomLeading)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: musicManager.isPlaying)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasMedia ? musicManager.songTitle : String(localized: "Nothing Playing"))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(hasMedia
                        ? (musicManager.artistName.isEmpty ? String(localized: "Music") : musicManager.artistName)
                        : String(localized: "Press Play to start listening"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if lyricsAvailable {
                    Button {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                            showLyricsPreference.toggle()
                        }
                    } label: {
                        Image(systemName: showLyricsPreference ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(showLyricsPreference ? .white : .white.opacity(0.6))
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(showLyricsPreference ? 0.22 : 0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Synced lyrics")
                    .transition(.opacity)
                }
            }

            TimelineView(.animation(minimumInterval: 0.25, paused: !musicManager.isPlaying)) { context in
                LockScreenScrubBar(
                    elapsed: musicManager.estimatedPlaybackPosition(at: context.date),
                    duration: musicManager.songDuration,
                    accentColor: accent,
                    showRemainingTime: $showRemainingTime
                )
            }

            LockScreenTransportControls(
                hasMediaTrack: hasMedia,
                albumAccent: accent,
                showAudioDrawer: $showAudioDrawer,
                onOpenAudioDrawer: { _ in }
            )

            if showAudioDrawer {
                LockScreenAudioDrawer(accentColor: accent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width, alignment: .leading)
        .shadow(color: .black.opacity(0.25), radius: 10)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showAudioDrawer)
    }

    @ViewBuilder
    private func lyricsColumn(size: CGSize) -> some View {
        let currentLines = lines
        Group {
            if currentLines.isEmpty {
                Text(musicManager.isFetchingLyrics ? String(localized: "Loading lyrics…") : "♪")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, LockScreenFullLyricsView.edgeMargin)
            } else {
                LockScreenFullLyricsView(lines: currentLines, isSynced: !musicManager.syncedLyrics.isEmpty)
            }
        }
        .padding(.top, 96)
        .padding(.bottom, size.height * 0.06)
        .padding(.leading, 24 - LockScreenFullLyricsView.edgeMargin)
        .padding(.trailing, max(60, size.width * 0.06) - LockScreenFullLyricsView.edgeMargin)
    }

    private func topBar(size: CGSize) -> some View {
        VStack {
            HStack(alignment: .top) {
                if let onClosePreview {
                    Button(action: onClosePreview) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Close preview")
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                }
            }
            .padding(.top, 46)
            .padding(.horizontal, max(60, size.width * 0.06))
            Spacer()
        }
    }
}

private struct LockScreenLyricsBackground: View {
    let videoURL: URL?
    let cover: NSImage

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                Image(nsImage: cover)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: videoURL == nil ? 80 : 0, opaque: true)
                    .saturation(videoURL == nil ? 1.35 : 1)
                    .scaleEffect(videoURL == nil ? 1.15 : 1)

                if let videoURL {
                    LoopingArtworkVideoView(url: videoURL)
                        .id(videoURL)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                Color.black.opacity(videoURL == nil ? 0.28 : 0.12)

                // Keeps the lyrics, the clock and the controls readable over any artwork
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.2),
                        .init(color: .clear, location: 0.55),
                        .init(color: .black.opacity(0.55), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(.easeInOut(duration: 0.6), value: videoURL)
    }
}

private struct LockScreenPlayerSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct LyricLineHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Every line keeps its natural height; the column is shifted so the active line sits near the top, and
/// each line follows with a small delay so the list moves like a wave. Lines blur and fade with their
/// distance to the active one.
private struct LockScreenFullLyricsView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    let lines: [FullScreenLyricLine]
    let isSynced: Bool

    @State private var heights: [Int: CGFloat] = [:]
    @State private var hoveredLine: Int?
    @State private var activeLineIndex: Int = 0
    /// Recently active lines kept on the glyph renderer while their lifted letters and glow settle smoothly
    @State private var settlingLines: [Int: Date] = [:]

    private static let spacing: CGFloat = 24
    private static let fontSize: CGFloat = 30
    private static let estimatedHeight: CGFloat = 40
    private static let interludeHeight: CGFloat = 30
    fileprivate static let settleDuration: Double = 0.6
    /// Slight anticipation so the next line begins gliding into focus right before its first syllable starts
    private static let scrollLeadTime: Double = 0.08
    /// Room on both sides of the text inside the clipped column, so the blur of the inactive lines and the
    /// glow of the active one fade out instead of being cut along a hard vertical edge
    static let edgeMargin: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            list(active: activeLineIndex, size: geo.size)
        }
        .background(
            // Evaluate a lightweight 30 Hz index check in a zero-cost background view (sub-16 ms scroll reaction)
            // and never mutate state mid-scroll: each row pauses its own TimelineView locally once settled.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !musicManager.isPlaying)) { context in
                Color.clear
                    .onChange(of: context.date) { _, now in
                        let lead = isSynced && musicManager.isPlaying ? Self.scrollLeadTime : 0
                        let next = activeIndex(at: musicManager.smoothedPlaybackPosition(at: now) + lead)
                        if next != activeLineIndex {
                            activateLine(next, at: now)
                        }
                    }
            }
        )
        .onAppear {
            settlingLines.removeAll()
            activeLineIndex = activeIndex(at: musicManager.smoothedPlaybackPosition())
        }
        .onChange(of: musicManager.timestampDate) { _, _ in
            let now = Date()
            let lead = isSynced && musicManager.isPlaying ? Self.scrollLeadTime : 0
            let next = activeIndex(at: musicManager.smoothedPlaybackPosition(at: now) + lead)
            if next != activeLineIndex {
                activateLine(next, at: now)
            }
        }
        .onChange(of: lines.count) { _, _ in
            settlingLines.removeAll()
            activeLineIndex = activeIndex(at: musicManager.smoothedPlaybackPosition())
        }
        .onPreferenceChange(LyricLineHeightsKey.self) { heights = $0 }
    }

    private func activateLine(_ next: Int, at now: Date) {
        let previous = activeLineIndex
        if isSynced, lines.indices.contains(previous), !lines[previous].isInterlude, abs(next - previous) <= 3 {
            settlingLines = settlingLines.filter { now.timeIntervalSince($0.value) < 3.0 }
            settlingLines[previous] = now
        } else {
            settlingLines.removeAll()
        }
        settlingLines.removeValue(forKey: next)
        activeLineIndex = next
    }

    private func list(active: Int, size: CGSize) -> some View {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for line in lines {
            tops.append(y)
            if line.isInterlude {
                // Takes room only while it plays, like in Apple Music; set here rather than measured so it
                // opens and closes with the same spring as the scroll
                y += line.id == active ? Self.interludeHeight + Self.spacing : 0
            } else {
                y += (heights[line.id] ?? Self.estimatedHeight) + Self.spacing
            }
        }
        let shift = size.height * 0.16 - (tops.indices.contains(active) ? tops[active] : 0)
        let creditsTop = y
        let rowSpring = Animation.spring(response: 0.56, dampingFraction: 0.98)

        return ZStack(alignment: .topLeading) {
            ForEach(lines) { line in
                row(line, active: active, width: max(0, size.width - 2 * Self.edgeMargin))
                    .offset(x: Self.edgeMargin, y: tops[line.id] + shift)
                    .animation(
                        rowSpring.delay(waveDelay(for: line.id, active: active)),
                        value: active
                    )
            }
            if !musicManager.lyricsSongwriters.isEmpty {
                creditsRow(width: max(0, size.width - 2 * Self.edgeMargin))
                    .opacity(lines.count - 1 - active <= 14 ? 1 : 0)
                    .offset(x: Self.edgeMargin, y: creditsTop + shift + 6)
                    .animation(
                        rowSpring.delay(waveDelay(for: lines.count, active: active)),
                        value: active
                    )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// "Written by" after the last line, as Apple Music ends its lyrics
    private func creditsRow(width: CGFloat) -> some View {
        let names = musicManager.lyricsSongwriters.formatted(.list(type: .and))
        return Text(String(localized: "Written by: \(names)"))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ line: FullScreenLyricLine, active: Int, width: CGFloat) -> some View {
        if line.isInterlude {
            interludeRow(line, isActive: line.id == active, width: width)
        } else {
            textRow(line, active: active, width: width)
        }
    }

    private func interludeRow(_ line: FullScreenLyricLine, isActive: Bool, width: CGFloat) -> some View {
        let start = line.time ?? 0
        return LockScreenInterludeDots(start: start, end: line.end ?? (start + 5), isActive: isActive)
            .frame(width: width, height: Self.interludeHeight, alignment: .leading)
            .scaleEffect(isActive ? 1 : 0.4, anchor: .leading)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
    }

    @ViewBuilder
    private func textRow(_ line: FullScreenLyricLine, active: Int, width: CGFloat) -> some View {
        let distance = line.id - active
        let isActive = distance == 0
        let isVisible = distance >= -4 && distance <= 14
        let isHovered = hoveredLine == line.id && line.time != nil
        let restOpacity = isHovered ? 0.75 : inactiveOpacity(distance)
        let deactivatedAt = isActive ? nil : settlingLines[line.id]
        // Keep the same view identity across all visible synced lines so transitioning into or out of
        // the active slot never destroys/recreates the underlying layer mid-spring.
        let usesKaraoke = isVisible && isSynced && line.time != nil
        let text = line.text.isEmpty ? "♪" : line.text

        Group {
            if usesKaraoke, let start = line.time {
                LockScreenKaraokeLine(
                    text: text,
                    start: start,
                    end: lineEnd(after: line.id, start: start),
                    words: line.words,
                    fontSize: Self.fontSize,
                    isActive: isActive,
                    deactivatedAt: deactivatedAt,
                    restOpacity: restOpacity
                )
            } else {
                Text(text)
                    .font(.system(size: Self.fontSize, weight: .bold))
                    .foregroundStyle(.white.opacity(isActive ? 1 : restOpacity))
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: LyricLineHeightsKey.self, value: [line.id: proxy.size.height])
            }
        )
        .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
        .blur(radius: (isActive || isHovered || !isVisible) ? 0 : min(CGFloat(abs(distance)) * 1.15, 5))
        .shadow(color: (isActive && !usesKaraoke) ? .white.opacity(0.18) : .clear, radius: 12)
        .opacity(isVisible ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredLine = inside ? line.id : (hoveredLine == line.id ? nil : hoveredLine)
        }
        .onTapGesture {
            if let time = line.time {
                musicManager.seek(to: time)
            }
        }
    }

    private func inactiveOpacity(_ distance: Int) -> Double {
        // Upcoming lines match `KaraokeGlyphRenderer.baseDimOpacity` (0.38) so rising into the active
        // slot produces zero brightness flash before the first word sweeps to 1.0.
        distance < 0 ? 0.32 : 0.38
    }

    private func waveDelay(for index: Int, active: Int) -> Double {
        let distance = index - active
        return distance > 0 ? Double(min(distance, 8)) * 0.024 : 0
    }

    private func lineEnd(after index: Int, start: Double) -> Double {
        if let end = lines[index].end { return end }
        let next = index + 1 < lines.count ? lines[index + 1].time : nil
        return next ?? (start + 5)
    }

    private func activeIndex(at elapsed: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        if isSynced {
            var low = 0
            var high = lines.count - 1
            var index = 0
            while low <= high {
                let mid = (low + high) / 2
                if (lines[mid].time ?? 0) <= elapsed {
                    index = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return index
        }
        // Plain lyrics carry no timing: follow the track's progress
        let duration = musicManager.songDuration
        let ratio = duration > 0 ? min(0.999, max(0, elapsed / duration)) : 0
        return min(lines.count - 1, Int(Double(lines.count) * ratio))
    }
}

/// Synced lyric row: stays mounted across the visible viewport (paused at 0 Hz while inactive) so scrolling
/// into or out of the active slot keeps one persistent layer and spring velocity with zero view swap.
private struct LockScreenKaraokeLine: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.lockScreenFullScreenLetterAnimation) private var animateLetters
    let text: String
    let start: Double
    let end: Double
    /// Real timing (Apple Music, or LRCLIB word sync); empty when only lines are timed, where it is estimated
    var words: [TimedLyricWord] = []
    let fontSize: CGFloat
    var isActive: Bool = true
    /// Non-nil once the next line takes over: lifted letters, swell and brightness ease smoothly down to rest
    var deactivatedAt: Date? = nil
    var restOpacity: Double = 0.32

    @State private var isSettling = false

    fileprivate struct Piece {
        let begin: Double
        let end: Double
        let emphasis: Double
        let followedBySpace: Bool
    }

    var body: some View {
        let timedPieces = words.isEmpty ? estimatedWords : words
        let isPaused = !(isActive && musicManager.isPlaying) && !isSettling
        Group {
            if #available(macOS 15.0, *) {
                // Lines timed only as a whole get estimated word times: they rise too, but never swell,
                // since how long a word is held is unknown
                let pieces = timedPieces.map { word in
                    Piece(
                        begin: word.begin,
                        end: word.end,
                        emphasis: (words.isEmpty || !animateLetters) ? 0 : Self.emphasis(of: word),
                        followedBySpace: word.followedBySpace
                    )
                }
                let renderedText = Self.taggedText(timedPieces)
                // Unthrottled `.animation` locks 1:1 to CADisplayLink VSync (60/120 Hz) without beat-frequency drops
                TimelineView(.animation(paused: isPaused)) { context in
                    let elapsed = musicManager.smoothedPlaybackPosition(at: context.date)
                    let settle = Self.settleProgress(isActive: isActive, deactivatedAt: deactivatedAt, now: context.date)
                    renderedText
                        .font(.system(size: fontSize, weight: .bold))
                        .textRenderer(KaraokeGlyphRenderer(
                            pieces: pieces,
                            elapsed: elapsed,
                            isActive: isActive,
                            settle: settle,
                            restOpacity: restOpacity,
                            fontSize: fontSize,
                            animateLetters: animateLetters
                        ))
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
                    let elapsed = musicManager.smoothedPlaybackPosition(at: context.date)
                    let settle = Self.settleProgress(isActive: isActive, deactivatedAt: deactivatedAt, now: context.date)
                    if !isActive && settle >= 0.999 {
                        Text(verbatim: text)
                            .foregroundColor(.white.opacity(restOpacity))
                            .font(.system(size: fontSize, weight: .bold))
                    } else {
                        (words.isEmpty ? estimatedText(at: elapsed, settle: settle) : timedText(at: elapsed, settle: settle))
                            .font(.system(size: fontSize, weight: .bold))
                    }
                }
            }
        }
        .task(id: deactivatedAt) {
            guard !isActive, let deactivatedAt else {
                isSettling = false
                return
            }
            let remaining = LockScreenFullLyricsView.settleDuration + 0.05 - Date().timeIntervalSince(deactivatedAt)
            guard remaining > 0 else {
                isSettling = false
                return
            }
            isSettling = true
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled {
                isSettling = false
            }
        }
    }

    private static func settleProgress(isActive: Bool, deactivatedAt: Date?, now: Date) -> Double {
        if isActive { return 0 }
        guard let deactivatedAt else { return 1 }
        let t = min(1, max(0, now.timeIntervalSince(deactivatedAt) / LockScreenFullLyricsView.settleDuration))
        return t * t * (3 - 2 * t)
    }

    /// Every word or syllable tagged with its index, with spaces outside the tag so trailing spaces never
    /// consume sweep width or syllable duration
    @available(macOS 15.0, *)
    private static func taggedText(_ pieces: [TimedLyricWord]) -> Text {
        pieces.indices.reduce(Text(verbatim: "")) { result, index in
            let wordText = Text(verbatim: pieces[index].text)
                .customAttribute(KaraokeWordAttribute(index: index))
            let space = pieces[index].followedBySpace && index < pieces.count - 1
                ? Text(verbatim: " ")
                : Text(verbatim: "")
            return result + wordText + space
        }
    }

    /// The words of a line timed only as a whole, spread like `estimatedText`
    private var estimatedWords: [TimedLyricWord] {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return [] }
        let sungDuration = Self.sungDuration(text: text, gap: end - start)
        let weights = parts.map { Double($0.count) + 1.5 }
        let total = weights.reduce(0, +)
        var cursor = start
        return parts.enumerated().map { index, part in
            let duration = sungDuration * weights[index] / total
            defer { cursor += duration }
            return TimedLyricWord(begin: cursor, end: cursor + duration, text: part, followedBySpace: true)
        }
    }

    /// How much a word or syllable swells, from how long it is sung: barely for a quick one, fully from
    /// about 1.8 s, like Apple Music
    private static func emphasis(of word: TimedLyricWord) -> Double {
        let t = min(1, max(0, (word.end - word.begin - 0.35) / 1.45))
        return t * t * (3 - 2 * t)
    }

    /// Each word or syllable lights up over its exact time (macOS 14 fallback)
    private func timedText(at elapsed: Double, settle: Double) -> Text {
        var result = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            let progress = min(1, max(0, (elapsed - word.begin) / max(0.05, word.end - word.begin)))
            let activeAlpha = 0.38 + 0.62 * progress
            let opacity = activeAlpha + (restOpacity - activeAlpha) * settle
            let spacer = word.followedBySpace && index < words.count - 1 ? " " : ""
            result = result + Text(verbatim: word.text + spacer)
                .foregroundColor(.white.opacity(opacity))
        }
        return result
    }

    /// Most LRCLIB entries only time whole lines, so the line is spread over its words, weighted by their length, to
    /// estimate when each one is sung. A line is usually sung faster than the gap before the next one.
    private func estimatedText(at elapsed: Double, settle: Double) -> Text {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else {
            let opacity = 1 + (restOpacity - 1) * settle
            return Text(verbatim: text).foregroundColor(.white.opacity(opacity))
        }
        let sungDuration = Self.sungDuration(text: text, gap: end - start)
        let weights = words.map { Double($0.count) + 1.5 }
        let total = weights.reduce(0, +)

        var cursor = start
        var result = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            let wordDuration = sungDuration * weights[index] / total
            let progress = min(1, max(0, (elapsed - cursor) / max(0.08, wordDuration)))
            let activeAlpha = 0.38 + 0.62 * progress
            let opacity = activeAlpha + (restOpacity - activeAlpha) * settle
            let piece = Text(verbatim: index == 0 ? word : " " + word)
                .foregroundColor(.white.opacity(opacity))
            result = result + piece
            cursor += wordDuration
        }
        return result
    }

    /// Estimated time to sing a line: about 0.11 s per character, never more than most of the gap
    static func sungDuration(text: String, gap: Double) -> Double {
        min(max(0.4, gap) * 0.9, max(1.0, Double(text.count) * 0.11))
    }
}

@available(macOS 15.0, *)
private struct KaraokeWordAttribute: TextAttribute {
    let index: Int
}

/// Draws the active line in the style of Apple Music:
/// - `.disablesSubpixelQuantization` on every glyph draw bypasses CoreText integer pixel snapping so slow
///   vertical floats and scales move smoothly between Retina subpixels without shimmering or trembling.
/// - Single-pass horizontal `LinearGradient` mask (`.destinationIn`) inside a fixed, integer-aligned layer
///   bounds eliminates dual-pass subpixel misregistration and moving-layer origin jitter.
/// - Held syllables fan out proportionally from the word center (`xOffset`)
///   so swollen letters preserve their relative kerning instead of colliding.
@available(macOS 15.0, *)
private struct KaraokeGlyphRenderer: TextRenderer {
    let pieces: [LockScreenKaraokeLine.Piece]
    let elapsed: Double
    let isActive: Bool
    let settle: Double
    let restOpacity: Double
    let fontSize: CGFloat
    let animateLetters: Bool

    private static let baseDimOpacity: Double = 0.38
    private static let liftTau: Double = 0.11
    private static let swellAttackTau: Double = 0.105
    private static let swellReleaseTau: Double = 0.12

    private struct PreparedGlyph {
        let slice: Text.Layout.RunSlice
        let bounds: CGRect
        let rise: CGFloat
        let scale: CGFloat
        let held: Double
    }

    private struct SyllableSegment {
        let begin: Double
        let end: Double
        var minX: CGFloat
        var maxX: CGFloat
    }

    /// Room for the lifted letters and their glow
    var displayPadding: EdgeInsets {
        let padding = fontSize * 0.6
        return EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if !isActive && settle >= 0.999 {
            var resting = context
            resting.opacity = restOpacity
            for line in layout {
                for run in line {
                    resting.draw(run, options: .disablesSubpixelQuantization)
                }
            }
            return
        }

        var totalGlyphs = Array(repeating: 0, count: pieces.count)
        for line in layout {
            for run in line {
                if let index = run[KaraokeWordAttribute.self]?.index, totalGlyphs.indices.contains(index) {
                    totalGlyphs[index] += run.count
                }
            }
        }

        let settleFactor = 1 - settle
        let dimOpacity = Self.baseDimOpacity + (restOpacity - Self.baseDimOpacity) * settle
        let litOpacity = 1 + (restOpacity - 1) * settle

        var seenGlyphs = Array(repeating: 0, count: pieces.count)

        for line in layout {
            var clusterRuns: [(index: Int, run: Text.Layout.Run)] = []

            for run in line {
                guard let index = run[KaraokeWordAttribute.self]?.index, pieces.indices.contains(index) else {
                    if !clusterRuns.isEmpty {
                        drawCluster(clusterRuns, totalGlyphs: totalGlyphs, seenGlyphs: &seenGlyphs,
                                    settleFactor: settleFactor, dimOpacity: dimOpacity, litOpacity: litOpacity,
                                    in: &context)
                        clusterRuns.removeAll(keepingCapacity: true)
                    }
                    var spaceCtx = context
                    spaceCtx.opacity = dimOpacity
                    spaceCtx.draw(run, options: .disablesSubpixelQuantization)
                    continue
                }

                if let last = clusterRuns.last {
                    let continuesSamePiece = index == last.index
                    let continuesMultiSyllableWord = index == last.index + 1 && !pieces[last.index].followedBySpace
                    if !continuesSamePiece && !continuesMultiSyllableWord {
                        drawCluster(clusterRuns, totalGlyphs: totalGlyphs, seenGlyphs: &seenGlyphs,
                                    settleFactor: settleFactor, dimOpacity: dimOpacity, litOpacity: litOpacity,
                                    in: &context)
                        clusterRuns.removeAll(keepingCapacity: true)
                    }
                }
                clusterRuns.append((index, run))
            }

            if !clusterRuns.isEmpty {
                drawCluster(clusterRuns, totalGlyphs: totalGlyphs, seenGlyphs: &seenGlyphs,
                            settleFactor: settleFactor, dimOpacity: dimOpacity, litOpacity: litOpacity,
                            in: &context)
            }
        }
    }

    private func drawCluster(
        _ runs: [(index: Int, run: Text.Layout.Run)],
        totalGlyphs: [Int],
        seenGlyphs: inout [Int],
        settleFactor: Double,
        dimOpacity: Double,
        litOpacity: Double,
        in context: inout GraphicsContext
    ) {
        var glyphs: [PreparedGlyph] = []
        var segments: [SyllableSegment] = []
        var currentSegIndex: Int?
        var currentSegStartOffset = 0
        var currentSegCount = 0
        var currentSegMinX: CGFloat = .infinity
        var currentSegMaxX: CGFloat = -.infinity
        var staticMinY: CGFloat = .infinity
        var staticMaxY: CGFloat = -.infinity
        var maxHeld: Double = 0
        var maxRise: CGFloat = 0

        func flushSegment() {
            guard let idx = currentSegIndex, currentSegCount > 0 else { return }
            let piece = pieces[idx]
            let total = Double(max(1, totalGlyphs[idx]))
            let duration = max(0.02, piece.end - piece.begin)
            let segBegin = piece.begin + (Double(currentSegStartOffset) / total) * duration
            let segEnd = piece.begin + (Double(currentSegStartOffset + currentSegCount) / total) * duration
            segments.append(SyllableSegment(
                begin: segBegin,
                end: max(segBegin + 0.01, segEnd),
                minX: currentSegMinX,
                maxX: max(currentSegMinX + 0.5, currentSegMaxX)
            ))
        }

        for (index, run) in runs {
            if currentSegIndex != index {
                flushSegment()
                currentSegIndex = index
                currentSegStartOffset = seenGlyphs[index]
                currentSegCount = 0
                currentSegMinX = .infinity
                currentSegMaxX = -.infinity
            }

            let piece = pieces[index]
            let count = Double(max(1, totalGlyphs[index]))
            let duration = max(0.02, piece.end - piece.begin)

            for slice in run {
                let position = Double(seenGlyphs[index])
                seenGlyphs[index] += 1
                currentSegCount += 1

                let bounds = slice.typographicBounds.rect
                currentSegMinX = min(currentSegMinX, bounds.minX)
                currentSegMaxX = max(currentSegMaxX, bounds.maxX)
                staticMinY = min(staticMinY, bounds.minY)
                staticMaxY = max(staticMaxY, bounds.maxY)

                let fraction = position / count
                let glyphStart = piece.begin + fraction * duration
                let raised = animateLetters
                    ? Self.criticallyDamped(elapsed - glyphStart, tau: Self.liftTau) * settleFactor
                    : 0

                let held: Double
                if animateLetters, piece.emphasis > 0, elapsed > glyphStart {
                    let attack = Self.criticallyDamped(elapsed - glyphStart, tau: Self.swellAttackTau)
                    let releaseStart = max(glyphStart + 0.22, piece.end - 0.16 + 0.12 * fraction)
                    let release = 1 - Self.criticallyDamped(elapsed - releaseStart, tau: Self.swellReleaseTau)
                    held = piece.emphasis * attack * release * settleFactor
                } else {
                    held = 0
                }

                if held > maxHeld { maxHeld = held }
                let rise = fontSize * CGFloat(0.048 * raised + 0.075 * held)
                if rise > maxRise { maxRise = rise }
                let scale = 1 + CGFloat(0.085 * held)
                glyphs.append(PreparedGlyph(slice: slice, bounds: bounds, rise: rise, scale: scale, held: held))
            }
        }
        flushSegment()

        guard !glyphs.isEmpty, !segments.isEmpty else { return }

        // Join adjacent syllable bounds seamlessly so a multi-syllable word sweeps with zero gap
        if segments.count > 1 {
            for i in 0..<(segments.count - 1) {
                let join = 0.5 * (segments[i].maxX + segments[i + 1].minX)
                segments[i].maxX = join
                segments[i + 1].minX = join
            }
        }

        let clusterMinX = segments[0].minX
        let clusterMaxX = max(clusterMinX + 1, segments[segments.count - 1].maxX)
        let clusterMidX = 0.5 * (clusterMinX + clusterMaxX)
        let sweep = Self.sweepFraction(elapsed: elapsed, segments: segments, minX: clusterMinX, maxX: clusterMaxX)

        // Unsung word: draw directly with subpixel quantization disabled so ignition never shifts alignment
        if sweep <= 0, maxHeld <= 0.002, maxRise <= 0.002 {
            var dimmed = context
            dimmed.opacity = dimOpacity
            for (_, run) in runs {
                dimmed.draw(run, options: .disablesSubpixelQuantization)
            }
            return
        }

        // Single per-word glow pass when a held syllable is active
        if maxHeld > 0.012 {
            var glowContext = context
            glowContext.addFilter(.shadow(
                color: .white.opacity(0.55 * maxHeld),
                radius: fontSize * 0.28 * CGFloat(maxHeld),
                x: 0,
                y: 0,
                options: .shadowOnly
            ))
            glowContext.drawLayer { glowLayer in
                for glyph in glyphs where glyph.held > 0.008 {
                    var sliceCtx = glowLayer
                    sliceCtx.opacity = min(1, glyph.held / maxHeld)
                    Self.drawTransformed(glyph, clusterMidX: clusterMidX, in: &sliceCtx)
                }
            }
        }

        // Fully sung word (or settling after completion): single subpixel-smooth pass
        if sweep >= 1 || abs(litOpacity - dimOpacity) < 0.002 {
            for glyph in glyphs {
                var sliceCtx = context
                sliceCtx.opacity = litOpacity
                Self.drawTransformed(glyph, clusterMidX: clusterMidX, in: &sliceCtx)
            }
            return
        }

        // Active sweep: single-pass glyph draw inside a fixed integer-aligned layer, modulated by a
        // continuous horizontal `.destinationIn` gradient from `litOpacity` to `dimOpacity`.
        let width = clusterMaxX - clusterMinX
        let feather = max(fontSize * 0.6, min(fontSize * 1.35, width * 0.52))
        let edgeStart = (clusterMinX - feather) + CGFloat(sweep) * (width + feather)
        let edgeEnd = edgeStart + feather

        let padX = ceil(feather + fontSize * 0.5)
        let padY = ceil(fontSize * 0.9)
        let staticMaskRect = CGRect(
            x: floor(clusterMinX - padX),
            y: floor(staticMinY - padY),
            width: max(1, ceil(width + 2 * padX)),
            height: max(1, ceil((staticMaxY - staticMinY) + 2 * padY))
        )
        let s0 = max(0, min(1, Double((edgeStart - staticMaskRect.minX) / staticMaskRect.width)))
        let s1 = max(s0, min(1, Double((edgeEnd - staticMaskRect.minX) / staticMaskRect.width)))
        let midA = dimOpacity + (litOpacity - dimOpacity) * 0.74
        let midB = dimOpacity + (litOpacity - dimOpacity) * 0.26

        context.drawLayer { layer in
            for glyph in glyphs {
                var sliceCtx = layer
                Self.drawTransformed(glyph, clusterMidX: clusterMidX, in: &sliceCtx)
            }
            var mask = layer
            mask.blendMode = .destinationIn
            mask.fill(
                Path(staticMaskRect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(litOpacity), location: s0),
                        .init(color: .white.opacity(midA), location: s0 + (s1 - s0) * 0.33),
                        .init(color: .white.opacity(midB), location: s0 + (s1 - s0) * 0.67),
                        .init(color: .white.opacity(dimOpacity), location: s1)
                    ]),
                    startPoint: CGPoint(x: staticMaskRect.minX, y: staticMaskRect.midY),
                    endPoint: CGPoint(x: staticMaskRect.maxX, y: staticMaskRect.midY)
                )
            )
        }
    }

    private static func drawTransformed(
        _ glyph: PreparedGlyph,
        clusterMidX: CGFloat,
        in context: inout GraphicsContext
    ) {
        if glyph.rise > 0.002 || glyph.scale > 1.0005 {
            // Fan letters out proportionally from the word center on swell
            let xOffset = (glyph.bounds.midX - clusterMidX) * (glyph.scale - 1)
            context.translateBy(x: glyph.bounds.midX + xOffset, y: glyph.bounds.maxY - glyph.rise)
            context.scaleBy(x: glyph.scale, y: glyph.scale)
            context.translateBy(x: -glyph.bounds.midX, y: -glyph.bounds.maxY)
        }
        context.draw(glyph.slice, options: .disablesSubpixelQuantization)
    }

    private static func sweepFraction(
        elapsed: Double,
        segments: [SyllableSegment],
        minX: CGFloat,
        maxX: CGFloat
    ) -> Double {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if elapsed <= first.begin { return 0 }
        if elapsed >= last.end { return 1 }

        var cursorX = last.maxX
        for segment in segments {
            if elapsed < segment.begin {
                cursorX = segment.minX
                break
            }
            if elapsed <= segment.end {
                let p = (elapsed - segment.begin) / max(0.01, segment.end - segment.begin)
                cursorX = segment.minX + CGFloat(p) * (segment.maxX - segment.minX)
                break
            }
        }
        return min(1, max(0, Double((cursorX - minX) / max(1, maxX - minX))))
    }

    /// Pure C-infinity critically damped spring (`damping = 1.0`, `f(0) = 0`, `f'(0) = 0`, no piecewise splice)
    private static func criticallyDamped(_ dt: Double, tau: Double) -> Double {
        guard dt > 0 else { return 0 }
        let u = dt / tau
        if u >= 12 { return 1 }
        return 1 - (1 + u) * exp(-u)
    }
}

/// Apple Music's instrumental dots: they light up one after the other over the break, breathe, and shrink
/// away just before the next line.
private struct LockScreenInterludeDots: View {
    @ObservedObject private var musicManager = MusicManager.shared
    let start: Double
    let end: Double
    let isActive: Bool

    private static let dotSize: CGFloat = 15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || !musicManager.isPlaying)) { context in
            let elapsed = musicManager.smoothedPlaybackPosition(at: context.date)
            let progress = min(1, max(0, (elapsed - start) / max(0.5, end - start)))
            let exit = min(1, max(0, (end - elapsed) / 0.45))
            let breathe = 1 + 0.07 * sin(context.date.timeIntervalSinceReferenceDate * 2.6)

            HStack(spacing: Self.dotSize * 0.6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(0.3 + 0.7 * min(1, max(0, progress * 3 - Double(index)))))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                }
            }
            .scaleEffect(breathe * (0.6 + 0.4 * exit), anchor: .leading)
            .opacity(exit)
        }
    }
}

/// Finds the looping "motion artwork" video Apple Music publishes for some albums, plus a high resolution cover.
/// Lookup runs for every track shown on the lock screen player: iTunes Search API to find the album page,
/// then the HLS playlist is read from the public album page and the best variant (a single MP4) is cached on disk,
/// because streaming the playlist directly stalls and never starts.
@MainActor
final class AnimatedArtworkService: ObservableObject {
    static let shared = AnimatedArtworkService()

    @Published private var videoURLs: [String: URL] = [:]
    /// Tracks of one album share its animated cover, so the next track gets it without waiting for a lookup
    private var albumVideoURLs: [String: URL] = [:]
    @Published private var stillImages: [String: NSImage] = [:]
    /// Lookups in progress. They belong to the service, not to the lock screen view: unlocking mid download
    /// no longer cancels it, and the next lock finds the video ready.
    private var inFlight: [String: Task<LookupOutcome, Never>] = [:]
    /// Only the current track keeps retrying in the background: skipping stops the previous one's retries
    private var prefetchTask: Task<Void, Never>?
    /// Tracks whose album was looked up successfully and has no animated cover, so they are not searched
    /// again on every lock (a network failure is never recorded here)
    private var withoutMotionArtwork: Set<String> = []
    /// Downloaded videos per track and album key, kept on disk so they show at once after a relaunch
    private var diskIndex: [String: String] = [:]
    /// High resolution cover found with the video, shown under it until its first frame
    private var artworkURLs: [String: URL] = [:]

    private struct Candidate {
        let pageURL: URL
        let artworkURL: URL?
        let albumMatches: Bool
    }

    private enum LookupOutcome {
        case found(URL, artworkURL: URL?)
        case none
        case failed
    }

    private enum PlaylistResult {
        case playlist(URL)
        case noMotionArtwork
        case failed
    }

    private init() {
        loadDiskIndex()
    }

    static func trackKey(title: String, artist: String, album: String) -> String {
        "\(title)|\(artist)|\(album)"
    }

    static func albumKey(artist: String, album: String) -> String? {
        album.isEmpty ? nil : "\(artist)|\(album)"
    }

    /// A file the cache deleted is never handed to the player: it would show a frozen, unblurred low
    /// resolution cover instead of the video
    func videoURL(for key: String, albumKey: String?) -> URL? {
        [videoURLs[key], albumKey.flatMap { albumVideoURLs[$0] }]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func stillImage(for key: String) -> NSImage? {
        stillImages[key]
    }

    /// Called when a track starts: finds and downloads its animated cover in the background, so it is
    /// already there when the Mac locks. Only when the lock screen shows the animated artwork.
    func prefetch(title: String, artist: String, album: String) {
        prefetchTask?.cancel()
        prefetchTask = nil
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard Defaults[.showOnLockScreen], Defaults[.lockScreenMediaPlayer], Defaults[.lockScreenAnimatedArtwork],
              !["", "Not Playing", "Unknown", "I'm Handsome"].contains(trimmed) else { return }
        let key = Self.trackKey(title: title, artist: artist, album: album)
        let albumKey = Self.albumKey(artist: artist, album: album)
        guard videoURL(for: key, albumKey: albumKey) == nil, !withoutMotionArtwork.contains(key) else { return }
        prefetchTask = Task { [weak self] in
            await self?.lookUpWithRetries(title: title, artist: artist, album: album, key: key, albumKey: albumKey)
        }
    }

    func load(
        title: String,
        artist: String,
        album: String,
        key: String,
        albumKey: String?,
        fallbackCover: NSImage,
        isAppleMusic: Bool
    ) async {
        guard !title.isEmpty else { return }
        if videoURL(for: key, albumKey: albumKey) == nil {
            guard !withoutMotionArtwork.contains(key) else { return }
            await lookUpWithRetries(title: title, artist: artist, album: album, key: key, albumKey: albumKey)
        }
        guard let videoFile = videoURL(for: key, albumKey: albumKey) else { return }
        // Shown again: moves it to the front of the cache so skipping through other tracks keeps it
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: videoFile.path)
        guard stillImages[key] == nil else { return }
        await prepareCover(key: key, artworkURL: artworkURLs[key], fallbackCover: fallbackCover, isAppleMusic: isAppleMusic)
    }

    /// A failed lookup (network hiccup, slow connection) is tried again after 8, 16, 32 then 64 s, as long
    /// as the caller still wants it, instead of waiting for the next track.
    private func lookUpWithRetries(title: String, artist: String, album: String, key: String, albumKey: String?) async {
        var delay: Double = 8
        for _ in 0..<5 {
            let task: Task<LookupOutcome, Never>
            if let running = inFlight[key] {
                task = running
            } else {
                task = Task { await Self.lookUp(title: title, artist: artist, album: album) }
                inFlight[key] = task
            }
            let outcome = await task.value
            inFlight[key] = nil

            switch outcome {
            case .found(let videoFile, let artworkURL):
                if let albumKey { albumVideoURLs[albumKey] = videoFile }
                videoURLs[key] = videoFile
                artworkURLs[key] = artworkURL
                pruneCache(keeping: 20, protecting: videoFile)
                rememberOnDisk(videoFile, keys: [key, albumKey].compactMap { $0 })
                return
            case .none:
                withoutMotionArtwork.insert(key)
                return
            case .failed:
                if Task.isCancelled || videoURL(for: key, albumKey: albumKey) != nil { return }
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                delay *= 2
            }
        }
    }

    nonisolated private static func lookUp(title: String, artist: String, album: String) async -> LookupOutcome {
        guard var candidates = await searchCandidates(title: title, artist: artist, album: album) else { return .failed }
        var usedWebAlbum = false
        var networkFailed = false
        if !candidates.contains(where: { $0.albumMatches }),
           let webAlbum = await AppleMusicWebCatalog.shared.album(title: title, album: album) {
            candidates.insert(Candidate(pageURL: webAlbum.pageURL, artworkURL: webAlbum.artworkURL, albumMatches: true), at: 0)
            usedWebAlbum = true
        }

        for candidate in candidates.prefix(3) {
            switch await motionPlaylistURL(pageURL: candidate.pageURL) {
            case .playlist(let playlistURL):
                guard let videoFile = await cachedVideoFile(masterPlaylistURL: playlistURL) else { return .failed }
                return .found(videoFile, artworkURL: candidates.first(where: { $0.albumMatches })?.artworkURL)
            case .failed:
                networkFailed = true
            case .noMotionArtwork:
                continue
            }
        }
        // The iTunes search can return another edition of the album (clean instead of explicit) that has
        // no motion artwork, so give the edition listed by the Apple Music web catalog a chance too.
        if !usedWebAlbum, let webAlbum = await AppleMusicWebCatalog.shared.album(title: title, album: album) {
            switch await motionPlaylistURL(pageURL: webAlbum.pageURL) {
            case .playlist(let playlistURL):
                guard let videoFile = await cachedVideoFile(masterPlaylistURL: playlistURL) else { return .failed }
                return .found(videoFile, artworkURL: webAlbum.artworkURL)
            case .failed:
                networkFailed = true
            case .noMotionArtwork:
                break
            }
        }
        return networkFailed ? .failed : .none
    }

    // MARK: Disk index

    private static var indexURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GravityNotch/MotionArtwork/index.json")
    }

    private func loadDiskIndex() {
        guard let url = Self.indexURL,
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        let folder = url.deletingLastPathComponent()
        for (key, fileName) in index {
            let file = folder.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            diskIndex[key] = fileName
            // Keys holding one "|" are album keys, track keys hold two
            if key.filter({ $0 == "|" }).count == 1 {
                albumVideoURLs[key] = file
            } else {
                videoURLs[key] = file
            }
        }
    }

    private func rememberOnDisk(_ videoFile: URL, keys: [String]) {
        guard let url = Self.indexURL else { return }
        let folder = url.deletingLastPathComponent()
        for key in keys { diskIndex[key] = videoFile.lastPathComponent }
        // Forget videos the cache pruned
        diskIndex = diskIndex.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.value).path) }
        if let data = try? JSONEncoder().encode(diskIndex) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Cover

    /// High resolution still shown under the video until its first frame is ready
    private func prepareCover(key: String, artworkURL: URL?, fallbackCover: NSImage, isAppleMusic: Bool) async {
        var cover: NSImage?
        if let artworkURL {
            cover = await Self.fetchImage(artworkURL)
        }
        if cover == nil {
            let fallbackData = fallbackCover.tiffRepresentation
            cover = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let musicData = isAppleMusic ? Self.currentMusicArtworkData() : nil
                return Self.upscaledCover(from: musicData) ?? Self.upscaledCover(from: fallbackData)
            }.value
        }
        // Skipped meanwhile: replacing the cache would drop the cover of the track now shown
        guard !Task.isCancelled else { return }
        if let cover {
            withAnimation(.easeInOut(duration: 0.4)) {
                // Keep a single decoded cover in memory
                stillImages = [key: cover]
            }
        }
    }

    /// nil when the search could not be done (network), an empty list when it found nothing
    nonisolated private static func searchCandidates(title: String, artist: String, album: String) async -> [Candidate]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier.lowercased() ?? "us")
        ]
        guard
            let searchURL = components?.url,
            let (data, response) = try? await URLSession.shared.data(from: searchURL),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let results = json["results"] as? [[String: Any]] else { return [] }

        let wantedTitle = simplified(title)
        let wantedAlbum = simplified(album)
        var seenCollections: Set<Int> = []
        var matching: [Candidate] = []
        var others: [Candidate] = []

        for result in results {
            let trackTitle = simplified(result["trackName"] as? String ?? "")
            guard !trackTitle.isEmpty, trackTitle.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(trackTitle) else { continue }
            guard
                let collectionID = result["collectionId"] as? Int,
                seenCollections.insert(collectionID).inserted,
                let pageString = result["collectionViewUrl"] as? String,
                let pageURL = URL(string: pageString)
            else { continue }

            let collection = simplified(result["collectionName"] as? String ?? "")
            let albumMatches = wantedAlbum.isEmpty || collection == wantedAlbum
                || collection.hasPrefix(wantedAlbum) || wantedAlbum.hasPrefix(collection)
            let artworkURL = (result["artworkUrl100"] as? String)
                .map { $0.replacingOccurrences(of: "100x100bb", with: "2000x2000bb") }
                .flatMap { URL(string: $0) }
            let candidate = Candidate(pageURL: pageURL, artworkURL: artworkURL, albumMatches: albumMatches)
            if albumMatches { matching.append(candidate) } else { others.append(candidate) }
        }
        return matching + others
    }

    nonisolated private static func motionPlaylistURL(pageURL: URL) async -> PlaylistResult {
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let html = String(data: data, encoding: .utf8)
        else { return .failed }

        for marker in ["\"motionDetailSquare\"", "\"motionDetailTall\""] {
            guard let markerRange = html.range(of: marker) else { continue }
            let tail = html[markerRange.upperBound...]
            if let match = tail.range(of: #"https://[^"\\]+?\.m3u8"#, options: .regularExpression),
               let url = URL(string: String(tail[match])) {
                return .playlist(url)
            }
        }
        return .noMotionArtwork
    }

    /// Picks the sharpest SDR variant (up to 2160p, around 9 Mbps) and downloads its MP4 into the caches folder.
    nonisolated private static func cachedVideoFile(masterPlaylistURL: URL) async -> URL? {
        guard
            let (masterData, _) = try? await URLSession.shared.data(from: masterPlaylistURL),
            let master = String(data: masterData, encoding: .utf8)
        else { return nil }

        var variants: [(height: Int, bandwidth: Int, url: URL)] = []
        let lines = master.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard
                !line.contains("VIDEO-RANGE=PQ"), !line.contains("VIDEO-RANGE=HLG"),
                index + 1 < lines.count,
                let url = URL(string: lines[index + 1].trimmingCharacters(in: .whitespaces), relativeTo: masterPlaylistURL),
                let height = firstInt(in: line, pattern: #"RESOLUTION=\d+x(\d+)"#),
                let bandwidth = firstInt(in: line, pattern: #"AVERAGE-BANDWIDTH=(\d+)"#)
            else { continue }
            variants.append((height, bandwidth, url))
        }
        let usable = variants.filter { $0.height <= 2160 }
        guard let bestHeight = usable.map(\.height).max() else { return nil }
        let targetBandwidth = 9_000_000
        guard let variant = usable
            .filter({ $0.height == bestHeight })
            .min(by: { abs($0.bandwidth - targetBandwidth) < abs($1.bandwidth - targetBandwidth) })
        else { return nil }

        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = cachesURL.appendingPathComponent("GravityNotch/MotionArtwork", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let assetID = masterPlaylistURL.deletingLastPathComponent().lastPathComponent
        let destination = folder.appendingPathComponent("\(assetID)-\(masterPlaylistURL.deletingPathExtension().lastPathComponent)-\(bestHeight).mp4")
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }

        guard
            let (variantData, _) = try? await URLSession.shared.data(from: variant.url),
            let playlist = String(data: variantData, encoding: .utf8),
            let mapRange = playlist.range(of: #"#EXT-X-MAP:URI="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let mapLine = String(playlist[mapRange])
        let fileName = mapLine
            .replacingOccurrences(of: "#EXT-X-MAP:URI=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        // The whole loop must live in that single file, otherwise a plain download would be incomplete
        let segmentFiles = Set(
            playlist.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
        guard segmentFiles == [fileName], let fileURL = URL(string: fileName, relativeTo: variant.url) else { return nil }

        guard
            let (temporaryURL, response) = try? await URLSession.shared.download(from: fileURL),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            // Two tracks of the same album downloaded it at the same time: the other copy is just as good
            guard fileManager.fileExists(atPath: destination.path) else { return nil }
        }
        return destination
    }

    /// Deletes the least recently used videos and forgets them in memory too: a track whose video was
    /// pruned is looked up and downloaded again instead of pointing the player at a missing file.
    private func pruneCache(keeping limit: Int, protecting kept: URL) {
        guard let folder = Self.indexURL?.deletingLastPathComponent() else { return }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let videos = files
            .filter { $0.pathExtension == "mp4" }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        var removed: Set<String> = []
        for file in videos.dropFirst(limit) where file.lastPathComponent != kept.lastPathComponent {
            if (try? fileManager.removeItem(at: file)) != nil {
                removed.insert(file.lastPathComponent)
            }
        }
        guard !removed.isEmpty else { return }
        videoURLs = videoURLs.filter { !removed.contains($0.value.lastPathComponent) }
        albumVideoURLs = albumVideoURLs.filter { !removed.contains($0.value.lastPathComponent) }
    }

    /// Original artwork file of the track playing in Music (usually sharper than what MediaRemote reports).
    nonisolated private static func currentMusicArtworkData() -> Data? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gravitynotch-artwork-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let script = """
        tell application "Music"
            if it is running then
                set artData to raw data of artwork 1 of current track
                set fileRef to open for access POSIX file "\(fileURL.path)" with write permission
                set eof fileRef to 0
                write artData to fileRef
                close access fileRef
            end if
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    /// Lanczos upscale to about 2400 px with a light sharpen, so a small cover stays clean when it fills the screen.
    nonisolated private static func upscaledCover(from data: Data?) -> NSImage? {
        guard let data, let input = CIImage(data: data), input.extent.width > 0 else { return nil }
        let targetWidth: CGFloat = 2400
        var output = input
        if input.extent.width < targetWidth {
            output = output.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: targetWidth / input.extent.width, kCIInputAspectRatioKey: 1.0]
            )
            output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func fetchImage(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    nonisolated private static func firstInt(in text: String, pattern: String) -> Int? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    /// Lowercased name without "(feat. X)", "[From Y]" or " - Single" style suffixes.
    nonisolated private static func simplified(_ value: String) -> String {
        var text = value.lowercased()
        for separator in [" (", " [", " - "] {
            if let range = text.range(of: separator) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LoopingArtworkVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingArtworkVideoNSView {
        LoopingArtworkVideoNSView(url: url)
    }

    func updateNSView(_ nsView: LoopingArtworkVideoNSView, context: Context) {}

    static func dismantleNSView(_ nsView: LoopingArtworkVideoNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class LoopingArtworkVideoNSView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()

        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        // Stay invisible until the first frame is decoded so the static cover shows through meanwhile
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.6)
                layer.opacity = 1
                CATransaction.commit()
            }
        }

        player.play()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func stop() {
        readyObservation = nil
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }
}

// MARK: - Agent Pixel Mascots & Progress Animations

/// Small animated pixel character shown next to an agent: walks while the agent works,
/// waves when the agent is done and waiting, sleeps when the session is inactive.
struct AgentPixelMascot: View {
    let kind: AgentKind
    let isWorking: Bool
    let isActive: Bool
    var pixel: CGFloat = 2

    private static let columns = 11
    private static let rows = 8

    private struct Sprite {
        let base: [String]
        let step: [String]
        let wave: [String]
    }

    // '#' body, '+' highlight, 'o' eye, '.' empty
    private static let critter = Sprite(
        base: [
            "...#####...",
            "..#######..",
            "..#o###o#..",
            "###########",
            "###########",
            "..#######..",
            "..#.#.#.#..",
            "..#.#.#.#.."
        ],
        step: [
            "...#####...",
            "..#######..",
            "..#o###o#..",
            "###########",
            "###########",
            "..#######..",
            "..#.#.#.#..",
            "..........."
        ],
        wave: [
            "...#####..#",
            "..#######.#",
            "..#o###o###",
            "#########..",
            "#########..",
            "..#######..",
            "..#.#.#.#..",
            "..#.#.#.#.."
        ]
    )

    private static let cloud = Sprite(
        base: [
            "....###....",
            "..#######..",
            ".#########.",
            "##o#####o##",
            "###########",
            ".#########.",
            "....+...+..",
            "..+...+...."
        ],
        step: [
            "....###....",
            "..#######..",
            ".#########.",
            "##o#####o##",
            "###########",
            ".#########.",
            "..+...+....",
            "....+...+.."
        ],
        wave: [
            "....###...+",
            "..#######.+",
            ".#########+",
            "##o#####o##",
            "###########",
            ".#########.",
            "...........",
            "..........."
        ]
    )

    private static let robot = Sprite(
        base: [
            ".....+.....",
            ".....#.....",
            ".#########.",
            ".#o#####o#.",
            ".#########.",
            ".##+++++##.",
            ".#########.",
            "..##...##.."
        ],
        step: [
            "...........",
            ".....#.....",
            ".#########.",
            ".#o#####o#.",
            ".#########.",
            ".###+++###.",
            ".#########.",
            "..##...##.."
        ],
        wave: [
            ".....+....+",
            ".....#....+",
            ".#########+",
            ".#o#####o#.",
            ".#########.",
            ".##+++++##.",
            ".#########.",
            "..##...##.."
        ]
    )

    private var sprite: Sprite {
        switch kind {
        case .claudeCode: return Self.critter
        case .antigravity: return Self.cloud
        case .codex: return Self.robot
        }
    }

    private var frameInterval: Double {
        isWorking ? 0.22 : 0.48
    }

    var body: some View {
        Group {
            if isActive {
                TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                    canvas(tick: Int(context.date.timeIntervalSinceReferenceDate / frameInterval))
                }
            } else {
                canvas(tick: nil)
            }
        }
        .frame(width: CGFloat(Self.columns) * pixel, height: CGFloat(Self.rows + 1) * pixel)
        .opacity(isActive ? 1 : 0.5)
        .accessibilityHidden(true)
    }

    private func canvas(tick: Int?) -> some View {
        let bodyColor = isActive ? kind.accentColor : Color.gray
        let highlight = isActive ? kind.secondaryAccentColor : Color.gray.opacity(0.7)
        let odd = (tick ?? 0) % 2 == 1

        let grid: [String]
        if tick == nil {
            grid = sprite.base
        } else if isWorking {
            grid = odd ? sprite.step : sprite.base
        } else {
            // Done and waiting for the user: wave hello
            grid = odd ? sprite.wave : sprite.base
        }
        let eyesClosed = tick == nil || ((tick ?? 0) % 14 == 0)
        let bob: CGFloat = (isWorking && odd) ? 0 : 1

        return Canvas { context, _ in
            for (rowIndex, row) in grid.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    let color: Color
                    switch cell {
                    case "#": color = bodyColor
                    case "+": color = highlight
                    case "o": color = eyesClosed ? bodyColor : Color.black
                    default: continue
                    }
                    let rect = CGRect(
                        x: CGFloat(columnIndex) * pixel,
                        y: (CGFloat(rowIndex) + bob) * pixel,
                        width: pixel + 0.3,
                        height: pixel + 0.3
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

/// Checklist marker: pulsing play arrow for the step in progress, checkmark for finished steps.
struct AgentStepMarker: View {
    let isCurrent: Bool
    let color: Color
    @State private var pulse = false

    var body: some View {
        Group {
            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .scaleEffect(pulse ? 1.18 : 0.86)
                    .opacity(pulse ? 1 : 0.6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(color)
            }
        }
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCurrent)
    }
}

/// Indeterminate progress bar sliding along the bottom of the active file pill.
struct AgentActivityBar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { geo in
                let segment = geo.size.width * 0.35
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(color.opacity(0.14))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0), color, color.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: segment)
                        .offset(x: -segment + (geo.size.width + segment) * CGFloat(progress))
                }
            }
        }
    }
}

// MARK: - Agent Speech Bubble (pops under the notch when an agent finishes or needs the user)

struct AgentSpeechBubble: Identifiable, Equatable {
    enum Reason {
        case finished
        case question
        case approval
    }

    let id = UUID()
    let kind: AgentKind
    let reason: Reason
    let message: String
    let detail: String
    let projectPath: String?
    let sessionID: String?
}

@MainActor
final class AgentSpeechBubbleController: ObservableObject {
    static let shared = AgentSpeechBubbleController()

    @Published private(set) var bubble: AgentSpeechBubble?
    private var window: BoringNotchSkyLightWindow?
    private var dismissTask: Task<Void, Never>?

    private static let windowSize = NSSize(width: 300, height: 84)
    private static let visibleDuration: Double = 7
    /// Open notch windows (one per screen). The bubble sits right under the notch, exactly where the open
    /// notch expands, so it would cover its content: hide it on open and stay quiet while open.
    /// Weak, so a notch window torn down while open (screen change) does not silence bubbles forever
    private let openNotches = NSHashTable<AnyObject>.weakObjects()

    func notchDidOpen(_ notch: AnyObject) {
        openNotches.add(notch)
        if bubble != nil { dismiss() }
    }

    func notchDidClose(_ notch: AnyObject) {
        openNotches.remove(notch)
    }

    /// Compares two refreshes of the agent monitor and announces sessions that just stopped working.
    func announceTransitions(from previous: [AgentSessionSnapshot], to current: [AgentSessionSnapshot]) {
        guard Defaults[.agentSpeechBubbles], !previous.isEmpty else { return }
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for session in current {
            guard
                let before = previousByID[session.id],
                before.isWorkingNow, !session.isWorkingNow, session.isActive
            else { continue }

            let reason: AgentSpeechBubble.Reason
            if session.phase == .waiting {
                reason = .finished
            } else {
                // Still mid-turn but silent: the agent is blocked on the user
                let pendingTool = session.recentEvents.first?.toolName ?? ""
                if AntigravityAgentMonitor.isUserPromptTool(pendingTool) {
                    reason = .question
                } else if session.phase == .editing {
                    reason = .approval
                } else {
                    continue
                }
            }
            show(kind: session.kind, reason: reason, detail: session.projectName, projectPath: session.projectPath, sessionID: session.id)
            return
        }
    }

    func show(kind: AgentKind, reason: AgentSpeechBubble.Reason, detail: String, projectPath: String? = nil, sessionID: String? = nil) {
        guard openNotches.allObjects.isEmpty else { return }
        let message: String
        switch reason {
        case .finished:
            let options = [
                String(localized: "All done!"),
                String(localized: "Ready for you!"),
                String(localized: "Task complete!"),
                String(localized: "Done!")
            ]
            message = options.randomElement() ?? String(localized: "All done!")
        case .question:
            message = String(localized: "I have a question…")
        case .approval:
            message = String(localized: "I need your approval")
        }

        guard let screen = NSScreen.screen(withUUID: BoringViewCoordinator.shared.selectedScreenUUID)
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let notchHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let size = Self.windowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - notchHeight - size.height - 2,
            width: size.width,
            height: size.height
        )

        let panel: BoringNotchSkyLightWindow
        if let existing = window {
            panel = existing
        } else {
            panel = BoringNotchSkyLightWindow(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = NSHostingView(rootView: AgentSpeechBubbleHost())
            window = panel
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            bubble = AgentSpeechBubble(kind: kind, reason: reason, message: message, detail: detail, projectPath: projectPath, sessionID: sessionID)
        }

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        guard let dismissedID = bubble?.id else { return }
        withAnimation(.easeIn(duration: 0.22)) {
            bubble = nil
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.bubble == nil || self.bubble?.id == dismissedID else { return }
            if self.bubble == nil {
                self.window?.orderOut(nil)
            }
        }
    }
}

/// Brings forward the app an agent runs in. The agent process is traced up its parents to the first one
/// living inside an .app bundle: the editor or terminal hosting it (Antigravity, VS Code, Cursor, Terminal…).
enum AgentHostAppLauncher {
    static func open(kind: AgentKind, projectPath: String?, sessionID: String? = nil) {
        Task.detached(priority: .userInitiated) {
            let bundlePath = kind == .antigravity
                ? antigravityHostBundlePath(sessionID: sessionID)
                : hostBundlePath(kind: kind, projectPath: projectPath)
            await MainActor.run { activate(bundlePath: bundlePath, kind: kind) }
        }
    }

    @MainActor private static func activate(bundlePath: String?, kind: AgentKind) {
        let url: URL?
        if let bundlePath {
            url = URL(fileURLWithPath: bundlePath)
        } else if let bundleID = fallbackBundleID(for: kind) {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        } else {
            url = nil
        }
        guard let url else { return }
        // LaunchServices activates a running app too, and unlike NSRunningApplication.activate() it is not
        // refused for a caller that is not frontmost (the bubble panel never activates GravityNotch)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Used when no host could be traced
    private static func fallbackBundleID(for kind: AgentKind) -> String? {
        switch kind {
        case .antigravity: return "com.google.antigravity"
        case .codex: return "com.openai.codex"
        case .claudeCode: return nil
        }
    }

    private nonisolated static let antigravityBundleIDs = ["com.google.antigravity", "com.google.antigravity-ide"]

    /// Antigravity.app and Antigravity IDE share ~/.gemini/antigravity/brain, so the transcript does not say
    /// which one runs a conversation. Each app's agent process (`agy` for the IDE, `language_server` for the
    /// app) keeps the directories of the conversations it shows open: the one holding brain/<id> leads up
    /// to the right app. A conversation open nowhere goes to whichever Antigravity is running.
    private nonisolated static func antigravityHostBundlePath(sessionID: String?) -> String? {
        if let sessionID {
            let conversationID = sessionID.hasPrefix("ag:") ? String(sessionID.dropFirst(3)) : sessionID
            if !conversationID.isEmpty, let bundle = bundleHoldingAntigravityConversation(conversationID) {
                return bundle
            }
        }
        for bundleID in antigravityBundleIDs {
            if let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL {
                return url.path
            }
        }
        return nil
    }

    private nonisolated static func bundleHoldingAntigravityConversation(_ conversationID: String) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }

        var parents: [pid_t: pid_t] = [:]
        var candidates: [pid_t] = []
        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }
            parents[pid] = proc.kp_eproc.e_ppid
            let comm = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if comm.hasPrefix("agy") || comm.hasPrefix("language_server") { candidates.append(pid) }
        }

        let marker = "/brain/" + conversationID
        for pid in candidates where holdsOpenPath(pid: pid, containing: marker) {
            if let bundle = appBundle(above: pid, parents: parents) { return bundle }
        }
        return nil
    }

    private nonisolated static func holdsOpenPath(pid: pid_t, containing marker: String) -> Bool {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return false }

        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if path.contains(marker) { return true }
        }
        return false
    }

    private nonisolated static func hostBundlePath(kind: AgentKind, projectPath: String?) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }

        var parents: [pid_t: pid_t] = [:]
        var agents: [pid_t] = []
        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }
            parents[pid] = proc.kp_eproc.e_ppid
            let match = AntigravityAgentMonitor.agentProcessMatch(pid: pid, comm: proc.kp_proc.p_comm)
            if kind == .claudeCode ? match.claude : match.codex { agents.append(pid) }
        }

        // Several sessions may run at once: the one started in the bubble's project comes first
        let target = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let ordered = agents.filter { target != nil && workingDirectory(of: $0) == target }
            + agents.filter { target == nil || workingDirectory(of: $0) != target }

        for pid in ordered {
            if let bundle = appBundle(above: pid, parents: parents) { return bundle }
        }
        return nil
    }

    private nonisolated static func appBundle(above pid: pid_t, parents: [pid_t: pid_t]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var current = parents[pid] ?? 0
        for _ in 0..<24 where current > 1 {
            if proc_pidpath(current, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                // The outermost bundle: helpers live in Frameworks/<Name> Helper.app inside the main app
                if let range = path.range(of: ".app/") {
                    return String(path[..<range.lowerBound]) + ".app"
                }
            }
            current = parents[current] ?? 0
        }
        return nil
    }

    private nonisolated static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private struct AgentSpeechBubbleHost: View {
    @ObservedObject private var controller = AgentSpeechBubbleController.shared
    @State private var cursorPushed = false

    private func setPointingCursor(_ active: Bool) {
        guard active != cursorPushed else { return }
        cursorPushed = active
        if active {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let bubble = controller.bubble {
                AgentSpeechBubbleView(bubble: bubble)
                    .id(bubble.id)
                    .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
                    .onTapGesture {
                        setPointingCursor(false)
                        AgentHostAppLauncher.open(kind: bubble.kind, projectPath: bubble.projectPath, sessionID: bubble.sessionID)
                        controller.dismiss()
                    }
                    .onHover { inside in
                        setPointingCursor(inside)
                    }
                    .onDisappear {
                        setPointingCursor(false)
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AgentSpeechBubbleView: View {
    let bubble: AgentSpeechBubble
    @State private var bounce = false

    private var accent: Color {
        bubble.reason == .finished ? bubble.kind.accentColor : Color(red: 0.98, green: 0.72, blue: 0.28)
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentPixelMascot(kind: bubble.kind, isWorking: false, isActive: true, pixel: 2.4)
                .offset(y: bounce ? -1.5 : 1.5)

            VStack(alignment: .leading, spacing: 1) {
                Text(bubble.message)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(bubble.kind.shortLabel) · \(bubble.detail)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            if bubble.reason != .finished {
                Image(systemName: bubble.reason == .question ? "questionmark.bubble.fill" : "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black)
                .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
        )
        .shadow(color: accent.opacity(0.35), radius: 10, y: 3)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                bounce = true
            }
        }
    }
}

// MARK: - Apple Music web catalog

/// Reads public Apple Music album pages. Used when Music streams from the catalog (no scriptable playlist)
/// and for albums the iTunes Search API does not list.
actor AppleMusicWebCatalog {
    static let shared = AppleMusicWebCatalog()

    struct Track: Sendable {
        let title: String
        let artist: String
        let duration: Double
        let isPlayable: Bool
    }

    struct Album: Sendable {
        let pageURL: URL
        let name: String
        let artworkURL: URL?
        let tracks: [Track]
    }

    private var cache: [String: Album] = [:]
    private var missed: Set<String> = []

    func album(title: String, album: String) async -> Album? {
        let wantedAlbum = Self.simplified(album)
        let wantedTitle = Self.simplified(title)
        guard !wantedAlbum.isEmpty, !wantedTitle.isEmpty else { return nil }
        if let cached = cache[wantedAlbum], Self.index(of: wantedTitle, in: cached) != nil { return cached }
        let missKey = wantedAlbum + "|" + wantedTitle
        guard !missed.contains(missKey) else { return nil }

        let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
        var components = URLComponents(string: "https://music.apple.com/\(storefront)/search")
        components?.queryItems = [URLQueryItem(name: "term", value: "\(title) \(album)")]
        guard let searchURL = components?.url, let searchHTML = await Self.fetchHTML(searchURL) else { return nil }

        var albumIDs: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"music\.apple\.com/[a-z]{2}/album/[^"\\?/]+/(\d+)"#) {
            let range = NSRange(searchHTML.startIndex..., in: searchHTML)
            for match in regex.matches(in: searchHTML, range: range) {
                guard let idRange = Range(match.range(at: 1), in: searchHTML) else { continue }
                let id = String(searchHTML[idRange])
                if !albumIDs.contains(id) { albumIDs.append(id) }
            }
        }

        var hadFetchFailure = albumIDs.isEmpty
        // "NI (Extension)" also starts with "NI": an edition whose name only shares a prefix is kept
        // as a fallback, the album with the exact name wins.
        var looseMatch: Album?
        for id in albumIDs.prefix(6) {
            guard let pageURL = URL(string: "https://music.apple.com/\(storefront)/album/\(id)") else { continue }
            guard let html = await Self.fetchHTML(pageURL) else {
                hadFetchFailure = true
                continue
            }
            guard let parsed = Self.parseAlbum(html: html, pageURL: pageURL) else { continue }
            let name = Self.simplified(parsed.name)
            guard name == wantedAlbum || name.hasPrefix(wantedAlbum) || wantedAlbum.hasPrefix(name) else { continue }
            guard Self.index(of: wantedTitle, in: parsed) != nil else { continue }
            guard name == wantedAlbum else {
                if looseMatch == nil { looseMatch = parsed }
                continue
            }
            cache[wantedAlbum] = parsed
            return parsed
        }
        if let looseMatch {
            cache[wantedAlbum] = looseMatch
            return looseMatch
        }
        // Only remember a miss when the catalog really answered, so a network failure can be retried
        if !hadFetchFailure { missed.insert(missKey) }
        return nil
    }

    /// Playable tracks that follow the given title in album order.
    func upcomingTracks(title: String, artist: String, album: String, limit: Int = 10) async -> [Track] {
        guard let found = await self.album(title: title, album: album) else { return [] }
        let wantedTitle = Self.simplified(title)
        let wantedArtist = Self.simplified(artist)
        let exact = found.tracks.firstIndex {
            Self.simplified($0.title) == wantedTitle && Self.simplified($0.artist) == wantedArtist
        }
        guard let current = exact ?? Self.index(of: wantedTitle, in: found) else { return [] }
        return Array(found.tracks[(current + 1)...].filter(\.isPlayable).prefix(limit))
    }

    private static func index(of simplifiedTitle: String, in album: Album) -> Int? {
        album.tracks.firstIndex { simplified($0.title) == simplifiedTitle }
    }

    private static func simplified(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func scriptJSON(in html: String, pattern: String) -> Any? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html),
            let data = String(html[range]).data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseAlbum(html: String, pageURL: URL) -> Album? {
        guard
            let meta = scriptJSON(in: html, pattern: #"<script[^>]*application/ld\+json[^>]*>(.*?)</script>"#) as? [String: Any],
            let name = meta["name"] as? String,
            let server = scriptJSON(in: html, pattern: #"<script[^>]*serialized-server-data[^>]*>(.*?)</script>"#)
        else { return nil }

        var tracks: [Track] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if dict["trackNumber"] is Int, let title = dict["title"] as? String {
                    let milliseconds = (dict["duration"] as? Double) ?? 0
                    tracks.append(Track(
                        title: title,
                        artist: dict["artistName"] as? String ?? "",
                        duration: milliseconds / 1000,
                        isPlayable: !((dict["isDisabled"] as? Bool) ?? false)
                    ))
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(server)
        guard !tracks.isEmpty else { return nil }

        let artworkURL = (meta["image"] as? String)
            .map { $0.replacingOccurrences(of: #"/\d+x\d+[a-z]*\.(jpg|png)$"#, with: "/2000x2000bb.jpg", options: .regularExpression) }
            .flatMap { URL(string: $0) }
        return Album(pageURL: pageURL, name: name, artworkURL: artworkURL, tracks: tracks)
    }
}

// MARK: - Update ready notice (Sparkle)

/// Sparkle downloads updates silently and installs them when the app quits, but a notch app is
/// rarely quit, so updates waited for the next reboot. Once one is ready, the notch announces it
/// and offers to restart right away. Sparkle still installs it on quit if the user ignores it.
@MainActor
final class UpdateReadyManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateReadyManager()

    @Published private(set) var readyVersion: String?
    @Published private(set) var isNoticeHidden = false
    private var installHandler: (() -> Void)?

    var showsNotice: Bool { readyVersion != nil && !isNoticeHidden }

    // Sparkle calls its delegate on the main thread
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            announce(version: version, installHandler: immediateInstallHandler)
        }
        // Keep the install handler: the update is installed when the user clicks, or on quit
        return true
    }

    func announce(version: String, installHandler: @escaping () -> Void) {
        let isNewVersion = readyVersion != version
        readyVersion = version
        self.installHandler = installHandler
        guard isNewVersion else { return }
        isNoticeHidden = false
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .updateReady)
    }

    func installNow() {
        installHandler?()
    }

    func hideNotice() {
        isNoticeHidden = true
    }

    #if DEBUG
    /// Debug builds only: GRAVITYNOTCH_SIMULATE_UPDATE=1.9.9 shows the notice a few seconds after launch.
    func simulateIfRequested() {
        guard let version = ProcessInfo.processInfo.environment["GRAVITYNOTCH_SIMULATE_UPDATE"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            announce(version: version) {
                NSLog("GravityNotch: simulated update install for \(version)")
            }
        }
    }
    #endif
}

/// Shown for a few seconds around the closed notch when an update has just been downloaded.
/// Both wings share one width: the block is centered as a whole, so uneven wings pushed the
/// text under the physical notch.
struct UpdateReadyClosedView: View {
    @ObservedObject private var manager = UpdateReadyManager.shared
    let notchWidth: CGFloat
    let height: CGFloat

    static let wingWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Text("Update ready")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.subheadline)
            .padding(.leading, 10)
            .frame(width: Self.wingWidth, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            Text(manager.readyVersion ?? "")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.trailing, 10)
                .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .frame(height: height, alignment: .center)
    }
}

/// Header button of the open notch: one click restarts GravityNotch on the new version.
struct UpdateReadyPill: View {
    @ObservedObject private var manager = UpdateReadyManager.shared

    var body: some View {
        Button {
            manager.installNow()
        } label: {
            // Same capsule, size and inherited font as the other header buttons, only the color differs
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "arrow.down")
                        .foregroundColor(.green)
                        .padding()
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help(String(localized: "GravityNotch \(manager.readyVersion ?? "") is ready. Click to restart and install it."))
        .contextMenu {
            Button("Install when GravityNotch quits") {
                manager.hideNotice()
            }
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
        }
    }
}
