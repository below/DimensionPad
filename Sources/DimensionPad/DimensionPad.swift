import Foundation
import Combine
import IOKit.hid

public enum TagType {
    case character
    case vehicle
    case unknown
}

public struct TagInfo {
    public let type: TagType
    public let id: Int
    public let signature: String
}

public struct TagEvent: Sendable {
    public enum Action: Sendable {
        case add
        case remove
    }

    public let action: Action
    public let pad: UInt8
    public let signature: String
    public let index: UInt8
    public let uid: [UInt8]
}

@MainActor
public final class DimensionPad {
    @Published public private(set) var connected: Bool = false
    @Published public private(set) var pads: [UInt8: (present: Bool, uid: String?)] = [
        1: (false, nil),
        2: (false, nil),
        3: (false, nil)
    ]
    public let events = PassthroughSubject<TagEvent, Never>()

    public enum Pad: UInt8 {
        case all = 0
        case center = 1
        case left = 2
        case right = 3
    }

    enum ToyPadReadError: Error {
        case notConnected
        case tagNotPresent
        case timeout
        case malformedResponse
        case deviceError(status: UInt8)
        case checksumMismatch
    }
    
    private let manager: IOHIDManager
    internal var device: IOHIDDevice?

    private let vendorID = 0x0E6F
    private let productID = 0x0241

