//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation
import Defaults

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case remindersPermission
    case accessibilityPermission
    case screenRecordingPermission
    case musicPermission
    case finished
}

private let calendarService = CalendarService()

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    @Default(.appLanguage) private var appLanguage
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .cameraPermission
                    }
                }
                .transition(.opacity)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: "Enable Camera Access",
                    description: "Boring Notch includes a mirror feature that lets you quickly check your appearance using your camera, right from the notch. Camera access is required only to show this live preview. You can turn the mirror feature on or off at any time in the app.",
                    privacyNote: "Your camera is never used without your consent, and nothing is recorded or stored.",
                    onAllow: {
                        Task {
                            await requestCameraPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.opacity)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "Enable Calendar Access",
                    description: "Boring Notch can show all your upcoming events in one place. Access to your calendar is needed to display your schedule.",
                    privacyNote: "Your calendar data is only used to show your events and is never shared.",
                    onAllow: {
                        Task {
                                await requestCalendarPermission()
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    step = .remindersPermission
                                }
                        }
                    },
                    onSkip: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .remindersPermission
                            }
                    }
                )
                .transition(.opacity)

                case .remindersPermission:
                    PermissionRequestView(
                        icon: Image(systemName: "checklist"),
                        title: "Enable Reminders Access",
                        description: "Boring Notch can show your scheduled reminders alongside your calendar events. Access to Reminders is needed to display your reminders.",
                        privacyNote: "Your reminders data is only used to show your reminders and is never shared.",
                        onAllow: {
                            Task {
                                await requestRemindersPermission()
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    step = .accessibilityPermission
                                }
                            }
                        },
                        onSkip: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .accessibilityPermission
                            }
                        }
                    )
                    .transition(.opacity)
                
            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: "Enable Accessibility Access",
                    description: "Accessibility access is required to replace system notifications with the Boring Notch HUD. This allows the app to intercept media and brightness events to display custom HUD overlays.",
                    privacyNote: "Accessibility access is used only to improve media and brightness notifications. No data is collected or shared.",
                    onAllow: {
                        Task {
                            await requestAccessibilityPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .screenRecordingPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .screenRecordingPermission
                        }
                    }
                )
                .transition(.opacity)

            case .screenRecordingPermission:
                PermissionRequestView(
                    icon: Image(systemName: "text.viewfinder"),
                    title: "Enable Screen Recording Access",
                    description: "Screen Recording access lets GravityNotch capture selected areas of your screen for instant OCR text extraction and quick shelf screenshots.",
                    privacyNote: "Screen captures happen locally on your Mac only when you trigger a capture. Nothing is ever recorded in the background.",
                    onAllow: {
                        Task {
                            await requestScreenRecordingPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        bringOnboardingWindowToFront(floating: true)
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)
                
            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            BoringViewCoordinator.shared.firstLaunch = false
                            step = .finished
                        }
                    }
                )
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name.accessibilityAuthorizationChanged)) { notification in
                    if (notification.userInfo?["granted"] as? Bool) == true {
                        bringOnboardingWindowToFront(floating: true)
                    }
                }
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
                    .onAppear {
                        bringOnboardingWindowToFront(floating: true)
                    }
            }
        }
        .frame(width: 400, height: 600)
        .environment(\.locale, appLanguage.locale)
    }

    // MARK: - Permission Request Logic

    @MainActor
    private func bringOnboardingWindowToFront(floating: Bool = true) {
        guard let window = NSApp.windows.first(where: { $0.identifier == NSUserInterfaceItemIdentifier("OnboardingWindow") }) else {
            return
        }
        window.level = floating ? .floating : .normal
        if floating {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func requestCameraPermission() async {
        await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            bringOnboardingWindowToFront(floating: true)
        }
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
        await MainActor.run {
            bringOnboardingWindowToFront(floating: true)
        }
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
        await MainActor.run {
            bringOnboardingWindowToFront(floating: true)
        }
    }
    
    func requestAccessibilityPermission() async {
        await MainActor.run {
            // Let the system prompt and System Settings stay unobstructed while granting Accessibility
            bringOnboardingWindowToFront(floating: false)
        }
        let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        if granted {
            await MainActor.run {
                bringOnboardingWindowToFront(floating: true)
            }
        }
    }

    func requestScreenRecordingPermission() async {
        let alreadyGranted = CGPreflightScreenCaptureAccess()
        if alreadyGranted {
            await MainActor.run {
                bringOnboardingWindowToFront(floating: true)
            }
            return
        }
        await MainActor.run {
            bringOnboardingWindowToFront(floating: false)
        }
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            await MainActor.run {
                bringOnboardingWindowToFront(floating: true)
            }
        }
    }
}
