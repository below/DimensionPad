import Foundation

/// Type of LEGO Dimensions NFC tag payload.
public enum TagType {
    case character
    case vehicle
    case unknown
}

/// Basic decoded tag information.
public struct TagInfo {
    public let type: TagType
    public let id: Int
    public let signature: String
}

/// Published state for a single pad.
public struct PadState: Sendable, Hashable {
    public let present: Bool
    public let uid: String?
    public let characterID: Int?
    public let name: String?
    public let world: String?

    /// Creates a new pad state.
    public init(present: Bool, uid: String?, characterID: Int?, name: String?, world: String?) {
        self.present = present
        self.uid = uid
        self.characterID = characterID
        self.name = name
        self.world = world
    }

    public static func == (lhs: PadState, rhs: PadState) -> Bool {
        lhs.uid == rhs.uid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }
}

public enum Pad: UInt8, Sendable {
    case all = 0
    case center = 1
    case left = 2
    case right = 3
}

public struct PadSlots: Sendable {
    public var center: PadState
    public var left: Set<PadState>
    public var right: Set<PadState>

    public init(center: PadState, left: Set<PadState> = [], right: Set<PadState> = []) {
        self.center = center
        self.left = left
        self.right = right
    }
}

/// Flash configuration for a pad.
public struct FlashPad: Sendable {
    /// Whether the pad is enabled (used by flashAll).
    public var enabled: Bool
    /// Ticks to stay on. Higher is longer.
    public var tickOn: UInt8
    /// Ticks to stay off. Higher is longer.
    public var tickOff: UInt8
    /// Number of pulses; 0xFF means forever.
    public var tickCount: UInt8
    /// Red component.
    public var r: UInt8
    /// Green component.
    public var g: UInt8
    /// Blue component.
    public var b: UInt8

    public init(enabled: Bool = true, tickOn: UInt8, tickOff: UInt8, tickCount: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        self.enabled = enabled
        self.tickOn = tickOn
        self.tickOff = tickOff
        self.tickCount = tickCount
        self.r = r
        self.g = g
        self.b = b
    }

    /// Convenience for flashing forever (tickCount = 0xFF).
    public static func forever(enabled: Bool = true, tickOn: UInt8, tickOff: UInt8, r: UInt8, g: UInt8, b: UInt8) -> FlashPad {
        FlashPad(enabled: enabled, tickOn: tickOn, tickOff: tickOff, tickCount: 0xFF, r: r, g: g, b: b)
    }
}

/// Fade configuration for a pad.
public struct FadePad: Sendable {
    /// Whether the pad is enabled (used by fadeAll).
    public var enabled: Bool
    /// Ticks to fade. Higher is longer.
    public var tickTime: UInt8
    /// Tick count. Even stops on old color, odd on new color. 0 is never.
    public var tickCount: UInt8
    /// Red component.
    public var r: UInt8
    /// Green component.
    public var g: UInt8
    /// Blue component.
    public var b: UInt8

    public init(enabled: Bool = true, tickTime: UInt8, tickCount: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        self.enabled = enabled
        self.tickTime = tickTime
        self.tickCount = tickCount
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Event emitted when a tag is added or removed.
public struct TagEvent: Sendable {
    public enum Action: Sendable {
        case add
        case remove
    }

    public let action: Action
    public let pad: Pad
    public let signature: String
    public let index: UInt8
    public let uid: [UInt8]
}
