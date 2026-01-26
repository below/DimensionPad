# DimensionPad

A Swift package for talking to the LEGO Dimensions Toy Pad over USB HID on macOS.

It provides:
- Device discovery and connection management.
- Tag add/remove events with UID and panel.
- Tag reads (including character/vehicle ID decoding).
- Metadata lookup (character/vehicle names/worlds).
- Basic LED control.

## Requirements

- macOS 13+ (IOKit HID)
- LEGO Dimensions Toy Pad (Wii, Playstation variant)

## Install

Add the package as a local or remote dependency in Xcode or SwiftPM.

## Quick Start

```swift
import DimensionPad
import Combine

let pad = DimensionPad()
var cancellables = Set<AnyCancellable>()

pad.$connected
    .sink { print($0 ? "ToyPad connected" : "ToyPad disconnected") }
    .store(in: &cancellables)

pad.events
    .sink { event in
        switch event.action {
        case .add:
            Task {
                let info = try await pad.readTagInfo(padByte: event.pad)
                print("Added: \(info.signature) -> \(info.type)")
            }
        case .remove:
            print("Removed: \(event.signature)")
        }
    }
    .store(in: &cancellables)

pad.connect()
RunLoop.main.run()
```

## API Overview

### Connection

- `DimensionPad.connect()` starts HID discovery and opens the device.
- `@Published connected` reports connection state.

### Tag Events

- `events: PassthroughSubject<TagEvent, Never>`
- `TagEvent` includes `action`, `pad`, `index`, `signature`, and `uid` bytes.

### Pad State

`pads` is a published dictionary of pad number to `PadState`:

- `present`: Bool
- `uid`: String?
- `name`: String? (resolved from metadata)

### Metadata

Access static metadata via `DimensionPadMetadata`:

- `getCharacterById(_:)`
- `getVehicleById(_:)`
- `listCharacters()`
- `listVehicles()`

## LED Control

```swift
try await pad.setColor(padByte: 1, r: 0, g: 255, b: 0)
```

`padByte` values:
- 0 = all, 1 = center, 2 = left, 3 = right

## Notes

- HID access may require the app to be run with appropriate USB permissions (Sandbox entitlement: USB device access).
- Metadata is bundled from the `node-toypad` datasets (minifigs/vehicles).

## Demo

There is a simple demo in `DimensinoPadDemo`. A more extensive demo SwiftUI demo app is [`OutOfSpace`](https://github.com/below/OutOfSpace), which consumes this package.

## Links

http://wasabifan.github.io/ev3dev.github.io/docs/tutorials/using-lego-dimensions-toy-pad/
https://github.com/AlinaNova21/node-ld
https://github.com/dolmen-go/legodim/blob/f1c5b25864649ec34fb060457fa32d7832f01b1e/tag/uid.go#L43
https://nfc.toys/workflow-inf.html
https://retrodeck.readthedocs.io/en/latest/wiki_controllers/toystolife/lego-toypad/
https://www.dajlab.org/jtoypad.html
https://www.nxp.com/docs/en/data-sheet/NTAG213_215_216.pdf
https://www.proxmark.io/www.proxmark.org/forum/viewtopic.php%3Fpid=20257.html
https://www.wendelpunkt.de/toypad-challenge/