    private let TOYPAD_INIT: [UInt8] = [
        0x55, 0x0f, 0xb0, 0x01, 0x28, 0x63, 0x29, 0x20,
        0x4c, 0x45, 0x47, 0x4f, 0x20, 0x32, 0x30, 0x31,
        0x34, 0xf7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    private var inputReport = [UInt8](repeating: 0, count: 32)

    internal var msgCounter: UInt8 = 0x01
    private func nextMsg() -> UInt8 {
        let m = msgCounter
        msgCounter &+= 1
        return m
    }

    internal enum PendingKind {
        case readPages
        case other
    }

    internal struct Pending55 {
        let kind: PendingKind
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    internal var pending55: [UInt8: Pending55] = [:]

    private struct PresentTag {
        let uid: [UInt8]
        let signature: String
        let index: UInt8
    }

    private var presentTagByPad: [UInt8: PresentTag] = [:]

    public init() {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
    }
    
    public func connect() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, dev in
            let this = Unmanaged<DimensionPad>.fromOpaque(context!).takeUnretainedValue()
            Task { @MainActor in await this.deviceMatched(dev) }
        }, Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, dev in
            let this = Unmanaged<DimensionPad>.fromOpaque(context!).takeUnretainedValue()
            Task { @MainActor in this.deviceRemoved(dev) }
        }, Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        print(r == kIOReturnSuccess ? "HID manager open ✅" : "HID manager open ❌ \(r)")
    }
 
    public func readTagInfo(padByte: UInt8) async throws -> TagInfo {
        guard let tag = presentTagByPad[padByte] else { throw ToyPadReadError.tagNotPresent }
        let block = try await readPages(padByte: padByte, startPage: 0x24)
        guard block.count >= 16 else { throw ToyPadReadError.malformedResponse }

        let payloadView = Array(block[8..<12])
        let type = detectTagType(payloadView)
        switch type {
        case .vehicle:
            let id = getVehicleId(block)
            return TagInfo(type: .vehicle, id: id, signature: tag.signature)
        case .character:
            let encrypted = Array(block[0..<8])
            let id = getCharacterId(uid: tag.uid, encrypted: encrypted)
            return TagInfo(type: .character, id: id, signature: tag.signature)
        case .unknown:
            return TagInfo(type: .unknown, id: 0, signature: tag.signature)
        }
    }


    public func color(pad: Pad, r: UInt8, g: UInt8, b: UInt8) {
        guard let dev = self.device else { return }
        switchPad(dev, pad: pad, r: r, g: g, b: b)
    }

    private func publishPad(_ pad: UInt8, present: Bool, uid: String?) {
        pads[pad] = (present, uid)
    }

    private func deviceMatched(_ dev: IOHIDDevice) async {
        device = dev
        connected = true
        // New USB session → reset protocol state
        msgCounter = 0x00
        pending55.removeAll()
        presentTagByPad.removeAll()
        
        print("Device matched: \((IOHIDDeviceGetProperty(dev,  kIOHIDProductKey as CFString) as? String) ?? "-")")

        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            print("IOHIDDeviceOpen failed: \(r)")
            return
        }

        // INIT wakes it up
        sendOutputReport(dev, TOYPAD_INIT)

        // Quick lightshow to indicate the device is active (await before registering input)
 //       await runLightshow(on: dev)

        // Register input callback
        inputReport = [UInt8](repeating: 0, count: 32)
        inputReport.withUnsafeMutableBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            IOHIDDeviceRegisterInputReportCallback(
                dev,
                ptr,
                buf.count,
                { context, result, _, _, reportID, report, reportLength in
                    let this = Unmanaged<DimensionPad>.fromOpaque(context!).takeUnretainedValue()
                    Task { @MainActor in
                        this.handleInput(result: result, reportID: reportID, report: report, length: reportLength)
                    }
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        print("Input callback registered + INIT sent.")
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        if let current = device, CFEqual(current, dev) {
            pending55.removeAll()
            device = nil
            connected = false
            print("Device removed.")
        }
    }

    private func sendOutputReport(_ dev: IOHIDDevice, _ bytes: [UInt8], reportID: CFIndex = 0) {
        bytes.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, ptr, bytes.count)
            print(r == kIOReturnSuccess ? "OUT ✅ \(bytes.count) bytes" : "OUT ❌ \(r)")
        }
    }

    private func handleInput(result: IOReturn, reportID: UInt32, report: UnsafeMutablePointer<UInt8>?, length: CFIndex) {
        guard result == kIOReturnSuccess, let report, length > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))

        if bytes.count == 32, bytes[0] == 0x55 {
            if handle55Response(bytes) { return }
        }
        if let ev = parseTag(bytes) {
            handleTag(ev)
        }
    }

    private struct TagEv {
        let pad: UInt8        // 1=center, 2=left, 3=right
        let index: UInt8      // index
        let action: UInt8     // 0=inserted, 1=removed
        let uid: [UInt8]      // 7 bytes
    }

    private func parseTag(_ b: [UInt8]) -> TagEv? {
        guard b.count == 32 else { return nil }
        guard b[0] == 0x56, b[1] == 0x0B else { return nil }

        let pad = b[2]
        let index = b[4]          // 0,1,2  (slot)
        let action = b[5]
        let uid = Array(b[6...12]) // 7 bytes

        print("TAG \(hex(b))")

        return TagEv(pad: pad, index: index, action: action, uid: uid)
    }
    
    private func handleTag(_ ev: TagEv) {
        let signature = signatureString(ev.uid)

        switch ev.action {
        case 0: // inserted
            // Only log/publish if this is a new UID for that pad
            if presentTagByPad[ev.pad]?.signature != signature {
                presentTagByPad[ev.pad] = PresentTag(uid: ev.uid, signature: signature, index: ev.index)
                print("✅ \(padName(ev.pad)) inserted uid=\(signature)")
                publishPad(ev.pad, present: true, uid: signature)
                events.send(TagEvent(action: .add, pad: ev.pad, signature: signature, index: ev.index, uid: ev.uid))
            }

        case 1: // removed
            // Only log/publish if something was present
            if let removed = presentTagByPad[ev.pad] {
                presentTagByPad[ev.pad] = nil
                print("❌ \(padName(ev.pad)) removed")
                publishPad(ev.pad, present: false, uid: nil)
                events.send(TagEvent(action: .remove, pad: ev.pad, signature: removed.signature, index: removed.index, uid: removed.uid))
            }

        default:
            break
        }
    }

    private func handle55Response(_ b: [UInt8]) -> Bool {
        // Frame starts with 0x55 and is always 32 bytes (padded)
        guard b.count == 32, b[0] == 0x55 else { return false }

        let len = Int(b[1])

        // Two observed conventions exist in the wild:
        // A) len counts (payload + checksum) and excludes the msg byte.
        //    -> [55][len][msg][payload...][cs]
        // B) len counts (msg + payload + checksum).
        //    -> [55][len][msg][payload...][cs]
        // We try both and accept the one with a valid checksum.

        func parseA() -> (msg: UInt8, payload: [UInt8], cs: UInt8)? {
            let start = 3
            let end = start + len
            guard len >= 1, end <= b.count else { return nil }
            let msg = b[2]
            let payloadPlusCs = Array(b[start..<end])
            guard let cs = payloadPlusCs.last else { return nil }
            let payload = Array(payloadPlusCs.dropLast())
            return (msg, payload, cs)
        }

        func parseB() -> (msg: UInt8, payload: [UInt8], cs: UInt8)? {
            let start = 2
            let end = start + len
            guard len >= 2, end <= b.count else { return nil }
            let msg = b[2]
            let payloadPlusCs = Array(b[3..<end])
            guard let cs = payloadPlusCs.last else { return nil }
            let payload = Array(payloadPlusCs.dropLast())
            return (msg, payload, cs)
        }

        func checksumValid(lenByte: UInt8, msg: UInt8, payload: [UInt8], cs: UInt8) -> Bool {
            // checksum is sum of all bytes before checksum modulo 256
            var sum: UInt16 = 0
            sum += UInt16(0x55)
            sum += UInt16(lenByte)
            sum += UInt16(msg)
            for x in payload { sum += UInt16(x) }
            return UInt8(sum & 0xFF) == cs
        }

        let lenByte = b[1]

        let candidateA = parseA()
        let candidateB = parseB()

        let chosen: (msg: UInt8, payload: [UInt8], cs: UInt8)? = {
            if let a = candidateA, checksumValid(lenByte: lenByte, msg: a.msg, payload: a.payload, cs: a.cs) { return a }
            if let b = candidateB, checksumValid(lenByte: lenByte, msg: b.msg, payload: b.payload, cs: b.cs) { return b }
            // If neither matches, still try A as a last resort (some pads ignore checksum)
            return candidateA ?? candidateB
        }()

        guard let frame = chosen else { return false }

        // Only handle frames for pending requests we are awaiting.
        guard let pending = pending55.removeValue(forKey: frame.msg) else {
            return false
        }

        // Debug what we actually got (helps when status != 0 or payload is short)
        print("IN55 len=\(len) msg=\(frame.msg) payloadLen=\(frame.payload.count) payload=\(hex(frame.payload))")

        switch pending.kind {
        case .other:
            pending.continuation.resume(returning: frame.payload)
            return true

        case .readPages:
            guard frame.payload.count >= 1 else {
                pending.continuation.resume(throwing: ToyPadReadError.malformedResponse)
                return true
            }

            let status = frame.payload[0]
            guard status == 0 else {
                pending.continuation.resume(throwing: ToyPadReadError.deviceError(status: status))
                return true
            }

            guard frame.payload.count >= 1 + 16 else {
                pending.continuation.resume(throwing: ToyPadReadError.malformedResponse)
                return true
            }

            let data16 = Array(frame.payload[1..<(1 + 16)])
            pending.continuation.resume(returning: data16)
            return true
        }
    }
    
    private func readPages(padByte: UInt8, startPage: UInt8) async throws -> [UInt8] {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }

        guard let tag = presentTagByPad[padByte] else { throw ToyPadReadError.tagNotPresent }
        let index = tag.index
        let msg = nextMsg()
        print("D2 READ msg=\(msg) pad=\(padByte) index=\(index) page=\(String(format:"%02X", startPage))")

        // cmd: 55 04 D2 <msg> <index> <page>
        let data16 = try await request55(
            kind: .readPages,
            dev: dev,
            cmd: createReadTagCommand(msg: msg, index: index, page: startPage)
        )

        // handle55Response(.readPages) liefert bereits nur die 16 Datenbytes
        guard data16.count == 16 else { throw ToyPadReadError.malformedResponse }
        return data16
    }

    /// Send a 0x55 command frame and await the 0x55 response payload (without checksum).
    private func request55(kind: PendingKind, dev: IOHIDDevice, cmd: [UInt8], timeoutNs: UInt64 = 800_000_000) async throws -> [UInt8] {
        // cmd must already include the leading 0x55, length, opcode, msg, ...
        guard cmd.count >= 4, cmd[0] == 0x55 else { throw ToyPadReadError.malformedResponse }
        let msg = cmd[3]

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            pending55[msg] = Pending55(kind: kind, continuation: cont)
            sendCommand(dev, cmd)

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNs)
                if let pending = self.pending55.removeValue(forKey: msg) {
                    pending.continuation.resume(throwing: ToyPadReadError.timeout)
                }
            }
        }
    }

    private func switchPad(_ dev: IOHIDDevice, pad: Pad, r: UInt8, g: UInt8, b: UInt8) {
        // 0x55 0x06 0xC0 0x02 = "switch pad color"
        // then: pad, R, G, B
        sendCommand(dev, [0x55, 0x06, 0xC0, 0x02, pad.rawValue, r, g, b])
    }

    private func sendCommand(_ dev: IOHIDDevice, _ cmd: [UInt8]) {
        var message = cmd
        message.append(checksum(cmd))        // add checksum byte

        // pad to 32 bytes
        while message.count < 32 { message.append(0x00) }

        message.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, ptr, message.count)
            if r == kIOReturnSuccess {
                print("⬆️ OUT \(message.count) bytes cmd=\(cmd.map{String(format:"%02X",$0)}.joined(separator:" "))")
            } else {
                print("IOHIDDeviceSetReport failed: \(r)")
            }
        }
    }

    // MARK: Comm Utilities
    
    private func checksum(_ bytes: [UInt8]) -> UInt8 {
        // modulo 256 sum
        var s: UInt16 = 0
        for b in bytes { s += UInt16(b) }
        return UInt8(s & 0xFF)
    }

    private func createReadTagCommand(msg: UInt8, index: UInt8, page: UInt8) -> [UInt8] {
        [0x55, 0x04, 0xD2, msg, index, page]
    }
    
    // MARK: Pad Utilities
    
    private func padName(_ pad: UInt8) -> String {
        switch pad {
        case 1: return "Center"
        case 2: return "Left"
        case 3: return "Right"
        default: return "Pad \(pad)"
        }
    }
    
    // MARK: General Utilities
    
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    private func signatureString(_ uid: [UInt8]) -> String {
        uid.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: Tag decoding

    private func detectTagType(_ block26: [UInt8]) -> TagType {
        let vehicleMarker: [UInt8] = [0x00, 0x01, 0x00, 0x00]
        guard block26.count >= vehicleMarker.count else { return .unknown }
        for i in 0..<vehicleMarker.count where block26[i] != vehicleMarker[i] {
            return .character
        }
        return .vehicle
    }

    private func getVehicleId(_ data: [UInt8]) -> Int {
        guard data.count >= 2 else { return 0 }
        return Int(UInt16(data[1]) << 8 | UInt16(data[0]))
    }

    private func getCharacterId(uid: [UInt8], encrypted: [UInt8]) -> Int {
        guard uid.count == 7, encrypted.count >= 8 else { return 0 }
        let key = generateKeys(uid)
        let v0 = readUInt32LE(encrypted, offset: 0)
        let v1 = readUInt32LE(encrypted, offset: 4)
        let decrypted = teaDecrypt(values: (v0, v1), key: key)
        guard decrypted.0 == decrypted.1 else { return 0 }
        return Int(decrypted.0 & 0xFFFF)
    }

    private func readUInt32LE(_ buffer: [UInt8], offset: Int) -> UInt32 {
        let b0 = UInt32(buffer[offset])
        let b1 = UInt32(buffer[offset + 1]) << 8
        let b2 = UInt32(buffer[offset + 2]) << 16
        let b3 = UInt32(buffer[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private func rotateRight(_ value: UInt32, count: UInt32) -> UInt32 {
        let normalized = count & 31
        return (value >> normalized) | (value << (32 - normalized))
    }

    private func scramble(_ uid: [UInt8], count: Int) -> UInt32 {
        var base: [UInt8] = [
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xb7,
            0xd5, 0xd7, 0xe6, 0xe7, 0xba, 0x3c, 0xa8, 0xd8,
            0x75, 0x47, 0x68, 0xcf, 0x23, 0xe9, 0xfe, 0xaa
        ]
        for i in 0..<min(uid.count, 7) {
            base[i] = uid[i]
        }
        base[count * 4 - 1] = 0xaa

        var v2: UInt32 = 0
        for i in 0..<count {
            let b = readUInt32LE(base, offset: i * 4)
            v2 = (b &+ rotateRight(v2, count: 25) &+ rotateRight(v2, count: 10) &- v2)
        }
        return v2
    }

    private func generateKeys(_ uid: [UInt8]) -> (UInt32, UInt32, UInt32, UInt32) {
        return (
            scramble(uid, count: 3),
            scramble(uid, count: 4),
            scramble(uid, count: 5),
            scramble(uid, count: 6)
        )
    }

    private func teaDecrypt(values: (UInt32, UInt32), key: (UInt32, UInt32, UInt32, UInt32)) -> (UInt32, UInt32) {
        var v0 = values.0
        var v1 = values.1
        var sum: UInt32 = 0xc6ef3720
        let delta: UInt32 = 0x9e3779b9
        let k0 = key.0
        let k1 = key.1
        let k2 = key.2
        let k3 = key.3

        for _ in 0..<32 {
            v1 = v1 &- (((v0 << 4) &+ k2) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k3))
            v0 = v0 &- (((v1 << 4) &+ k0) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k1))
            sum = sum &- delta
        }
        return (v0, v1)
    }
    
}
