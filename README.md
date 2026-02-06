# DimensionPad

A Swift package for communicating with the LEGO Dimensions Toy Pad over USB HID on macOS.

It provides:
- Device discovery and connection management.
- Tag add/remove events with UID and panel.
- Tag reads (including character/vehicle ID decoding).
- Tag writing (generic block write and vehicle programming).
- Metadata lookup (character/vehicle names/vehicles/worlds).
- Basic LED control.

## Motivation

After discovering that LEGO Dimensions tags are essentially NFC tags — which can be used to trigger iOS Shortcuts and other fun experiments — I finally got my hands on a used Toy Pad. These come relatively cheap now, as the backend infrastructure for LEGO Dimensions appears to be slowly falling apart.

And since there is no such thing as “too many side projects,” I returned to an old favorite of mine: talking to USB devices. Let's see if there will ever be a *real usecase* for it. :p

## Requirements

- macOS 13+ (IOKit HID)
- LEGO Dimensions Toy Pad (Wii, PlayStation variant)

## Demo

There is a simple demo which can be started just by calling

```sh
swift run DimensionPadDemo
```

A more extensive SwiftUI demo app is [`OutOfSpace`](https://github.com/below/OutOfSpace), which consumes this package.

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
                let info = try await pad.readTagInfo(pad: event.pad)
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

- `events` is a publisher that emits `TagEvent` values.
- `TagEvent` includes `action`, `pad`, `index`, `signature`, and `uid` bytes.

### Pad State

`pads` is a published `PadSlots` value representing the current state of the Toy Pad:

- `center: PadState`
- `left: Set<PadState>`
- `right: Set<PadState>`

The center pad can hold only a single tag at a time, whereas the left and right pads can each hold multiple tags (up to three each). The left and right pads are represented as unordered sets because the individual slots have no defined or stable ordering — only presence and identity matter. The number of tags on left and right pads is simply limited by hardware constraints.

Each `PadState` contains:
- `present`: Bool
- `uid`: String?
- `name`: String? (resolved from metadata)
- `world`: String? (resolved from metadata)

### Metadata

Access static metadata via `DimensionPadMetadata`:

- `getCharacterById(_:)`
- `getVehicleById(_:)`
- `listCharacters()`
- `listVehicles()`

## LED Control

```swift
try await pad.setColor(pad: .left, r: 0, g: 255, b: 0)
```

### Flash

```swift
// Flash a single pad
try await pad.flash(pad: .center, tickOn: 10, tickOff: 10, tickCount: 8, r: 255, g: 0, b: 0)

// Flash forever using the helper
let forever = FlashPad.forever(tickOn: 6, tickOff: 6, r: 0, g: 0, b: 255)
try await pad.flash(pad: .left, flashPad: forever)

// Flash all pads with independent patterns
let center = FlashPad(tickOn: 8, tickOff: 8, tickCount: 12, r: 255, g: 255, b: 0)
let left = FlashPad(tickOn: 4, tickOff: 4, tickCount: 0xFF, r: 0, g: 255, b: 255)
let right = FlashPad(tickOn: 12, tickOff: 12, tickCount: 6, r: 255, g: 0, b: 255)
try await pad.flashAll(center: center, left: left, right: right)
```

### Fade

```swift
// Fade a single pad
try await pad.fade(pad: .center, tickTime: 20, tickCount: 5, r: 0, g: 0, b: 255)

// Fade all pads with independent patterns
let fadeCenter = FadePad(tickTime: 24, tickCount: 3, r: 255, g: 0, b: 0)
let fadeLeft = FadePad(tickTime: 12, tickCount: 0xFF, r: 0, g: 255, b: 0)
let fadeRight = FadePad(tickTime: 18, tickCount: 7, r: 255, g: 255, b: 255)
try await pad.fadeAll(center: fadeCenter, left: fadeLeft, right: fadeRight)

// Fade to random colors
try await pad.fadeRandom(pad: .right, tickTime: 16, tickCount: 10)
```

## Writing

```swift
// Write 16 bytes (4 pages) starting at page 0x24.
// If multiple tags are on the same pad, pass signature: "...".
try await pad.writeTagBlock(
    pad: .center,
    page: 0x24,
    data16: [UInt8](repeating: 0, count: 16)
)

// Program a vehicle payload on an existing vehicle tag.
try await pad.writeVehicle(pad: .center, vehicleID: 1000)

// Initialize a blank/unknown tag as a vehicle (skips vehicle precheck).
try await pad.initializeBlankVehicle(pad: .center, vehicleID: 1006, step: 0)

// Program a specific rebuild step variant (0 = base, 1/2 = upgrades where available).
try await pad.writeVehicle(pad: .center, vehicleID: 1000, step: 1)
```

## Notes

- HID access may require the app to be run with appropriate USB permissions (Sandbox entitlement: USB device access).
- Metadata is bundled from the `node-toypad` datasets (minifigs/vehicles).

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
