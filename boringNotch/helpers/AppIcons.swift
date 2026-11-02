//
//  AppIcons.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 16/08/24.
//

import SwiftUI
import AppKit
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
    private var promotedIDs: [String] = []
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = MusicManager.shared.$songTitle
            .removeDuplicates()
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
        promotedIDs.removeAll { $0 == item.id }
        Task.detached(priority: .userInitiated) {
            let script = """
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

    func refreshQueue() async {
        isLoading = true
        defer { isLoading = false }

        let fetched: [UpNextTrackItem] = await Task.detached(priority: .utility) {
            let script = """
            tell application "Music"
                if it is running and player state is not stopped then
                    set curIdx to index of current track
                    set pl to current playlist
                    set totalCnt to count of tracks of pl
                    set outList to ""
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
                guard let output = String(data: data, encoding: .utf8) else { return [] }
                var items: [UpNextTrackItem] = []
                for line in output.components(separatedBy: .newlines) {
                    let parts = line.components(separatedBy: "|")
                    guard parts.count >= 4, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let durStr = parts[3].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                    let dur = Double(durStr) ?? 0
                    items.append(UpNextTrackItem(id: "\(idx)-\(title)", playlistIndex: idx, title: title, artist: artist, duration: dur))
                }
                return items
            } catch {
                return []
            }
        }.value

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
                Text("Playing Next")
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
                                Text("\(index + 1)")
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

                                if index > 0 {
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

// MARK: - Antigravity & Coding Agents Live Monitor (Droppy Agents Feature)

struct AgentToolEvent: Identifiable, Equatable {
    let id: String
    let stepIndex: Int
    let toolName: String
    let summary: String
    let timestamp: Date

    var iconName: String {
        switch toolName {
        case "edit_file", "write_file": return "pencil.and.outline"
        case "run_command": return "terminal.fill"
        case "read_file": return "doc.text.magnifyingglass"
        default: return "cpu.fill"
        }
    }
}

@MainActor
final class AntigravityAgentMonitor: ObservableObject {
    static let shared = AntigravityAgentMonitor()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var conversationID: String = ""
    @Published private(set) var stepCount: Int = 0
    @Published private(set) var contextTokens: Int = 0
    @Published private(set) var cacheReadTokens: Int = 0
    @Published private(set) var totalOutputTokens: Int = 0
    @Published private(set) var filesModifiedCount: Int = 0
    @Published private(set) var currentActionTitle: String = "Idle"
    @Published private(set) var currentActionDetail: String = "Waiting for prompt…"
    @Published private(set) var recentEvents: [AgentToolEvent] = []

    private var timer: Timer?
    private let maxContextWindow: Double = 1_000_000.0

    var contextPercentage: Double {
        min(100.0, (Double(contextTokens) / maxContextWindow) * 100.0)
    }

    var cacheHitPercentage: Double {
        guard contextTokens > 0 else { return 0 }
        return min(100.0, (Double(cacheReadTokens) / Double(contextTokens)) * 100.0)
    }

    var formattedContextTokens: String {
        if contextTokens >= 1_000 {
            return String(format: "%.1fK", Double(contextTokens) / 1_000.0)
        }
        return "\(contextTokens)"
    }

    var formattedOutputTokens: String {
        if totalOutputTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalOutputTokens) / 1_000.0)
        }
        return "\(totalOutputTokens)"
    }

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private nonisolated static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let home = Self.realHomeDirectory()
            let brainDir = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity/brain")
            guard let subdirs = try? FileManager.default.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            var newestTranscript: URL?
            var newestConvID: String = ""
            var newestDate: Date = .distantPast

            for dir in subdirs {
                let transcript = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                if let vals = try? transcript.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = vals.contentModificationDate,
                   modDate > newestDate {
                    newestDate = modDate
                    newestTranscript = transcript
                    newestConvID = dir.lastPathComponent
                }
            }

            guard let transcriptURL = newestTranscript,
                  let data = try? Data(contentsOf: transcriptURL),
                  let text = String(data: data, encoding: .utf8) else { return }

            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var lastStep = 0
            var lastContext = 0
            var lastCache = 0
            var sumOutput = 0
            var editCount = 0
            var latestTitle = "Antigravity Ready"
            var latestDetail = "Session active"
            var events: [AgentToolEvent] = []

            let isoFormatter = ISO8601DateFormatter()
            var lastStepDate: Date = newestDate

            for line in lines.suffix(120) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let stepIdx = (obj["step_index"] as? Int) ?? lastStep
                lastStep = max(lastStep, stepIdx)

                if let createdStr = obj["created_at"] as? String,
                   let parsedDate = isoFormatter.date(from: createdStr) {
                    lastStepDate = parsedDate
                }

                let inTok = (obj["input_tokens"] as? Int) ?? 0
                let cacheTok = (obj["cache_read_tokens"] as? Int) ?? 0
                let outTok = (obj["output_tokens"] as? Int) ?? 0
                if inTok + cacheTok > 0 {
                    lastContext = inTok + cacheTok
                    lastCache = cacheTok
                }
                sumOutput += outTok

                if let toolCalls = obj["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        let name = (tc["name"] as? String) ?? "tool"
                        let args = (tc["args"] as? [String: Any]) ?? [:]
                        if name == "edit_file" || name == "write_file" {
                            editCount += 1
                        }
                        let detail: String
                        if let summary = args["toolSummary"] as? String {
                            detail = summary.replacingOccurrences(of: "\"", with: "")
                        } else if let path = args["Path"] as? String {
                            detail = URL(fileURLWithPath: path.replacingOccurrences(of: "\"", with: "")).lastPathComponent
                        } else {
                            detail = name
                        }
                        latestTitle = name
                        latestDetail = detail
                        events.append(
                            AgentToolEvent(
                                id: "\(stepIdx)-\(name)-\(events.count)",
                                stepIndex: stepIdx,
                                toolName: name,
                                summary: detail,
                                timestamp: lastStepDate
                            )
                        )
                    }
                }
            }

            let activeNow = Date().timeIntervalSince(newestDate) < 45.0
            let recentSuffix = Array(events.suffix(8).reversed())
            let finalStep = lastStep
            let finalContext = lastContext
            let finalCache = lastCache
            let finalOutput = sumOutput
            let finalEdits = editCount
            let finalTitle = latestTitle
            let finalDetail = latestDetail
            let finalConvID = String(newestConvID.prefix(8))

            await MainActor.run {
                let mon = AntigravityAgentMonitor.shared
                mon.isActive = activeNow
                mon.conversationID = finalConvID
                mon.stepCount = finalStep
                mon.contextTokens = finalContext
                mon.cacheReadTokens = finalCache
                mon.totalOutputTokens = finalOutput
                mon.filesModifiedCount = finalEdits
                mon.currentActionTitle = finalTitle
                mon.currentActionDetail = finalDetail
                mon.recentEvents = recentSuffix
            }
        }
    }
}

