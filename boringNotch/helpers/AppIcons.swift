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
import Sparkle

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
final class AudioOutputRoutingMenu: NSObject {
    static let shared = AudioOutputRoutingMenu()

    struct OutputDevice {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
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

        var outputs: [OutputDevice] = []
        for id in ids {
            var streamSize: UInt32 = 0
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 {
                var cfName: CFString = "" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = withUnsafeMutablePointer(to: &cfName) { ptr in
                    AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
                }
                if status == noErr {
                    outputs.append(OutputDevice(id: id, name: cfName as String, isDefault: id == defaultID))
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
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
    }

    func popUpAtMouseLocation() {
        let menu = NSMenu(title: String(localized: "Audio Output"))
        let header = NSMenuItem(title: String(localized: "Audio Output Device"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let devices = availableOutputDevices()
        for dev in devices {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(dev.id)
            item.state = dev.isDefault ? .on : .off
            let lower = dev.name.lowercased()
            let symbol = lower.contains("airpod") ? "airpodspro" : (lower.contains("headphone") ? "headphones" : "hifispeaker.fill")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: dev.name)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        setOutputDevice(AudioDeviceID(sender.tag))
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
        let statuses = [kAXCreatedNotification, kAXWindowCreatedNotification, kAXMovedNotification].map {
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
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
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

    private static func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func copyElementArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var valueRef: CFTypeRef?
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
            Task { @MainActor in
                self?.tick()
            }
        }
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
    private var monitor: Any?

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
        .onChange(of: interactive) { _, _ in
            installWheelHandler()
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
                expiresAt = Date().addingTimeInterval(TimeInterval(mins * 60))
                updateRemainingText()
                timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.tick()
                    }
                }
            } else {
                expiresAt = nil
                remainingText = "∞"
            }
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
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
        return content
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
        restoreHistory()
        captureCurrentPasteboard(initial: true)
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
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
        guard Defaults[.persistClipboardHistory],
              let data = try? Data(contentsOf: Self.historyFileURL),
              let saved = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else { return }
        let fm = FileManager.default
        let existing = saved.filter { item in
            guard item.kind == .file else { return true }
            guard let fileURL = item.fileURL else { return false }
            return fm.fileExists(atPath: fileURL.path)
        }
        isRestoring = true
        items = Self.trimmed(existing)
        isRestoring = false
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
        guard Defaults[.persistClipboardHistory], let data = try? JSONEncoder().encode(items) else { return }
        Self.saveQueue.sync { Self.write(data) }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard Defaults[.persistClipboardHistory], let data = try? JSONEncoder().encode(items) else { return }
        Self.saveQueue.async { Self.write(data) }
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

        if let raw = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
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
        items.filter { item in
            if onlyPinned && !item.isPinned { return false }
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private var filteredIDs: Set<UUID> {
        Set(manager.filteredItems.map(\.id))
    }

    private var allFilteredSelected: Bool {
        !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedIDs)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5))
            .overlay {
                VStack(spacing: 8) {
                    headerToolbar
                    if manager.filteredItems.isEmpty {
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
                            HStack(spacing: 8) {
                                ForEach(manager.filteredItems) { item in
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

    private var headerToolbar: some View {
        HStack(spacing: 8) {
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
        /// carrying a "Clear" button identified as "action"; only the first rows of a table are checked
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
            guard let title = texts.first else { return nil }
            // Subtitle reads "Artist <em dash> Album"
            let subtitle = texts.count > 1 ? texts[1] : ""
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

    func toggleQueueView() {
        withAnimation(.smooth(duration: 0.22)) {
            showQueueInHome.toggle()
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

    func refreshQueue() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }

        if MusicManager.shared.bundleIdentifier == "com.apple.Music" {
            var result = await Task.detached(priority: .utility) {
                MusicQueuePanelReader.upcomingTracks()
            }.value
            if case .failed = result {
                try? await Task.sleep(for: .milliseconds(800))
                guard generation == refreshGeneration else { return }
                result = await Task.detached(priority: .utility) {
                    MusicQueuePanelReader.upcomingTracks()
                }.value
            }
            guard generation == refreshGeneration else { return }
            switch result {
            case .queue(let live):
                musicQueuePanelHidden = false
                isLiveMusicQueue = true
                isShuffleOn = false
                tracks = live.enumerated().map { offset, track in
                    UpNextTrackItem(
                        id: "live-\(offset)-\(track.title)",
                        playlistIndex: -(offset + 1),
                        title: track.title,
                        artist: track.artist,
                        duration: 0
                    )
                }
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

    func capture(mode: CaptureMode) {
        Task { @MainActor in
            // Allow the notch to close cleanly before interactive crosshair
            try? await Task.sleep(for: .milliseconds(180))
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("gravity_capture_\(Int(Date().timeIntervalSince1970)).png")

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
                    try? FileManager.default.removeItem(at: tempFile)
                    ImageProcessingService.shared.presentOCRResultModal(
                        text: extracted,
                        sourceName: String(localized: "Screen Capture")
                    )
                } catch {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            case .areaToShelf, .windowToShelf:
                if let bookmark = try? Bookmark(url: tempFile) {
                    let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                    ShelfStateViewModel.shared.add([item])
                    BoringViewCoordinator.shared.currentView = .shelf
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
    case waiting = "Ready"
    case idle = "Idle"

    var localizedTitle: String {
        switch self {
        case .thinking: return String(localized: "Thinking")
        case .editing: return String(localized: "Editing")
        case .running: return String(localized: "In Progress")
        case .reading: return String(localized: "Reading")
        case .searching: return String(localized: "Searching")
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

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
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
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if offset > 0 && !lines.isEmpty {
            // Discard partial JSON fragment at arbitrary byte boundary
            lines.removeFirst()
        }
        return lines
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
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for i in 0..<actual {
            if claudeRunning && codexRunning { break }
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }

            let comm = withUnsafePointer(to: procs[i].kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0).lowercased()
                }
            }
            if comm == "claude" { claudeRunning = true }
            if comm == "codex" { codexRunning = true }

            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuf).lowercased()
            if path.contains("/claude/") || path.hasSuffix("/claude") {
                claudeRunning = true
            }
            if path.contains("/codex/") || path.hasSuffix("/codex") || path.contains("codex.app") {
                codexRunning = true
            }
            if (!claudeRunning || !codexRunning) && (path.hasSuffix("/node") || path.hasSuffix("/bun")) {
                var argsMib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
                var argsSize: Int = 0
                if sysctl(&argsMib, 3, nil, &argsSize, nil, 0) == 0, argsSize > 4, argsSize < 65_536 {
                    var argsBuf = [UInt8](repeating: 0, count: argsSize)
                    if sysctl(&argsMib, 3, &argsBuf, &argsSize, nil, 0) == 0 {
                        let args = argsBuf.dropFirst(4).split(separator: 0).prefix(6).compactMap {
                            String(bytes: $0, encoding: .utf8)?.lowercased()
                        }
                        if args.contains(where: { $0.hasSuffix("/claude") || $0.contains("/claude/") || $0 == "claude" }) {
                            claudeRunning = true
                        }
                        if args.contains(where: { $0.hasSuffix("/codex") || $0.contains("/codex/") || $0 == "codex" }) {
                            codexRunning = true
                        }
                    }
                }
            }
        }
        return (claudeRunning, codexRunning)
    }

    private nonisolated static func resolveSnapshot(
        from entry: CachedSessionEntry,
        now: Date,
        processRunning: Bool = true
    ) -> AgentSessionSnapshot {
        let s = entry.snapshot
        let age = max(0, now.timeIntervalSince(entry.lastEventDate))

        // Mid-turn the transcript stays silent while a command, a search or a long thought runs,
        // so silence alone does not mean the agent stopped. Edits and questions are the exception:
        // there, silence means the agent is blocked on the user.
        let midTurn = !entry.turnComplete
        let pendingTool = entry.hasPendingTool ? (s.recentEvents.first?.toolName ?? "") : ""
        let blockedOnUser = entry.hasPendingTool && (entry.rawPhase == .editing || isUserPromptTool(pendingTool))
        let isActive = age < (midTurn && processRunning ? 600.0 : 45.0)
        let isWorkingNow = processRunning && midTurn && age < (blockedOnUser ? 22.0 : 600.0)
        let workingPhase: AgentWorkPhase = entry.rawPhase == .waiting ? .thinking : entry.rawPhase
        let effectivePhase: AgentWorkPhase = (entry.turnComplete || !isActive || !processRunning) ? .waiting : workingPhase

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
            recentEvents: s.recentEvents
        )
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

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)
        for dir in subdirs {
            let transcript = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if let vals = try? transcript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let modDate = vals.contentModificationDate,
               modDate > cutoff {
                candidates.append((transcript, dir.lastPathComponent, modDate, vals.fileSize ?? 0))
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var snapshots: [AgentSessionSnapshot] = []
        for candidate in candidates.prefix(3) {
            let key = "ag:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                snapshots.append(resolveSnapshot(from: cached, now: now))
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

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
            var lastRecordType = ""
            var lastTurnComplete = false
            var pendingToolCalls = 0

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
                    lastTurnComplete = false
                    pendingToolCalls = toolCalls.count
                    for tc in toolCalls {
                        let name = (tc["name"] as? String) ?? "tool"
                        let args = (tc["args"] as? [String: Any]) ?? [:]
                        let phase = AgentWorkPhase.classify(toolName: name)
                        if phase == .editing { editCount += 1 }

                        var targetFile: String? = nil
                        if let path = (args["Path"] as? String) ?? (args["TargetFile"] as? String) ?? (args["AbsolutePath"] as? String) {
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

                        latestTitle = name
                        latestDetail = detail
                        latestPhase = phase
                        if let targetFile { latestFile = targetFile }

                        events.append(
                            AgentToolEvent(
                                id: "ag-\(candidate.id.prefix(6))-\(stepIdx)-\(events.count)",
                                stepIndex: stepIdx,
                                toolName: name,
                                phase: phase,
                                summary: detail,
                                targetFile: targetFile,
                                timestamp: lastStepDate
                            )
                        )
                    }
                } else if recordType == "PLANNER_RESPONSE" {
                    pendingToolCalls = 0
                    lastTurnComplete = (recordStatus == "DONE")
                    if !lastTurnComplete && latestPhase == .waiting {
                        latestPhase = .thinking
                    }
                } else if recordType == "USER_INPUT" {
                    lastTurnComplete = false
                    pendingToolCalls = 0
                    latestPhase = .thinking
                    latestTitle = String(localized: "Processing prompt")
                    latestDetail = String(localized: "Analyzing context…")
                } else if !recordType.isEmpty {
                    lastTurnComplete = false
                    if recordType == "SYSTEM_MESSAGE" {
                        pendingToolCalls = 0
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
                filesModifiedCount: editCount,
                linesAdded: 0,
                linesRemoved: 0,
                currentFile: latestFile,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed())
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                lastEventDate: max(lastStepDate, candidate.modDate),
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: lastTurnComplete,
                hasPendingTool: pendingToolCalls > 0
            )
            cache[key] = entry
            snapshots.append(resolveSnapshot(from: entry, now: now))
        }
        return snapshots
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

            for line in lines.suffix(180) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let rowType = (obj["type"] as? String) ?? ""
                let parsedTimestamp = dateParser.parse(obj["timestamp"] as? String)
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
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
                    if userText.hasPrefix("<command-name>/compact") || userText.hasPrefix("<local-command-") {
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
                            let phase = AgentWorkPhase.classify(toolName: name)
                            if phase == .editing { editCount += 1 }

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
                linesAdded: linesAdded,
                linesRemoved: linesRemoved,
                currentFile: latestFile,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed())
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                lastEventDate: lastEventDate,
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: lastTurnComplete,
                hasPendingTool: hasPendingTool
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
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let modDate = vals.contentModificationDate,
               modDate > cutoff {
                candidates.append((fileURL, fileURL.deletingPathExtension().lastPathComponent, modDate, vals.fileSize ?? 0))
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
                recentEvents: Array(events.suffix(12).reversed())
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
        guard !isRefreshing else { return }
        isRefreshing = true
        let initialCache = sessionCache
        let prevProcessCheckDate = lastProcessCheckDate
        let prevRunningProcesses = cachedRunningProcesses

        Task.detached(priority: .utility) {
            let home = Self.realHomeDirectory()
            let now = Date()
            let dateParser = ISODateParser()
            var nextCache = initialCache

            let runningProcesses: (claude: Bool, codex: Bool)
            let processCheckDate: Date
            if now.timeIntervalSince(prevProcessCheckDate) >= 4.0 {
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
                mon.sessionCache = updatedCache
                mon.lastProcessCheckDate = processCheckDate
                mon.cachedRunningProcesses = runningProcesses

                AgentSpeechBubbleController.shared.announceTransitions(from: mon.sessions, to: trimmed)
                mon.updateCompletionPulse(from: mon.sessions, to: trimmed)
                if mon.sessions != trimmed { mon.sessions = trimmed }
                if mon.isActive != anyActive { mon.isActive = anyActive }
                if mon.isWorkingNow != anyWorking { mon.isWorkingNow = anyWorking }
                if mon.activeAgentCount != activeSessions.count { mon.activeAgentCount = activeSessions.count }

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
                if mon.selectedSessionID == nil {
                    mon.selectedSessionID = activeSessions.first?.id ?? trimmed.first?.id
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
    @ObservedObject var monitor = AntigravityAgentMonitor.shared

    var body: some View {
        Group {
            if let session = monitor.activeSession {
                VStack(spacing: 5) {
                    if monitor.sessions.count > 1 {
                        AgentSessionSwitcherBar(
                            sessions: monitor.sessions,
                            selectedID: session.id,
                            activeCount: monitor.activeAgentCount,
                            onSelect: { monitor.selectSession($0) }
                        )
                        .frame(height: 21)
                    }

                    HStack(spacing: 8) {
                        AgentStatusCard(session: session)
                            .frame(width: 262)

                        AgentToolStreamCard(session: session)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
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

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(sessions) { session in
                        let isSelected = session.id == selectedID
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                onSelect(session.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(session.isActive ? session.kind.accentColor : Color.white.opacity(0.28))
                                    .frame(width: 5, height: 5)
                                Text(session.kind.shortLabel)
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                                Text("· \(session.projectName)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(isSelected ? .white.opacity(0.84) : .gray)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? session.kind.accentColor.opacity(0.20) : Color.white.opacity(0.05))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                isSelected ? session.kind.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                                                lineWidth: 0.8
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, activeCount > 0 ? 10 : 2)
            }
            .mask(
                HStack(spacing: 0) {
                    Rectangle().fill(Color.white)
                    if activeCount > 0 {
                        LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 14)
                    }
                }
            )

            if activeCount > 0 {
                Text("\(activeCount) running")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            }
        }
    }
}

private struct AgentStatusCard: View {
    let session: AgentSessionSnapshot

    private var accent: Color { session.kind.accentColor }
    private var secondary: Color { session.kind.secondaryAccentColor }

    private var actionHeadline: String {
        if let file = session.currentFile {
            if session.currentActionDetail != file && !session.currentActionDetail.isEmpty {
                return "\(file) · \(session.currentActionDetail)"
            }
            return file
        }
        if !session.currentActionDetail.isEmpty && session.currentActionDetail != session.currentActionTitle {
            return "\(session.currentActionTitle) · \(session.currentActionDetail)"
        }
        return session.currentActionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Identity Row
            HStack(spacing: 6) {
                AgentPixelMascot(
                    kind: session.kind,
                    isWorking: session.isWorkingNow,
                    isActive: session.isActive,
                    pixel: 2
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(session.kind.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let model = session.modelName {
                            Text(model)
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                    Text(session.sessionTitle.isEmpty ? session.projectName : "\(session.projectName) · \(session.sessionTitle)")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 3.5) {
                    if session.isWorkingNow {
                        AgentCompactWaveform(isWorking: true, color: accent, secondaryColor: secondary)
                    }
                    Text(session.phase.localizedTitle)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(session.isActive ? session.phase.color : .gray)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(session.isActive ? session.phase.color.opacity(0.16) : Color.white.opacity(0.06))
                )
            }

            Spacer(minLength: 3)

            // Active File / Command Highlight Pill (compact single line)
            HStack(spacing: 5) {
                Image(systemName: session.phase.iconName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(session.phase.color)
                    .frame(width: 13)

                Text(actionHeadline)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if session.linesAdded > 0 || session.linesRemoved > 0 {
                    HStack(spacing: 4) {
                        Text("+\(session.linesAdded)")
                            .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.56))
                        Text("-\(session.linesRemoved)")
                            .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.42))
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(alignment: .bottom) {
                        if session.isWorkingNow {
                            AgentActivityBar(color: accent)
                                .frame(height: 2)
                                .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(session.isWorkingNow ? accent.opacity(0.28) : Color.white.opacity(0.07), lineWidth: 0.8)
                    )
            )
            .animation(.easeInOut(duration: 0.25), value: session.isWorkingNow)

            Spacer(minLength: 3)

            // Context Window Progress Gauge
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Context")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("\(session.formattedContextTokens) / \(session.formattedMaxContext) · \(String(format: "%.0f%%", session.contextPercentage))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(session.contextPercentage > 80 ? Color.orange : .white.opacity(0.9))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: session.contextPercentage > 82
                                        ? [.orange, .red]
                                        : [accent, secondary],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(5, geo.size.width * CGFloat(session.contextPercentage / 100.0)))
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 3)

            // Compact 3-Metric Swiss Telemetry Footer (single-line chips)
            HStack(spacing: 5) {
                if session.linesAdded > 0 || session.linesRemoved > 0 {
                    metricChip(
                        label: String(localized: "Diff"),
                        value: "+\(session.linesAdded)-\(session.linesRemoved)",
                        valueColor: .green
                    )
                } else {
                    metricChip(label: String(localized: "Edits"), value: "\(session.filesModifiedCount)", valueColor: .white)
                }
                metricChip(label: String(localized: "Cache"), value: String(format: "%.0f%%", session.cacheHitPercentage), valueColor: .white)
                metricChip(label: String(localized: "Out"), value: session.formattedOutputTokens, valueColor: .white)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    (session.isWorkingNow ? accent : Color.white).opacity(0.24),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
        )
    }

    private func metricChip(label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }
}

private struct AgentToolStreamCard: View {
    let session: AgentSessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Progress")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("Step #\(session.stepCount)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if session.recentEvents.isEmpty {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Waiting for agent tool calls…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(session.recentEvents.enumerated()), id: \.element.id) { index, ev in
                            let isNewest = index == 0 && session.isWorkingNow
                            HStack(spacing: 6) {
                                AgentStepMarker(isCurrent: isNewest, color: session.kind.accentColor)
                                    .frame(width: 17, height: 17)

                                HStack(spacing: 4) {
                                    Text(ev.toolName)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(1)
                                    if let file = ev.targetFile {
                                        Text(file)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(ev.tintColor)
                                            .lineLimit(1)
                                    } else if ev.summary != ev.toolName && !ev.summary.isEmpty {
                                        Text(ev.summary)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .lineLimit(1)
                                    }
                                    if ev.targetFile != nil && ev.summary != ev.targetFile && ev.summary != ev.toolName && !ev.summary.isEmpty {
                                        Text("· \(ev.summary)")
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(.white.opacity(0.45))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 4)

                                Text(relativeAgeText(ev.timestamp))
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isNewest ? session.kind.accentColor.opacity(0.11) : Color.white.opacity(0.045))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                isNewest ? session.kind.accentColor.opacity(0.28) : Color.clear,
                                                lineWidth: 0.8
                                            )
                                    )
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.recentEvents.first?.id)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.9)
                )
        )
    }

    private func relativeAgeText(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h"
    }
}

private struct AgentsEmptyStateView: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("No Coding Agents Running")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text("Claude Code, Antigravity & Codex sessions appear here live")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
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

    private init() {
        positionObserver = Defaults.publisher(keys: .lockScreenMediaHorizontalPosition, .lockScreenMediaVerticalPosition)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyPanelPosition()
                }
            }
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
        guard let window = panelWindow, window.isVisible, let screen = panelScreen else { return }
        if isWindowExpanded {
            updateExpandedCardPlacement(on: screen)
        } else {
            window.setFrame(compactFrame(on: screen), display: true)
        }
    }

    func toggleWallpaperMode() {
        guard isWallpaperMode || animatedArtworkURL != nil else { return }
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
        guard !isWallpaperMode, let window = panelWindow, let screen = panelScreen else { return }
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
        guard isWallpaperMode, let window = panelWindow, let screen = panelScreen else { return }
        wallpaperTransitionID += 1
        let transitionID = wallpaperTransitionID
        withAnimation(.easeInOut(duration: 0.35)) {
            isWallpaperMode = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.wallpaperTransitionID == transitionID, !self.isWallpaperMode else { return }
            self.isWindowExpanded = false
            window.setFrame(self.compactFrame(on: screen), display: true)
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        pendingDismissTask?.cancel()
        pendingDismissTask = nil
        resetWallpaperMode()
        // On every lock the wallpaper comes back by itself as soon as a track has an animated artwork;
        // tapping it away only lasts until the next lock
        wallpaperWanted = delegateToSkyLight
        panelScreen = screen
        let frame = compactFrame(on: screen)

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
        TimelineView(.periodic(from: .now, by: musicManager.isPlaying ? 0.2 : 1.5)) { context in
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

    private var lyricsFound: Bool {
        !musicManager.syncedLyrics.isEmpty
            || !musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                                    Image(systemName: outputSymbol(for: dev.name))
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

    private func outputSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpod") { return "airpodspro" }
        if lower.contains("headphone") || lower.contains("beats") || lower.contains("sony") { return "headphones" }
        return "hifispeaker.fill"
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
    /// Last lookup per track. A failed lookup (network hiccup, slow catalog) is retried later instead of
    /// leaving the track without its animated cover until the app restarts.
    private var lastAttempts: [String: Date] = [:]

    private struct Candidate {
        let pageURL: URL
        let artworkURL: URL?
        let albumMatches: Bool
    }

    func videoURL(for key: String, albumKey: String?) -> URL? {
        videoURLs[key] ?? albumKey.flatMap { albumVideoURLs[$0] }
    }

    func stillImage(for key: String) -> NSImage? {
        stillImages[key]
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
        guard !title.isEmpty, videoURLs[key] == nil else { return }
        if let last = lastAttempts[key], Date().timeIntervalSince(last) < 45 { return }
        lastAttempts[key] = Date()

        var candidates = await Self.searchCandidates(title: title, artist: artist, album: album)
        var usedWebAlbum = false
        if !candidates.contains(where: { $0.albumMatches }),
           let webAlbum = await AppleMusicWebCatalog.shared.album(title: title, album: album) {
            candidates.insert(Candidate(pageURL: webAlbum.pageURL, artworkURL: webAlbum.artworkURL, albumMatches: true), at: 0)
            usedWebAlbum = true
        }

        var videoFile: URL?
        for candidate in candidates.prefix(3) {
            guard let playlistURL = await Self.motionPlaylistURL(pageURL: candidate.pageURL) else { continue }
            videoFile = await Self.cachedVideoFile(masterPlaylistURL: playlistURL)
            break
        }
        // The iTunes search can return another edition of the album (clean instead of explicit) that has
        // no motion artwork, so give the edition listed by the Apple Music web catalog a chance too.
        if videoFile == nil, !usedWebAlbum,
           let webAlbum = await AppleMusicWebCatalog.shared.album(title: title, album: album),
           let playlistURL = await Self.motionPlaylistURL(pageURL: webAlbum.pageURL) {
            videoFile = await Self.cachedVideoFile(masterPlaylistURL: playlistURL)
        }
        // No animated artwork: the cover stays in the player, nothing else to prepare
        guard let videoFile else { return }
        if let albumKey { albumVideoURLs[albumKey] = videoFile }
        videoURLs[key] = videoFile

        // High resolution still shown under the video until its first frame is ready
        var cover: NSImage?
        if let artworkURL = candidates.first(where: { $0.albumMatches })?.artworkURL {
            cover = await Self.fetchImage(artworkURL)
        }
        if cover == nil {
            let fallbackData = fallbackCover.tiffRepresentation
            cover = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let musicData = isAppleMusic ? Self.currentMusicArtworkData() : nil
                return Self.upscaledCover(from: musicData) ?? Self.upscaledCover(from: fallbackData)
            }.value
        }
        if let cover {
            withAnimation(.easeInOut(duration: 0.4)) {
                // Keep a single decoded cover in memory
                stillImages = [key: cover]
            }
        }
    }

    nonisolated private static func searchCandidates(title: String, artist: String, album: String) async -> [Candidate] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier.lowercased() ?? "us")
        ]
        guard
            let searchURL = components?.url,
            let (data, _) = try? await URLSession.shared.data(from: searchURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { return [] }

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

    nonisolated private static func motionPlaylistURL(pageURL: URL) async -> URL? {
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let html = String(data: data, encoding: .utf8)
        else { return nil }

        for marker in ["\"motionDetailSquare\"", "\"motionDetailTall\""] {
            guard let markerRange = html.range(of: marker) else { continue }
            let tail = html[markerRange.upperBound...]
            if let match = tail.range(of: #"https://[^"\\]+?\.m3u8"#, options: .regularExpression) {
                return URL(string: String(tail[match]))
            }
        }
        return nil
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
            return nil
        }
        pruneCache(in: folder, keeping: 10)
        return destination
    }

    nonisolated private static func pruneCache(in folder: URL, keeping limit: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sorted = files.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for file in sorted.dropFirst(limit) {
            try? fileManager.removeItem(at: file)
        }
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
                    .font(.system(size: 8.5, weight: .bold))
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
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(color.opacity(0.75))
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
            show(kind: session.kind, reason: reason, detail: session.projectName)
            return
        }
    }

    func show(kind: AgentKind, reason: AgentSpeechBubble.Reason, detail: String) {
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
            bubble = AgentSpeechBubble(kind: kind, reason: reason, message: message, detail: detail)
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

private struct AgentSpeechBubbleHost: View {
    @ObservedObject private var controller = AgentSpeechBubbleController.shared

    var body: some View {
        VStack(spacing: 0) {
            if let bubble = controller.bubble {
                AgentSpeechBubbleView(bubble: bubble)
                    .id(bubble.id)
                    .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
                    .onTapGesture {
                        controller.dismiss()
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
