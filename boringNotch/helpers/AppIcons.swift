//
//  AppIcons.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 16/08/24.
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Defaults
import IOKit.pwr_mgt

struct AppIcons {
    
    func getIcon(file path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path)
        else { return nil }
        
        return NSWorkspace.shared.icon(forFile: path)
    }
    
    func getIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        )?.absoluteString
        else { return nil }
        
        return getIcon(file: path)
    }
    
        /// Easily read Info.plist as a Dictionary from any bundle by accessing .infoDictionary on Bundle
    func bundle(forBundleID: String) -> Bundle? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: forBundleID)
        else { return nil }
        
        return Bundle(url: url)
    }
    
}

func AppIcon(for bundleID: String) -> Image {
    let workspace = NSWorkspace.shared
    
    if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        return Image(nsImage: appIcon)
    }
    
    return Image(nsImage: workspace.icon(for: .applicationBundle))
}


func AppIconAsNSImage(for bundleID: String) -> NSImage? {
    let workspace = NSWorkspace.shared
    
    if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        appIcon.size = NSSize(width: 256, height: 256)
        return appIcon
    }
    return nil
}

// MARK: - CoreAudio Output Device Switcher (Droppy Audio Routing)

@MainActor
final class AudioOutputRoutingMenu: NSObject {
    static let shared = AudioOutputRoutingMenu()

    struct OutputDevice {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }

    func availableOutputDevices() -> [OutputDevice] {
        var defaultID = AudioDeviceID(0)
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &defSize, &defaultID)

        var propSize: UInt32 = 0
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &propSize) == noErr else {
            return []
        }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &propSize, &ids) == noErr else {
            return []
        }

        var outputs: [OutputDevice] = []
        for id in ids {
            var streamSize: UInt32 = 0
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 {
                var cfName: CFString = "" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = withUnsafeMutablePointer(to: &cfName) { ptr in
                    AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
                }
                if status == noErr {
                    outputs.append(OutputDevice(id: id, name: cfName as String, isDefault: id == defaultID))
                }
            }
        }
        return outputs
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
    }

    func popUpAtMouseLocation() {
        let menu = NSMenu(title: "Audio Output")
        let header = NSMenuItem(title: "Audio Output Device", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let devices = availableOutputDevices()
        for dev in devices {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(dev.id)
            item.state = dev.isDefault ? .on : .off
            let lower = dev.name.lowercased()
            let symbol = lower.contains("airpod") ? "airpodspro" : (lower.contains("headphone") ? "headphones" : "hifispeaker.fill")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: dev.name)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        setOutputDevice(AudioDeviceID(sender.tag))
    }
}

// MARK: - Caffeine Manager (Droppy Keep-Mac-Awake Extension)

@MainActor
final class CaffeineManager: ObservableObject {
    static let shared = CaffeineManager()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var expiresAt: Date? = nil
    @Published private(set) var remainingText: String = ""

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?

    private init() {}

    func toggle(durationMinutes: Int? = nil) {
        if isActive && durationMinutes == nil {
            deactivate()
        } else {
            activate(durationMinutes: durationMinutes)
        }
    }

    func activate(durationMinutes: Int? = nil) {
        deactivate()
        let reason = "BoringNotch Caffeine Mode (Prevent Sleep)" as CFString
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
            if let mins = durationMinutes, mins > 0 {
                expiresAt = Date().addingTimeInterval(TimeInterval(mins * 60))
                updateRemainingText()
                timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.tick()
                    }
                }
            } else {
                expiresAt = nil
                remainingText = "∞"
            }
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        if isActive && assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
        expiresAt = nil
        remainingText = ""
    }

    private func tick() {
        guard let expiresAt else { return }
        if Date() >= expiresAt {
            deactivate()
        } else {
            updateRemainingText()
        }
    }

    private func updateRemainingText() {
        guard let expiresAt else {
            remainingText = isActive ? "∞" : ""
            return
        }
        let mins = max(1, Int(ceil(expiresAt.timeIntervalSinceNow / 60.0)))
        remainingText = mins >= 60 ? "\(mins / 60)h\(mins % 60 > 0 ? "\(mins % 60)m" : "")" : "\(mins)m"
    }
}

// MARK: - Droppy Clipboard History Manager & Notch View

struct DroppyClipItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case text
        case url
        case color
        case file
    }

    let id: UUID
    let kind: Kind
    let content: String
    let fileURL: URL?
    let sourceAppBundleID: String?
    let timestamp: Date
    var isPinned: Bool = false

    var displayTitle: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        return content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var iconName: String {
        switch kind {
        case .text: return "doc.text.fill"
        case .url: return "link"
        case .color: return "paintpalette.fill"
        case .file: return "doc.fill"
        }
    }
}

@MainActor
final class DroppyClipboardManager: ObservableObject {
    static let shared = DroppyClipboardManager()

    @Published private(set) var items: [DroppyClipItem] = []
    @Published var searchQuery: String = ""
    @Published var onlyPinned: Bool = false
    @Published var recentlyCopiedID: UUID? = nil

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?

    private init() {
        CapsLockHUDMonitor.shared.start()
        captureCurrentPasteboard(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
    }

    private func pollPasteboard() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        captureCurrentPasteboard(initial: false)
    }