struct AgentsNotchView: View {
    @ObservedObject var monitor = AntigravityAgentMonitor.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5))
            .overlay {
                HStack(spacing: 12) {
                    // Left column: Live Agent Status & Quota/Context Gauge
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(monitor.isActive ? Color.green : Color.cyan)
                                .frame(width: 8, height: 8)
                            Text("Antigravity Agent")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("Step #\(monitor.stepCount)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        }

                        // Quota & Context Window Progress Bar
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Context / Quota")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.gray)
                                Spacer()
                                Text("\(monitor.formattedContextTokens) / 1M (\(String(format: "%.1f%%", monitor.contextPercentage)))")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.1))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [.cyan, .purple],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(6, geo.size.width * CGFloat(monitor.contextPercentage / 100.0)))
                                }
                            }
                            .frame(height: 6)
                        }

                        HStack(spacing: 8) {
                            statBadge(label: "Cache Hit", value: String(format: "%.0f%%", monitor.cacheHitPercentage))
                            statBadge(label: "Out Tokens", value: monitor.formattedOutputTokens)
                            statBadge(label: "Edits", value: "\(monitor.filesModifiedCount)")
                        }

                        HStack(spacing: 5) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.cyan)
                            Text("\(monitor.currentActionTitle): \(monitor.currentActionDetail)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 255)

                    Divider()
                        .background(Color.white.opacity(0.12))

                    // Right column: Live Tool Call Stream
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Recent Agent Tool Calls")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.gray)
                            Spacer()
                            Button {
                                DroppyLockScreenMediaPanelManager.shared.togglePreviewOnDesktop()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.display")
                                        .font(.system(size: 9))
                                    Text("Lock Screen Preview")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }

                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 4) {
                                ForEach(monitor.recentEvents) { ev in
                                    HStack(spacing: 6) {
                                        Image(systemName: ev.iconName)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.cyan)
                                            .frame(width: 14)
                                        Text(ev.toolName)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.85))
                                        Text(ev.summary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.gray)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("#\(ev.stepIndex)")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.gray.opacity(0.7))
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(10)
            }
    }

    private func statBadge(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.gray)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Lock Screen Media Player Panel via SkyLightWindow (Droppy Lock Screen Feature)

@MainActor
final class DroppyLockScreenMediaPanelManager {
    static let shared = DroppyLockScreenMediaPanelManager()

