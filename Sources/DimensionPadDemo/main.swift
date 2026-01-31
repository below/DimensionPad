import Foundation
import Darwin
import Combine
import DimensionPad

let pad = DimensionPad()
var cancellables = Set<AnyCancellable>()
var activeAssignments: [String: (type: String, name: String, world: String)] = [:]
let demoDurationSeconds: UInt64 = 8
let noDeviceTimeoutSeconds: UInt64 = 12
var shutdownScheduled = false
var noDeviceTimeoutScheduled = false

// Observe connection changes
pad.$connected
    .removeDuplicates()
    .sink { isConnected in
        print(isConnected ? "ToyPad connected" : "ToyPad disconnected")
        guard isConnected else { return }
        Task { @MainActor in
            do {
                let center = FlashPad(tickOn: 8, tickOff: 8, tickCount: 12, r: 255, g: 255, b: 0)
                let left = FlashPad.forever(tickOn: 6, tickOff: 6, r: 0, g: 255, b: 255)
                let right = FlashPad(tickOn: 12, tickOff: 12, tickCount: 6, r: 255, g: 0, b: 255)
                try await pad.flashAll(center: center, left: left, right: right)
                
                let fadeCenter = FadePad(tickTime: 20, tickCount: 5, r: 0, g: 0, b: 255)
                let fadeLeft = FadePad(tickTime: 12, tickCount: 0xFF, r: 0, g: 255, b: 0)
                let fadeRight = FadePad(tickTime: 18, tickCount: 7, r: 255, g: 255, b: 255)
                try await pad.fadeAll(center: fadeCenter, left: fadeLeft, right: fadeRight)

                if !shutdownScheduled {
                    shutdownScheduled = true
                    try await Task.sleep(nanoseconds: demoDurationSeconds * 1_000_000_000)
                    try await pad.setColor(pad: .all, r: 0, g: 0, b: 0)
                    print("Demo complete. LEDs off. Exiting.")
                    exit(0)
                }
            } catch {
                print("Demo failed: \(error)")
            }
        }
    }
    .store(in: &cancellables)

pad.events
    .sink { event in
        switch event.action {
        case .add:
            Task {
                do {
                    let info = try await pad.readTagInfo(pad: event.pad)
                    switch info.type {
                    case .character:
                        let character = DimensionPadMetadata.getCharacterById(info.id)
                        let name = character?.name ?? String(info.id)
                        let world = character?.world ?? "Unknown"
                        print("Character: \(name) (\(world)) added to panel \(event.pad) (\(info.signature))")
                        activeAssignments[info.signature] = (type: "Character", name: name, world: world)
                    case .vehicle:
                        let vehicle = DimensionPadMetadata.getVehicleById(info.id)
                        let name = vehicle?.name ?? String(info.id)
                        let world = vehicle?.world ?? "Unknown"
                        print("Vehicle: \(name) (\(world)) added to panel \(event.pad) (\(info.signature))")
                        activeAssignments[info.signature] = (type: "Vehicle", name: name, world: world)
                    case .unknown:
                        print("Tag: \(info.id) added to panel \(event.pad) (\(info.signature))")
                    }
                } catch {
                    print("Tag read failed on panel \(event.pad): \(error)")
                }
            }
        case .remove:
            if let info = activeAssignments[event.signature] {
                print("\(info.type): \(info.name) (\(info.world)) removed from panel \(event.pad) (\(event.signature))")
            } else {
                print("Tag removed from panel \(event.pad) (\(event.signature))")
            }
            activeAssignments[event.signature] = nil
        }
    }
    .store(in: &cancellables)

pad.connect()

Task { @MainActor in
    guard !noDeviceTimeoutScheduled else { return }
    noDeviceTimeoutScheduled = true
    try? await Task.sleep(nanoseconds: noDeviceTimeoutSeconds * 1_000_000_000)
    if !pad.connected {
        print("No device detected within \(noDeviceTimeoutSeconds)s. Exiting.")
        exit(0)
    }
}

print("Waiting for Toy Pad events… Press Ctrl-C to quit.")
RunLoop.main.run()
