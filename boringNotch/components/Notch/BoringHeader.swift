//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @ObservedObject var caffeine = CaffeineManager.shared
    @ObservedObject var notchTimer = NotchTimerManager.shared
    @ObservedObject var mediaKeyInterceptor = MediaKeyInterceptor.shared
    @Default(.boringShelf) private var boringShelf
    @Default(.showClipboardTab) private var showClipboardTab
    @Default(.showAgentsTab) private var showAgentsTab

    private var hasExtraTabs: Bool {
        boringShelf || showClipboardTab || showAgentsTab
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if hasExtraTabs && ((!tvm.isEmpty && boringShelf) || coordinator.alwaysShowTabs) {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.hudReplacement] && !mediaKeyInterceptor.isAccessibilityGranted {
                            Button(action: {
                                mediaKeyInterceptor.openAccessibilitySystemSettings()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.orange)
                                    Text("Permission required")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundColor(.orange)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.16))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 0.8)
                                        )
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Accessibility permission required - Click to open System Settings")
                        }
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        Button(action: {
                            vm.close()
                            ScreenCaptureOCRService.shared.capture(mode: .ocrText)
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "text.viewfinder")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Text Capture (OCR) - Right-click for Element / Area Capture & Audio Output")
                        .contextMenu {
                            Button("Capture Screen Text (OCR → Clipboard)") {
                                vm.close()
                                ScreenCaptureOCRService.shared.capture(mode: .ocrText)
                            }
                            Button("Capture Area → Shelf") {
                                vm.close()
                                ScreenCaptureOCRService.shared.capture(mode: .areaToShelf)
                            }
                            Button("Capture Window / Element → Shelf") {
                                vm.close()
                                ScreenCaptureOCRService.shared.capture(mode: .windowToShelf)
                            }
                            Divider()
                            Button("Switch Audio Output…") {
                                AudioOutputRoutingMenu.shared.popUpAtMouseLocation()
                            }
                        }
                        Button(action: {
                            toggleView(.caffeine)
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: caffeine.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                                        .foregroundColor(caffeine.isActive || coordinator.currentView == .caffeine ? CaffeinePickerView.accent : .white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(String(localized: "Keep Mac Awake (Caffeine)"))
                        Button(action: {
                            toggleView(.timer)
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: notchTimer.isActive ? "timer.circle.fill" : "timer")
                                        .foregroundColor(notchTimer.isActive || coordinator.currentView == .timer ? NotchTimerManager.accent : .white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(
                            notchTimer.isActive
                                ? String(localized: "Timer: \(notchTimer.remainingText)")
                                : String(localized: "Start a Timer")
                        )
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                                
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    private func toggleView(_ view: NotchViews) {
        withAnimation(.smooth) {
            coordinator.currentView = coordinator.currentView == view ? .home : view
        }
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
