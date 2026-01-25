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

// Observe pad state and emit event-like messages
var previous = pad.pads
pad.$pads
    .sink { current in
        for p in [UInt8]([1, 2, 3]) {
            let old = previous[p] ?? (false, nil)
            let new = current[p] ?? (false, nil)

            if !old.present && new.present {
                Task {
                    do {
                        let info = try await pad.readTagInfo(padByte: p)
                        switch info.type {
                        case .character:
                            let character = DimensionPadMetadata.getCharacterById(info.id)
                            let name = character?.name ?? String(info.id)
                            let world = character?.world ?? "Unknown"
                            print("Character: \(name) (\(world)) added to panel \(p) (\(info.signature))")
                            activeAssignments[info.signature] = (type: "Character", name: name, world: world)
                        case .vehicle:
                            let vehicle = DimensionPadMetadata.getVehicleById(info.id)
                            let name = vehicle?.name ?? String(info.id)
                            let world = vehicle?.world ?? "Unknown"
                            print("Vehicle: \(name) (\(world)) added to panel \(p) (\(info.signature))")
                            activeAssignments[info.signature] = (type: "Vehicle", name: name, world: world)
                        case .unknown:
                            print("Tag: \(info.id) added to panel \(p) (\(info.signature))")
                        }
                    } catch {
                        print("Tag read failed on panel \(p): \(error)")
                    }
                }
            } else if old.present && !new.present {
                if let signature = old.uid, let info = activeAssignments[signature] {
                    print("\(info.type): \(info.name) (\(info.world)) removed from panel \(p) (\(signature))")
                } else if let signature = old.uid {
                    print("Tag removed from panel \(p) (\(signature))")
                } else {
                    print("Tag removed from panel \(p)")
                }
            } else if old.present && new.present && old.uid != new.uid {
                print("swap: pad \(p) uid=\(new.uid ?? "?")")
            }
        }
        previous = current
    }
    .store(in: &cancellables)

pad.connect()

print("Waiting for Toy Pad events… Press Ctrl-C to quit.")
RunLoop.main.run()
