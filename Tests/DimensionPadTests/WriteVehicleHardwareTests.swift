// Manual setup for running this test:
// 1) Place a writable vehicle tag (or blank compatible NFC tag) on the CENTER pad.
// 2) Set DIMENSIONPAD_HARDWARE_TESTS=1 to enable hardware tests.
// 3) Set DIMENSIONPAD_WRITE_TESTS=1 to explicitly allow writes.
// 4) (Optional) Set DIMENSIONPAD_WAIT_FOR_KEYPRESS=1 to confirm before writing.
// 5) (Optional) Set DIMENSIONPAD_WRITE_SIGNATURE="<uid signature>" if selection is ambiguous.

import XCTest
import DimensionPad

final class WriteVehicleHardwareTests: XCTestCase {
    private let bennySpaceshipID = 1009
    private let batmobileID = 1006

    @MainActor
    func testWriteVehicleToCenterTag() async throws {
        guard ProcessInfo.processInfo.environment["DIMENSIONPAD_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set DIMENSIONPAD_HARDWARE_TESTS=1 to run hardware tests.")
        }
        guard ProcessInfo.processInfo.environment["DIMENSIONPAD_WRITE_TESTS"] == "1" else {
            throw XCTSkip("Set DIMENSIONPAD_WRITE_TESTS=1 to allow tag writes.")
        }

        let waitForKeypress = ProcessInfo.processInfo.environment["DIMENSIONPAD_WAIT_FOR_KEYPRESS"] == "1"
        let signature = ProcessInfo.processInfo.environment["DIMENSIONPAD_WRITE_SIGNATURE"]
        let vehicle = batmobileID

        if waitForKeypress {
            print("About to write vehicle id \(vehicle) (Batmobile) to the center tag.")
            print("Press Enter to continue...")
            _ = readLine()
        }

        let pad = DimensionPad()
        pad.connect()

        let connected = await waitUntil(timeout: 6, pollInterval: 0.1) { pad.connected }
        XCTAssertTrue(connected, "Toy Pad not connected within timeout.")
        if !connected { return }

        try await waitForCenterTagPresence(pad)

        try await pad.initializeBlankVehicle(
            pad: .center,
            vehicleID: vehicle,
            step: 0,
            signature: signature
        )

        try await Task.sleep(nanoseconds: 300_000_000)

        let info = try await pad.readTagInfo(pad: .center)
        XCTAssertEqual(info.type, .vehicle, "Expected a vehicle tag after write.")
        XCTAssertEqual(info.id, vehicle, "Expected vehicle id \(vehicle) after write.")
    }

    @MainActor
    private func waitForCenterTagPresence(_ pad: DimensionPad) async throws {
        let present = await waitUntil(timeout: 8, pollInterval: 0.2) {
            pad.pads.center.present
        }
        XCTAssertTrue(present, "No center tag detected within timeout.")
        if !present {
            throw XCTSkip("Center tag not detected.")
        }
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
