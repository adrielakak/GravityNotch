//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var animatedBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentScreenBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	private lazy var burst = RelativeLevelBurst(
		read: { [client] in await client.currentScreenBrightness() },
		write: { [client] in await client.setScreenBrightness($0) },
		onTarget: { @MainActor [weak self] target in
			self?.publish(brightness: target, touchDate: true)
			BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(target))
		},
		onWriteFailed: { [weak self] in self?.refresh() }
	)

	@MainActor func setRelative(delta: Float) {
		burst.step(by: delta, fallback: rawBrightness)
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setScreenBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	private func publish(brightness: Float, touchDate: Bool) {
		DispatchQueue.main.async {
			if self.rawBrightness != brightness || touchDate {
				if touchDate { self.lastChangeAt = Date() }
				self.rawBrightness = brightness
				self.animatedBrightness = brightness
			}
		}
	}
}

// (DisplayServices helpers moved into XPC helper)

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	private lazy var burst = RelativeLevelBurst(
		read: { [client] in await client.currentKeyboardBrightness() },
		write: { [client] in await client.setKeyboardBrightness($0) },
		onTarget: { @MainActor [weak self] target in
			self?.publish(brightness: target, touchDate: true)
			BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(target))
		},
		onWriteFailed: { [weak self] in self?.refresh() }
	)

	@MainActor func setRelative(delta: Float) {
		burst.step(by: delta, fallback: rawBrightness)
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setKeyboardBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	private func publish(brightness: Float, touchDate: Bool) {
		DispatchQueue.main.async {
			if self.rawBrightness != brightness || touchDate {
				if touchDate { self.lastChangeAt = Date() }
				self.rawBrightness = brightness
			}
		}
	}
}

// MARK: - Key repeat handling

/// Brightness lives behind the XPC helper: reading then writing it costs two round trips per key press.
/// Spamming the keys used to queue those trips, so the HUD kept updating (out of order, interleaved with
/// the volume HUD) for seconds after the last press. Only the first press of a burst reads the real value
/// (auto-brightness may have moved it), the next ones build on the last target, the HUD updates at once,
/// and writes are coalesced: one in flight, then only the latest value.
final class RelativeLevelBurst {
	private let read: () async -> Float?
	private let write: (Float) async -> Bool
	private let onTarget: @MainActor (Float) -> Void
	private let onWriteFailed: () -> Void

	private static let burstWindow: TimeInterval = 1.5
	private var target: Float?
	private var burstEndsAt: Date = .distantPast
	private var isReadingBase = false
	private var deltaWhileReading: Float = 0
	private var pendingWrite: Float?
	private var isWriting = false

	init(
		read: @escaping () async -> Float?,
		write: @escaping (Float) async -> Bool,
		onTarget: @escaping @MainActor (Float) -> Void,
		onWriteFailed: @escaping () -> Void
	) {
		self.read = read
		self.write = write
		self.onTarget = onTarget
		self.onWriteFailed = onWriteFailed
	}

	@MainActor func step(by delta: Float, fallback: Float) {
		if let target, Date() < burstEndsAt {
			apply(target + delta)
			return
		}
		deltaWhileReading += delta
		guard !isReadingBase else { return }
		isReadingBase = true
		Task { @MainActor in
			let base = await read() ?? fallback
			isReadingBase = false
			let delta = deltaWhileReading
			deltaWhileReading = 0
			apply(base + delta)
		}
	}

	@MainActor private func apply(_ value: Float) {
		let clamped = max(0, min(1, value))
		target = clamped
		burstEndsAt = Date().addingTimeInterval(Self.burstWindow)
		onTarget(clamped)
		pendingWrite = clamped
		guard !isWriting else { return }
		isWriting = true
		Task { @MainActor in
			while let next = pendingWrite {
				pendingWrite = nil
				if !(await write(next)) { onWriteFailed() }
			}
			isWriting = false
		}
	}
}
