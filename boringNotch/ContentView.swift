//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var autoMixMonitor = AppleMusicAutoMixMonitor.shared
    @ObservedObject var systemNotificationMonitor = SystemNotificationMonitor.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var agentMonitor = AntigravityAgentMonitor.shared
    @ObservedObject var notchTimer = NotchTimerManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    @State private var headerDropTargeting: Bool = false
    @State private var nonShelfDropTargeting: Bool = false

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.enableAgentLiveActivity) var enableAgentLiveActivity
    @Default(.prioritizeAgentsOverPausedMusic) var prioritizeAgentsOverPausedMusic
    @Default(.cornerRadiusScaling) var cornerRadiusScaling
    @Default(.enableShadow) var enableShadow
    @Default(.enableGestures) var enableGestures
    @Default(.closeGestureEnabled) var closeGestureEnabled
    @Default(.hideTitleBar) var hideTitleBar
    @Default(.boringShelf) var boringShelf
    @Default(.showClipboardTab) var showClipboardTab
    @Default(.showAgentsTab) var showAgentsTab
    @Default(.showPowerStatusNotifications) var showPowerStatusNotifications
    @Default(.showBluetoothAudioLiveActivity) var showBluetoothAudioLiveActivity
    @Default(.showListeningModeLiveActivity) var showListeningModeLiveActivity
    @Default(.showFocusLiveActivity) var showFocusLiveActivity
    @Default(.inlineHUD) var inlineHUD
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.coloredSpectrogram) var coloredSpectrogram
    @Default(.playerColorTinting) var playerColorTinting

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && cornerRadiusScaling)
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && cornerRadiusScaling)
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var shouldShowAgentLiveActivity: Bool {
        let musicAllowsAgent = musicManager.isPlayerIdle
            || !coordinator.musicLiveActivityEnabled
            || (!musicManager.isPlaying && prioritizeAgentsOverPausedMusic)
        return !coordinator.expandingView.show
            && vm.notchState == .closed
            && musicAllowsAgent
            && enableAgentLiveActivity
            && agentMonitor.isActive
            && !vm.hideOnClosed
            && !shouldShowTimerLiveActivity
    }

    private var shouldShowMusicLiveActivity: Bool {
        (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
        && vm.notchState == .closed
        && (musicManager.isPlaying || !musicManager.isPlayerIdle)
        && coordinator.musicLiveActivityEnabled
        && !vm.hideOnClosed
        && !shouldShowAgentLiveActivity
        && !shouldShowTimerLiveActivity
    }

    private var shouldShowBluetoothLiveActivity: Bool {
        coordinator.expandingView.type == .bluetoothAudio
            && coordinator.expandingView.show
            && vm.notchState == .closed
            && showBluetoothAudioLiveActivity
            && !coordinator.sneakPeek.show
            && !vm.hideOnClosed
    }

    private var shouldShowListeningModeLiveActivity: Bool {
        coordinator.expandingView.type == .listeningMode
            && coordinator.expandingView.show
            && vm.notchState == .closed
            && showListeningModeLiveActivity
            && !coordinator.sneakPeek.show
            && !vm.hideOnClosed
    }

    private var shouldShowSystemNotificationLiveActivity: Bool {
        coordinator.expandingView.type == .systemNotification
            && coordinator.expandingView.show
            && systemNotificationMonitor.currentItem != nil
            && vm.notchState == .closed
            && !coordinator.sneakPeek.show
            && !vm.hideOnClosed
    }

    private var shouldShowBatteryNotification: Bool {
        coordinator.expandingView.type == .battery
            && coordinator.expandingView.show
            && vm.notchState == .closed
            && showPowerStatusNotifications
            && !coordinator.sneakPeek.show
            && !vm.hideOnClosed
    }

    private var shouldShowTimerLiveActivity: Bool {
        notchTimer.isActive
            && !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if shouldShowBatteryNotification {
            chinWidth += 2 * (isHovering ? 148 : 38)
        } else if coordinator.expandingView.type == .updateReady && coordinator.expandingView.show
            && vm.notchState == .closed
        {
            chinWidth = vm.closedNotchSize.width + 10 + 2 * UpdateReadyClosedView.wingWidth
        } else if shouldShowBluetoothLiveActivity {
            chinWidth += 2 * (isHovering
                ? BluetoothAudioClosedNotchView.expandedWingWidth
                : BluetoothAudioClosedNotchView.compactWingWidth(closedHeight: vm.effectiveClosedNotchHeight))
        } else if shouldShowListeningModeLiveActivity {
            chinWidth += 2 * (isHovering
                ? ListeningModeClosedNotchView.expandedWingWidth
                : ListeningModeClosedNotchView.compactWingWidth(closedHeight: vm.effectiveClosedNotchHeight))
        } else if shouldShowSystemNotificationLiveActivity {
            chinWidth += 2 * (isHovering
                ? SystemNotificationClosedNotchView.expandedWingWidth
                : SystemNotificationClosedNotchView.compactWingWidth(closedHeight: vm.effectiveClosedNotchHeight))
        } else if shouldShowTimerLiveActivity {
            chinWidth += 2 * TimerClosedNotchView.wingWidth
        } else if shouldShowAgentLiveActivity {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if shouldShowMusicLiveActivity
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && showNotHumanFace
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                            ? (cornerRadiusScaling ? cornerRadiusInsets.opened.top : cornerRadiusInsets.opened.bottom)
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && enableShadow)
                            ? .black.opacity(0.7) : .clear, radius: cornerRadiusScaling ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        let bluetoothAnimation = Animation.spring(response: 0.40, dampingFraction: 0.84, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(bluetoothAnimation, value: shouldShowBluetoothLiveActivity)
                            .animation(bluetoothAnimation, value: shouldShowListeningModeLiveActivity)
                            .animation(bluetoothAnimation, value: shouldShowSystemNotificationLiveActivity)
                            .animation(bluetoothAnimation, value: shouldShowBatteryNotification)
                            .animation(bluetoothAnimation, value: shouldShowTimerLiveActivity)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if shouldShowBluetoothLiveActivity {
                            coordinator.toggleExpandingView(status: false, type: .bluetoothAudio)
                            doOpen()
                        } else if shouldShowListeningModeLiveActivity {
                            coordinator.toggleExpandingView(status: false, type: .listeningMode)
                            doOpen()
                        } else if shouldShowSystemNotificationLiveActivity {
                            let opensClips = systemNotificationMonitor.currentItem?.opensClipboard == true
                            coordinator.toggleExpandingView(status: false, type: .systemNotification)
                            if opensClips && showClipboardTab {
                                coordinator.currentView = .clipboard
                            }
                            doOpen()
                        } else if shouldShowBatteryNotification {
                            coordinator.toggleExpandingView(status: false, type: .battery)
                            doOpen()
                        } else if shouldShowTimerLiveActivity {
                            coordinator.currentView = .timer
                            doOpen()
                        } else if shouldShowAgentLiveActivity {
                            openAgentsTab()
                        } else {
                            doOpen()
                        }
                    }
                    .panGesture(direction: .down, enabled: enableGestures) { translation, phase in
                        handleDownGesture(translation: translation, phase: phase)
                    }
                    .panGesture(direction: .up, enabled: closeGestureEnabled && enableGestures) { translation, phase in
                        handleUpGesture(translation: translation, phase: phase)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .task(id: vm.notchState == .open && isHovering) {
                        guard vm.notchState == .open && isHovering else { return }
                        var outsideTicks = 0
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { break }
                            // Pause while a menu is tracking so an open context menu never closes the notch
                            guard RunLoop.main.currentMode == .default || RunLoop.main.currentMode == nil else {
                                outsideTicks = 0
                                continue
                            }
                            guard vm.notchState == .open, isHovering,
                                  NSEvent.pressedMouseButtons == 0,
                                  !vm.anyDropZoneTargeting,
                                  !vm.isBatteryPopoverActive,
                                  !SharingStateManager.shared.preventNotchClose,
                                  isPointerOutsideOpenNotch() else {
                                outsideTicks = 0
                                continue
                            }
                            outsideTicks += 1
                            if outsideTicks >= 2 {
                                handleHover(false)
                                break
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if gestureProgress != .zero {
                            withAnimation(animationSpring) {
                                gestureProgress = .zero
                            }
                        }
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if hideTitleBar && vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: headerDropTargeting || nonShelfDropTargeting) { _, isTargeted in
            vm.generalDropTargeting = isTargeted
        }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed && boringShelf {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !isHovering && !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if shouldShowBatteryNotification {
                        let batteryWing: CGFloat = isHovering ? 148 : 38
                        let earHeight = vm.effectiveClosedNotchHeight > 0 ? max(28, vm.effectiveClosedNotchHeight) : 32
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: batteryModel.isCharging ? "bolt.fill" : (batteryModel.isInLowPowerMode ? "battery.25percent" : "powerplug.fill"))
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(batteryModel.isCharging ? .green : (batteryModel.isInLowPowerMode ? .yellow : .white.opacity(0.85)))
                                    .frame(width: 18, height: 18)

                                if isHovering {
                                    Text(batteryModel.statusText)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .tracking(-0.1)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .transition(.opacity.combined(with: .offset(x: -4)))
                                }
                            }
                            .padding(.leading, 4)
                            .frame(width: batteryWing, height: earHeight, alignment: .leading)
                            .clipped()

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width)

                            HStack(spacing: 5) {
                                if isHovering {
                                    Text("\(Int(batteryModel.levelBattery))%")
                                        .font(.system(size: 11, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.white.opacity(0.75))
                                        .transition(.opacity.combined(with: .offset(x: 4)))
                                }
                                BoringBatteryView(
                                    batteryWidth: 26,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .padding(.trailing, 4)
                            .frame(width: batteryWing, height: earHeight, alignment: .trailing)
                            .clipped()
                        }
                        .frame(height: earHeight, alignment: .center)
                        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: isHovering)
                      } else if coordinator.expandingView.type == .updateReady && coordinator.expandingView.show
                                    && vm.notchState == .closed {
                          UpdateReadyClosedView(
                              notchWidth: vm.closedNotchSize.width,
                              height: vm.effectiveClosedNotchHeight
                          )
                          .transition(.opacity)
                      } else if coordinator.sneakPeek.show && inlineHUD && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if shouldShowBluetoothLiveActivity {
                          BluetoothAudioClosedNotchView(
                              closedHeight: vm.effectiveClosedNotchHeight,
                              centerSpacerWidth: vm.closedNotchSize.width,
                              isHovered: isHovering
                          )
                          .transition(.opacity)
                      } else if shouldShowListeningModeLiveActivity {
                          ListeningModeClosedNotchView(
                              closedHeight: vm.effectiveClosedNotchHeight,
                              centerSpacerWidth: vm.closedNotchSize.width,
                              isHovered: isHovering
                          )
                          .transition(.opacity)
                      } else if shouldShowSystemNotificationLiveActivity {
                          SystemNotificationClosedNotchView(
                              closedHeight: vm.effectiveClosedNotchHeight,
                              centerSpacerWidth: vm.closedNotchSize.width,
                              isHovered: isHovering
                          )
                          .transition(.opacity)
                      } else if shouldShowTimerLiveActivity {
                          TimerClosedNotchView(
                              closedHeight: vm.effectiveClosedNotchHeight,
                              centerSpacerWidth: vm.closedNotchSize.width
                          )
                          .transition(.opacity)
                      } else if shouldShowAgentLiveActivity {
                          AgentClosedNotchView(
                              closedHeight: vm.effectiveClosedNotchHeight,
                              centerSpacerWidth: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top
                          )
                          .transition(.opacity.combined(with: .scale(scale: 0.95)))
                      } else if shouldShowMusicLiveActivity {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && showNotHumanFace && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !inlineHUD && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      case .backlight where coordinator.sneakPeek.icon.isEmpty:
                                          KeyboardBacklightManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && sneakPeekStyles == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: playerColorTinting ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .fixedSize(
                  horizontal: (coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && sneakPeekStyles == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed)),
                  vertical: (coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && sneakPeekStyles == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))
              )
              .onDrop(
                  of: [.fileURL, .url, .utf8PlainText, .plainText, .data],
                  delegate: GeneralDropTargetDelegate(isTargeted: $headerDropTargeting)
              )
              .zIndex(2)
            if vm.notchState == .open {
                let openContentMaxHeight = max(108, vm.notchSize.height - max(24, vm.effectiveClosedNotchHeight) - 22)
                VStack {
                    if coordinator.currentView == .shelf && boringShelf {
                        ShelfView()
                    } else {
                        nonShelfTabContent(maxHeight: openContentMaxHeight)
                            .onDrop(
                                of: [.fileURL, .url, .utf8PlainText, .plainText, .data],
                                delegate: GeneralDropTargetDelegate(isTargeted: $nonShelfDropTargeting)
                            )
                            .onDisappear {
                                nonShelfDropTargeting = false
                            }
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }

    @ViewBuilder
    private func nonShelfTabContent(maxHeight: CGFloat) -> some View {
        switch coordinator.currentView {
        case .home, .shelf:
            NotchHomeView(albumArtNamespace: albumArtNamespace)
        case .clipboard:
            if showClipboardTab {
                ClipboardNotchView()
            } else {
                NotchHomeView(albumArtNamespace: albumArtNamespace)
            }
        case .agents:
            if showAgentsTab {
                AgentsNotchView()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
            } else {
                NotchHomeView(albumArtNamespace: albumArtNamespace)
            }
        case .timer:
            TimerPickerView()
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
        case .caffeine:
            CaffeinePickerView()
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        let isAutoMixing = autoMixMonitor.isMixing && Defaults[.showAutoMixIndicator]
        let ringColor = Defaults[.coloredSpectrogram]
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.72)
            : Color.white.opacity(0.9)

        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .overlay {
                    if let outgoing = musicManager.outgoingAutoMixArt, musicManager.outgoingAutoMixArtOpacity > 0.005 {
                        Image(nsImage: outgoing)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(musicManager.outgoingAutoMixArtOpacity)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )
                .overlay(alignment: .bottomTrailing) {
                    if showFocusLiveActivity, let focus = systemNotificationMonitor.activeFocus {
                        Image(systemName: focus.symbol)
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(focus.tint)
                            .frame(width: 12, height: 12)
                            .background(Circle().fill(Color.black.opacity(0.88)))
                            .offset(x: 2, y: 2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if isAutoMixing {
                    AutoMixAlchemyRingsView(diameter: 11.5, accent: ringColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                        .transition(.opacity)
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.92), value: isAutoMixing)
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
            .overlay(alignment: .bottomTrailing) {
                if enableAgentLiveActivity && agentMonitor.isActive {
                    Circle()
                        .fill(agentMonitor.activeBrandColor)
                        .frame(width: 5.5, height: 5.5)
                        .shadow(color: agentMonitor.activeBrandColor.opacity(0.9), radius: 3)
                        .offset(x: -0.5, y: -0.5)
                }
            }
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if boringShelf && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dragDetectorTargeting) { providers in
                    vm.dropEvent = true
                    ShelfStateViewModel.shared.load(providers)
                    return true
                }
                .onDisappear {
                    vm.dragDetectorTargeting = false
                }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    /// Hover and swipe opens: straight to the Agents tab while an agent works, when the user asked for it
    private func openForUser() {
        if Defaults[.openAgentsTabWhileWorking] && AntigravityAgentMonitor.shared.isWorkingNow {
            openAgentsTab()
        } else {
            doOpen()
        }
    }

    private func openAgentsTab() {
        guard Defaults[.showAgentsTab] else {
            doOpen()
            return
        }
        withAnimation(animationSpring) {
            coordinator.currentView = .agents
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        let hoverKey = vm.screenUUID ?? "default"
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            let isShowingCompactBanner = shouldShowBluetoothLiveActivity
                || shouldShowListeningModeLiveActivity
                || shouldShowSystemNotificationLiveActivity
                || shouldShowBatteryNotification

            if isShowingCompactBanner {
                coordinator.setExpandingViewHover(true, screenUUID: hoverKey)
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            // A HUD no longer blocks hover-to-open, except when its own expansion put the notch under the cursor
            let hoverCausedBySneakPeek = coordinator.sneakPeek.show
                && Date().timeIntervalSince(coordinator.sneakPeekShownAt) < 0.4
            guard vm.notchState == .closed,
                  !hoverCausedBySneakPeek,
                  !isShowingCompactBanner,
                  !shouldShowTimerLiveActivity,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.shouldShowBluetoothLiveActivity,
                          !self.shouldShowListeningModeLiveActivity,
                          !self.shouldShowSystemNotificationLiveActivity,
                          !self.shouldShowBatteryNotification,
                          !self.shouldShowTimerLiveActivity else { return }
                    
                    self.openForUser()
                }
            }
        } else {
            coordinator.setExpandingViewHover(false, screenUUID: hoverKey)
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    let isMenuTracking = RunLoop.main.currentMode != .default && RunLoop.main.currentMode != nil
                    if self.vm.notchState == .open
                        && !isMenuTracking
                        && NSEvent.pressedMouseButtons == 0
                        && !self.vm.anyDropZoneTargeting
                        && !self.vm.isBatteryPopoverActive
                        && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    private func isPointerOutsideOpenNotch() -> Bool {
        guard let screen = getScreenFrame(vm.screenUUID) else { return false }
        let margin: CGFloat = 8
        let width = vm.notchSize.width + margin * 2
        let height = vm.notchSize.height + vm.chinHeight + margin
        let area = NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height + margin)
        return !area.contains(NSEvent.mouseLocation)
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .ended || phase == .cancelled {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard vm.notchState == .closed else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            openForUser()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .ended || phase == .cancelled {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            return
        }
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
