# DimensionPad

A Swift interface for the LEGO Dimensions Toy Pad over USB on macOS.

## Overview

`DimensionPad` discovers and connects to a LEGO Dimensions Toy Pad, emits tag add/remove events, and can read tag data to decode character and vehicle IDs. It also provides a small metadata lookup layer that resolves IDs to names/worlds using bundled datasets.

The most common flow is:
1. Create a `DimensionPad` instance.
2. Call `connect()`.
3. Listen to `events` for tag add/remove.
4. Call `readTagInfo(padByte:)` to decode a tag.
5. Maybe call setColor(padByte:r:g:b:) to set a color in response

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
        if event.action == .add {
            Task {
                let info = try await pad.readTagInfo(padByte: event.pad)
                print("Tag: \(info.signature) type=\(info.type) id=\(info.id)")
            }
        }
    }
    .store(in: &cancellables)

pad.connect()
RunLoop.main.run()
```

## Topics

### Core Types

- ``DimensionPad``
- ``TagEvent``
- ``TagInfo``
- ``TagType``
- ``PadState``

### Metadata

- ``DimensionPadMetadata``
- ``CharacterMetadata``
- ``VehicleMetadata``