    private var panelWindow: BoringNotchSkyLightWindow?
    private var isPreviewVisible: Bool = false

    func showOnLockScreen() {
        guard Defaults[.showOnLockScreen] else { return }
        presentPanel(delegateToSkyLight: true)
    }

    func hideFromLockScreen() {
        isPreviewVisible = false
        guard let window = panelWindow else { return }
        window.disableSkyLight()
        window.orderOut(nil)
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
        let width: CGFloat = 396
        let height: CGFloat = 236
        let originX = screen.frame.midX - (width / 2)
        let originY = screen.frame.origin.y + (screen.frame.height * 0.21)
        let frame = NSRect(x: originX, y: originY, width: width, height: height)

        if MusicManager.shared.currentLyrics.isEmpty && MusicManager.shared.syncedLyrics.isEmpty && !MusicManager.shared.isFetchingLyrics {
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
            window.hasShadow = true
            panelWindow = window
        }

        window.setFrame(frame, display: true)
        let host = NSHostingView(rootView: DroppyLockScreenMediaPanelView(onClosePreview: { [weak self] in
            self?.hideFromLockScreen()
        }))
        host.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = host

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
    @State private var showLyricsCard: Bool = true
    var onClosePreview: (() -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: musicManager.isPlaying ? 0.25 : 2.0)) { context in
            let elapsed = musicManager.estimatedPlaybackPosition(at: context.date)
            let progress = musicManager.songDuration > 0 ? min(1, max(0, elapsed / musicManager.songDuration)) : 0
            let lyricTriple = lyricLines(at: elapsed, duration: musicManager.songDuration)

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: musicManager.albumArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(musicManager.songTitle.isEmpty ? "Not Playing" : musicManager.songTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(musicManager.artistName.isEmpty ? "Apple Music" : musicManager.artistName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showLyricsCard.toggle()
                        }
                        if musicManager.currentLyrics.isEmpty && musicManager.syncedLyrics.isEmpty {
                            musicManager.refreshLyrics()
                        }
                    } label: {
                        Image(systemName: showLyricsCard ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(showLyricsCard ? .white : .white.opacity(0.55))
                            .padding(6)
                            .background(Circle().fill(Color.white.opacity(showLyricsCard ? 0.22 : 0.08)))
                    }
                    .buttonStyle(.plain)

                    if let onClosePreview {
                        Button(action: onClosePreview) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showLyricsCard {
                    VStack(spacing: 3) {
                        if let prev = lyricTriple.previous, !prev.isEmpty {
                            Text(prev)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(1)
                        }
                        Text(lyricTriple.current)
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .shadow(color: .white.opacity(0.25), radius: 6)
                            .id(lyricTriple.current)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        if let next = lyricTriple.next, !next.isEmpty {
                            Text(next)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
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
                    .animation(.easeInOut(duration: 0.22), value: lyricTriple.current)
                }

                HStack(spacing: 8) {
                    Text(formatTime(elapsed))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 32, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            Capsule()
                                .fill(Color.white)
                                .frame(width: max(4, geo.size.width * progress))
                        }
                    }
                    .frame(height: 5)

                    Text(formatTime(musicManager.songDuration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 32, alignment: .trailing)
                }

                HStack(spacing: 38) {
                    Button {
                        musicManager.previousTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        musicManager.togglePlay()
                    } label: {
                        Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        musicManager.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(width: 396, height: 236)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .onAppear {
                if musicManager.currentLyrics.isEmpty && musicManager.syncedLyrics.isEmpty && !musicManager.isFetchingLyrics {
                    musicManager.refreshLyrics()
                }
            }
        }
    }

    private func lyricLines(at elapsed: Double, duration: Double) -> (previous: String?, current: String, next: String?) {
        if musicManager.isFetchingLyrics {
            return (nil, "Synchronisation des paroles…", nil)
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
            let prev = idx > 0 ? synced[idx - 1].text : nil
            let curr = synced[idx].text
            let next = (idx + 1) < synced.count ? synced[idx + 1].text : nil
            return (prev, curr, next)
        }
        let plainLines = musicManager.currentLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !plainLines.isEmpty else {
            return (nil, "♪ Instrumental / Aucune parole trouvée", nil)
        }
        let ratio = duration > 0 ? min(0.999, max(0, elapsed / duration)) : 0
        let idx = min(plainLines.count - 1, max(0, Int(Double(plainLines.count) * ratio)))
        let prev = idx > 0 ? plainLines[idx - 1] : nil
        let curr = plainLines[idx]
        let next = (idx + 1) < plainLines.count ? plainLines[idx + 1] : nil
        return (prev, curr, next)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

