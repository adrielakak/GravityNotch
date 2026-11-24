//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

private enum SkyLightSymbols {
    typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_NOW
    )

    /// Verifies all private symbols required by SkyLightWindow before instantiating `SkyLightOperator.shared`.
    static let isAvailable: Bool = {
        guard let handle else { return false }
        let required = [
            "SLSMainConnectionID",
            "SLSSpaceCreate",
            "SLSSpaceSetAbsoluteLevel",
            "SLSShowSpaces",
            "SLSSpaceAddWindowsAndRemoveFromSpaces"
        ]
        return required.allSatisfy { dlsym(handle, $0) != nil }
    }()

    static let removeWindowsFromSpaces: F_SLSRemoveWindowsFromSpaces? = {
        guard let handle, let sym = dlsym(handle, "SLSRemoveWindowsFromSpaces") else { return nil }
        return unsafeBitCast(sym, to: F_SLSRemoveWindowsFromSpaces.self)
    }()
}

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        guard let removeWindows = SkyLightSymbols.removeWindowsFromSpaces else { return }
        _ = removeWindows(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    /// Only the interactive notch panel opts into becoming key (on demand for TextField inputs like Clips search).
    var allowsKeyWindow: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        guard SkyLightSymbols.isAvailable else { return }
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    override var canBecomeKey: Bool { allowsKeyWindow && !isSkyLightEnabled && BoringViewModel.openNotchCount > 0 }
    override var canBecomeMain: Bool { false }
}
