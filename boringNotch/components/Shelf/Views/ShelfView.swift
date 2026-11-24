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
    @State private var showingClearOptions = false
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .onChange(of: tvm.items) { _, items in
            if items.isEmpty {
                showingClearOptions = false
                selection.exitSelectionMode()
            }
        }
        .quickLookPresenter(using: quickLookService)
        .onDisappear {
            quickLookService.hide()
            vm.dragDetectorTargeting = false
        }
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
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.001))
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    vm.dragDetectorTargeting
                        ? Color.accentColor.opacity(0.9)
                        : Color.white.opacity(0.1),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                )
        }
            .overlay {
                content
                    .padding()
            }
            .overlay(alignment: .bottomTrailing) {
                if !tvm.isEmpty {
                    quickActionsBar
                        .padding(8)
                }
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if !selection.isSelectionMode {
                    selection.clear()
                }
            }
    }

    private var activeShelfItems: [ShelfItem] {
        let selected = selection.selectedItems(in: tvm.items)
        return selected.isEmpty ? tvm.items : selected
    }

    private var quickActionsBar: some View {
        let targetURLs = activeShelfItems.compactMap { $0.fileURL }
        let ocrURLs = targetURLs.filter { ImageProcessingService.shared.isOCRCompatible($0) }
        let selectedItems = selection.selectedItems(in: tvm.items)
        let allSelected = !tvm.items.isEmpty && selectedItems.count == tvm.items.count
        return HStack(spacing: 5) {
            if selection.isSelectionMode {
                quickActionPill(
                    icon: allSelected ? "checkmark.circle.fill" : "checkmark.circle",
                    title: allSelected ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All")
                ) {
                    if allSelected {
                        selection.clear()
                    } else {
                        selection.selectAll(in: tvm.items)
                    }
                }
                quickActionPill(
                    icon: "trash",
                    title: LocalizedStringKey("Delete (\(selectedItems.count))"),
                    isDestructive: true,
                    isDisabled: selectedItems.isEmpty
                ) {
                    ShelfStateViewModel.shared.remove(selectedItems)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection.exitSelectionMode()
                    }
                }
                quickActionPill(icon: "xmark", title: LocalizedStringKey("Cancel")) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection.exitSelectionMode()
                    }
                }
            } else if showingClearOptions {
                if !selectedItems.isEmpty {
                    quickActionPill(
                        icon: "trash",
                        title: LocalizedStringKey("Delete (\(selectedItems.count))"),
                        isDestructive: true
                    ) {
                        ShelfStateViewModel.shared.remove(selectedItems)
                        selection.clear()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showingClearOptions = false
                        }
                    }
                }
                quickActionPill(icon: "checkmark.circle", title: LocalizedStringKey("Select")) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showingClearOptions = false
                        selection.enterSelectionMode()
                    }
                }
                quickActionPill(icon: "trash", title: LocalizedStringKey("Clear all"), isDestructive: true) {
                    ShelfStateViewModel.shared.remove(tvm.items)
                    selection.clear()
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
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                if let firstOCR = ocrURLs.first {
                    quickActionPill(icon: "text.viewfinder", title: LocalizedStringKey("OCR")) {
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
                    quickActionPill(icon: "doc.zipper", title: LocalizedStringKey("ZIP")) {
                        Task {
                            if let zipURL = await targetURLs.accessSecurityScopedResources(accessor: { urls in
                                await TemporaryFileStorageService.shared.createZip(from: urls)
                            }), let bookmark = try? Bookmark(url: zipURL) {
                                let newItem = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                                ShelfStateViewModel.shared.add([newItem])
                            }
                        }
                    }
                    quickActionPill(icon: "link.icloud.fill", title: LocalizedStringKey("0x0.st")) {
                        Task {
                            await QuickShareService.shared.uploadTo0x0(urls: targetURLs)
                        }
                    }
                    quickActionPill(icon: "airplayaudio", title: LocalizedStringKey("AirDrop")) {
                        Task {
                            let airDrop = QuickShareProvider(id: "AirDrop", imageData: nil, supportsRawText: false)
                            await QuickShareService.shared.shareFilesOrText(targetURLs, using: airDrop, from: NSApp.keyWindow?.contentView)
                        }
                    }
                }
                quickActionPill(icon: "trash", title: LocalizedStringKey("Clear"), isDestructive: true) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showingClearOptions = true
                    }
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

    private func quickActionPill(
        icon: String,
        title: LocalizedStringKey,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
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
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}
