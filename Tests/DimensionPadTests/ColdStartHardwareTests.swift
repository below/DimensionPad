// Manual setup for running this test:
// 1) Put Wyldstyle (character id 3) and Chell (character id 9) on the LEFT pad.
// 2) Put Batman (character id 1) and Gandalf (character id 2) on the RIGHT pad.
// 3) (Optional) Leave center empty.
// 4) Set DIMENSIONPAD_HARDWARE_TESTS=1 to enable.
// 5) Optionally set DIMENSIONPAD_WAIT_FOR_KEYPRESS=1 to wait for Enter before starting.

import XCTest
import DimensionPad

final class ColdStartHardwareTests: XCTestCase {
    @MainActor
    func testColdStartDetectsPreExistingTags() async throws {
        guard ProcessInfo.processInfo.environment["DIMENSIONPAD_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set DIMENSIONPAD_HARDWARE_TESTS=1 to run hardware tests.")
        }

        let waitForKeypress = ProcessInfo.processInfo.environment["DIMENSIONPAD_WAIT_FOR_KEYPRESS"] == "1"
        if waitForKeypress {
            print("Press Enter to start DimensionPad cold-start test...")
            _ = readLine()
        } else {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let pad = DimensionPad()
        pad.connect()

        let connected = await waitUntil(timeout: 6, pollInterval: 0.1) { pad.connected }
        XCTAssertTrue(connected, "Toy Pad not connected within timeout.")
        if !connected { return }

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
