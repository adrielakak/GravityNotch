//
//  MusicControlButton.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-16.
//

import Defaults

enum MusicControlButton: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case shuffle
    case previous
    case playPause
    case next
    case repeatMode
    case volume
    case favorite
    case audioOutput
    case playingNext
    case goBackward
    case goForward
    case none

    var id: String { rawValue }

    static let defaultLayout: [MusicControlButton] = [
        .shuffle,
        .previous,
        .playPause,
        .next,
        .playingNext,
        .audioOutput
    ]

    static let minSlotCount: Int = 3
    static let maxSlotCount: Int = 6

    static let pickerOptions: [MusicControlButton] = [
        .shuffle,
        .previous,
        .playPause,
        .next,
        .playingNext,
        .repeatMode,
        .favorite,
        .volume,
        .audioOutput,
        .goBackward,
        .goForward
    ]

    var label: String {
        switch self {
        case .shuffle:
            return String(localized: "Shuffle")
        case .previous:
            return String(localized: "Previous")
        case .playPause:
            return String(localized: "Play/Pause")
        case .next:
            return String(localized: "Next")
        case .repeatMode:
            return String(localized: "Repeat")
        case .volume:
            return String(localized: "Volume")
        case .favorite:
            return String(localized: "Favorite")
        case .audioOutput:
            return String(localized: "Audio Output")
        case .playingNext:
            return String(localized: "Playing Next")
        case .goBackward:
            return String(localized: "Backward 15s")
        case .goForward:
            return String(localized: "Forward 15s")
        case .none:
            return String(localized: "Empty slot")
        }
    }

    var iconName: String {
        switch self {
        case .shuffle:
            return "shuffle"
        case .previous:
            return "backward.fill"
        case .playPause:
            return "playpause"
        case .next:
            return "forward.fill"
        case .repeatMode:
            return "repeat"
        case .volume:
            return "speaker.wave.2.fill"
        case .favorite:
            return "heart"
        case .audioOutput:
            return "airplayaudio"
        case .playingNext:
            return "music.note.list"
        case .goBackward:
            return "gobackward.15"
        case .goForward:
            return "goforward.15"
        case .none:
            return ""
        }
    }

    var prefersLargeScale: Bool {
        self == .playPause
    }
}
