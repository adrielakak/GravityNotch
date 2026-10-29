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

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()
    
    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case keyboardBrightnessUp = 21
        case keyboardBrightnessDown = 22
    }
    
    fileprivate var hidTap: CFMachPort?
    fileprivate var sessionTap: CFMachPort?
    fileprivate var annotatedTap: CFMachPort?
    private var hidSource: CFRunLoopSource?
    private var sessionSource: CFRunLoopSource?
    private var annotatedSource: CFRunLoopSource?
    private var eventTapQueue: DispatchQueue?
    private var eventTapRunLoop: CFRunLoop?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionPollTimer: Timer?
    private var lastProcessedTimestamp: CGEventTimestamp = 0
    private let step: Float = 1.0 / 16.0
    private var audioPlayer: AVAudioPlayer?
    
    private init() {}
    
    private func logStatus(_ message: String) {
        // Diagnostic hook for HUD tap verification
    }
    
    // MARK: - Accessibility
    
    func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        if AXIsProcessTrusted() { return true }
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options) { return true }
        }
        return await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }
    
    // MARK: - Event Tap (Zero-Blocking Multi-Layer Tap for macOS Tahoe 26)
    
    func start(promptIfNeeded: Bool = false) async {
        guard Defaults[.hudReplacement] else {
            stop()
            return
        }
        
        if installEventTapIfAuthorized() {
            return
        }
        
        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }
        
        if permissionPollTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.permissionPollTimer?.invalidate()
                self?.permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.installEventTapIfAuthorized() {
                        self.permissionPollTimer?.invalidate()
                        self.permissionPollTimer = nil
                    }
                }
            }
        }
        
        if hidTap == nil && sessionTap == nil && annotatedTap == nil && globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                self?.handlePassiveSystemEvent(event)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                self?.handlePassiveSystemEvent(event)
                return event
            }
        }
    }
    
    @discardableResult
    private func installEventTapIfAuthorized() -> Bool {
        if hidTap != nil || sessionTap != nil || annotatedTap != nil { return true }
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            logStatus("Waiting for Accessibility permission (AXIsProcessTrusted=false)")
            return false
        }
        
        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if AXIsProcessTrusted() {
                    if let t = interceptor.hidTap { CGEvent.tapEnable(tap: t, enable: true) }
                    if let t = interceptor.sessionTap { CGEvent.tapEnable(tap: t, enable: true) }
                    if let t = interceptor.annotatedTap { CGEvent.tapEnable(tap: t, enable: true) }
                }
                return Unmanaged.passUnretained(cgEvent)
            }
            return interceptor.handleEventFast(cgEvent, type: type)
        }
        
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // Install at all 3 levels (HID, Session, AnnotatedSession) so ControlCenter on macOS Tahoe never receives the key event
        hidTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: selfPtr)
        sessionTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: selfPtr)
        annotatedTap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: selfPtr)
        
        guard hidTap != nil || sessionTap != nil || annotatedTap != nil else {
            logStatus("AXIsProcessTrusted=true but tapCreate returned nil")
            return false
        }
        
        logStatus("ACTIVE TAPS INSTALLED: hid=\(hidTap != nil), session=\(sessionTap != nil), annotated=\(annotatedTap != nil)")
        
        if let t = hidTap { hidSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) }
        if let t = sessionTap { sessionSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) }
        if let t = annotatedTap { annotatedSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) }
        
        let queue = DispatchQueue(label: "com.droppy.MediaKeyTap", qos: .userInteractive)
        eventTapQueue = queue
        queue.async { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()
            self.eventTapRunLoop = rl
            if let s = self.hidSource { CFRunLoopAddSource(rl, s, .commonModes) }
            if let s = self.sessionSource { CFRunLoopAddSource(rl, s, .commonModes) }
            if let s = self.annotatedSource { CFRunLoopAddSource(rl, s, .commonModes) }
            if let t = self.hidTap { CGEvent.tapEnable(tap: t, enable: true) }
            if let t = self.sessionTap { CGEvent.tapEnable(tap: t, enable: true) }
            if let t = self.annotatedTap { CGEvent.tapEnable(tap: t, enable: true) }
            CFRunLoopRun()
        }
        
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        return true
    }
    
    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        if let t = hidTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let t = sessionTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let t = annotatedTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let rl = eventTapRunLoop {
            if let s = hidSource { CFRunLoopRemoveSource(rl, s, .commonModes) }
            if let s = sessionSource { CFRunLoopRemoveSource(rl, s, .commonModes) }
            if let s = annotatedSource { CFRunLoopRemoveSource(rl, s, .commonModes) }
            CFRunLoopStop(rl)
        }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hidSource = nil
        sessionSource = nil
        annotatedSource = nil
        eventTapRunLoop = nil
        eventTapQueue = nil
        hidTap = nil
        sessionTap = nil
        annotatedTap = nil
    }

    private func handlePassiveSystemEvent(_ nsEvent: NSEvent) {
        if installEventTapIfAuthorized() { return }
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
    
    // MARK: - Zero-Blocking CGEvent Field Extraction (< 1 microsecond, no NSEvent, no main.sync)
    
    private func handleEventFast(_ cgEvent: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard type.rawValue == 14 else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        // Field 99 = NSEvent.subtype (8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        // Field 149 = NSEvent.data1 ((keyCode << 16) | (keyState << 8) | repeatFlag)
        guard let subtypeField = CGEventField(rawValue: 99),
              let data1Field = CGEventField(rawValue: 149) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let subtype = cgEvent.getIntegerValueField(subtypeField)
        guard subtype == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let data1 = Int(cgEvent.getIntegerValueField(data1Field))
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let stateByte = (keyFlags & 0xFF00) >> 8
        
        // Pass through transport keys (Play/Pause/Next/Prev: 16..20) immediately untouched
        guard let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let keyDown = (stateByte == 0x0A || stateByte == 0x08)
        let keyUp = (stateByte == 0x0B)
        let keyRepeat = (keyFlags & 0x1) != 0
        let shouldProcess = (keyDown || keyRepeat) && !keyUp
        
        guard shouldProcess else {
            // Swallow keyUp (0x0B) so ControlCenter never sees it
            return nil
        }
        
        // Deduplicate if the same event was already handled by an earlier tap layer
        let ts = cgEvent.timestamp
        if ts != 0 && ts == lastProcessedTimestamp {
            return nil
        }
        lastProcessedTimestamp = ts
        
        let rawFlags = cgEvent.flags
        let option = rawFlags.contains(.maskAlternate)
        let shift = rawFlags.contains(.maskShift)
        let command = rawFlags.contains(.maskCommand)
        
        if option && !shift {
            if handleOptionAction(for: keyType, command: command) {
                return nil
            }
        }
        
        handleKeyPress(keyType: keyType, option: option, shift: shift, command: command)
        return nil
    }
    
    private func handleOptionAction(for keyType: NXKeyType, command: Bool) -> Bool {
        let action = Defaults[.optionKeyAction]
        
        switch action {
        case .openSettings:
            openSystemSettings(for: keyType, command: command)
            return true
        case .showHUD:
            showHUD(for: keyType, command: command)
            return true
        case .none:
            return true
        }
    }
    
    private func prepareAudioPlayerIfNeeded() {
        guard audioPlayer == nil else { return }

        let defaultPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        if FileManager.default.fileExists(atPath: defaultPath) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: defaultPath))
                print("🔊 [MediaKeyInterceptor] Loaded default Bezel audio from: \(defaultPath)")
            } catch {
                print("⚠️ [MediaKeyInterceptor] Failed to init AVAudioPlayer with default path \(defaultPath): \(error.localizedDescription)")
            }
        } else {
            print("⚠️ [MediaKeyInterceptor] Default bezel audio not found at: \(defaultPath)")
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
        guard let player = audioPlayer else {
            print("⚠️ [MediaKeyInterceptor] No audio player available to play feedback sound")
            return
        }
        if let url = player.url {
            print("🔊 [MediaKeyInterceptor] Playing feedback sound from: \(url.path)")
        } else {
            print("🔊 [MediaKeyInterceptor] Playing feedback sound (no url available for AVAudioPlayer)")
        }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        player.play()
    }

    private func handleKeyPress(keyType: NXKeyType, option: Bool, shift: Bool, command: Bool) {
        let stepDivisor: Float = (option && shift) ? 4.0 : 1.0
        
        switch keyType {
        case .soundUp:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.increase(stepDivisor: stepDivisor)
            }
        case .soundDown:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.decrease(stepDivisor: stepDivisor)
            }
        case .mute:
            Task { @MainActor in
                VolumeManager.shared.toggleMuteAction()
            }
        case .brightnessUp, .keyboardBrightnessUp:
            let delta = step / stepDivisor
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessUp || command)
        case .brightnessDown, .keyboardBrightnessDown:
            let delta = -(step / stepDivisor)
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessDown || command)
        }
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
