//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
enum GravityNotchEntrypoint {
    static func main() {
        if CommandLine.arguments.contains("--check-post-event") {
            Darwin.exit(CGPreflightPostEventAccess() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check-ax") {
            Darwin.exit(AXIsProcessTrusted() ? 0 : 1)
        }
        DynamicNotchApp.main()
    }
}

struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        // Sparkle auto-updater pointed at https://adrielakak.github.io/GravityNotch/appcast.xml
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: UpdateReadyManager.shared, userDriverDelegate: nil)
        // Sparkle only checks once its interval has elapsed since the last check, even across relaunches,
        // so with the default 24 h a fresh release could wait a whole day. Also check shortly after launch.
        let updater = updaterController.updater
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if updater.automaticallyChecksForUpdates && updater.canCheckForUpdates {
                updater.checkForUpdatesInBackground()
            }
        }
        #if DEBUG
        UpdateReadyManager.shared.simulateIfRequested()
        #endif

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("boring.notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            Divider()
            Button("Restart Boring Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var disableSkyLightTask: Task<Void, Never>?
    private var dragExitCloseTasks: [String: Task<Void, Never>] = [:]
    private var windowScreenObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector
    private var previousScreenMetrics: [(uuid: String, frame: NSRect, visibleFrame: NSRect, safeTop: CGFloat)] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        for obs in windowScreenObservers.values {
            NotificationCenter.default.removeObserver(obs)
        }
        windowScreenObservers.removeAll()
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        MediaKeyInterceptor.shared.stop()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    /// When an update changes the code signature, macOS keeps the old Accessibility row: the switch
    /// still looks on but the new build is not trusted, and users had to remove and re-add the app.
    /// Once per new build, if the HUD needs Accessibility and the fresh check fails, drop that stale
    /// row and show the system prompt, so turning the switch back on is enough.
    private func resetStaleAccessibilityGrantAfterUpdate() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let previousBuild = Defaults[.lastLaunchedBuild]
        Defaults[.lastLaunchedBuild] = build
        guard !coordinator.firstLaunch, !build.isEmpty, previousBuild != build,
              Defaults[.hudReplacement], let bundleID = Bundle.main.bundleIdentifier else { return }

        Task.detached(priority: .utility) {
            guard !MediaKeyInterceptor.isTrustedFreshViaSubprocess() else { return }
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleID]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            do {
                try reset.run()
                reset.waitUntilExit()
            } catch {
                NSLog("GravityNotch: tccutil reset failed: \(error.localizedDescription)")
                return
            }
            NSLog("GravityNotch: reset stale Accessibility grant after update to build \(build) (status \(reset.terminationStatus))")
            await MainActor.run {
                MediaKeyInterceptor.shared.requestAccessibilityAuthorization()
            }
        }
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        coordinator.isScreenLocked = true
        disableSkyLightTask?.cancel()
        disableSkyLightTask = nil
        closeNotchTask?.cancel()
        closeNotchTask = nil
        vm.close(force: true)
        viewModels.values.forEach { $0.close(force: true) }
        cleanupDragDetectors()
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
            LockScreenMediaPanelManager.shared.showOnLockScreen()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        coordinator.isScreenLocked = false
        LockScreenMediaPanelManager.shared.hideFromLockScreen()
        disableSkyLightOnAllWindows()
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        }
        setupDragDetectors()
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? BoringNotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        disableSkyLightTask?.cancel()
        // Delay disabling SkyLight to avoid flicker during unlock transition
        disableSkyLightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !self.isScreenLocked else { return }
            let activeWindows: [NSWindow] = Defaults[.showOnAllDisplays]
                ? Array(self.windows.values)
                : (self.window.map { [$0] } ?? [])
            for window in activeWindows {
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.disableSkyLight()
                    NotchSpaceManager.shared.notchSpace.reattach(skyWindow)
                    skyWindow.orderFrontRegardless()
                }
            }
        }
    }

    private func removeWindowScreenObserver(for window: NSWindow) {
        if let obs = windowScreenObservers.removeValue(forKey: ObjectIdentifier(window)) {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            viewModels.values.forEach { $0.close(force: true) }
            windows.values.forEach { window in
                removeWindowScreenObserver(for: window)
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else {
            vm.close(force: true)
            if let window = window {
                removeWindowScreenObserver(for: window)
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
                self.window = nil
            }
        }
    }

    private func cleanupDragDetectors() {
        dragExitCloseTasks.values.forEach { $0.cancel() }
        dragExitCloseTasks.removeAll()
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard !isScreenLocked, Defaults[.expandedDragDetection], Defaults[.boringShelf] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            guard let window = window, window.alphaValue > 0 else { return }
            let preferredScreen: NSScreen? = window.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        detector.onDragExitsNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragExitsNotchRegion(screenUUID: uuid)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    @MainActor
    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard !isScreenLocked, Defaults[.boringShelf], let uuid = screen.displayUUID else { return }
        dragExitCloseTasks[uuid]?.cancel()
        dragExitCloseTasks.removeValue(forKey: uuid)
        
        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.open()
            coordinator.currentView = .shelf
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, window?.alphaValue ?? 0 > 0, screen == windowScreen {
            vm.open()
            coordinator.currentView = .shelf
        }
    }

    @MainActor
    private func handleDragExitsNotchRegion(screenUUID uuid: String) {
        dragExitCloseTasks[uuid]?.cancel()
        dragExitCloseTasks[uuid] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            let targetVM: BoringViewModel? = Defaults[.showOnAllDisplays] ? self.viewModels[uuid] : self.vm
            guard let targetVM,
                  targetVM.notchState == .open,
                  !targetVM.anyDropZoneTargeting,
                  !targetVM.isMouseHovering(),
                  !targetVM.isBatteryPopoverActive,
                  !SharingStateManager.shared.preventNotchClose else { return }
            targetVM.close()
        }
    }

    private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        window.allowsKeyWindow = true
        
        // Enable SkyLight only when screen is locked AND showOnLockScreen is enabled
        if isScreenLocked && Defaults[.showOnLockScreen] {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)
        return window
    }

    private func observeScreenChange(for window: NSWindow) {
        guard windowScreenObservers[ObjectIdentifier(window)] == nil else { return }
        windowScreenObservers[ObjectIdentifier(window)] = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        resetStaleAccessibilityGrantAfterUpdate()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        })

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isScreenLocked else { return }

                let mouseLocation = NSEvent.mouseLocation
                let viewModel: BoringViewModel
                if Defaults[.showOnAllDisplays] {
                    guard let matched = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
                          let uuid = matched.displayUUID,
                          let screenViewModel = self.viewModels[uuid] else { return }
                    viewModel = screenViewModel
                } else {
                    viewModel = self.vm
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    viewModel.open()

                    let task = Task { @MainActor [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled, let viewModel else { return }
                            guard !viewModel.isMouseHovering(),
                                  !viewModel.isBatteryPopoverActive,
                                  !viewModel.anyDropZoneTargeting,
                                  !SharingStateManager.shared.preventNotchClose else { return }
                            viewModel.close()
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    viewModel.close()
                }
            }
        }

        adjustWindowPosition(changeAlpha: true)

        setupDragDetectors()

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
        previousScreenMetrics = currentScreenMetrics(from: NSScreen.screens)
    }

    private func currentScreenMetrics(from screens: [NSScreen]) -> [(uuid: String, frame: NSRect, visibleFrame: NSRect, safeTop: CGFloat)] {
        screens.compactMap { screen in
            guard let uuid = screen.displayUUID else { return nil }
            return (uuid, screen.frame, screen.visibleFrame, screen.safeAreaInsets.top)
        }.sorted { $0.uuid < $1.uuid }
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens
        let nextMetrics = currentScreenMetrics(from: currentScreens)

        let screensChanged: Bool = {
            if nextMetrics.count != previousScreenMetrics.count { return true }
            for (lhs, rhs) in zip(nextMetrics, previousScreenMetrics) {
                if lhs.uuid != rhs.uuid || lhs.frame != rhs.frame || lhs.visibleFrame != rhs.visibleFrame || lhs.safeTop != rhs.safeTop {
                    return true
                }
            }
            return false
        }()

        previousScreens = currentScreens
        previousScreenMetrics = nextMetrics

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isScreenLocked && !Defaults[.showOnLockScreen] { return }
                self.adjustWindowPosition()
                self.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if isScreenLocked && !Defaults[.showOnLockScreen] {
            return
        }

        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                viewModels[uuid]?.close(force: true)
                if let window = windows[uuid] {
                    removeWindowScreenObserver(for: window)
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = BoringViewModel(screenUUID: uuid)
                    let window = createBoringNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    let closedSize = getClosedNotchSize(screenUUID: uuid)
                    viewModel.closedNotchSize = closedSize
                    if viewModel.notchState == .closed {
                        viewModel.notchSize = closedSize
                    }
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)
                    observeScreenChange(for: window)
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay],
                      let mainScreen = NSScreen.main ?? NSScreen.screens.first,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            let closedSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)
            vm.closedNotchSize = closedSize
            if vm.notchState == .closed {
                vm.notchSize = closedSize
            }

            if window == nil {
                window = createBoringNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)
                observeScreenChange(for: window)
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        NSApp.setActivationPolicy(.regular)

        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: { [weak self, weak window] in
                        window?.orderOut(nil)
                        window?.close()
                        window?.contentView = nil
                        self?.onboardingWindowController = nil
                        NSApp.setActivationPolicy(.accessory)
                        NSApp.deactivate()
                    },
                    onOpenSettings: { [weak self, weak window] in
                        window?.close()
                        window?.contentView = nil
                        self?.onboardingWindowController = nil
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.level = .floating
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
