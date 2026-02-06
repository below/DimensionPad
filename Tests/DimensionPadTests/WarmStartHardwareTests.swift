// Manual setup for running this test:
// 1) Ensure the Toy Pad is connected and empty.
// 2) Place Wyldstyle (character id 3) and Chell (character id 9) on the LEFT pad.
// 3) Place Batman (character id 1) and Gandalf (character id 2) on the RIGHT pad.
// 4) Set DIMENSIONPAD_HARDWARE_TESTS=1 to enable.
// 5) Set DIMENSIONPAD_WAIT_FOR_KEYPRESS=1 to wait for Enter before starting.

import XCTest
import DimensionPad

final class WarmStartHardwareTests: XCTestCase {
    @MainActor
    func testWarmStartDetectsAddedTags() async throws {
        guard ProcessInfo.processInfo.environment["DIMENSIONPAD_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set DIMENSIONPAD_HARDWARE_TESTS=1 to run hardware tests.")
        }

        let waitForKeypress = ProcessInfo.processInfo.environment["DIMENSIONPAD_WAIT_FOR_KEYPRESS"] == "1"

        let pad = DimensionPad()
        pad.connect()

        let connected = await waitUntil(timeout: 6, pollInterval: 0.1) { pad.connected }
        XCTAssertTrue(connected, "Toy Pad not connected within timeout.")
        if !connected { return }

        if waitForKeypress {
            print("Press Enter to place tags and start assertions...")
            _ = readLine()
        } else {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let expectedLeft: Set<Int> = [3, 9]
        let expectedRight: Set<Int> = [1, 2]

        let detected = await waitUntil(timeout: 8, pollInterval: 0.2) {
            let leftIds = Set(pad.pads.left.compactMap { $0.characterID })
            let rightIds = Set(pad.pads.right.compactMap { $0.characterID })
            return leftIds == expectedLeft && rightIds == expectedRight
        }

        XCTAssertTrue(detected, "Expected left IDs \(expectedLeft) and right IDs \(expectedRight) within timeout. Current left=\(Set(pad.pads.left.compactMap { $0.characterID })) right=\(Set(pad.pads.right.compactMap { $0.characterID }))")
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
}
