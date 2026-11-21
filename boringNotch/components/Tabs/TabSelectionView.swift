//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI
import Defaults

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Clips", icon: "doc.on.clipboard.fill", view: .clipboard),
    TabModel(label: "Agents", icon: "sparkles", view: .agents)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) private var boringShelf
    @Default(.showClipboardTab) private var showClipboardTab
    @Default(.showAgentsTab) private var showAgentsTab
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home:
                return true
            case .shelf:
                return boringShelf
            case .clipboard:
                return showClipboardTab
            case .agents:
                return showAgentsTab
            case .timer, .caffeine:
                return false
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .onChange(of: boringShelf) { _, enabled in
            if !enabled && coordinator.currentView == .shelf {
                coordinator.currentView = .home
            }
        }
        .onChange(of: showClipboardTab) { _, enabled in
            if !enabled && coordinator.currentView == .clipboard {
                coordinator.currentView = .home
            }
        }
        .onChange(of: showAgentsTab) { _, enabled in
            if !enabled && coordinator.currentView == .agents {
                coordinator.currentView = .home
            }
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
