//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .overlay(alignment: .bottomTrailing) {
                if !tvm.isEmpty {
                    droppyQuickActionsBar
                        .padding(8)
                }
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    private var activeShelfItems: [ShelfItem] {
        let selected = selection.selectedItems(in: tvm.items)
        return selected.isEmpty ? tvm.items : selected
    }

    private var droppyQuickActionsBar: some View {
        let targetURLs = activeShelfItems.compactMap { $0.fileURL }
        let ocrURLs = targetURLs.filter { ImageProcessingService.shared.isOCRCompatible($0) }
        return HStack(spacing: 5) {
            if let firstOCR = ocrURLs.first {
                quickActionPill(icon: "text.viewfinder", title: "OCR") {
                    Task {
                        if let text = try? await firstOCR.accessSecurityScopedResource(accessor: { scoped in
                            try await ImageProcessingService.shared.extractText(from: scoped)
                        }) {
                            ImageProcessingService.shared.presentOCRResultModal(
                                text: text,
                                sourceName: firstOCR.lastPathComponent
                            )
                        }
                    }
                }
            }
            if !targetURLs.isEmpty {
                quickActionPill(icon: "doc.zipper", title: "ZIP") {
                    Task {
                        if let zipURL = try? await targetURLs.accessSecurityScopedResources(accessor: { urls in
                            await TemporaryFileStorageService.shared.createZip(from: urls)
                        }), let bookmark = try? Bookmark(url: zipURL) {
                            let newItem = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                            ShelfStateViewModel.shared.add([newItem])
                        }
                    }
                }
                quickActionPill(icon: "link.icloud.fill", title: "0x0.st") {
                    Task {
                        await QuickShareService.shared.uploadTo0x0(urls: targetURLs)
                    }
                }
                quickActionPill(icon: "airplayaudio", title: "AirDrop") {
                    NSSharingService(named: .sendViaAirDrop)?.perform(withItems: targetURLs)
                }
            }
            quickActionPill(icon: "trash", title: "Clear", isDestructive: true) {
                for item in tvm.items {
                    ShelfActionService.remove(item)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.75))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        )
    }

    private func quickActionPill(icon: String, title: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isDestructive ? Color.red.opacity(0.9) : Color.white.opacity(0.88))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}