    func captureCurrentPasteboard(initial: Bool = false) {
        let pb = NSPasteboard.general
        let frontBundle = initial ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let firstFile = urls.first {
            insertItem(kind: .file, content: firstFile.path, fileURL: firstFile, bundleID: frontBundle)
            return
        }

        if let raw = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let kind: DroppyClipItem.Kind
            if Self.isValidHexColor(raw) {
                kind = .color
            } else if let u = URL(string: raw), let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                kind = .url
            } else {
                kind = .text
            }
            insertItem(kind: kind, content: raw, fileURL: nil, bundleID: frontBundle)
        }
    }

    private func insertItem(kind: DroppyClipItem.Kind, content: String, fileURL: URL?, bundleID: String?) {
        if let existingIdx = items.firstIndex(where: { $0.content == content && $0.kind == kind }) {
            let pinned = items[existingIdx].isPinned
            items.remove(at: existingIdx)
            let updated = DroppyClipItem(
                id: UUID(),
                kind: kind,
                content: content,
                fileURL: fileURL,
                sourceAppBundleID: bundleID,
                timestamp: Date(),
                isPinned: pinned
            )
            items.insert(updated, at: 0)
            return
        }

        let newItem = DroppyClipItem(
            id: UUID(),
            kind: kind,
            content: content,
            fileURL: fileURL,
            sourceAppBundleID: bundleID,
            timestamp: Date()
        )
        items.insert(newItem, at: 0)
        if items.count > 40 {
            if let lastUnpinned = items.lastIndex(where: { !$0.isPinned }) {
                items.remove(at: lastUnpinned)
            }
        }
    }

    func copyToPasteboard(_ item: DroppyClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let fileURL = item.fileURL {
            pb.writeObjects([fileURL as NSURL])
        } else {
            pb.setString(item.content, forType: .string)
        }
        lastChangeCount = pb.changeCount
        recentlyCopiedID = item.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if self.recentlyCopiedID == item.id {
                self.recentlyCopiedID = nil
            }
        }
    }

    func togglePin(_ item: DroppyClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
    }

    func remove(_ item: DroppyClipItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
    }

    func sendToShelf(_ item: DroppyClipItem) {
        if let fileURL = item.fileURL, let bookmark = try? Bookmark(url: fileURL) {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data))])
        } else if item.kind == .url, let url = URL(string: item.content) {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .link(url: url))])
        } else {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: item.content))])
        }
        BoringViewCoordinator.shared.currentView = .shelf
    }

    var filteredItems: [DroppyClipItem] {
        items.filter { item in
            if onlyPinned && !item.isPinned { return false }
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return item.content.lowercased().contains(q)
        }
    }

    static func isValidHexColor(_ str: String) -> Bool {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") && (s.count == 7 || s.count == 4) else { return false }
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        return s.dropFirst().unicodeScalars.allSatisfy { hexChars.contains($0) }
    }

    static func color(fromHex hex: String) -> Color? {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if clean.count == 3 {
            clean = clean.map { "\($0)\($0)" }.joined()
        }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        return Color(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

struct ClipboardNotchView: View {
    @ObservedObject private var manager = DroppyClipboardManager.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5))
            .overlay {
                VStack(spacing: 8) {
                    headerToolbar
                    if manager.filteredItems.isEmpty {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.gray)
                            Text("No clipboard items found")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(manager.filteredItems) { item in
                                    clipCard(for: item)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(10)
            }
    }

    private var headerToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                TextField("Search clipboard…", text: $manager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                if !manager.searchQuery.isEmpty {
                    Button {
                        manager.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .frame(maxWidth: 220)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    manager.onlyPinned.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: manager.onlyPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                    Text("Pinned")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(manager.onlyPinned ? Color.yellow : Color.white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(manager.onlyPinned ? Color.yellow.opacity(0.18) : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(manager.items.count) clips")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.gray)

            if !manager.items.isEmpty {
                Button {
                    manager.clearUnpinned()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Clear unpinned clips")
            }
        }
    }

    private func clipCard(for item: DroppyClipItem) -> some View {
        let isCopied = manager.recentlyCopiedID == item.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if item.kind == .color, let swatch = DroppyClipboardManager.color(fromHex: item.content) {
                    Circle()
                        .fill(swatch)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
                } else {
                    Image(systemName: item.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Text(item.kind.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.gray)

                Spacer()

                Button {
                    manager.togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(item.isPinned ? .yellow : .gray.opacity(0.7))
                }
                .buttonStyle(.plain)

                Button {
                    manager.sendToShelf(item)
                } label: {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Send to Shelf")
            }

            Text(item.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Text(isCopied ? "Copied ✓" : "Click to copy")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isCopied ? .green : .gray)
                Spacer()
                if item.kind == .url, let url = URL(string: item.content) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .frame(width: 145, height: 82)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCopied ? Color.green.opacity(0.16) : Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isCopied ? Color.green.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            manager.copyToPasteboard(item)
        }
        .onDrag {
            if let fileURL = item.fileURL {
                return NSItemProvider(object: fileURL as NSURL)
            }
            return NSItemProvider(object: item.content as NSString)
        }
    }
}

// MARK: - Caps Lock HUD Monitor (Droppy Feature)

@MainActor
final class CapsLockHUDMonitor {
    static let shared = CapsLockHUDMonitor()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isCapsLockOn: Bool = NSEvent.modifierFlags.contains(.capsLock)

    func start() {
        guard globalMonitor == nil else { return }
        isCapsLockOn = NSEvent.modifierFlags.contains(.capsLock)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let newState = event.modifierFlags.contains(.capsLock)
        guard newState != isCapsLockOn else { return }
        isCapsLockOn = newState
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .backlight,
            value: newState ? 1.0 : 0.0,
            icon: newState ? "capslock.fill" : "capslock"
        )
    }
}

// MARK: - Playing Next Queue Manager & View (Droppy Playing Next Feature)

struct UpNextTrackItem: Identifiable, Equatable {
    let id: String
    let playlistIndex: Int
    let title: String
    let artist: String
    let duration: Double
    var isPromoted: Bool = false

    var formattedDuration: String {
        guard duration > 0 else { return "" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
final class PlayingNextManager: ObservableObject {
    static let shared = PlayingNextManager()

    @Published var showQueueInHome: Bool = false
    @Published private(set) var tracks: [UpNextTrackItem] = []
    @Published private(set) var isLoading: Bool = false
    /// Music does not expose its shuffled Up Next order, so the playlist order is not the real queue while shuffling.
    @Published private(set) var isShuffleOn: Bool = false
    private var promotedIDs: [String] = []
    private var cancellable: AnyCancellable?
    private var shuffleCancellable: AnyCancellable?

    private init() {
        cancellable = MusicManager.shared.$songTitle
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshQueue()
                }
            }
        shuffleCancellable = MusicManager.shared.$isShuffled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshQueue()
                }
            }
        Task {
            await refreshQueue()
        }
    }

    func toggleQueueView() {
        withAnimation(.smooth(duration: 0.22)) {
            showQueueInHome.toggle()
        }
        if showQueueInHome {
            Task { await refreshQueue() }
        }
    }

    func promoteToTop(_ item: UpNextTrackItem) {
        promotedIDs.removeAll { $0 == item.id }
        promotedIDs.insert(item.id, at: 0)
        applyPromotedOrder()
    }

    private func applyPromotedOrder() {
        var promoted: [UpNextTrackItem] = []
        var rest: [UpNextTrackItem] = []
        for var t in tracks {
            if promotedIDs.contains(t.id) {
                t.isPromoted = true
                promoted.append(t)
            } else {
                t.isPromoted = false
                rest.append(t)
            }
        }
        promoted.sort { (promotedIDs.firstIndex(of: $0.id) ?? 999) < (promotedIDs.firstIndex(of: $1.id) ?? 999) }
        tracks = promoted + rest
    }

    func playTrack(_ item: UpNextTrackItem) {
        let targetIndex = item.playlistIndex
        // Negative index: catalog queue, reached by skipping forward (only reliable without shuffle)
        if targetIndex < 0 && isShuffleOn { return }
        promotedIDs.removeAll { $0 == item.id }
        Task.detached(priority: .userInitiated) {
            let script = targetIndex < 0 ? """
            tell application "Music"
                if it is running then
                    repeat \(-targetIndex) times
                        next track
                        delay 0.15
                    end repeat
                end if
            end tell
            """ : """
            tell application "Music"
                if it is running then
                    play track \(targetIndex) of current playlist
                end if
            end tell
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run {
                MusicManager.shared.forceUpdate()
                Task { await PlayingNextManager.shared.refreshQueue() }
            }
        }
    }

    func turnOffShuffle() {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"Music\" to if it is running then set shuffle enabled to false"]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run {
                MusicManager.shared.forceUpdate()
                Task { await PlayingNextManager.shared.refreshQueue() }
            }
        }
    }

    func refreshQueue() async {
        isLoading = true
        defer { isLoading = false }

        let (fetched, shuffleOn): ([UpNextTrackItem], Bool) = await Task.detached(priority: .utility) {
            let script = """
            tell application "Music"
                if it is running and player state is not stopped then
                    set outList to "SHUFFLE|" & (shuffle enabled as text) & "\\n"
                    try
                        set pl to current playlist
                        set totalCnt to count of tracks of pl
                    on error
                        set t to current track
                        return outList & "CATALOG|" & (name of t) & "|" & (artist of t) & "|" & (album of t) & "\\n"
                    end try
                    set curIdx to index of current track
                    repeat with i from (curIdx + 1) to (curIdx + 10)
                        if i <= totalCnt then
                            set t to track i of pl
                            set outList to outList & i & "|" & (name of t) & "|" & (artist of t) & "|" & (duration of t) & "\\n"
                        end if
                    end repeat
                    if (curIdx + 1) > totalCnt and totalCnt > 1 then
                        repeat with i from 1 to 6
                            if i < curIdx and i <= totalCnt then
                                set t to track i of pl
                                set outList to outList & i & "|" & (name of t) & "|" & (artist of t) & "|" & (duration of t) & "\\n"
                            end if
                        end repeat
                    end if
                    return outList
                end if
            end tell
            """
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else { return ([], false) }
                let shuffleOn = output.contains("SHUFFLE|true")
                var items: [UpNextTrackItem] = []
                for line in output.components(separatedBy: .newlines) {
                    let parts = line.components(separatedBy: "|")
                    if parts.first == "CATALOG", parts.count >= 4 {
                        // Streaming from the Apple Music catalog: Music exposes no playlist, read the album page instead
                        let upcoming = await AppleMusicWebCatalog.shared.upcomingTracks(
                            title: parts[1], artist: parts[2], album: parts[3...].joined(separator: "|")
                        )
                        for (offset, track) in upcoming.enumerated() {
                            items.append(UpNextTrackItem(
                                id: "catalog-\(offset)-\(track.title)",
                                playlistIndex: -(offset + 1),
                                title: track.title,
                                artist: track.artist,
                                duration: track.duration
                            ))
                        }
                        return (items, shuffleOn)
                    }
                    guard parts.count >= 4, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let durStr = parts[3].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                    let dur = Double(durStr) ?? 0
                    items.append(UpNextTrackItem(id: "\(idx)-\(title)", playlistIndex: idx, title: title, artist: artist, duration: dur))
                }
                return (items, shuffleOn)
            } catch {
                return ([], false)
            }
        }.value

        self.isShuffleOn = shuffleOn
        self.tracks = fetched
        applyPromotedOrder()
    }
}

struct PlayingNextView: View {
    @ObservedObject var manager = PlayingNextManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(manager.isShuffleOn ? "In This Playlist" : "Playing Next")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await manager.refreshQueue() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Refresh Queue")

                Button {
                    manager.toggleQueueView()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text("Calendar")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            if manager.isShuffleOn {
                HStack(spacing: 5) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Shuffle is on: Music hides its real order")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Button {
                        manager.turnOffShuffle()
                    } label: {
                        Text("Turn off")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("Turn off shuffle to see the real upcoming tracks")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }

            if manager.tracks.isEmpty {
                Spacer()
                VStack(spacing: 4) {
                    Text(manager.isLoading ? "Loading queue…" : "No upcoming tracks")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                    Text("Start a playlist or album in Music")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(Array(manager.tracks.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 6) {
                                Text(manager.isShuffleOn ? "·" : "\(index + 1)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(track.isPromoted ? Color.accentColor : .gray)
                                    .frame(width: 14, alignment: .leading)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.gray)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 2)

                                if index > 0 && !manager.isShuffleOn {
                                    Button {
                                        withAnimation(.smooth) {
                                            manager.promoteToTop(track)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.up.to.line")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.gray)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Move to top of Playing Next")
                                }

                                Text(track.formattedDuration)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.gray.opacity(0.8))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(track.isPromoted ? 0.12 : 0.05))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .onTapGesture {
                                manager.playTrack(track)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Element Capture & Screen Text Capture / OCR (Droppy Capture Feature)

@MainActor
final class ScreenCaptureOCRService {
    static let shared = ScreenCaptureOCRService()

    enum CaptureMode {
        case ocrText
        case areaToShelf
        case windowToShelf
    }

    func capture(mode: CaptureMode) {
        Task { @MainActor in
            // Allow the notch to close cleanly before interactive crosshair
            try? await Task.sleep(for: .milliseconds(180))
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("droppy_capture_\(Int(Date().timeIntervalSince1970)).png")

            let args: [String]
            switch mode {
            case .ocrText, .areaToShelf:
                args = ["-i", "-x", tempFile.path]
            case .windowToShelf:
                args = ["-i", "-w", "-x", tempFile.path]
            }

            let didCapture: Bool = await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = args
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempFile.path)
                } catch {
                    return false
                }
            }.value

            guard didCapture else { return }

            switch mode {
            case .ocrText:
                do {
                    let extracted = try await ImageProcessingService.shared.extractText(from: tempFile)
                    try? FileManager.default.removeItem(at: tempFile)
                    ImageProcessingService.shared.presentOCRResultModal(
                        text: extracted,
                        sourceName: "Screen Capture"
                    )
                } catch {
                    try? FileManager.default.removeItem(at: tempFile)
                }
            case .areaToShelf, .windowToShelf:
                if let bookmark = try? Bookmark(url: tempFile) {
                    let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                    ShelfStateViewModel.shared.add([item])
                    BoringViewCoordinator.shared.currentView = .shelf
                }
            }
        }
    }
}

// MARK: - Coding Agents Live Monitor & Droppy Agents UI (Claude Code / Antigravity / Codex)

enum AgentKind: String, Equatable, CaseIterable {
    case claudeCode = "Claude Code"
    case antigravity = "Antigravity"
    case codex = "Codex CLI"

    var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .antigravity: return "AGY"
        case .codex: return "Codex"
        }
    }

    var badgeIcon: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .antigravity: return "atom"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var accentColor: Color {
        switch self {
        case .claudeCode: return Color(red: 0.91, green: 0.49, blue: 0.34) // Claude coral-amber
        case .antigravity: return Color(red: 0.32, green: 0.80, blue: 0.98) // Antigravity sky-cyan
        case .codex: return Color(red: 0.16, green: 0.78, blue: 0.56) // Codex emerald
        }
    }

    var secondaryAccentColor: Color {
        switch self {
        case .claudeCode: return Color(red: 0.98, green: 0.67, blue: 0.42)
        case .antigravity: return Color(red: 0.62, green: 0.44, blue: 0.98)
        case .codex: return Color(red: 0.32, green: 0.90, blue: 0.72)
        }
    }
}

enum AgentWorkPhase: String, Equatable {
    case thinking = "Thinking"
    case editing = "Editing"
    case running = "Running"
    case reading = "Reading"
    case searching = "Searching"
    case waiting = "Ready"
    case idle = "Idle"

    var shortBadge: String {
        switch self {
        case .thinking: return "THINK"
        case .editing: return "EDIT"
        case .running: return "RUN"
        case .reading: return "READ"
        case .searching: return "FIND"
        case .waiting: return "DONE"
        case .idle: return "IDLE"
        }
    }

    var iconName: String {
        switch self {
        case .thinking: return "brain.head.profile"
        case .editing: return "pencil.and.outline"
        case .running: return "terminal.fill"
        case .reading: return "doc.text.magnifyingglass"
        case .searching: return "magnifyingglass"
        case .waiting: return "checkmark.circle.fill"
        case .idle: return "cpu.fill"
        }
    }

    var color: Color {
        switch self {
        case .thinking: return Color(red: 0.68, green: 0.52, blue: 0.98)
        case .editing: return Color(red: 0.30, green: 0.85, blue: 0.58)
        case .running: return Color(red: 0.98, green: 0.65, blue: 0.25)
        case .reading: return Color(red: 0.36, green: 0.78, blue: 0.98)
        case .searching: return Color(red: 0.48, green: 0.64, blue: 0.98)
        case .waiting: return Color.white.opacity(0.65)
        case .idle: return Color.gray
        }
    }

    static func classify(toolName: String) -> AgentWorkPhase {
        let lower = toolName.lowercased()
        if lower.contains("edit") || lower.contains("write") || lower.contains("replace") || lower.contains("patch") {
            return .editing
        }
        if lower.contains("bash") || lower.contains("command") || lower.contains("shell") || lower.contains("exec") || lower.contains("terminal") {
            return .running
        }
        if lower.contains("read") || lower.contains("view") || lower.contains("list") {
            return .reading
        }
        if lower.contains("search") || lower.contains("grep") || lower.contains("glob") || lower.contains("find") || lower.contains("web") || lower.contains("fetch") {
            return .searching
        }
        return .thinking
    }
}

struct AgentToolEvent: Identifiable, Equatable {
    let id: String
    let stepIndex: Int
    let toolName: String
    let phase: AgentWorkPhase
    let summary: String
    let targetFile: String?
    let timestamp: Date

    var iconName: String {
        phase == .thinking || phase == .waiting || phase == .idle ? "cpu.fill" : phase.iconName
    }

    var tintColor: Color {
        phase.color
    }
}

struct AgentSessionSnapshot: Identifiable, Equatable {
    let id: String
    let kind: AgentKind
    let projectName: String
    let sessionTitle: String
    let modelName: String?
    let phase: AgentWorkPhase
    let isActive: Bool
    let isWorkingNow: Bool
    let lastUpdated: Date
    let stepCount: Int
    let contextTokens: Int
    let maxContextWindow: Double
    let cacheReadTokens: Int
    let outputTokens: Int
    let filesModifiedCount: Int
    let linesAdded: Int
    let linesRemoved: Int
    let currentFile: String?
    let currentActionTitle: String
    let currentActionDetail: String
    let recentEvents: [AgentToolEvent]

    var contextPercentage: Double {
        guard maxContextWindow > 0 else { return 0 }
        return min(100.0, (Double(contextTokens) / maxContextWindow) * 100.0)
    }

    var cacheHitPercentage: Double {
        guard contextTokens > 0 else { return 0 }
        return min(100.0, (Double(cacheReadTokens) / Double(contextTokens)) * 100.0)
    }

    var formattedContextTokens: String { Self.formatCompactTokens(contextTokens) }
    var formattedMaxContext: String { Self.formatCompactTokens(Int(maxContextWindow)) }
    var formattedOutputTokens: String { Self.formatCompactTokens(outputTokens) }

    static func formatCompactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000.0
            return m == floor(m) ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000.0)
        }
        return "\(value)"
    }
}

@MainActor
final class AntigravityAgentMonitor: ObservableObject {
    static let shared = AntigravityAgentMonitor()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var isWorkingNow: Bool = false
    @Published private(set) var activeAgentCount: Int = 0
    @Published private(set) var sessions: [AgentSessionSnapshot] = []
    @Published var selectedSessionID: String? = nil

    // Backwards-compatible summary properties bound to selected (or latest) session
    @Published private(set) var conversationID: String = ""
    @Published private(set) var stepCount: Int = 0
    @Published private(set) var contextTokens: Int = 0
    @Published private(set) var cacheReadTokens: Int = 0
    @Published private(set) var totalOutputTokens: Int = 0
    @Published private(set) var filesModifiedCount: Int = 0
    @Published private(set) var currentActionTitle: String = "Idle"
    @Published private(set) var currentActionDetail: String = "Waiting for prompt…"
    @Published private(set) var recentEvents: [AgentToolEvent] = []

    private struct CachedSessionEntry: Sendable {
        let modDate: Date
        let fileSize: Int
        let snapshot: AgentSessionSnapshot
        let rawPhase: AgentWorkPhase
        let turnComplete: Bool
    }

    private struct ISODateParser {
        let frac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let basic: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parse(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            return frac.date(from: raw) ?? basic.date(from: raw)
        }
    }

    private var timer: Timer?
    private var maxContextWindow: Double = 1_000_000.0
    private var sessionCache: [String: CachedSessionEntry] = [:]
    private var isRefreshing: Bool = false

    var activeSession: AgentSessionSnapshot? {
        if let selectedSessionID, let match = sessions.first(where: { $0.id == selectedSessionID }) {
            return match
        }
        return sessions.first(where: { $0.isActive }) ?? sessions.first
    }

    var activeKind: AgentKind {
        activeSession?.kind ?? .antigravity
    }

    var activePhase: AgentWorkPhase {
        activeSession?.phase ?? .idle
    }

    var activeBrandColor: Color {
        activeKind.accentColor
    }

    var contextPercentage: Double {
        activeSession?.contextPercentage ?? min(100.0, (Double(contextTokens) / max(1.0, maxContextWindow)) * 100.0)
    }

    var cacheHitPercentage: Double {
        if let activeSession { return activeSession.cacheHitPercentage }
        guard contextTokens > 0 else { return 0 }
        return min(100.0, (Double(cacheReadTokens) / Double(contextTokens)) * 100.0)
    }

    var formattedContextTokens: String {
        AgentSessionSnapshot.formatCompactTokens(contextTokens)
    }

    var formattedOutputTokens: String {
        AgentSessionSnapshot.formatCompactTokens(totalOutputTokens)
    }

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func selectSession(_ id: String) {
        selectedSessionID = id
        syncSummaryProperties()
    }

    private func syncSummaryProperties() {
        guard let session = activeSession else {
            if !conversationID.isEmpty { conversationID = "" }
            if stepCount != 0 { stepCount = 0 }
            if contextTokens != 0 { contextTokens = 0 }
            if cacheReadTokens != 0 { cacheReadTokens = 0 }
            if totalOutputTokens != 0 { totalOutputTokens = 0 }
            if filesModifiedCount != 0 { filesModifiedCount = 0 }
            if currentActionTitle != "Idle" { currentActionTitle = "Idle" }
            if currentActionDetail != "Waiting for prompt…" { currentActionDetail = "Waiting for prompt…" }
            if !recentEvents.isEmpty { recentEvents = [] }
            maxContextWindow = 1_000_000.0
            return
        }
        let nextConvID = String(session.id.suffix(8))
        if conversationID != nextConvID { conversationID = nextConvID }
        if stepCount != session.stepCount { stepCount = session.stepCount }
        if contextTokens != session.contextTokens { contextTokens = session.contextTokens }
        if cacheReadTokens != session.cacheReadTokens { cacheReadTokens = session.cacheReadTokens }
        if totalOutputTokens != session.outputTokens { totalOutputTokens = session.outputTokens }
        if filesModifiedCount != session.filesModifiedCount { filesModifiedCount = session.filesModifiedCount }
        if currentActionTitle != session.currentActionTitle { currentActionTitle = session.currentActionTitle }
        if currentActionDetail != session.currentActionDetail { currentActionDetail = session.currentActionDetail }
        if recentEvents != session.recentEvents { recentEvents = session.recentEvents }
        maxContextWindow = session.maxContextWindow
    }

    private nonisolated static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private nonisolated static func readTailLines(from url: URL, maxBytes: UInt64 = 196_608) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if offset > 0 && !lines.isEmpty {
            // Discard partial JSON fragment at arbitrary byte boundary
            lines.removeFirst()
        }
        return lines
    }

    private nonisolated static func resolveSnapshot(from entry: CachedSessionEntry, now: Date) -> AgentSessionSnapshot {
        let s = entry.snapshot
        let age = now.timeIntervalSince(entry.modDate)
        let isActive = age < 45.0
        let isWorkingNow: Bool
        let effectivePhase: AgentWorkPhase

        switch s.kind {
        case .antigravity:
            isWorkingNow = age < 18.0
            if isWorkingNow && entry.rawPhase == .waiting {
                effectivePhase = .thinking
            } else if !isActive {
                effectivePhase = .waiting
            } else {
                effectivePhase = entry.rawPhase
            }
        case .claudeCode, .codex:
            isWorkingNow = age < 22.0 && !entry.turnComplete
            effectivePhase = (entry.turnComplete || !isActive) ? .waiting : entry.rawPhase
        }

        return AgentSessionSnapshot(
            id: s.id,
            kind: s.kind,
            projectName: s.projectName,
            sessionTitle: s.sessionTitle,
            modelName: s.modelName,
            phase: effectivePhase,
            isActive: isActive,
            isWorkingNow: isWorkingNow,
            lastUpdated: s.lastUpdated,
            stepCount: s.stepCount,
            contextTokens: s.contextTokens,
            maxContextWindow: s.maxContextWindow,
            cacheReadTokens: s.cacheReadTokens,
            outputTokens: s.outputTokens,
            filesModifiedCount: s.filesModifiedCount,
            linesAdded: s.linesAdded,
            linesRemoved: s.linesRemoved,
            currentFile: s.currentFile,
            currentActionTitle: s.currentActionTitle,
            currentActionDetail: s.currentActionDetail,
            recentEvents: s.recentEvents
        )
    }

    private nonisolated static func inferProjectName(fromPath path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        if let idx = components.firstIndex(where: { $0.contains("Développement") || $0.lowercased() == "projects" || $0.lowercased() == "repos" }),
           idx + 1 < components.count {
            return components[idx + 1]
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty || parent == "/" ? URL(fileURLWithPath: path).lastPathComponent : parent
    }

    private nonisolated static func parseAntigravitySessions(
        home: String,
        now: Date,
        dateParser: ISODateParser,
        cache: inout [String: CachedSessionEntry]
    ) -> [AgentSessionSnapshot] {
        let brainDir = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity/brain")
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)
        for dir in subdirs {
            let transcript = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if let vals = try? transcript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let modDate = vals.contentModificationDate,
               modDate > cutoff {
                candidates.append((transcript, dir.lastPathComponent, modDate, vals.fileSize ?? 0))
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var snapshots: [AgentSessionSnapshot] = []
        for candidate in candidates.prefix(3) {
            let key = "ag:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                snapshots.append(resolveSnapshot(from: cached, now: now))
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

            var lastStep = 0
            var lastContext = 0
            var lastCache = 0
            var sumOutput = 0
            var editCount = 0
            var latestTitle = "Antigravity Ready"
            var latestDetail = "Session active"
            var latestPhase: AgentWorkPhase = .waiting
            var latestFile: String? = nil
            var inferredProject = "Antigravity"
            var events: [AgentToolEvent] = []
            var lastStepDate: Date = candidate.modDate
            var lastRecordType = ""

            for line in lines.suffix(160) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let stepIdx = (obj["step_index"] as? Int) ?? lastStep
                lastStep = max(lastStep, stepIdx)
                lastRecordType = (obj["type"] as? String) ?? lastRecordType

                if let d = dateParser.parse(obj["created_at"] as? String) {
                    lastStepDate = d
                }

                let inTok = (obj["input_tokens"] as? Int) ?? 0
                let cacheTok = (obj["cache_read_tokens"] as? Int) ?? 0
                let outTok = (obj["output_tokens"] as? Int) ?? 0
                if inTok + cacheTok > 0 {
                    lastContext = inTok + cacheTok
                    lastCache = cacheTok
                }
                sumOutput += outTok

                if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for tc in toolCalls {
                        let name = (tc["name"] as? String) ?? "tool"
                        let args = (tc["args"] as? [String: Any]) ?? [:]
                        let phase = AgentWorkPhase.classify(toolName: name)
                        if phase == .editing { editCount += 1 }

                        var targetFile: String? = nil
                        if let path = (args["Path"] as? String) ?? (args["TargetFile"] as? String) ?? (args["AbsolutePath"] as? String) {
                            let clean = path.replacingOccurrences(of: "\"", with: "")
                            targetFile = URL(fileURLWithPath: clean).lastPathComponent
                            let isWorkspacePath = clean.contains("Développement")
                                || clean.localizedCaseInsensitiveContains("/projects/")
                                || clean.localizedCaseInsensitiveContains("/repos/")
                            let proj = inferProjectName(fromPath: clean)
                            if !proj.isEmpty && proj != "/" && (inferredProject == "Antigravity" || isWorkspacePath) {
                                inferredProject = proj
                            }
                        }

                        let detail: String
                        if let summary = args["toolSummary"] as? String, !summary.isEmpty {
                            detail = summary.replacingOccurrences(of: "\"", with: "")
                        } else if let targetFile {
                            detail = targetFile
                        } else if let cmd = args["CommandLine"] as? String {
                            detail = String(cmd.prefix(64))
                        } else {
                            detail = name
                        }

                        latestTitle = name
                        latestDetail = detail
                        latestPhase = phase
                        if let targetFile { latestFile = targetFile }

                        events.append(
                            AgentToolEvent(
                                id: "ag-\(candidate.id.prefix(6))-\(stepIdx)-\(events.count)",
                                stepIndex: stepIdx,
                                toolName: name,
                                phase: phase,
                                summary: detail,
                                targetFile: targetFile,
                                timestamp: lastStepDate
                            )
                        )
                    }
                } else if lastRecordType == "USER_INPUT" {
                    latestPhase = .thinking
                    latestTitle = "Processing prompt"
                    latestDetail = "Analyzing context…"
                }
            }

            let baseSnapshot = AgentSessionSnapshot(
                id: key,
                kind: .antigravity,
                projectName: inferredProject,
                sessionTitle: "Step #\(lastStep)",
                modelName: "Gemini",
                phase: latestPhase,
                isActive: false,
                isWorkingNow: false,
                lastUpdated: candidate.modDate,
                stepCount: lastStep,
                contextTokens: lastContext,
                maxContextWindow: 1_000_000.0,
                cacheReadTokens: lastCache,
                outputTokens: sumOutput,
                filesModifiedCount: editCount,
                linesAdded: 0,
                linesRemoved: 0,
                currentFile: latestFile,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed())
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: false
            )
            cache[key] = entry
            snapshots.append(resolveSnapshot(from: entry, now: now))
        }
        return snapshots
    }

    private nonisolated static func parseClaudeSessions(
        home: String,
        now: Date,
        dateParser: ISODateParser,
        cache: inout [String: CachedSessionEntry]
    ) -> [AgentSessionSnapshot] {
        let projectsDir = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        guard let projectFolders = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)

        for folder in projectFolders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let modDate = vals.contentModificationDate,
                   modDate > cutoff {
                    candidates.append((file, file.deletingPathExtension().lastPathComponent, modDate, vals.fileSize ?? 0))
                }
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var snapshots: [AgentSessionSnapshot] = []
        for candidate in candidates.prefix(4) {
            let key = "cc:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                snapshots.append(resolveSnapshot(from: cached, now: now))
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

            var projectName = "Claude Code"
            var sessionTitle = ""
            var modelDisplay: String? = nil
            var contextTokens = 0
            var cacheRead = 0
            var sumOutput = 0
            var stepCounter = 0
            var editCount = 0
            var linesAdded = 0
            var linesRemoved = 0
            var latestTitle = "Claude Ready"
            var latestDetail = "Session active"
            var latestPhase: AgentWorkPhase = .waiting
            var latestFile: String? = nil
            var events: [AgentToolEvent] = []
            var eventTime = candidate.modDate
            var lastTurnComplete = false

            for line in lines.suffix(180) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let rowType = (obj["type"] as? String) ?? ""
                if let d = dateParser.parse(obj["timestamp"] as? String) {
                    eventTime = d
                }
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                }

                if rowType == "ai-title", let title = obj["aiTitle"] as? String, !title.isEmpty {
                    sessionTitle = title
                    continue
                }
                if rowType == "cost-state" {
                    linesAdded = max(linesAdded, (obj["totalLinesAdded"] as? Int) ?? 0)
                    linesRemoved = max(linesRemoved, (obj["totalLinesRemoved"] as? Int) ?? 0)
                    continue
                }
                if rowType == "system" {
                    let subtype = (obj["subtype"] as? String) ?? ""
                    if subtype == "turn_duration" || subtype == "stop_hook_summary" {
                        lastTurnComplete = true
                    }
                    continue
                }

                guard rowType == "assistant", let message = obj["message"] as? [String: Any] else {
                    if rowType == "user" && ((obj["isMeta"] as? Bool) != true) {
                        lastTurnComplete = false
                        latestPhase = .thinking
                        latestTitle = "Thinking"
                        latestDetail = sessionTitle.isEmpty ? "Analyzing context…" : sessionTitle
                    }
                    continue
                }

                lastTurnComplete = false
                stepCounter += 1

                if let model = message["model"] as? String, !model.isEmpty {
                    modelDisplay = formatClaudeModelName(model)
                }

                if let usage = message["usage"] as? [String: Any] {
                    let inTok = (usage["input_tokens"] as? Int) ?? 0
                    let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let cRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let outTok = (usage["output_tokens"] as? Int) ?? 0
                    let totalIn = inTok + cacheCreate + cRead
                    if totalIn > 0 {
                        contextTokens = totalIn
                        cacheRead = cRead
                    }
                    sumOutput += outTok
                }

                if let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        let cType = (item["type"] as? String) ?? ""
                        if cType == "thinking" {
                            latestPhase = .thinking
                            latestTitle = "Thinking"
                            latestDetail = sessionTitle.isEmpty ? "Reasoning…" : sessionTitle
                        } else if cType == "tool_use" {
                            let name = (item["name"] as? String) ?? "Tool"
                            let input = (item["input"] as? [String: Any]) ?? [:]
                            let phase = AgentWorkPhase.classify(toolName: name)
                            if phase == .editing { editCount += 1 }

                            var targetFile: String? = nil
                            if let fp = input["file_path"] as? String, !fp.isEmpty {
                                targetFile = URL(fileURLWithPath: fp).lastPathComponent
                            }

                            let detail: String
                            if let desc = input["description"] as? String, !desc.isEmpty {
                                detail = desc
                            } else if let targetFile {
                                detail = targetFile
                            } else if let cmd = input["command"] as? String, !cmd.isEmpty {
                                detail = String(cmd.prefix(64))
                            } else if let pattern = input["pattern"] as? String, !pattern.isEmpty {
                                detail = pattern
                            } else {
                                detail = name
                            }

                            latestTitle = name
                            latestDetail = detail
                            latestPhase = phase
                            if let targetFile { latestFile = targetFile }

                            events.append(
                                AgentToolEvent(
                                    id: "cc-\(candidate.id.prefix(6))-\(stepCounter)-\(events.count)",
                                    stepIndex: stepCounter,
                                    toolName: name,
                                    phase: phase,
                                    summary: detail,
                                    targetFile: targetFile,
                                    timestamp: eventTime
                                )
                            )
                        }
                    }
                }
            }

            let windowSize: Double = contextTokens > 200_000 ? 1_000_000.0 : 200_000.0
            let baseSnapshot = AgentSessionSnapshot(
                id: key,
                kind: .claudeCode,
                projectName: projectName,
                sessionTitle: sessionTitle,
                modelName: modelDisplay,
                phase: latestPhase,
                isActive: false,
                isWorkingNow: false,
                lastUpdated: candidate.modDate,
                stepCount: stepCounter,
                contextTokens: contextTokens,
                maxContextWindow: windowSize,
                cacheReadTokens: cacheRead,
                outputTokens: sumOutput,
                filesModifiedCount: editCount,
                linesAdded: linesAdded,
                linesRemoved: linesRemoved,
                currentFile: latestFile,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed())
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: lastTurnComplete
            )
            cache[key] = entry
            snapshots.append(resolveSnapshot(from: entry, now: now))
        }
        return snapshots
    }

    private nonisolated static func parseCodexSessions(
        home: String,
        now: Date,
        dateParser: ISODateParser,
        cache: inout [String: CachedSessionEntry]
    ) -> [AgentSessionSnapshot] {
        let sessionsRoot = URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, id: String, modDate: Date, fileSize: Int)] = []
        let cutoff = now.addingTimeInterval(-86_400)
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let modDate = vals.contentModificationDate,
               modDate > cutoff {
                candidates.append((fileURL, fileURL.deletingPathExtension().lastPathComponent, modDate, vals.fileSize ?? 0))
            }
        }
        candidates.sort { $0.modDate > $1.modDate }

        var snapshots: [AgentSessionSnapshot] = []
        for candidate in candidates.prefix(2) {
            let key = "cx:\(candidate.id)"
            if let cached = cache[key],
               cached.modDate == candidate.modDate,
               cached.fileSize == candidate.fileSize {
                snapshots.append(resolveSnapshot(from: cached, now: now))
                continue
            }

            let lines = readTailLines(from: candidate.url)
            guard !lines.isEmpty else { continue }

            var projectName = "Codex"
            var windowSize: Double = 200_000.0
            var contextTokens = 0
            var cacheRead = 0
            var sumOutput = 0
            var stepCounter = 0
            var editCount = 0
            var latestTitle = "Codex Ready"
            var latestDetail = "Session active"
            var latestPhase: AgentWorkPhase = .waiting
            var events: [AgentToolEvent] = []
            var eventTime = candidate.modDate
            var taskComplete = false

            for line in lines.suffix(150) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let rowType = (obj["type"] as? String) ?? ""
                if let d = dateParser.parse(obj["timestamp"] as? String) {
                    eventTime = d
                }

                let payload = obj["payload"] as? [String: Any]
                if rowType == "session_meta", let cwd = payload?["cwd"] as? String, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                } else if rowType == "event_msg", let payload {
                    let pType = (payload["type"] as? String) ?? ""
                    if pType == "task_started" {
                        taskComplete = false
                        if let win = payload["model_context_window"] as? Int, win > 0 {
                            windowSize = Double(win)
                        }
                        latestPhase = .thinking
                    } else if pType == "task_complete" {
                        taskComplete = true
                        latestPhase = .waiting
                    } else if pType == "token_count", let info = payload["info"] as? [String: Any] {
                        if let last = info["last_token_usage"] as? [String: Any] {
                            let inTok = (last["input_tokens"] as? Int) ?? 0
                            let cached = (last["cached_input_tokens"] as? Int) ?? 0
                            let outTok = (last["output_tokens"] as? Int) ?? 0
                            if inTok > 0 { contextTokens = inTok; cacheRead = cached }
                            sumOutput = max(sumOutput, outTok)
                        }
                        if let win = info["model_context_window"] as? Int, win > 0 {
                            windowSize = Double(win)
                        }
                    }
                } else if rowType == "response_item", let payload {
                    let pType = (payload["type"] as? String) ?? ""
                    if pType == "function_call" || pType == "custom_tool_call" {
                        stepCounter += 1
                        let name = (payload["name"] as? String) ?? "tool"
                        let phase = AgentWorkPhase.classify(toolName: name)
                        if phase == .editing { editCount += 1 }
                        latestTitle = name
                        latestDetail = projectName
                        latestPhase = phase
                        events.append(
                            AgentToolEvent(
                                id: "cx-\(candidate.id.prefix(6))-\(stepCounter)-\(events.count)",
                                stepIndex: stepCounter,
                                toolName: name,
                                phase: phase,
                                summary: name,
                                targetFile: nil,
                                timestamp: eventTime
                            )
                        )
                    }
                }
            }

            let baseSnapshot = AgentSessionSnapshot(
                id: key,
                kind: .codex,
                projectName: projectName,
                sessionTitle: "",
                modelName: "Codex",
                phase: latestPhase,
                isActive: false,
                isWorkingNow: false,
                lastUpdated: candidate.modDate,
                stepCount: stepCounter,
                contextTokens: contextTokens,
                maxContextWindow: windowSize,
                cacheReadTokens: cacheRead,
                outputTokens: sumOutput,
                filesModifiedCount: editCount,
                linesAdded: 0,
                linesRemoved: 0,
                currentFile: nil,
                currentActionTitle: latestTitle,
                currentActionDetail: latestDetail,
                recentEvents: Array(events.suffix(12).reversed())
            )
            let entry = CachedSessionEntry(
                modDate: candidate.modDate,
                fileSize: candidate.fileSize,
                snapshot: baseSnapshot,
                rawPhase: latestPhase,
                turnComplete: taskComplete
            )
            cache[key] = entry
            snapshots.append(resolveSnapshot(from: entry, now: now))
        }
        return snapshots
    }

    private nonisolated static func formatClaudeModelName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("opus-4-6") { return "Opus 4.6" }
        if lower.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if lower.contains("haiku-4-5") { return "Haiku 4.5" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("haiku") { return "Haiku" }
        return raw
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let initialCache = sessionCache

        Task.detached(priority: .utility) {
            let home = Self.realHomeDirectory()
            let now = Date()
            let dateParser = ISODateParser()
            var nextCache = initialCache

            var combined: [AgentSessionSnapshot] = []
            combined.append(contentsOf: Self.parseClaudeSessions(home: home, now: now, dateParser: dateParser, cache: &nextCache))
            combined.append(contentsOf: Self.parseAntigravitySessions(home: home, now: now, dateParser: dateParser, cache: &nextCache))
            combined.append(contentsOf: Self.parseCodexSessions(home: home, now: now, dateParser: dateParser, cache: &nextCache))

            combined.sort { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                if lhs.isWorkingNow != rhs.isWorkingNow { return lhs.isWorkingNow && !rhs.isWorkingNow }
                return lhs.lastUpdated > rhs.lastUpdated
            }

            let trimmed = Array(combined.prefix(6))
            let validKeys = Set(trimmed.map { $0.id })
            nextCache = nextCache.filter { validKeys.contains($0.key) }

            let activeSessions = trimmed.filter { $0.isActive }
            let anyActive = !activeSessions.isEmpty
            let anyWorking = activeSessions.contains { $0.isWorkingNow }
            let updatedCache = nextCache

            await MainActor.run {
                let mon = AntigravityAgentMonitor.shared
                mon.isRefreshing = false
                mon.sessionCache = updatedCache

                AgentSpeechBubbleController.shared.announceTransitions(from: mon.sessions, to: trimmed)
                if mon.sessions != trimmed { mon.sessions = trimmed }
                if mon.isActive != anyActive { mon.isActive = anyActive }
                if mon.isWorkingNow != anyWorking { mon.isWorkingNow = anyWorking }
                if mon.activeAgentCount != activeSessions.count { mon.activeAgentCount = activeSessions.count }

                // Auto-follow newest active session unless the user explicitly clicked a session
                if let currentSelected = mon.selectedSessionID,
                   !trimmed.contains(where: { $0.id == currentSelected }) {
                    mon.selectedSessionID = nil
                }
                if mon.selectedSessionID == nil {
                    mon.selectedSessionID = activeSessions.first?.id ?? trimmed.first?.id
                }
                mon.syncSummaryProperties()
            }
        }
    }
}

// MARK: - Closed-Notch Droppy Agent Wing Live Activity

struct AgentCompactWaveform: View {
    let isWorking: Bool
    let color: Color
    let secondaryColor: Color

    var body: some View {
        Group {
            if isWorking {
                TimelineView(.periodic(from: .now, by: 0.34)) { context in
                    let tick = Int(context.date.timeIntervalSince1970 * 3)
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { index in
                            let height: CGFloat = [6, 11, 8, 13, 7, 10][(tick + index * 2) % 6]
                            Capsule()
                                .fill(index == 1 ? secondaryColor : color)
                                .frame(width: 2.2, height: height)
                                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: tick)
                        }
                    }
                    .frame(height: 14, alignment: .center)
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill((index == 1 ? secondaryColor : color).opacity(0.65))
                            .frame(width: 2.2, height: 4)
                    }
                }
                .frame(height: 14, alignment: .center)
            }
        }
    }
}

struct AgentClosedNotchView: View {
    @ObservedObject var monitor = AntigravityAgentMonitor.shared
    let closedHeight: CGFloat
    let centerSpacerWidth: CGFloat

    private var wingHeight: CGFloat {
        max(18, closedHeight - 8)
    }

    private var brandColor: Color {
        monitor.activeBrandColor
    }

    private var secondaryColor: Color {
        monitor.activeKind.secondaryAccentColor
    }

    var body: some View {
        let session = monitor.activeSession
        let phase = session?.phase ?? .thinking
        let working = session?.isWorkingNow ?? monitor.isWorkingNow
        let pct = max(0, min(100, Int(round(monitor.contextPercentage))))

        HStack(spacing: 0) {
            // Left ear: Pulsing Droppy orb + active phase/agent icon
            HStack(spacing: 5) {
                AgentPixelMascot(
                    kind: monitor.activeKind,
                    isWorking: working,
                    isActive: session?.isActive ?? monitor.isActive,
                    pixel: 1.5
                )
                Text(monitor.activeKind.shortLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(width: 74, height: wingHeight, alignment: .center)
            .background(
                Capsule()
                    .fill(brandColor.opacity(0.14))
                    .overlay(
                        Capsule()
                            .strokeBorder(brandColor.opacity(0.32), lineWidth: 0.75)
                    )
            )

            Rectangle()
                .fill(.black)
                .frame(width: max(20, centerSpacerWidth))

            // Right ear: Waveform + Phase/Count/Context Gauge
            HStack(spacing: 5) {
                AgentCompactWaveform(
                    isWorking: working,
                    color: brandColor,
                    secondaryColor: secondaryColor
                )

                Text(monitor.activeAgentCount > 1 ? "\(monitor.activeAgentCount)× · \(pct)%" : "\(pct)%")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(width: 74, height: wingHeight, alignment: .center)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
            )
        }
        .frame(height: closedHeight, alignment: .center)
        .help("\(monitor.activeKind.rawValue) (\(phase.rawValue)) — Click to inspect Agents")
    }
}

struct AgentPulsingOrb: View {
    let color: Color
    let isWorking: Bool
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isWorking {
                Circle()
                    .fill(color.opacity(pulse ? 0.08 : 0.45))
                    .frame(width: size * (pulse ? 2.1 : 1.3), height: size * (pulse ? 2.1 : 1.3))
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(isWorking ? 0.85 : 0.35), radius: isWorking ? 4 : 1)
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .onAppear {
            if isWorking {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .onChange(of: isWorking) { _, working in
            if working {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    pulse = false
                }
            }
        }
    }
}

// MARK: - Expanded Notch Agent Hub (Droppy Agents Droplet)

struct AgentsNotchView: View {
    @ObservedObject var monitor = AntigravityAgentMonitor.shared

    var body: some View {
        Group {
            if let session = monitor.activeSession {
                VStack(spacing: 5) {
                    if monitor.sessions.count > 1 {
                        AgentSessionSwitcherBar(
                            sessions: monitor.sessions,
                            selectedID: session.id,
                            activeCount: monitor.activeAgentCount,
                            onSelect: { monitor.selectSession($0) }
                        )
                        .frame(height: 21)
                    }

                    HStack(spacing: 8) {
                        AgentStatusCard(session: session)
                            .frame(width: 262)

                        AgentToolStreamCard(session: session)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                AgentsEmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AgentSessionSwitcherBar: View {
    let sessions: [AgentSessionSnapshot]
    let selectedID: String
    let activeCount: Int
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(sessions) { session in
                        let isSelected = session.id == selectedID
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                onSelect(session.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(session.isActive ? session.kind.accentColor : Color.white.opacity(0.28))
                                    .frame(width: 5, height: 5)
                                Text(session.kind.shortLabel)
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                                Text("· \(session.projectName)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(isSelected ? .white.opacity(0.84) : .gray)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? session.kind.accentColor.opacity(0.20) : Color.white.opacity(0.05))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                isSelected ? session.kind.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                                                lineWidth: 0.8
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, activeCount > 0 ? 10 : 2)
            }
            .mask(
                HStack(spacing: 0) {
                    Rectangle().fill(Color.white)
                    if activeCount > 0 {
                        LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 14)
                    }
                }
            )

            if activeCount > 0 {
                Text("\(activeCount) running")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            }
        }
    }
}

private struct AgentStatusCard: View {
    let session: AgentSessionSnapshot

    private var accent: Color { session.kind.accentColor }
    private var secondary: Color { session.kind.secondaryAccentColor }

    private var actionHeadline: String {
        if let file = session.currentFile {
            if session.currentActionDetail != file && !session.currentActionDetail.isEmpty {
                return "\(file) · \(session.currentActionDetail)"
            }
            return file
        }
        if !session.currentActionDetail.isEmpty && session.currentActionDetail != session.currentActionTitle {
            return "\(session.currentActionTitle) · \(session.currentActionDetail)"
        }
        return session.currentActionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Identity Row
            HStack(spacing: 6) {
                AgentPixelMascot(
                    kind: session.kind,
                    isWorking: session.isWorkingNow,
                    isActive: session.isActive,
                    pixel: 2
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(session.kind.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let model = session.modelName {
                            Text(model)
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                    Text(session.sessionTitle.isEmpty ? session.projectName : "\(session.projectName) · \(session.sessionTitle)")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 3.5) {
                    if session.isWorkingNow {
                        AgentCompactWaveform(isWorking: true, color: accent, secondaryColor: secondary)
                    }
                    Text(session.phase.rawValue)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(session.isActive ? session.phase.color : .gray)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(session.isActive ? session.phase.color.opacity(0.16) : Color.white.opacity(0.06))
                )
            }

            Spacer(minLength: 3)

            // Active File / Command Highlight Pill (compact single line)
            HStack(spacing: 5) {
                Image(systemName: session.phase.iconName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(session.phase.color)
                    .frame(width: 13)

                Text(actionHeadline)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if session.linesAdded > 0 || session.linesRemoved > 0 {
                    HStack(spacing: 4) {
                        Text("+\(session.linesAdded)")
                            .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.56))
                        Text("-\(session.linesRemoved)")
                            .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.42))
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(alignment: .bottom) {
                        if session.isWorkingNow {
                            AgentActivityBar(color: accent)
                                .frame(height: 2)
                                .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(session.isWorkingNow ? accent.opacity(0.28) : Color.white.opacity(0.07), lineWidth: 0.8)
                    )
            )
            .animation(.easeInOut(duration: 0.25), value: session.isWorkingNow)

            Spacer(minLength: 3)

            // Context Window Progress Gauge
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Context")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("\(session.formattedContextTokens) / \(session.formattedMaxContext) · \(String(format: "%.0f%%", session.contextPercentage))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(session.contextPercentage > 80 ? Color.orange : .white.opacity(0.9))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: session.contextPercentage > 82
                                        ? [.orange, .red]
                                        : [accent, secondary],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(5, geo.size.width * CGFloat(session.contextPercentage / 100.0)))
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 3)

            // Compact 3-Metric Swiss Telemetry Footer (single-line chips)
            HStack(spacing: 5) {
                if session.linesAdded > 0 || session.linesRemoved > 0 {
                    metricChip(
                        label: "Diff",
                        value: "+\(session.linesAdded)-\(session.linesRemoved)",
                        valueColor: .green
                    )
                } else {
                    metricChip(label: "Edits", value: "\(session.filesModifiedCount)", valueColor: .white)
                }
                metricChip(label: "Cache", value: String(format: "%.0f%%", session.cacheHitPercentage), valueColor: .white)
                metricChip(label: "Out", value: session.formattedOutputTokens, valueColor: .white)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    (session.isWorkingNow ? accent : Color.white).opacity(0.24),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
        )
    }

    private func metricChip(label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }
}

private struct AgentToolStreamCard: View {
    let session: AgentSessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Progress")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("Step #\(session.stepCount)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if session.recentEvents.isEmpty {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Waiting for agent tool calls…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(session.recentEvents.enumerated()), id: \.element.id) { index, ev in
                            let isNewest = index == 0 && session.isWorkingNow
                            HStack(spacing: 6) {
                                AgentStepMarker(isCurrent: isNewest, color: session.kind.accentColor)
                                    .frame(width: 17, height: 17)

                                HStack(spacing: 4) {
                                    Text(ev.toolName)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(1)
                                    if let file = ev.targetFile {
                                        Text(file)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(ev.tintColor)
                                            .lineLimit(1)
                                    } else if ev.summary != ev.toolName && !ev.summary.isEmpty {
                                        Text(ev.summary)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .lineLimit(1)
                                    }
                                    if ev.targetFile != nil && ev.summary != ev.targetFile && ev.summary != ev.toolName && !ev.summary.isEmpty {
                                        Text("· \(ev.summary)")
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(.white.opacity(0.45))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 4)

                                Text(relativeAgeText(ev.timestamp))
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isNewest ? session.kind.accentColor.opacity(0.11) : Color.white.opacity(0.045))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                isNewest ? session.kind.accentColor.opacity(0.28) : Color.clear,
                                                lineWidth: 0.8
                                            )
                                    )
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.recentEvents.first?.id)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.9)
                )
        )
    }

    private func relativeAgeText(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h"
    }
}

private struct AgentsEmptyStateView: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("No Coding Agents Running")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text("Claude Code, Antigravity & Codex sessions appear here live")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
    }
}

// MARK: - Lock Screen Music Player Panel via SkyLightWindow (Droppy Lock Screen Music UI)

@MainActor
final class DroppyLockScreenMediaPanelManager: ObservableObject {
    static let shared = DroppyLockScreenMediaPanelManager()

    private var panelWindow: BoringNotchSkyLightWindow?
    private var panelScreen: NSScreen?
    private var wallpaperTransitionID: Int = 0
    @Published private(set) var isPreviewVisible: Bool = false
    /// Artwork (animated when available) fills the whole screen behind the player.
    @Published private(set) var isWallpaperMode: Bool = false
    /// The panel window currently covers the whole screen (stays true while the wallpaper fades out).
    @Published private(set) var isWindowExpanded: Bool = false
    @Published private(set) var cardBottomInset: CGFloat = 0

    private func compactFrame(on screen: NSScreen) -> NSRect {
        let envelopeWidth: CGFloat = 436
        let envelopeHeight: CGFloat = 390
        let originX = screen.frame.midX - (envelopeWidth / 2)
        // Center comfortably in the fractal area, lowered cleanly above the login avatar (~195pt) and well below the clock
        let targetCenterY = screen.frame.origin.y + (screen.frame.height * 0.35)
        let originY = max(screen.frame.origin.y + 60, targetCenterY - (envelopeHeight / 2))
        return NSRect(x: originX, y: originY, width: envelopeWidth, height: envelopeHeight)
    }

    func toggleWallpaperMode() {
        guard let window = panelWindow, let screen = panelScreen else { return }
        wallpaperTransitionID += 1
        let transitionID = wallpaperTransitionID
        if !isPreviewVisible { Defaults[.lockScreenArtworkWallpaper] = !isWallpaperMode }
        if !isWallpaperMode {
            cardBottomInset = compactFrame(on: screen).minY - screen.frame.minY
            isWindowExpanded = true
            window.setFrame(screen.frame, display: true)
            withAnimation(.easeInOut(duration: 0.45)) {
                isWallpaperMode = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                isWallpaperMode = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.wallpaperTransitionID == transitionID, !self.isWallpaperMode else { return }
                self.isWindowExpanded = false
                window.setFrame(self.compactFrame(on: screen), display: true)
            }
        }
    }

    private func resetWallpaperMode() {
        wallpaperTransitionID += 1
        isWallpaperMode = false
        isWindowExpanded = false
    }

    static func hasActiveMedia(_ music: MusicManager? = nil) -> Bool {
        let music = music ?? MusicManager.shared
        return !(music.songTitle == "I'm Handsome"
          && music.bundleIdentifier == nil
          && music.songDuration <= 0
          && !music.isPlaying)
    }

    func showOnLockScreen() {
        isPreviewVisible = false
        guard Defaults[.showOnLockScreen], Defaults[.lockScreenMediaPlayer] else { return }
        presentPanel(delegateToSkyLight: true)
    }

    func hideFromLockScreen() {
        isPreviewVisible = false
        resetWallpaperMode()
        guard let window = panelWindow else { return }
        window.disableSkyLight()
        window.orderOut(nil)
        // Drop the SwiftUI tree so a looping artwork video stops playing while hidden
        window.contentView = nil
    }

    func togglePreviewOnDesktop() {
        if isPreviewVisible {
            hideFromLockScreen()
        } else {
            isPreviewVisible = true
            presentPanel(delegateToSkyLight: false)
        }
    }

    private func presentPanel(delegateToSkyLight: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        resetWallpaperMode()
        panelScreen = screen
        let frame = compactFrame(on: screen)

        if Self.hasActiveMedia()
            && MusicManager.shared.currentLyrics.isEmpty
            && MusicManager.shared.syncedLyrics.isEmpty
            && !MusicManager.shared.isFetchingLyrics {
            MusicManager.shared.refreshLyrics()
        }

        let window: BoringNotchSkyLightWindow
        if let existing = panelWindow {
            window = existing
        } else {
            window = BoringNotchSkyLightWindow(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            panelWindow = window
        }

        window.setFrame(frame, display: true)
        let rootView = LockScreenPanelRootView(
            onClosePreview: delegateToSkyLight ? nil : { [weak self] in
                self?.hideFromLockScreen()
            }
        )
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        // Wallpaper mode is a lasting choice: restore it on every lock until the user turns it off
        if delegateToSkyLight && Defaults[.lockScreenArtworkWallpaper] && Self.hasActiveMedia() {
            cardBottomInset = frame.minY - screen.frame.minY
            isWindowExpanded = true
            isWallpaperMode = true
            window.setFrame(screen.frame, display: true)
        }

        if delegateToSkyLight {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }
        window.orderFrontRegardless()
    }
}

struct DroppyLockScreenMediaPanelView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.lockScreenShowLyrics) private var lockScreenShowLyrics
    @State private var isArtworkExpanded: Bool = false
    @State private var showAudioDrawer: Bool = false
    @State private var showRemainingTime: Bool = true
    var onClosePreview: (() -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: musicManager.isPlaying ? 0.2 : 1.5)) { context in
            LockScreenMediaCardContainer(
                currentDate: context.date,
                showLyricsCard: lockScreenShowLyrics,
                onToggleLyrics: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        lockScreenShowLyrics.toggle()
                    }
                    if DroppyLockScreenMediaPanelManager.hasActiveMedia(musicManager)
                        && musicManager.currentLyrics.isEmpty
                        && musicManager.syncedLyrics.isEmpty {
                        musicManager.refreshLyrics()
                    }
                },
                isArtworkExpanded: $isArtworkExpanded,
                showAudioDrawer: $showAudioDrawer,
                showRemainingTime: $showRemainingTime,
                onClosePreview: onClosePreview
            )
        }
        .frame(width: 436, height: 390, alignment: .center)
        .onAppear {
            if DroppyLockScreenMediaPanelManager.hasActiveMedia(musicManager)
                && musicManager.currentLyrics.isEmpty
                && musicManager.syncedLyrics.isEmpty
                && !musicManager.isFetchingLyrics {
                musicManager.refreshLyrics()
            }
        }
    }
}

private struct LockScreenMediaCardContainer: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject private var panelManager = DroppyLockScreenMediaPanelManager.shared
    @Default(.lockScreenMediaAmbientGlow) private var ambientGlowEnabled

    let currentDate: Date
    let showLyricsCard: Bool
    let onToggleLyrics: () -> Void
    @Binding var isArtworkExpanded: Bool
    @Binding var showAudioDrawer: Bool
    @Binding var showRemainingTime: Bool
    let onClosePreview: (() -> Void)?

    private var hasMediaTrack: Bool {
        DroppyLockScreenMediaPanelManager.hasActiveMedia(musicManager)
    }

    private var albumAccent: Color {
        Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.65)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)

            if ambientGlowEnabled && hasMediaTrack {
                Circle()
                    .fill(albumAccent.opacity(musicManager.isPlaying ? 0.30 : 0.14))
                    .frame(width: 300, height: 180)
                    .blur(radius: 52)
                    .animation(.easeInOut(duration: 0.6), value: musicManager.isPlaying)
            }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(panelManager.isWallpaperMode ? 0 : 1)
    }

    var body: some View {
        let elapsed = musicManager.estimatedPlaybackPosition(at: currentDate)

        VStack(spacing: 10) {
            LockScreenArtworkHeader(
                hasMediaTrack: hasMediaTrack,
                albumAccent: albumAccent,
                showLyricsCard: showLyricsCard,
                onToggleLyrics: onToggleLyrics,
                isArtworkExpanded: $isArtworkExpanded,
                onExpandCollapseDrawer: {
                    if $0 { showAudioDrawer = false }
                },
                onClosePreview: onClosePreview
            )

            if hasMediaTrack && showLyricsCard {
                LockScreenSyncedLyricsCard(
                    elapsed: elapsed,
                    duration: musicManager.songDuration,
                    albumAccent: albumAccent
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if hasMediaTrack {
                LockScreenScrubBar(
                    elapsed: elapsed,
                    duration: musicManager.songDuration,
                    accentColor: albumAccent,
                    showRemainingTime: $showRemainingTime
                )
            }

            LockScreenTransportControls(
                hasMediaTrack: hasMediaTrack,
                albumAccent: albumAccent,
                showAudioDrawer: $showAudioDrawer,
                onOpenAudioDrawer: {
                    if $0 { isArtworkExpanded = false }
                }
            )

            if showAudioDrawer {
                LockScreenAudioDrawer(accentColor: albumAccent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 396)
        .background(cardBackground)
        .shadow(
            color: panelManager.isWallpaperMode
                ? .clear
                : ((ambientGlowEnabled && musicManager.isPlaying && hasMediaTrack)
                    ? albumAccent.opacity(0.18)
                    : .black.opacity(0.32)),
            radius: 18,
            y: 8
        )
        .shadow(color: panelManager.isWallpaperMode ? .clear : .black.opacity(0.34), radius: 12, y: 6)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: showLyricsCard)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: isArtworkExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showAudioDrawer)
    }
}

private struct LockScreenArtworkHeader: View {
    @ObservedObject var musicManager = MusicManager.shared
    let hasMediaTrack: Bool
    let albumAccent: Color
    let showLyricsCard: Bool
    let onToggleLyrics: () -> Void
    @Binding var isArtworkExpanded: Bool
    var onExpandCollapseDrawer: (Bool) -> Void
    var onClosePreview: (() -> Void)?

    var body: some View {
        VStack(spacing: isArtworkExpanded ? 10 : 0) {
            if isArtworkExpanded && hasMediaTrack {
                HStack(alignment: .top, spacing: 14) {
                    artworkView(size: 86, radius: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(musicManager.songTitle)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            topRightUtilityCluster
                        }

                        Text(musicManager.artistName.isEmpty ? "Music" : musicManager.artistName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)

                        if !musicManager.album.isEmpty {
                            Text(musicManager.album)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.50))
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    if hasMediaTrack {
                        artworkView(size: 50, radius: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.09))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasMediaTrack ? musicManager.songTitle : "Nothing Playing")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(hasMediaTrack ? (musicManager.artistName.isEmpty ? "Apple Music" : musicManager.artistName) : "Press Play to start listening")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(hasMediaTrack ? .white.opacity(0.65) : .white.opacity(0.48))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    topRightUtilityCluster
                }
            }
        }
    }

    private func artworkView(size: CGFloat, radius: CGFloat) -> some View {
        Button {
            DroppyLockScreenMediaPanelManager.shared.toggleWallpaperMode()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.35), radius: musicManager.isPlaying ? 6 : 3, y: 2)

                if let bundleID = musicManager.bundleIdentifier, !musicManager.usingAppIconForArtwork {
                    AppIcon(for: bundleID)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size > 75 ? 20 : 15, height: size > 75 ? 20 : 15)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 2.5)
                        .offset(x: 2.5, y: 2.5)
                }
            }
            .scaleEffect(musicManager.isPlaying ? 1.0 : 0.90)
            .opacity(musicManager.isPlaying ? 1.0 : 0.82)
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: musicManager.isPlaying)
        }
        .buttonStyle(.plain)
        .help("Toggle full screen artwork")
    }

    private var topRightUtilityCluster: some View {
        HStack(spacing: 6) {
            if hasMediaTrack {
                Rectangle()
                    .fill(albumAccent.gradient)
                    .frame(width: 16, height: 12)
                    .mask {
                        AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                            .frame(width: 14, height: 11)
                    }
                    .opacity(musicManager.isPlaying ? 0.9 : 0.38)

                Button(action: onToggleLyrics) {
                    Image(systemName: showLyricsCard ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(showLyricsCard ? .white : .white.opacity(0.55))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(showLyricsCard ? 0.22 : 0.08)))
                }
                .buttonStyle(.plain)
                .help("Synced lyrics")
            }

            if let onClosePreview {
                Button(action: onClosePreview) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Close preview")
            }
        }
    }
}

private struct LockScreenSyncedLyricsCard: View {
    @ObservedObject var musicManager = MusicManager.shared
    let elapsed: Double
    let duration: Double
    let albumAccent: Color

    @State private var hoveredLine: Int? = nil

    private struct LyricDisplayTriple: Equatable {
        let prevText: String?
        let prevTime: Double?
        let currText: String
        let nextText: String?
        let nextTime: Double?
    }

    private func computeTriple() -> LyricDisplayTriple {
        if musicManager.isFetchingLyrics {
            return LyricDisplayTriple(prevText: nil, prevTime: nil, currText: "Loading lyrics…", nextText: nil, nextTime: nil)
        }
        if !musicManager.syncedLyrics.isEmpty {
            let synced = musicManager.syncedLyrics
            var low = 0
            var high = synced.count - 1
            var idx = 0
            while low <= high {
                let mid = (low + high) / 2
                if synced[mid].time <= elapsed {
                    idx = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            let prev = idx > 0 ? synced[idx - 1] : nil
            let curr = synced[idx]
            let next = (idx + 1) < synced.count ? synced[idx + 1] : nil
            return LyricDisplayTriple(
                prevText: prev?.text,
                prevTime: prev?.time,
                currText: curr.text,
                nextText: next?.text,
                nextTime: next?.time
            )
        }

        let plainLines = musicManager.currentLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !plainLines.isEmpty else {
            return LyricDisplayTriple(prevText: nil, prevTime: nil, currText: "♪ Instrumental / No lyrics found", nextText: nil, nextTime: nil)
        }
        let ratio = duration > 0 ? min(0.999, max(0, elapsed / duration)) : 0
        let idx = min(plainLines.count - 1, max(0, Int(Double(plainLines.count) * ratio)))
        let prev = idx > 0 ? plainLines[idx - 1] : nil
        let curr = plainLines[idx]
        let next = (idx + 1) < plainLines.count ? plainLines[idx + 1] : nil
        return LyricDisplayTriple(prevText: prev, prevTime: nil, currText: curr, nextText: next, nextTime: nil)
    }

    var body: some View {
        let triple = computeTriple()

        VStack(spacing: 3) {
            if let prev = triple.prevText, !prev.isEmpty {
                lyricRow(text: prev, seekTime: triple.prevTime, slot: 0, isCurrent: false, baseOpacity: 0.35)
            }
            lyricRow(text: triple.currText, seekTime: nil, slot: 1, isCurrent: true, baseOpacity: 1.0)
                .id(triple.currText)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            if let next = triple.nextText, !next.isEmpty {
                lyricRow(text: next, seekTime: triple.nextTime, slot: 2, isCurrent: false, baseOpacity: 0.45)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )
        )
        .animation(.easeInOut(duration: 0.22), value: triple.currText)
    }

    @ViewBuilder
    private func lyricRow(text: String, seekTime: Double?, slot: Int, isCurrent: Bool, baseOpacity: Double) -> some View {
        let isRTL = text.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
        let hovered = hoveredLine == slot && seekTime != nil
        let font = isRTL
            ? Font.custom("Vazirmatn-Regular", size: isCurrent ? 13.5 : 11)
            : Font.system(size: isCurrent ? 13.5 : 11, weight: isCurrent ? .bold : .medium, design: .rounded)

        Text(text)
            .font(font)
            .foregroundStyle(isCurrent ? Color.white : (hovered ? albumAccent : Color.white.opacity(baseOpacity)))
            .multilineTextAlignment(.center)
            .lineLimit(isCurrent ? 2 : 1)
            .shadow(color: isCurrent ? .white.opacity(0.25) : .clear, radius: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if seekTime != nil {
                    hoveredLine = inside ? slot : (hoveredLine == slot ? nil : hoveredLine)
                }
            }
            .onTapGesture {
                if let seekTime {
                    musicManager.seek(to: seekTime)
                }
            }
    }
}

private struct LockScreenScrubBar: View {
    @ObservedObject var musicManager = MusicManager.shared
    let elapsed: Double
    let duration: Double
    let accentColor: Color
    @Binding var showRemainingTime: Bool

    @State private var isDragging: Bool = false
    @State private var isHovering: Bool = false
    @State private var dragProgress: Double = 0
    @State private var optimisticTarget: Double? = nil
    @State private var lastSeekDate: Date = .distantPast

    private var effectiveProgress: Double {
        guard duration > 0 else { return 0 }
        if isDragging { return dragProgress }
        if let optimisticTarget, Date().timeIntervalSince(lastSeekDate) < 0.75 {
            return min(1, max(0, optimisticTarget / duration))
        }
        return min(1, max(0, elapsed / duration))
    }

    private var displayedElapsed: Double {
        guard duration > 0 else { return 0 }
        return effectiveProgress * duration
    }

    var body: some View {
        let activeHeight: CGFloat = (isDragging || isHovering) ? 7 : 5

        HStack(spacing: 8) {
            Text(formatTime(displayedElapsed))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(isDragging ? 0.95 : 0.65))
                .frame(width: 34, alignment: .leading)
                .contentTransition(.numericText())

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let filled = max(4, width * CGFloat(effectiveProgress))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: activeHeight)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: min(width, filled), height: activeHeight)
                        .shadow(color: isDragging ? accentColor.opacity(0.45) : .clear, radius: 5)
                }
                .frame(height: 14, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragProgress = min(1, max(0, Double(value.location.x / width)))
                        }
                        .onEnded { value in
                            let finalRatio = min(1, max(0, Double(value.location.x / width)))
                            let target = finalRatio * max(0, duration)
                            optimisticTarget = target
                            lastSeekDate = Date()
                            isDragging = false
                            musicManager.seek(to: target)
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isDragging)

            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                    showRemainingTime.toggle()
                }
            } label: {
                let rightText = showRemainingTime && duration > 0
                    ? "-\(formatTime(max(0, duration - displayedElapsed)))"
                    : formatTime(duration)
                Text(rightText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 38, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .help("Click to toggle remaining / total time")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct LockScreenTransportControls: View {
    @ObservedObject var musicManager = MusicManager.shared
    let hasMediaTrack: Bool
    let albumAccent: Color
    @Binding var showAudioDrawer: Bool
    var onOpenAudioDrawer: (Bool) -> Void

    @State private var playPressed: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Left secondary cluster: Favorite + Shuffle
            HStack(spacing: 12) {
                Button {
                    musicManager.toggleFavoriteTrack()
                } label: {
                    Image(systemName: musicManager.isFavoriteTrack ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(musicManager.isFavoriteTrack ? Color.pink : Color.white.opacity(musicManager.canFavoriteTrack ? 0.58 : 0.22))
                }
                .buttonStyle(.plain)
                .disabled(!musicManager.canFavoriteTrack || !hasMediaTrack)

                Button {
                    musicManager.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(musicManager.isShuffled ? albumAccent : .white.opacity(hasMediaTrack ? 0.58 : 0.25))
                }
                .buttonStyle(.plain)
                .disabled(!hasMediaTrack)
            }

            Spacer(minLength: 0)

            // Center classic naked luminous white transport controls
            HStack(spacing: 32) {
                Button {
                    musicManager.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(hasMediaTrack ? 0.95 : 0.45))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.20, dampingFraction: 0.65)) {
                        playPressed = true
                    }
                    musicManager.togglePlay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.75)) {
                            playPressed = false
                        }
                    }
                } label: {
                    Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .scaleEffect(playPressed ? 0.88 : 1.0)
                }
                .buttonStyle(.plain)

                Button {
                    musicManager.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(hasMediaTrack ? 0.95 : 0.45))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            // Right secondary cluster: Repeat + Inline Audio/Volume Drawer
            HStack(spacing: 12) {
                Button {
                    musicManager.toggleRepeat()
                } label: {
                    Image(systemName: musicManager.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(musicManager.repeatMode != .off ? albumAccent : .white.opacity(hasMediaTrack ? 0.58 : 0.25))
                }
                .buttonStyle(.plain)
                .disabled(!hasMediaTrack)

                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        showAudioDrawer.toggle()
                        onOpenAudioDrawer(showAudioDrawer)
                    }
                } label: {
                    Image(systemName: showAudioDrawer ? "airplayaudio.circle.fill" : "airplayaudio")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(showAudioDrawer ? albumAccent : .white.opacity(0.62))
                }
                .buttonStyle(.plain)
                .help("Volume & Audio Output")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct LockScreenAudioDrawer: View {
    @ObservedObject var volumeManager = VolumeManager.shared
    let accentColor: Color

    @State private var devices: [AudioOutputRoutingMenu.OutputDevice] = []
    @State private var localVolume: Float? = nil

    private var effectiveVolume: Float {
        localVolume ?? (volumeManager.isMuted ? 0 : volumeManager.rawVolume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inline CoreAudio System Volume Slider
            HStack(spacing: 8) {
                Button {
                    volumeManager.toggleMuteAction()
                } label: {
                    Image(systemName: effectiveVolume <= 0.01 ? "speaker.slash.fill" : (effectiveVolume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)

                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .frame(height: 5)
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: max(5, w * CGFloat(effectiveVolume)), height: 5)
                    }
                    .frame(height: 14, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let ratio = Float(min(1, max(0, value.location.x / w)))
                                localVolume = ratio
                                volumeManager.setAbsolute(ratio)
                            }
                            .onEnded { value in
                                let ratio = Float(min(1, max(0, value.location.x / w)))
                                volumeManager.setAbsolute(ratio)
                                localVolume = nil
                            }
                    )
                }
                .frame(height: 14)

                Text("\(Int(round(effectiveVolume * 100)))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 30, alignment: .trailing)
            }

            // Inline CoreAudio Output Device Switcher (SkyLight-safe!)
            if !devices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(devices, id: \.id) { dev in
                            Button {
                                AudioOutputRoutingMenu.shared.setOutputDevice(dev.id)
                                devices = AudioOutputRoutingMenu.shared.availableOutputDevices()
                                volumeManager.refresh()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: outputSymbol(for: dev.name))
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(dev.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(dev.isDefault ? .white : .white.opacity(0.65))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(
                                    Capsule()
                                        .fill(dev.isDefault ? accentColor.opacity(0.28) : Color.white.opacity(0.08))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(dev.isDefault ? accentColor.opacity(0.55) : Color.white.opacity(0.1), lineWidth: 0.75)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )
        )
        .onAppear {
            devices = AudioOutputRoutingMenu.shared.availableOutputDevices()
            volumeManager.refresh()
        }
    }

    private func outputSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpod") { return "airpodspro" }
        if lower.contains("headphone") || lower.contains("beats") || lower.contains("sony") { return "headphones" }
        return "hifispeaker.fill"
    }
}



// MARK: - Lock Screen Full Screen Artwork Wallpaper (animated Apple Music covers)

struct LockScreenPanelRootView: View {
    @ObservedObject private var manager = DroppyLockScreenMediaPanelManager.shared
    var onClosePreview: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            if manager.isWallpaperMode {
                LockScreenArtworkWallpaperView(onDismiss: { manager.toggleWallpaperMode() })
                    .transition(.opacity)
            }

            DroppyLockScreenMediaPanelView(onClosePreview: onClosePreview)
                .padding(.bottom, manager.isWindowExpanded ? manager.cardBottomInset : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

struct LockScreenArtworkWallpaperView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var artworkService = AnimatedArtworkService.shared
    @Default(.lockScreenAnimatedArtwork) private var animatedArtworkEnabled
    let onDismiss: () -> Void

    private var trackKey: String {
        "\(musicManager.songTitle)|\(musicManager.artistName)|\(musicManager.album)"
    }

    var body: some View {
        GeometryReader { geo in
            let videoURL = animatedArtworkEnabled ? artworkService.videoURL(for: trackKey) : nil
            let highResCover = artworkService.stillImage(for: trackKey)

            ZStack {
                Color.black

                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if let highResCover {
                    Image(nsImage: highResCover)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }

                if let videoURL {
                    LoopingArtworkVideoView(url: videoURL)
                        .id(videoURL)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0.0),
                        .init(color: .clear, location: 0.18),
                        .init(color: .clear, location: 0.40),
                        .init(color: .black.opacity(0.62), location: 0.72),
                        .init(color: .black.opacity(0.88), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    }
                    .padding(.top, 58)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .task(id: trackKey) {
            guard DroppyLockScreenMediaPanelManager.hasActiveMedia(musicManager) else { return }
            await artworkService.load(
                title: musicManager.songTitle,
                artist: musicManager.artistName,
                album: musicManager.album,
                key: trackKey,
                wantsVideo: animatedArtworkEnabled,
                fallbackCover: musicManager.albumArt,
                isAppleMusic: musicManager.bundleIdentifier == "com.apple.Music"
            )
        }
    }
}

/// Finds the looping "motion artwork" video Apple Music publishes for some albums, plus a high resolution cover.
/// Lookup is done only when the full screen wallpaper is shown: iTunes Search API to find the album page,
/// then the HLS playlist is read from the public album page and the best variant (a single MP4) is cached on disk,
/// because streaming the playlist directly stalls and never starts.
@MainActor
final class AnimatedArtworkService: ObservableObject {
    static let shared = AnimatedArtworkService()

    @Published private var videoURLs: [String: URL] = [:]
    @Published private var stillImages: [String: NSImage] = [:]
    private var attemptedKeys: Set<String> = []

    private struct Candidate {
        let pageURL: URL
        let artworkURL: URL?
        let albumMatches: Bool
    }

    func videoURL(for key: String) -> URL? {
        videoURLs[key]
    }

    func stillImage(for key: String) -> NSImage? {
        stillImages[key]
    }

    func load(
        title: String,
        artist: String,
        album: String,
        key: String,
        wantsVideo: Bool,
        fallbackCover: NSImage,
        isAppleMusic: Bool
    ) async {
        guard !title.isEmpty, !attemptedKeys.contains(key) else { return }
        attemptedKeys.insert(key)

        var candidates = await Self.searchCandidates(title: title, artist: artist, album: album)
        if !candidates.contains(where: { $0.albumMatches }),
           let webAlbum = await AppleMusicWebCatalog.shared.album(title: title, album: album) {
            candidates.insert(Candidate(pageURL: webAlbum.pageURL, artworkURL: webAlbum.artworkURL, albumMatches: true), at: 0)
        }

        var cover: NSImage?
        if let artworkURL = candidates.first(where: { $0.albumMatches })?.artworkURL {
            cover = await Self.fetchImage(artworkURL)
        }
        if cover == nil {
            // Album not in the public catalog: upscale the best local cover instead of stretching it raw
            let fallbackData = fallbackCover.tiffRepresentation
            cover = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let musicData = isAppleMusic ? Self.currentMusicArtworkData() : nil
                return Self.upscaledCover(from: musicData) ?? Self.upscaledCover(from: fallbackData)
            }.value
        }
        if let cover {
            withAnimation(.easeInOut(duration: 0.4)) {
                // Keep a single decoded cover in memory
                stillImages = [key: cover]
            }
        }

        guard wantsVideo else { return }
        for candidate in candidates.prefix(3) {
            guard let playlistURL = await Self.motionPlaylistURL(pageURL: candidate.pageURL) else { continue }
            if let fileURL = await Self.cachedVideoFile(masterPlaylistURL: playlistURL) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    videoURLs[key] = fileURL
                }
            }
            break
        }
    }

    nonisolated private static func searchCandidates(title: String, artist: String, album: String) async -> [Candidate] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier.lowercased() ?? "us")
        ]
        guard
            let searchURL = components?.url,
            let (data, _) = try? await URLSession.shared.data(from: searchURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { return [] }

        let wantedTitle = simplified(title)
        let wantedAlbum = simplified(album)
        var seenCollections: Set<Int> = []
        var matching: [Candidate] = []
        var others: [Candidate] = []

        for result in results {
            let trackTitle = simplified(result["trackName"] as? String ?? "")
            guard !trackTitle.isEmpty, trackTitle.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(trackTitle) else { continue }
            guard
                let collectionID = result["collectionId"] as? Int,
                seenCollections.insert(collectionID).inserted,
                let pageString = result["collectionViewUrl"] as? String,
                let pageURL = URL(string: pageString)
            else { continue }

            let collection = simplified(result["collectionName"] as? String ?? "")
            let albumMatches = wantedAlbum.isEmpty || collection == wantedAlbum
                || collection.hasPrefix(wantedAlbum) || wantedAlbum.hasPrefix(collection)
            let artworkURL = (result["artworkUrl100"] as? String)
                .map { $0.replacingOccurrences(of: "100x100bb", with: "2000x2000bb") }
                .flatMap { URL(string: $0) }
            let candidate = Candidate(pageURL: pageURL, artworkURL: artworkURL, albumMatches: albumMatches)
            if albumMatches { matching.append(candidate) } else { others.append(candidate) }
        }
        return matching + others
    }

    nonisolated private static func motionPlaylistURL(pageURL: URL) async -> URL? {
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let html = String(data: data, encoding: .utf8)
        else { return nil }

        for marker in ["\"motionDetailSquare\"", "\"motionDetailTall\""] {
            guard let markerRange = html.range(of: marker) else { continue }
            let tail = html[markerRange.upperBound...]
            if let match = tail.range(of: #"https://[^"\\]+?\.m3u8"#, options: .regularExpression) {
                return URL(string: String(tail[match]))
            }
        }
        return nil
    }

    /// Picks the sharpest SDR variant (up to 2160p, around 9 Mbps) and downloads its MP4 into the caches folder.
    nonisolated private static func cachedVideoFile(masterPlaylistURL: URL) async -> URL? {
        guard
            let (masterData, _) = try? await URLSession.shared.data(from: masterPlaylistURL),
            let master = String(data: masterData, encoding: .utf8)
        else { return nil }

        var variants: [(height: Int, bandwidth: Int, url: URL)] = []
        let lines = master.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard
                !line.contains("VIDEO-RANGE=PQ"), !line.contains("VIDEO-RANGE=HLG"),
                index + 1 < lines.count,
                let url = URL(string: lines[index + 1].trimmingCharacters(in: .whitespaces), relativeTo: masterPlaylistURL),
                let height = firstInt(in: line, pattern: #"RESOLUTION=\d+x(\d+)"#),
                let bandwidth = firstInt(in: line, pattern: #"AVERAGE-BANDWIDTH=(\d+)"#)
            else { continue }
            variants.append((height, bandwidth, url))
        }
        let usable = variants.filter { $0.height <= 2160 }
        guard let bestHeight = usable.map(\.height).max() else { return nil }
        let targetBandwidth = 9_000_000
        guard let variant = usable
            .filter({ $0.height == bestHeight })
            .min(by: { abs($0.bandwidth - targetBandwidth) < abs($1.bandwidth - targetBandwidth) })
        else { return nil }

        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = cachesURL.appendingPathComponent("GravityNotch/MotionArtwork", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let assetID = masterPlaylistURL.deletingLastPathComponent().lastPathComponent
        let destination = folder.appendingPathComponent("\(assetID)-\(masterPlaylistURL.deletingPathExtension().lastPathComponent)-\(bestHeight).mp4")
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }

        guard
            let (variantData, _) = try? await URLSession.shared.data(from: variant.url),
            let playlist = String(data: variantData, encoding: .utf8),
            let mapRange = playlist.range(of: #"#EXT-X-MAP:URI="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let mapLine = String(playlist[mapRange])
        let fileName = mapLine
            .replacingOccurrences(of: "#EXT-X-MAP:URI=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        // The whole loop must live in that single file, otherwise a plain download would be incomplete
        let segmentFiles = Set(
            playlist.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
        guard segmentFiles == [fileName], let fileURL = URL(string: fileName, relativeTo: variant.url) else { return nil }

        guard
            let (temporaryURL, response) = try? await URLSession.shared.download(from: fileURL),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            return nil
        }
        pruneCache(in: folder, keeping: 10)
        return destination
    }

    nonisolated private static func pruneCache(in folder: URL, keeping limit: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sorted = files.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for file in sorted.dropFirst(limit) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Original artwork file of the track playing in Music (usually sharper than what MediaRemote reports).
    nonisolated private static func currentMusicArtworkData() -> Data? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gravitynotch-artwork-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let script = """
        tell application "Music"
            if it is running then
                set artData to raw data of artwork 1 of current track
                set fileRef to open for access POSIX file "\(fileURL.path)" with write permission
                set eof fileRef to 0
                write artData to fileRef
                close access fileRef
            end if
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    /// Lanczos upscale to about 2400 px with a light sharpen, so a small cover stays clean when it fills the screen.
    nonisolated private static func upscaledCover(from data: Data?) -> NSImage? {
        guard let data, let input = CIImage(data: data), input.extent.width > 0 else { return nil }
        let targetWidth: CGFloat = 2400
        var output = input
        if input.extent.width < targetWidth {
            output = output.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: targetWidth / input.extent.width, kCIInputAspectRatioKey: 1.0]
            )
            output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func fetchImage(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    nonisolated private static func firstInt(in text: String, pattern: String) -> Int? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    /// Lowercased name without "(feat. X)", "[From Y]" or " - Single" style suffixes.
    nonisolated private static func simplified(_ value: String) -> String {
        var text = value.lowercased()
        for separator in [" (", " [", " - "] {
            if let range = text.range(of: separator) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LoopingArtworkVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingArtworkVideoNSView {
        LoopingArtworkVideoNSView(url: url)
    }

    func updateNSView(_ nsView: LoopingArtworkVideoNSView, context: Context) {}

    static func dismantleNSView(_ nsView: LoopingArtworkVideoNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class LoopingArtworkVideoNSView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()

        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        // Stay invisible until the first frame is decoded so the static cover shows through meanwhile
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.6)
                layer.opacity = 1
                CATransaction.commit()
            }
        }

        player.play()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func stop() {
        readyObservation = nil
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }
}

// MARK: - Agent Pixel Mascots & Progress Animations

/// Small animated pixel character shown next to an agent: walks while the agent works,
/// waves when the agent is done and waiting, sleeps when the session is inactive.
struct AgentPixelMascot: View {
    let kind: AgentKind
    let isWorking: Bool
    let isActive: Bool
    var pixel: CGFloat = 2

    private static let columns = 11
    private static let rows = 8

    private struct Sprite {
        let base: [String]
        let step: [String]
        let wave: [String]
    }

    // '#' body, '+' highlight, 'o' eye, '.' empty
    private static let critter = Sprite(
        base: [
            "...#####...",
            "..#######..",
            "..#o###o#..",
            "###########",
            "###########",
            "..#######..",
            "..#.#.#.#..",
            "..#.#.#.#.."
        ],
        step: [
            "...#####...",
            "..#######..",
            "..#o###o#..",
            "###########",
            "###########",
            "..#######..",
            "..#.#.#.#..",
            "..........."
        ],
        wave: [
            "...#####..#",
            "..#######.#",
            "..#o###o###",
            "#########..",
            "#########..",
            "..#######..",
            "..#.#.#.#..",
            "..#.#.#.#.."
        ]
    )

    private static let cloud = Sprite(
        base: [
            "....###....",
            "..#######..",
            ".#########.",
            "##o#####o##",
            "###########",
            ".#########.",
            "....+...+..",
            "..+...+...."
        ],
        step: [
            "....###....",
            "..#######..",
            ".#########.",
            "##o#####o##",
            "###########",
            ".#########.",
            "..+...+....",
            "....+...+.."
        ],
        wave: [
            "....###...+",
            "..#######.+",
            ".#########+",
            "##o#####o##",
            "###########",
            ".#########.",
            "...........",
            "..........."
        ]
    )

    private static let robot = Sprite(
        base: [
            ".....+.....",
            ".....#.....",
            ".#########.",
            ".#o#####o#.",
            ".#########.",
            ".##+++++##.",
            ".#########.",
            "..##...##.."
        ],
        step: [
            "...........",
            ".....#.....",
            ".#########.",
            ".#o#####o#.",
            ".#########.",
            ".###+++###.",
            ".#########.",
            "..##...##.."
        ],
        wave: [
            ".....+....+",
            ".....#....+",
            ".#########+",
            ".#o#####o#.",
            ".#########.",
            ".##+++++##.",
            ".#########.",
            "..##...##.."
        ]
    )

    private var sprite: Sprite {
        switch kind {
        case .claudeCode: return Self.critter
        case .antigravity: return Self.cloud
        case .codex: return Self.robot
        }
    }

    private var frameInterval: Double {
        isWorking ? 0.22 : 0.48
    }

    var body: some View {
        Group {
            if isActive {
                TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                    canvas(tick: Int(context.date.timeIntervalSinceReferenceDate / frameInterval))
                }
            } else {
                canvas(tick: nil)
            }
        }
        .frame(width: CGFloat(Self.columns) * pixel, height: CGFloat(Self.rows + 1) * pixel)
        .opacity(isActive ? 1 : 0.5)
        .accessibilityHidden(true)
    }

    private func canvas(tick: Int?) -> some View {
        let bodyColor = isActive ? kind.accentColor : Color.gray
        let highlight = isActive ? kind.secondaryAccentColor : Color.gray.opacity(0.7)
        let odd = (tick ?? 0) % 2 == 1

        let grid: [String]
        if tick == nil {
            grid = sprite.base
        } else if isWorking {
            grid = odd ? sprite.step : sprite.base
        } else {
            // Done and waiting for the user: wave hello
            grid = odd ? sprite.wave : sprite.base
        }
        let eyesClosed = tick == nil || ((tick ?? 0) % 14 == 0)
        let bob: CGFloat = (isWorking && odd) ? 0 : 1

        return Canvas { context, _ in
            for (rowIndex, row) in grid.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    let color: Color
                    switch cell {
                    case "#": color = bodyColor
                    case "+": color = highlight
                    case "o": color = eyesClosed ? bodyColor : Color.black
                    default: continue
                    }
                    let rect = CGRect(
                        x: CGFloat(columnIndex) * pixel,
                        y: (CGFloat(rowIndex) + bob) * pixel,
                        width: pixel + 0.3,
                        height: pixel + 0.3
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

/// Checklist marker: pulsing play arrow for the step in progress, checkmark for finished steps.
struct AgentStepMarker: View {
    let isCurrent: Bool
    let color: Color
    @State private var pulse = false

    var body: some View {
        Group {
            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(color)
                    .scaleEffect(pulse ? 1.18 : 0.86)
                    .opacity(pulse ? 1 : 0.6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(color.opacity(0.75))
            }
        }
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCurrent)
    }
}

/// Indeterminate progress bar sliding along the bottom of the active file pill.
struct AgentActivityBar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { geo in
                let segment = geo.size.width * 0.35
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(color.opacity(0.14))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0), color, color.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: segment)
                        .offset(x: -segment + (geo.size.width + segment) * CGFloat(progress))
                }
            }
        }
    }
}

// MARK: - Agent Speech Bubble (pops under the notch when an agent finishes or needs the user)

struct AgentSpeechBubble: Identifiable, Equatable {
    enum Reason {
        case finished
        case question
        case approval
    }

    let id = UUID()
    let kind: AgentKind
    let reason: Reason
    let message: String
    let detail: String
}

@MainActor
final class AgentSpeechBubbleController: ObservableObject {
    static let shared = AgentSpeechBubbleController()

    @Published private(set) var bubble: AgentSpeechBubble?
    private var window: BoringNotchSkyLightWindow?
    private var dismissTask: Task<Void, Never>?

    private static let windowSize = NSSize(width: 300, height: 84)
    private static let visibleDuration: Double = 7

    /// Compares two refreshes of the agent monitor and announces sessions that just stopped working.
    func announceTransitions(from previous: [AgentSessionSnapshot], to current: [AgentSessionSnapshot]) {
        guard Defaults[.agentSpeechBubbles], !previous.isEmpty else { return }
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for session in current {
            guard
                let before = previousByID[session.id],
                before.isWorkingNow, !session.isWorkingNow, session.isActive
            else { continue }

            let reason: AgentSpeechBubble.Reason
            if session.phase == .waiting || session.kind == .antigravity {
                reason = .finished
            } else {
                // Still mid-turn but silent: the agent is blocked on the user
                let pendingTool = session.recentEvents.first?.toolName.lowercased() ?? ""
                if pendingTool.contains("askuser") || pendingTool.contains("question") || pendingTool.contains("exitplan") {
                    reason = .question
                } else if session.phase == .editing {
                    reason = .approval
                } else {
                    continue
                }
            }
            show(kind: session.kind, reason: reason, detail: session.projectName)
            return
        }
    }

    func show(kind: AgentKind, reason: AgentSpeechBubble.Reason, detail: String) {
        let message: String
        switch reason {
        case .finished:
            message = ["J'ai fini !", "C'est prêt !", "Terminé, à toi !", "Et voilà !"].randomElement() ?? "J'ai fini !"
        case .question:
            message = "J'ai une question…"
        case .approval:
            message = "J'ai besoin de ton accord"
        }

        guard let screen = NSScreen.screen(withUUID: BoringViewCoordinator.shared.selectedScreenUUID)
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let notchHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let size = Self.windowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - notchHeight - size.height - 2,
            width: size.width,
            height: size.height
        )

        let panel: BoringNotchSkyLightWindow
        if let existing = window {
            panel = existing
        } else {
            panel = BoringNotchSkyLightWindow(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = NSHostingView(rootView: AgentSpeechBubbleHost())
            window = panel
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            bubble = AgentSpeechBubble(kind: kind, reason: reason, message: message, detail: detail)
        }

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        guard let dismissedID = bubble?.id else { return }
        withAnimation(.easeIn(duration: 0.22)) {
            bubble = nil
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.bubble == nil || self.bubble?.id == dismissedID else { return }
            if self.bubble == nil {
                self.window?.orderOut(nil)
            }
        }
    }
}

private struct AgentSpeechBubbleHost: View {
    @ObservedObject private var controller = AgentSpeechBubbleController.shared

    var body: some View {
        VStack(spacing: 0) {
            if let bubble = controller.bubble {
                AgentSpeechBubbleView(bubble: bubble)
                    .id(bubble.id)
                    .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
                    .onTapGesture {
                        controller.dismiss()
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AgentSpeechBubbleView: View {
    let bubble: AgentSpeechBubble
    @State private var bounce = false

    private var accent: Color {
        bubble.reason == .finished ? bubble.kind.accentColor : Color(red: 0.98, green: 0.72, blue: 0.28)
    }

    var body: some View {
        VStack(spacing: -1) {
            // Tail pointing up at the notch
            BubbleTail()
                .fill(Color.black)
                .frame(width: 16, height: 8)

            HStack(spacing: 10) {
                AgentPixelMascot(kind: bubble.kind, isWorking: false, isActive: true, pixel: 2.4)
                    .offset(y: bounce ? -1.5 : 1.5)

                VStack(alignment: .leading, spacing: 1) {
                    Text(bubble.message)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(bubble.kind.shortLabel) · \(bubble.detail)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                if bubble.reason != .finished {
                    Image(systemName: bubble.reason == .question ? "questionmark.bubble.fill" : "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.black)
                    .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
            )
            .shadow(color: accent.opacity(0.35), radius: 10, y: 3)
        }
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                bounce = true
            }
        }
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Apple Music web catalog

/// Reads public Apple Music album pages. Used when Music streams from the catalog (no scriptable playlist)
/// and for albums the iTunes Search API does not list.
actor AppleMusicWebCatalog {
    static let shared = AppleMusicWebCatalog()

    struct Track: Sendable {
        let title: String
        let artist: String
        let duration: Double
        let isPlayable: Bool
    }

    struct Album: Sendable {
        let pageURL: URL
        let name: String
        let artworkURL: URL?
        let tracks: [Track]
    }

    private var cache: [String: Album] = [:]
    private var missed: Set<String> = []

    func album(title: String, album: String) async -> Album? {
        let wantedAlbum = Self.simplified(album)
        let wantedTitle = Self.simplified(title)
        guard !wantedAlbum.isEmpty, !wantedTitle.isEmpty else { return nil }
        if let cached = cache[wantedAlbum], Self.index(of: wantedTitle, in: cached) != nil { return cached }
        let missKey = wantedAlbum + "|" + wantedTitle
        guard !missed.contains(missKey) else { return nil }

        let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
        var components = URLComponents(string: "https://music.apple.com/\(storefront)/search")
        components?.queryItems = [URLQueryItem(name: "term", value: "\(title) \(album)")]
        guard let searchURL = components?.url, let searchHTML = await Self.fetchHTML(searchURL) else { return nil }

        var albumIDs: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"music\.apple\.com/[a-z]{2}/album/[^"\\?/]+/(\d+)"#) {
            let range = NSRange(searchHTML.startIndex..., in: searchHTML)
            for match in regex.matches(in: searchHTML, range: range) {
                guard let idRange = Range(match.range(at: 1), in: searchHTML) else { continue }
                let id = String(searchHTML[idRange])
                if !albumIDs.contains(id) { albumIDs.append(id) }
            }
        }

        for id in albumIDs.prefix(6) {
            guard
                let pageURL = URL(string: "https://music.apple.com/\(storefront)/album/\(id)"),
                let html = await Self.fetchHTML(pageURL),
                let parsed = Self.parseAlbum(html: html, pageURL: pageURL)
            else { continue }
            let name = Self.simplified(parsed.name)
            guard name == wantedAlbum || name.hasPrefix(wantedAlbum) || wantedAlbum.hasPrefix(name) else { continue }
            guard Self.index(of: wantedTitle, in: parsed) != nil else { continue }
            cache[wantedAlbum] = parsed
            return parsed
        }
        missed.insert(missKey)
        return nil
    }

    /// Playable tracks that follow the given title in album order.
    func upcomingTracks(title: String, artist: String, album: String, limit: Int = 10) async -> [Track] {
        guard let found = await self.album(title: title, album: album) else { return [] }
        let wantedTitle = Self.simplified(title)
        let wantedArtist = Self.simplified(artist)
        let exact = found.tracks.firstIndex {
            Self.simplified($0.title) == wantedTitle && Self.simplified($0.artist) == wantedArtist
        }
        guard let current = exact ?? Self.index(of: wantedTitle, in: found) else { return [] }
        return Array(found.tracks[(current + 1)...].filter(\.isPlayable).prefix(limit))
    }

    private static func index(of simplifiedTitle: String, in album: Album) -> Int? {
        album.tracks.firstIndex { simplified($0.title) == simplifiedTitle }
    }

    private static func simplified(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func scriptJSON(in html: String, pattern: String) -> Any? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html),
            let data = String(html[range]).data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseAlbum(html: String, pageURL: URL) -> Album? {
        guard
            let meta = scriptJSON(in: html, pattern: #"<script[^>]*application/ld\+json[^>]*>(.*?)</script>"#) as? [String: Any],
            let name = meta["name"] as? String,
            let server = scriptJSON(in: html, pattern: #"<script[^>]*serialized-server-data[^>]*>(.*?)</script>"#)
        else { return nil }

        var tracks: [Track] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if dict["trackNumber"] is Int, let title = dict["title"] as? String {
                    let milliseconds = (dict["duration"] as? Double) ?? 0
                    tracks.append(Track(
                        title: title,
                        artist: dict["artistName"] as? String ?? "",
                        duration: milliseconds / 1000,
                        isPlayable: !((dict["isDisabled"] as? Bool) ?? false)
                    ))
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(server)
        guard !tracks.isEmpty else { return nil }

        let artworkURL = (meta["image"] as? String)
            .map { $0.replacingOccurrences(of: #"/\d+x\d+[a-z]*\.(jpg|png)$"#, with: "/2000x2000bb.jpg", options: .regularExpression) }
            .flatMap { URL(string: $0) }
        return Album(pageURL: pageURL, name: name, artworkURL: artworkURL, tracks: tracks)
    }
}
