//
//  MediaKeyInterceptor.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-23.

import Foundation
import AppKit
import ApplicationServices
import Defaults
import AVFoundation
import os.log

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

final class MediaKeyInterceptor: ObservableObject {
    static let shared = MediaKeyInterceptor()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "theboringteam.boringnotch",
        category: "MediaKeyInterceptor"
    )

    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case keyboardBrightnessUp = 21
        case keyboardBrightnessDown = 22
    }

    // Published state for UI (Settings & Notch header)
    @MainActor @Published private(set) var isAccessibilityGranted: Bool = MediaKeyInterceptor.isTrustedForActiveTap()
    @MainActor @Published private(set) var isTapActive: Bool = false
    @MainActor @Published private(set) var isDegradedMode: Bool = false
    @MainActor @Published private(set) var isDisabledBySafetyTimeout: Bool = false
    @MainActor @Published private(set) var safetyRemainingSeconds: Int = 0

    // Event tap resources (synchronized with stateLock; never touched via blocking IPC in callback)
    private let stateLock = NSLock()
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapThread: Thread?
    private var eventTapRunLoop: CFRunLoop?

    // Passive fallback monitors (listen-only, never block system input)
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Off-main trust watchdog + TCC database stat stamp + DistributedNotification observer + 30s safety debug timer
    private let watchdogQueue = DispatchQueue(label: "com.gravitynotch.TrustWatchdog", qos: .userInteractive)
    private var permissionWatchdog: DispatchSourceTimer?
    private var lastIdleTrustCheck: CFAbsoluteTime = 0
    private var lastTCCStamp: TCCStamp?
    private var accessibilityDistributedObserver: Any?
    private var safetyCountdownTimer: Timer?
    private var safetyDeadline: Date?
    private var lastKnownTrust: Bool = MediaKeyInterceptor.isTrustedForActiveTap()

    // Lock-free flags read by the real-time tap callback (never do TCC IPC in callback)
    fileprivate var cachedTrustForCallback: Bool = MediaKeyInterceptor.isTrustedForActiveTap()
    fileprivate var lastTrustConfirmation: CFAbsoluteTime = 0
    fileprivate var isSafetyHoldActive: Bool = false
    fileprivate var consecutiveTimeoutCount: Int = 0
    fileprivate var lastTimeoutTimestamp: CFAbsoluteTime = 0

    private let step: Float = 1.0 / 16.0
    private static let safetyTimeoutDuration: TimeInterval = 30.0
    private static let activeWatchdogInterval: TimeInterval = 0.10
    private static let idleWatchdogInterval: TimeInterval = 0.75
    fileprivate static let trustStalenessLimit: CFAbsoluteTime = 1.5

    private struct FileStamp: Equatable {
        let rc: Int32
        let mtimeSec: Int
        let mtimeNsec: Int
        let size: off_t
    }

    private struct TCCStamp: Equatable {
        let db: FileStamp
        let wal: FileStamp
        let dir: FileStamp
    }

    private static func statStamp(_ path: String) -> FileStamp {
        var st = stat()
        let rc = lstat(path, &st)
        if rc != 0 {
            return FileStamp(rc: -1, mtimeSec: 0, mtimeNsec: 0, size: 0)
        }
        return FileStamp(
            rc: 0,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            size: st.st_size
        )
    }

    private static func readTCCStamp() -> TCCStamp {
        TCCStamp(
            db: statStamp("/Library/Application Support/com.apple.TCC/TCC.db"),
            wal: statStamp("/Library/Application Support/com.apple.TCC/TCC.db-wal"),
            dir: statStamp("/Library/Application Support/com.apple.TCC")
        )
    }

    /// Both AXIsProcessTrusted() and CGPreflightPostEventAccess() cache `true` per process for its
    /// entire lifetime on macOS Tahoe, so removing the app with "-" leaves in-process checks returning true.
    /// Spawning a short-lived self-probe (--check-post-event) gives a fresh PID that hits tccd directly
    /// with the exact same bundle ID and ad-hoc cdhash.
    static func isTrustedFreshViaSubprocess() -> Bool {
        guard let execURL = Bundle.main.executableURL else {
            return CGPreflightPostEventAccess()
        }
        let process = Process()
        process.executableURL = execURL
        process.arguments = ["--check-post-event"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            done.signal()
        }
        do {
            try process.run()
        } catch {
            return CGPreflightPostEventAccess()
        }
        if done.wait(timeout: .now() + 1.0) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    static func isTrustedForActiveTap() -> Bool {
        CGPreflightPostEventAccess()
    }
    private var audioPlayer: AVAudioPlayer?

    private init() {
        startPermissionWatchdog()
    }

    var isSafetyDebugModeEnabled: Bool {
        if ProcessInfo.processInfo.environment["GRAVITYNOTCH_TAP_SAFETY_TIMEOUT"] == "1" {
            return true
        }
        return Defaults[.hudTapSafetyTimeout]
    }

    // MARK: - Accessibility Permissions

    func checkAccessibilityPermission() -> Bool {
        Self.isTrustedFreshViaSubprocess()
    }

    func requestAccessibilityAuthorization() {
        Self.logger.notice("Requesting Accessibility authorization prompt")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
    }

    func openAccessibilitySystemSettings() {
        Self.logger.notice("Opening macOS System Settings -> Privacy & Security -> Accessibility")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        if Self.isTrustedForActiveTap() { return true }
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options) { return true }
        }
        return await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }

    // MARK: - Off-Main Trust Watchdog (0.25s while a tap is active, 1.5s otherwise)

    private func startPermissionWatchdog() {
        watchdogQueue.async { [weak self] in
            guard let self, self.permissionWatchdog == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
            timer.schedule(deadline: .now(), repeating: Self.activeWatchdogInterval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                self?.checkTrustOnWatchdogQueue(force: false)
            }
            timer.resume()
            self.permissionWatchdog = timer
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.accessibilityDistributedObserver == nil else { return }
            self.accessibilityDistributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.watchdogQueue.async { self.checkTrustOnWatchdogQueue(force: true) }
            }
        }
    }

    /// Runs on watchdogQueue so a busy or hung main thread can never delay the revocation response.
    /// Uses ultra-cheap POSIX stat() on the system TCC database (~2 us) to detect any TCC change
    /// (such as clicking "-" in Accessibility) in <= 100 ms, bypassing in-process TCC caching.
    private func checkTrustOnWatchdogQueue(force: Bool) {
        stateLock.lock()
        let tapActive = eventTap != nil
        stateLock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        let currentStamp = Self.readTCCStamp()
        let isInitialCheck = (lastTCCStamp == nil)
        let stampChanged = !isInitialCheck && (currentStamp != lastTCCStamp)

        if isInitialCheck {
            lastTCCStamp = currentStamp
        } else if stampChanged {
            lastTCCStamp = currentStamp
        }

        if !force && !isInitialCheck && !stampChanged {
            if tapActive {
                // TCC database unchanged: refresh callback fail-closed lease
                lastTrustConfirmation = now
            }
            return
        }
        lastIdleTrustCheck = now

        // If TCC changed while an active tap is installed, tear down the Mach port IMMEDIATELY
        // before spawning the fresh probe so WindowServer cannot drop a single mouse click.
        if (stampChanged || force) && tapActive {
            cachedTrustForCallback = false
            emergencyDisableTap()
        }

        let trusted = Self.isTrustedFreshViaSubprocess()

        cachedTrustForCallback = trusted
        if trusted {
            lastTrustConfirmation = CFAbsoluteTimeGetCurrent()
        } else if tapActive {
            emergencyDisableTap()
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyTrustState(trusted, freshVerified: true)
        }
    }

    /// Thread-safe: disables and invalidates the Mach port right away. Full cleanup follows on main.
    private func emergencyDisableTap() {
        stateLock.lock()
        let tap = eventTap
        stateLock.unlock()
        guard let tap, CFMachPortIsValid(tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        Self.logger.error("PostEvent permission revoked while tap active: CGEventTap disabled and invalidated from watchdog queue.")
    }

    private func applyTrustState(_ trusted: Bool, freshVerified: Bool = false) {
        let trustChanged = (trusted != lastKnownTrust)
        lastKnownTrust = trusted

        Task { @MainActor in
            if self.isAccessibilityGranted != trusted {
                self.isAccessibilityGranted = trusted
            }
            if trustChanged {
                Self.logger.notice("Accessibility permission state changed: PostEventAccess=\(trusted, privacy: .public)")
                NotificationCenter.default.post(
                    name: .accessibilityAuthorizationChanged,
                    object: nil,
                    userInfo: ["granted": trusted]
                )
            }
        }

        if !trusted {
            if eventTap != nil {
                Self.logger.error("Accessibility permission lost while tap active! Disabling and invalidating CGEventTap immediately.")
                tearDownActiveTap(reason: "Accessibility permission revoked", enterSafetyHold: false)
            }
            if Defaults[.hudReplacement] {
                installPassiveMonitorsIfNeeded()
                Task { @MainActor in
                    if !self.isDegradedMode { self.isDegradedMode = true }
                }
            }
            return
        }

        // Permission is granted: recreate active tap if HUD replacement is enabled and not held by safety timeout
        if Defaults[.hudReplacement] && eventTap == nil && !isSafetyHoldActive {
            Self.logger.notice("Accessibility permission available: installing active CGEventTap without app restart.")
            _ = installEventTapIfAuthorized(trustAlreadyVerified: freshVerified)
        }
    }

    // MARK: - Lifecycle (Start / Stop / Safety Debug Rearm)

    func start(promptIfNeeded: Bool = false) async {
        startPermissionWatchdog()

        guard Defaults[.hudReplacement] else {
            Self.logger.info("HUD replacement setting is disabled; stopping MediaKeyInterceptor.")
            stop()
            return
        }

        let trusted = checkAccessibilityPermission()
        let listenPreflight = CGPreflightListenEventAccess()
        Self.logger.info("Starting MediaKeyInterceptor (PostEventAccess=\(trusted, privacy: .public), CGPreflightListenEventAccess=\(listenPreflight, privacy: .public))")

        await MainActor.run {
            self.isAccessibilityGranted = trusted
        }

        guard trusted else {
            Self.logger.warning("Accessibility permission missing: refusing to create active CGEventTap. Entering degraded mode.")
            tearDownActiveTap(reason: "Permission missing on start", enterSafetyHold: false)
            installPassiveMonitorsIfNeeded()
            await MainActor.run {
                self.isDegradedMode = true
            }
            if promptIfNeeded {
                requestAccessibilityAuthorization()
            }
            return
        }

        isSafetyHoldActive = false
        await MainActor.run {
            self.isDisabledBySafetyTimeout = false
        }
        _ = installEventTapIfAuthorized(trustAlreadyVerified: true)
    }

    func stop() {
        Self.logger.info("Stopping MediaKeyInterceptor and tearing down all taps/monitors.")
        disarmSafetyTimer()
        isSafetyHoldActive = false
        tearDownActiveTap(reason: "Interceptor stopped", enterSafetyHold: false)
        removePassiveMonitors()
        Task { @MainActor in
            self.isTapActive = false
            self.isDegradedMode = false
            self.isDisabledBySafetyTimeout = false
            self.safetyRemainingSeconds = 0
        }
    }

    func rearmSafetyTap() {
        Self.logger.notice("Re-arming active CGEventTap from safety debug mode.")
        isSafetyHoldActive = false
        Task { @MainActor in
            self.isDisabledBySafetyTimeout = false
        }
        if Defaults[.hudReplacement] {
            _ = installEventTapIfAuthorized(trustAlreadyVerified: false)
        }
    }

    func updateSafetyDebugMode(_ enabled: Bool) {
        Self.logger.notice("Safety debug 30s auto-disable mode set to \(enabled, privacy: .public)")
        if enabled {
            if eventTap != nil {
                armSafetyTimerIfNeeded()
            }
        } else {
            disarmSafetyTimer()
            if isSafetyHoldActive {
                rearmSafetyTap()
            }
        }
    }

    // MARK: - Active Event Tap Installation & Immediate Safe Teardown

    @discardableResult
    private func installEventTapIfAuthorized(trustAlreadyVerified: Bool = false) -> Bool {
        let trusted = trustAlreadyVerified ? true : Self.isTrustedFreshViaSubprocess()
        cachedTrustForCallback = trusted
        guard trusted else {
            Self.logger.warning("installEventTapIfAuthorized aborted: CGPreflightPostEventAccess=false")
            if eventTap != nil {
                tearDownActiveTap(reason: "Permission check failed", enterSafetyHold: false)
            }
            installPassiveMonitorsIfNeeded()
            Task { @MainActor in
                self.isAccessibilityGranted = false
                self.isTapActive = false
                self.isDegradedMode = Defaults[.hudReplacement]
            }
            return false
        }

        stateLock.lock()
        let existingTap = eventTap
        stateLock.unlock()

        if let existingTap {
            if CFMachPortIsValid(existingTap) {
                return true
            }
            tearDownActiveTap(reason: "Stale invalid CFMachPort detected", enterSafetyHold: false)
        }

        // Strict mask: ONLY NSSystemDefined (type 14, media/aux keys).
        // NEVER include mouse events or standard keyboard events in an active (.defaultTap) tap.
        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)

        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByUserInput {
                // Never re-enable on user/system revocation: disable immediately and tear down async.
                // Never call any TCC check (sync IPC) inside a CGEventTap callback.
                interceptor.cachedTrustForCallback = false
                if let tap = interceptor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                MediaKeyInterceptor.logger.warning("CGEventTap received tapDisabledByUserInput; disabling and tearing down immediately.")
                DispatchQueue.main.async {
                    interceptor.tearDownActiveTap(
                        reason: "Disabled via tapDisabledByUserInput",
                        enterSafetyHold: interceptor.isSafetyHoldActive
                    )
                }
                return Unmanaged.passUnretained(cgEvent)
            }

            if type == .tapDisabledByTimeout {
                let now = CFAbsoluteTimeGetCurrent()
                if now - interceptor.lastTimeoutTimestamp < 5.0 {
                    interceptor.consecutiveTimeoutCount += 1
                } else {
                    interceptor.consecutiveTimeoutCount = 1
                }
                interceptor.lastTimeoutTimestamp = now

                let shouldReenable = interceptor.cachedTrustForCallback
                    && !interceptor.isSafetyHoldActive
                    && interceptor.consecutiveTimeoutCount < 2

                if shouldReenable, let tap = interceptor.eventTap, CFMachPortIsValid(tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    MediaKeyInterceptor.logger.notice("Re-enabled CGEventTap after transient tapDisabledByTimeout")
                } else {
                    if let tap = interceptor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: false)
                    }
                    MediaKeyInterceptor.logger.warning("CGEventTap disabled after tapDisabledByTimeout; tearing down.")
                    DispatchQueue.main.async {
                        interceptor.tearDownActiveTap(
                            reason: "Disabled via tapDisabledByTimeout",
                            enterSafetyHold: interceptor.isSafetyHoldActive
                        )
                    }
                }
                return Unmanaged.passUnretained(cgEvent)
            }

            // Fail closed for EVERY event, not only volume keys: each event passed through an active tap
            // is re-checked by WindowServer, and dropped once the permission is gone.
            let trustIsFresh = CFAbsoluteTimeGetCurrent() - interceptor.lastTrustConfirmation
                < MediaKeyInterceptor.trustStalenessLimit
            if !interceptor.cachedTrustForCallback || !trustIsFresh {
                if let tap = interceptor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                DispatchQueue.main.async {
                    interceptor.tearDownActiveTap(
                        reason: interceptor.cachedTrustForCallback
                            ? "Trust not confirmed for \(MediaKeyInterceptor.trustStalenessLimit)s (fail-closed)"
                            : "Permission lost detected inside callback",
                        enterSafetyHold: interceptor.isSafetyHoldActive
                    )
                }
                return Unmanaged.passUnretained(cgEvent)
            }

            return interceptor.handleEventFast(cgEvent, type: type)
        }

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Use ONLY .cgSessionEventTap with mask restricted to NSSystemDefined (14).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            Self.logger.error("CGEvent.tapCreate(.cgSessionEventTap) returned nil despite PostEventAccess=true. Falling back to degraded mode.")
            installPassiveMonitorsIfNeeded()
            Task { @MainActor in
                self.isTapActive = false
                self.isDegradedMode = true
            }
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Self.logger.error("CFMachPortCreateRunLoopSource returned nil; invalidating tap.")
            CFMachPortInvalidate(tap)
            return false
        }

        consecutiveTimeoutCount = 0
        lastTimeoutTimestamp = 0
        lastTrustConfirmation = CFAbsoluteTimeGetCurrent()

        let threadReady = DispatchSemaphore(value: 0)
        var capturedRunLoop: CFRunLoop?

        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            capturedRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            threadReady.signal()
            CFRunLoopRun()
            // Ensure self stays weakly referenced without leaking
            _ = self
        }
        thread.name = "com.gravitynotch.MediaKeyTap"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        eventTapThread = thread
        stateLock.unlock()

        thread.start()
        threadReady.wait()

        stateLock.lock()
        eventTapRunLoop = capturedRunLoop
        stateLock.unlock()

        Self.logger.notice("Active CGEventTap installed and enabled on dedicated Thread run loop (mask=NSSystemDefined only).")

        removePassiveMonitors()
        armSafetyTimerIfNeeded()

        Task { @MainActor in
            self.isAccessibilityGranted = true
            self.isTapActive = true
            self.isDegradedMode = false
        }
        return true
    }

    /// Safely disables the active tap FIRST, invalidates the CFMachPort immediately so WindowServer
    /// drops the Mach port without blocking input, and tears down the dedicated RunLoop from its own thread.
    private func tearDownActiveTap(reason: String, enterSafetyHold: Bool) {
        disarmSafetyTimer()
        if enterSafetyHold {
            isSafetyHoldActive = true
        }

        stateLock.lock()
        let tapToInvalidate = eventTap
        let sourceToRemove = runLoopSource
        let runLoopToStop = eventTapRunLoop

        eventTap = nil
        runLoopSource = nil
        eventTapRunLoop = nil
        eventTapThread = nil
        stateLock.unlock()

        if let tap = tapToInvalidate {
            // 1. Disable tap FIRST and invalidate Mach port immediately (may already be done by the watchdog)
            if CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }

            // 2. Remove source and stop dedicated RunLoop on its owning thread
            if let rl = runLoopToStop {
                CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
                    if let src = sourceToRemove {
                        CFRunLoopRemoveSource(rl, src, .commonModes)
                    }
                    CFRunLoopStop(rl)
                }
                CFRunLoopWakeUp(rl)
            }
            Self.logger.notice("Active CGEventTap disabled and CFMachPort invalidated (reason: \(reason, privacy: .public))")
        }

        if Defaults[.hudReplacement] {
            installPassiveMonitorsIfNeeded()
        }

        Task { @MainActor in
            self.isTapActive = false
            self.isDegradedMode = Defaults[.hudReplacement]
            self.isDisabledBySafetyTimeout = enterSafetyHold
            self.safetyRemainingSeconds = 0
        }
    }

    // MARK: - 30s Safety Debug Mode Timer

    private func armSafetyTimerIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.disarmSafetyTimer()
            guard self.isSafetyDebugModeEnabled, self.eventTap != nil else { return }

            let duration = Self.safetyTimeoutDuration
            let deadline = Date().addingTimeInterval(duration)
            self.safetyDeadline = deadline
            self.safetyRemainingSeconds = Int(duration)
            Self.logger.notice("Safety debug mode active: CGEventTap will auto-disable in \(Int(duration), privacy: .public)s.")

            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self else {
                    t.invalidate()
                    return
                }
                guard let deadline = self.safetyDeadline else {
                    t.invalidate()
                    return
                }
                let remaining = Int(ceil(deadline.timeIntervalSinceNow))
                if remaining <= 0 {
                    t.invalidate()
                    self.safetyCountdownTimer = nil
                    self.safetyDeadline = nil
                    Self.logger.warning("Safety debug timer (30s) expired: auto-disabling active CGEventTap now.")
                    self.tearDownActiveTap(reason: "30s safety debug timer expired", enterSafetyHold: true)
                } else {
                    Task { @MainActor in
                        self.safetyRemainingSeconds = remaining
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.safetyCountdownTimer = timer
        }
    }

    private func disarmSafetyTimer() {
        safetyCountdownTimer?.invalidate()
        safetyCountdownTimer = nil
        safetyDeadline = nil
    }

    // MARK: - Passive Degraded Mode Monitors (Listen-Only)

    private func installPassiveMonitorsIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.eventTap == nil else { return }
            if self.globalMonitor == nil {
                self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                    self?.handlePassiveSystemEvent(event)
                }
                Self.logger.info("Installed passive NSEvent global monitor for degraded HUD mode.")
            }
            if self.localMonitor == nil {
                self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                    self?.handlePassiveSystemEvent(event)
                    return event
                }
            }
        }
    }

    private func removePassiveMonitors() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let globalMonitor = self.globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let localMonitor = self.localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }
    }

    private func handlePassiveSystemEvent(_ nsEvent: NSEvent) {
        guard nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else { return }
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = ((data1 & 0xFF00) >> 8)
        guard stateByte == 0xA, let keyType = NXKeyType(rawValue: keyCode) else { return }
        let command = nsEvent.modifierFlags.contains(.command)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(35))
            self.showHUD(for: keyType, command: command)
        }
    }

    // MARK: - Ultra-Fast Non-Blocking CGEvent Callback (< 2 microseconds)

    private func handleEventFast(_ cgEvent: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // 1. Only inspect NSSystemDefined (type 14). Pass everything else untouched immediately.
        guard type.rawValue == 14 else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // 2. Check subtype == 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS) before reading data1 (field 149).
        guard let subtypeField = CGEventField(rawValue: 99),
              cgEvent.getIntegerValueField(subtypeField) == 8,
              let data1Field = CGEventField(rawValue: 149) else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = Int(cgEvent.getIntegerValueField(data1Field))
        let keyCode = (data1 & 0xFFFF_0000) >> 16

        // 3. Only intercept volume, brightness, and keyboard backlight keys.
        // Pass Play/Pause/Next/Prev and all other media keys untouched immediately.
        guard let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // 4. Verify cached permission and safety hold before swallowing any event (zero sync IPC here).
        if isSafetyHoldActive || !cachedTrustForCallback {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tearDownActiveTap(
                    reason: "Permission lost or safety hold detected inside callback",
                    enterSafetyHold: self.isSafetyHoldActive
                )
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        let keyFlags = data1 & 0x0000_FFFF
        let stateByte = (keyFlags & 0xFF00) >> 8
        let keyDown = (stateByte == 0x0A || stateByte == 0x08)
        let keyUp = (stateByte == 0x0B)
        let keyRepeat = (keyFlags & 0x1) != 0
        let shouldProcess = (keyDown || keyRepeat) && !keyUp

        guard shouldProcess else {
            // Swallow keyUp (0x0B) for intercepted volume/brightness keys so ControlCenter never shows Apple HUD
            return nil
        }

        let rawFlags = cgEvent.flags
        let option = rawFlags.contains(.maskAlternate)
        let shift = rawFlags.contains(.maskShift)
        let command = rawFlags.contains(.maskCommand)

        // 5. Delegate ALL work (Defaults lookup, volume/brightness changes, HUD display, sound) asynchronously to main thread.
        DispatchQueue.main.async { [weak self] in
            self?.processInterceptedKeyOnMain(
                keyType: keyType,
                option: option,
                shift: shift,
                command: command
            )
        }
        return nil
    }

    @MainActor
    private func processInterceptedKeyOnMain(
        keyType: NXKeyType,
        option: Bool,
        shift: Bool,
        command: Bool
    ) {
        if option && !shift {
            let action = Defaults[.optionKeyAction]
            switch action {
            case .openSettings:
                openSystemSettings(for: keyType, command: command)
                return
            case .showHUD:
                showHUD(for: keyType, command: command)
                return
            case .none:
                return
            }
        }

        let stepDivisor: Float = (option && shift) ? 4.0 : 1.0
        switch keyType {
        case .soundUp:
            playFeedbackSound()
            VolumeManager.shared.increase(stepDivisor: stepDivisor)
        case .soundDown:
            playFeedbackSound()
            VolumeManager.shared.decrease(stepDivisor: stepDivisor)
        case .mute:
            VolumeManager.shared.toggleMuteAction()
        case .brightnessUp, .keyboardBrightnessUp:
            let delta = step / stepDivisor
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessUp || command)
        case .brightnessDown, .keyboardBrightnessDown:
            let delta = -(step / stepDivisor)
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessDown || command)
        }
    }

    private func prepareAudioPlayerIfNeeded() {
        guard audioPlayer == nil else { return }

        let defaultPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        if FileManager.default.fileExists(atPath: defaultPath) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: defaultPath))
            } catch {
                Self.logger.error("Failed to init AVAudioPlayer: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let player = audioPlayer {
            player.volume = 1.0
            player.numberOfLoops = 0
            player.prepareToPlay()
        }
    }

    private func playFeedbackSound() {
        guard let feedback = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["com.apple.sound.beep.feedback"] as? Int,
              feedback == 1 else { return }

        prepareAudioPlayerIfNeeded()
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        player.play()
    }

    private func adjustBrightness(delta: Float, keyboard: Bool) {
        Task { @MainActor in
            if keyboard {
                KeyboardBacklightManager.shared.setRelative(delta: delta)
            } else {
                BrightnessManager.shared.setRelative(delta: delta)
            }
        }
    }

    private func showHUD(for keyType: NXKeyType, command: Bool) {
        Task { @MainActor in
            switch keyType {
            case .soundUp, .soundDown, .mute:
                let v = VolumeManager.shared.rawVolume
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
            case .brightnessUp, .brightnessDown:
                if command {
                    let v = KeyboardBacklightManager.shared.rawBrightness
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                } else {
                    let v = BrightnessManager.shared.rawBrightness
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v))
                }
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                let v = KeyboardBacklightManager.shared.rawBrightness
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
            }
        }
    }

    private func openSystemSettings(for keyType: NXKeyType, command: Bool) {
        let urlString: String
        switch keyType {
        case .soundUp, .soundDown, .mute:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        case .brightnessUp, .brightnessDown:
            if command {
                urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.displays"
            }
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
        }

        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
