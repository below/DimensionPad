import Foundation
import Combine
import DimensionPad

let pad = DimensionPad()
var cancellables = Set<AnyCancellable>()
var activeAssignments: [String: (type: String, name: String, world: String)] = [:]

// Observe connection changes
pad.$connected
    .removeDuplicates()
    .sink { isConnected in
        print(isConnected ? "ToyPad connected" : "ToyPad disconnected")
    }
    .store(in: &cancellables)

pad.events
    .sink { event in
        switch event.action {
        case .add:
            Task {
                do {
                    let info = try await pad.readTagInfo(padByte: event.pad)
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

print("Waiting for Toy Pad events… Press Ctrl-C to quit.")
RunLoop.main.run()
