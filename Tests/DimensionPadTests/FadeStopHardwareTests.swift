// Manual test: visually confirm that center pad stops fading after the off command.
// 1) Set DIMENSIONPAD_HARDWARE_TESTS=1 to enable.
// 2) (Optional) Set DIMENSIONPAD_WAIT_FOR_KEYPRESS=1 to wait for Enter before starting.

import XCTest
import DimensionPad

final class FadeStopHardwareTests: XCTestCase {
    @MainActor
    func testStopFadeAll() async throws {
        guard ProcessInfo.processInfo.environment["DIMENSIONPAD_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set DIMENSIONPAD_HARDWARE_TESTS=1 to run hardware tests.")
        }

        let waitForKeypress = ProcessInfo.processInfo.environment["DIMENSIONPAD_WAIT_FOR_KEYPRESS"] == "1"
        let triangulate = ProcessInfo.processInfo.environment["DIMENSIONPAD_FADE_STOP_TRIANGULATE"] == "1"
        if waitForKeypress {
            print("Press Enter to start fade/stop test...")
            _ = readLine()
        }

        let pad = DimensionPad()
        pad.connect()

        let connected = await waitUntil(timeout: 6, pollInterval: 0.1) { pad.connected }
        XCTAssertTrue(connected, "Toy Pad not connected within timeout.")
        if !connected { return }

        if triangulate {
            try await runTriangulation(pad)
            return
        }

        try await runStopSequence(pad)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return condition()
    }

    @MainActor
    private func runStopSequence(_ pad: DimensionPad) async throws {
        try await pad.setColor(pad: .center, r: 255, g: 255, b: 255)
        try await pad.fade(pad: .center, tickTime: 40, tickCount: 0xFF, r: 0x46, g: 0x46, b: 0x46)

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let offFade = FadePad(enabled: false, tickTime: 0, tickCount: 0, r: 0, g: 0, b: 0)
        try await pad.fadeAll(center: offFade, left: offFade, right: offFade)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await pad.setColor(pad: .all, r: 0, g: 0, b: 0)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let offFlash = FlashPad(enabled: false, tickOn: 0, tickOff: 0, tickCount: 0, r: 0, g: 0, b: 0)
        try await pad.flashAll(center: offFlash, left: offFlash, right: offFlash)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await pad.fade(pad: .center, tickTime: 1, tickCount: 1, r: 0, g: 0, b: 0)
    }

    @MainActor
    private func runTriangulation(_ pad: DimensionPad) async throws {
        let offFade = FadePad(enabled: false, tickTime: 0, tickCount: 0, r: 0, g: 0, b: 0)
        let offFlash = FlashPad(enabled: false, tickOn: 0, tickOff: 0, tickCount: 0, r: 0, g: 0, b: 0)

        let steps: [(String, () async throws -> Void)] = [
//            ("fadeAll disabled", { try await pad.fadeAll(center: offFade, left: offFade, right: offFade) }),
//            ("setColor all off", { try await pad.setColor(pad: .all, r: 0, g: 0, b: 0) }),
//            ("flashAll disabled", { try await pad.flashAll(center: offFlash, left: offFlash, right: offFlash) }),
            ("fade(center tickTime:1 tickCount:1 to black)", { try await pad.fade(pad: .center, tickTime: 1, tickCount: 1, r: 0, g: 0, b: 0) })
        ]

        for (label, action) in steps {
            print("Starting fade (center)...")
            try await pad.setColor(pad: .center, r: 255, g: 255, b: 255)
            try await pad.fade(pad: .center, tickTime: 40, tickCount: 0xFF, r: 0x46, g: 0x46, b: 0x46)
            try await Task.sleep(nanoseconds: 2_000_000_000)

            print("Applying stop step: \(label)")
            try await action()
            print("Observe the pad now. If fading stopped at this step, note it.")
            print("Press Enter to continue to next step...")
            _ = readLine()
        }
    }
}
