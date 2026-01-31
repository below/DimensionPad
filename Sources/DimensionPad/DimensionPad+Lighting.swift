import Foundation
import IOKit.hid

extension DimensionPad {
    /// Set the RGB LED color for a pad, or all pads
    public func setColor(pad: Pad, r: UInt8, g: UInt8, b: UInt8) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        let cmd = createSetColorCommand(msg: msg, pad: pad.rawValue, r: r, g: g, b: b)
        sendCommand(dev, cmd)
    }

    /// Flash a single pad with a color pattern.
    public func flash(pad: Pad, flashPad: FlashPad) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        let cmd = createFlashCommand(
            msg: msg,
            pad: pad.rawValue,
            tickOn: flashPad.tickOn,
            tickOff: flashPad.tickOff,
            tickCount: flashPad.tickCount,
            r: flashPad.r,
            g: flashPad.g,
            b: flashPad.b
        )
        sendCommand(dev, cmd)
    }

    /// Flash a single pad with explicit parameters.
    public func flash(
        pad: Pad,
        tickOn: UInt8,
        tickOff: UInt8,
        tickCount: UInt8,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) async throws {
        let flashPad = FlashPad(tickOn: tickOn, tickOff: tickOff, tickCount: tickCount, r: r, g: g, b: b)
        try await flash(pad: pad, flashPad: flashPad)
    }

    /// Flash all pads with independent patterns.
    public func flashAll(center: FlashPad, left: FlashPad, right: FlashPad) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        let cmd = createFlashAllCommand(msg: msg, center: center, left: left, right: right)
        sendCommand(dev, cmd)
    }

    /// Fade a single pad with a color transition.
    public func fade(pad: Pad, fadePad: FadePad) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        let cmd = createFadeCommand(
            msg: msg,
            pad: pad.rawValue,
            tickTime: fadePad.tickTime,
            tickCount: fadePad.tickCount,
            r: fadePad.r,
            g: fadePad.g,
            b: fadePad.b
        )
        sendCommand(dev, cmd)
    }

    /// Fade a single pad with explicit parameters.
    public func fade(
        pad: Pad,
        tickTime: UInt8,
        tickCount: UInt8,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) async throws {
        let fadePad = FadePad(tickTime: tickTime, tickCount: tickCount, r: r, g: g, b: b)
        try await fade(pad: pad, fadePad: fadePad)
    }

    /// Fade all pads with independent patterns.
    public func fadeAll(center: FadePad, left: FadePad, right: FadePad) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        let cmd = createFadeAllCommand(msg: msg, center: center, left: left, right: right)
        sendCommand(dev, cmd)
    }

    /// Fade to random colors on a pad.
    public func fadeRandom(pad: Pad, tickTime: UInt8, tickCount: UInt8) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        let cmd = createFadeRandomCommand(msg: msg, pad: pad.rawValue, tickTime: tickTime, tickCount: tickCount)
        sendCommand(dev, cmd)
    }
}

extension DimensionPad {
    private func createSetColorCommand(msg: UInt8, pad: UInt8, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        [0x55, 0x06, 0xC0, msg, pad, r, g, b]
    }

    private func createFlashCommand(
        msg: UInt8,
        pad: UInt8,
        tickOn: UInt8,
        tickOff: UInt8,
        tickCount: UInt8,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) -> [UInt8] {
        // 0x55 0x09 0xC3 <msg> <pad> <tickOn> <tickOff> <tickCount> <R> <G> <B>
        [0x55, 0x09, 0xC3, msg, pad, tickOn, tickOff, tickCount, r, g, b]
    }

    private func createFlashAllCommand(
        msg: UInt8,
        center: FlashPad,
        left: FlashPad,
        right: FlashPad
    ) -> [UInt8] {
        // 0x55 0x17 0xC7 <msg> then 3x: <enabled> <tickOn> <tickOff> <tickCount> <R> <G> <B>
        [
            0x55, 0x17, 0xC7, msg,
            center.enabled ? 0x01 : 0x00, center.tickOn, center.tickOff, center.tickCount, center.r, center.g, center.b,
            left.enabled ? 0x01 : 0x00, left.tickOn, left.tickOff, left.tickCount, left.r, left.g, left.b,
            right.enabled ? 0x01 : 0x00, right.tickOn, right.tickOff, right.tickCount, right.r, right.g, right.b
        ]
    }

    private func createFadeCommand(
        msg: UInt8,
        pad: UInt8,
        tickTime: UInt8,
        tickCount: UInt8,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) -> [UInt8] {
        // 0x55 0x08 0xC2 <msg> <pad> <tickTime> <tickCount> <R> <G> <B>
        [0x55, 0x08, 0xC2, msg, pad, tickTime, tickCount, r, g, b]
    }

    private func createFadeAllCommand(
        msg: UInt8,
        center: FadePad,
        left: FadePad,
        right: FadePad
    ) -> [UInt8] {
        // 0x55 0x14 0xC6 <msg> then 3x: <enabled> <tickTime> <tickCount> <R> <G> <B>
        [
            0x55, 0x14, 0xC6, msg,
            center.enabled ? 0x01 : 0x00, center.tickTime, center.tickCount, center.r, center.g, center.b,
            left.enabled ? 0x01 : 0x00, left.tickTime, left.tickCount, left.r, left.g, left.b,
            right.enabled ? 0x01 : 0x00, right.tickTime, right.tickCount, right.r, right.g, right.b
        ]
    }

    private func createFadeRandomCommand(msg: UInt8, pad: UInt8, tickTime: UInt8, tickCount: UInt8) -> [UInt8] {
        // 0x55 0x05 0xC4 <msg> <pad> <tickTime> <tickCount>
        [0x55, 0x05, 0xC4, msg, pad, tickTime, tickCount]
    }
}
