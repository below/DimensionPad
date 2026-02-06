import Foundation
import Combine
import IOKit.hid

/// HID-backed interface to the LEGO Dimensions Toy Pad.
@MainActor
public final class DimensionPad {
    /// Connection state for the HID device.
    @Published public private(set) var connected: Bool = false
    /// Per-pad state (presence, UID, resolved name).
    @Published public private(set) var pads = PadSlots(
        center: PadState(present: false, uid: nil, characterID: nil, name: nil, world: nil),
        left: [],
        right: []
    )
    /// Tag add/remove events emitted by the Toy Pad.
    public let events = PassthroughSubject<TagEvent, Never>()

    enum ToyPadReadError: Error {
        case notConnected
        case tagNotPresent
        case timeout
        case malformedResponse
        case deviceError(status: UInt8)
        case checksumMismatch
        case busy
        case invalidWriteDataLength
        case invalidPasswordLength
        case ambiguousTagSelection
        case notVehicleTag
        case unknownVehicle
        case invalidVehicleStep
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
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["DIMENSIONPAD_DEBUG_LOGS"] == "1"

    internal var msgCounter: UInt8 = 0x01
    func nextMsgAvailable() throws -> UInt8 {
        for _ in 0..<256 {
            let m = msgCounter
            msgCounter &+= 1
            if pending55[m] == nil {
                return m
            }
        }
        throw ToyPadReadError.malformedResponse
    }

    internal enum PendingKind {
        case readPages
        case tagList
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

    private enum PortalPasswordMode: UInt8 {
        case disable = 0
        case automatic = 1
        case custom = 2
    }

    private struct TagSlotKey: Hashable {
        let pad: Pad
        let index: UInt8
    }

    private var presentTagBySlot: [TagSlotKey: PresentTag] = [:]
    private var isManagerConfigured = false

    public init() {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
    }
    
    /// Start  discovery and connect to the Toy Pad if present.
    public func connect() {
        guard !isManagerConfigured else { return }
        isManagerConfigured = true
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
        if debugLoggingEnabled {
            print(r == kIOReturnSuccess ? "HID manager open ✅" : "HID manager open ❌ \(r)")
        }
    }
 
    /// Read and decode tag information for a given pad
    public func readTagInfo(pad: Pad) async throws -> TagInfo {
        guard pad != .all else { throw ToyPadReadError.tagNotPresent }
        guard let tag = firstTag(for: pad) else { throw ToyPadReadError.tagNotPresent }
        let block = try await readPages(tagIndex: tag.index, startPage: 0x24)
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

    /// Write a 16-byte block to a tag page (writes 4 pages starting at `page`).
    /// If there are multiple tags on `pad`, provide `signature` to select one.
    public func writeTagBlock(
        pad: Pad,
        page: UInt8,
        data16: [UInt8],
        signature: String? = nil
    ) async throws {
        guard pad != .all else { throw ToyPadReadError.tagNotPresent }
        let tag = try resolveTagForWrite(pad: pad, signature: signature)
        try await writePages(tagIndex: tag.index, startPage: page, data16: data16)
    }

    /// Program a vehicle tag payload on page `0x24`.
    /// If `step` is omitted, it is derived from the passed `vehicleID` variant.
    /// If there are multiple tags on `pad`, provide `signature` to select one.
    public func writeVehicle(
        pad: Pad,
        vehicleID: Int,
        step: Int? = nil,
        signature: String? = nil
    ) async throws {
        try await writeVehicleInternal(
            pad: pad,
            vehicleID: vehicleID,
            step: step,
            signature: signature,
            requireExistingVehicleTag: true
        )
    }

    /// Initialize a blank/unknown tag as a vehicle by writing a vehicle payload to page `0x24`.
    /// This intentionally skips the "must already be a vehicle tag" precheck.
    public func initializeBlankVehicle(
        pad: Pad,
        vehicleID: Int,
        step: Int? = nil,
        signature: String? = nil
    ) async throws {
        try await writeVehicleInternal(
            pad: pad,
            vehicleID: vehicleID,
            step: step,
            signature: signature,
            requireExistingVehicleTag: false
        )
    }

    private func readTagInfo(pad: Pad, signature: String) async throws -> TagInfo {
        guard pad != .all else { throw ToyPadReadError.tagNotPresent }
        guard let tag = tagFor(pad: pad, signature: signature) else { throw ToyPadReadError.tagNotPresent }
        let block = try await readPages(tagIndex: tag.index, startPage: 0x24)
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

    private func writeVehicleInternal(
        pad: Pad,
        vehicleID: Int,
        step: Int?,
        signature: String?,
        requireExistingVehicleTag: Bool
    ) async throws {
        guard pad != .all else { throw ToyPadReadError.tagNotPresent }
        let tag = try resolveTagForWrite(pad: pad, signature: signature)

        if requireExistingVehicleTag {
            let info = try await readTagInfo(pad: pad, signature: tag.signature)
            guard info.type == .vehicle else { throw ToyPadReadError.notVehicleTag }
        }

        let variant = try resolveVehicleVariant(vehicleID: vehicleID, step: step)
        let payload = createVehiclePayload(vehicleID: variant.id, step: variant.step)

        // Some blank/generic tags reject writes while the portal is in automatic password mode.
        // For blank initialization we temporarily disable password handling on the target index.
        if !requireExistingVehicleTag {
            await setTagPasswordBestEffort(mode: .disable, index: tag.index)
        }

        do {
            try await writePages(tagIndex: tag.index, startPage: 0x24, data16: payload)
        } catch {
            if !requireExistingVehicleTag {
                await setTagPasswordBestEffort(mode: .automatic, index: tag.index)
            }
            throw error
        }

        // Some generic/blank tags acknowledge 16-byte writes but only persist the first 4 bytes.
        // Verify and force 4-byte page writes when the readback does not match the desired payload.
        let readback = try await readPages(tagIndex: tag.index, startPage: 0x24)
        if readback != payload {
            if debugLoggingEnabled {
                print("Write verify mismatch at page 0x24; forcing 4-byte page writes.")
                print("Expected: \(hex(payload))")
                print("Actual  : \(hex(readback))")
            }
            try await writePagesInChunks(tagIndex: tag.index, startPage: 0x24, data16: payload)
        }

        if !requireExistingVehicleTag {
            await setTagPasswordBestEffort(mode: .automatic, index: tag.index)
        }

        await resolveNameForPad(pad: pad, signature: tag.signature)
    }

    private func resolveNameForPad(pad: Pad, signature: String) async {
        guard pad != .all else { return }
        do {
            let info = try await readTagInfo(pad: pad, signature: signature)
            let name: String
            let world: String
            switch info.type {
            case .character:
                let character = DimensionPadMetadata.getCharacterById(info.id)
                let display = character?.name ?? String(info.id)
                world = character?.world ?? "Unknown"
                name = display
            case .vehicle:
                let vehicle = DimensionPadMetadata.getVehicleById(info.id)
                let display = vehicle?.name ?? String(info.id)
                world = vehicle?.world ?? "Unknown"
                name = display
            case .unknown:
                return
            }

            if pad == .center {
                if pads.center.uid == signature {
                    publishPad(pad, present: true, uid: signature, characterID: info.id, name: name, world: world)
                }
            } else if containsUid(signature, in: pad) {
                publishPad(pad, present: true, uid: signature, characterID: info.id, name: name, world: world)
            }
        } catch {
            // ignore read failures
        }
    }

    private func publishPad(_ pad: Pad, present: Bool, uid: String?, characterID: Int?, name: String?, world: String?) {
        var next = pads
        switch pad {
        case .center:
            next.center = PadState(present: present, uid: uid, characterID: characterID, name: name, world: world)
        case .left:
            updateSet(&next.left, present: present, uid: uid, characterID: characterID, name: name, world: world)
        case .right:
            updateSet(&next.right, present: present, uid: uid, characterID: characterID, name: name, world: world)
        case .all:
            break
        }
        pads = next
    }

    private func updateSet(_ set: inout Set<PadState>, present: Bool, uid: String?, characterID: Int?, name: String?, world: String?) {
        guard let uid else {
            if !present {
                set.removeAll()
            }
            return
        }

        set = set.filter { $0.uid != uid }
        if present {
            set.insert(PadState(present: true, uid: uid, characterID: characterID, name: name, world: world))
        }
    }

    private func containsUid(_ uid: String, in pad: Pad) -> Bool {
        switch pad {
        case .left:
            return pads.left.contains { $0.uid == uid }
        case .right:
            return pads.right.contains { $0.uid == uid }
        case .center:
            return pads.center.uid == uid
        case .all:
            return false
        }
    }

    private func firstTag(for pad: Pad) -> PresentTag? {
        return presentTagBySlot.first { $0.key.pad == pad }?.value
    }

    private func tagFor(pad: Pad, signature: String) -> PresentTag? {
        return presentTagBySlot.first { $0.key.pad == pad && $0.value.signature == signature }?.value
    }

    private func tags(for pad: Pad) -> [PresentTag] {
        presentTagBySlot
            .filter { $0.key.pad == pad }
            .map(\.value)
    }

    private func resolveTagForWrite(pad: Pad, signature: String?) throws -> PresentTag {
        if let signature {
            guard let tag = tagFor(pad: pad, signature: signature) else {
                throw ToyPadReadError.tagNotPresent
            }
            return tag
        }

        let entries = tags(for: pad)
        guard !entries.isEmpty else {
            throw ToyPadReadError.tagNotPresent
        }
        guard entries.count == 1 else {
            throw ToyPadReadError.ambiguousTagSelection
        }
        return entries[0]
    }

    private func parseTagList(_ payload: [UInt8]) -> [(Pad, UInt8)] {
        var results: [(Pad, UInt8)] = []
        var i = 0
        while i + 1 < payload.count {
            let padIndex = payload[i]
            let tagType = payload[i + 1]
            i += 2

            if padIndex == 0 { continue }
            let padNum = padIndex >> 4
            let index = padIndex & 0x0F
            guard let pad = Pad(rawValue: padNum) else { continue }
            if tagType != 0x00 { continue }
            results.append((pad, index))
        }
        return results
    }

    private func deviceMatched(_ dev: IOHIDDevice) async {
        device = dev
        connected = true
        // New USB session → reset protocol state
        msgCounter = 0x00
        pending55.removeAll()
        presentTagBySlot.removeAll()
        
        if debugLoggingEnabled {
            print("Device matched: \((IOHIDDeviceGetProperty(dev,  kIOHIDProductKey as CFString) as? String) ?? "-")")
        }

        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            print("IOHIDDeviceOpen failed: \(r)")
            return
        }

        // INIT wakes it up
        sendOutputReport(dev, TOYPAD_INIT)

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

        Task { @MainActor in
            await self.refreshPresentTagsFromList()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self.refreshPresentTagsFromList()
        }

        if debugLoggingEnabled {
            print("Input callback registered + INIT sent.")
        }
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        if let current = device, CFEqual(current, dev) {
            cancelPendingRequests()
            device = nil
            connected = false
            resetPads()
            if debugLoggingEnabled {
                print("Device removed.")
            }
        }
    }

    private func sendOutputReport(_ dev: IOHIDDevice, _ bytes: [UInt8], reportID: CFIndex = 0) {
        bytes.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, ptr, bytes.count)
            if debugLoggingEnabled {
                print(r == kIOReturnSuccess ? "OUT ✅ \(bytes.count) bytes" : "OUT ❌ \(r)")
            }
        }
    }

    private func refreshPresentTagsFromList() async {
        guard let dev = self.device else { return }
        for attempt in 0..<4 {
            do {
                let msg = try nextMsgAvailable()
                let payload = try await request55(
                    kind: .tagList,
                    dev: dev,
                    cmd: createTagListCommand(msg: msg)
                )

                let entries = parseTagList(payload)
                if entries.isEmpty && attempt < 3 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }

                for (pad, index) in entries {
                    let tagIndex = index
                    let data16 = try await readPages(tagIndex: tagIndex, startPage: 0x00)
                    guard data16.count >= 8 else { continue }
                    let uid: [UInt8] = [data16[0], data16[1], data16[2], data16[4], data16[5], data16[6], data16[7]]
                    let signature = signatureString(uid)
                    let key = TagSlotKey(pad: pad, index: tagIndex)

                    if presentTagBySlot[key]?.signature != signature {
                        presentTagBySlot[key] = PresentTag(uid: uid, signature: signature, index: tagIndex)
                        publishPad(pad, present: true, uid: signature, characterID: nil, name: nil, world: nil)
                        Task { @MainActor in
                            await resolveNameForPad(pad: pad, signature: signature)
                        }
                        events.send(TagEvent(action: .add, pad: pad, signature: signature, index: tagIndex, uid: uid))
                    }
                }
                break
            } catch {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                break
            }
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
        let pad: Pad
        let index: UInt8      // index
        let action: UInt8     // 0=inserted, 1=removed
        let uid: [UInt8]      // 7 bytes
    }

    private func parseTag(_ b: [UInt8]) -> TagEv? {
        guard b.count == 32 else { return nil }
        guard b[0] == 0x56, b[1] == 0x0B else { return nil }

        guard let pad = Pad(rawValue: b[2]) else { return nil }
        let index = b[4]          // 0,1,2  (slot)
        let action = b[5]
        let uid = Array(b[6...12]) // 7 bytes

        if debugLoggingEnabled {
            print("TAG \(hex(b))")
        }

        return TagEv(pad: pad, index: index, action: action, uid: uid)
    }
    
    private func handleTag(_ ev: TagEv) {
        let signature = signatureString(ev.uid)

        switch ev.action {
        case 0: // inserted
            // Only log/publish if this is a new UID for that pad
            let key = TagSlotKey(pad: ev.pad, index: ev.index)
            if presentTagBySlot[key]?.signature != signature {
                presentTagBySlot[key] = PresentTag(uid: ev.uid, signature: signature, index: ev.index)
                if debugLoggingEnabled {
                    print("✅ \(ev.pad.rawValue) inserted uid=\(signature)")
                }
                publishPad(ev.pad, present: true, uid: signature, characterID: nil, name: nil, world: nil)
                Task { @MainActor in
                    await resolveNameForPad(pad: ev.pad, signature: signature)
                }
                events.send(TagEvent(action: .add, pad: ev.pad, signature: signature, index: ev.index, uid: ev.uid))
            }

        case 1: // removed
            // Only log/publish if something was present
            let key = TagSlotKey(pad: ev.pad, index: ev.index)
            if let removed = presentTagBySlot[key] {
                presentTagBySlot[key] = nil
                if debugLoggingEnabled {
                    print("❌ \(ev.pad.rawValue) removed")
                }
                publishPad(ev.pad, present: false, uid: removed.signature, characterID: nil, name: nil, world: nil)
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
        if debugLoggingEnabled {
            print("IN55 len=\(len) msg=\(frame.msg) payloadLen=\(frame.payload.count) payload=\(hex(frame.payload))")
        }

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

        case .tagList:
            pending.continuation.resume(returning: frame.payload)
            return true
        }
    }
    
    private func readPages(tagIndex: UInt8, startPage: UInt8) async throws -> [UInt8] {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        let msg = try nextMsgAvailable()
        if debugLoggingEnabled {
            print("D2 READ msg=\(msg) index=\(tagIndex) page=\(String(format:"%02X", startPage))")
        }

        let data16 = try await request55(
            kind: .readPages,
            dev: dev,
            cmd: createReadTagCommand(msg: msg, index: tagIndex, page: startPage)
        )

        guard data16.count == 16 else { throw ToyPadReadError.malformedResponse }
        return data16
    }

    private func writePages(tagIndex: UInt8, startPage: UInt8, data16: [UInt8]) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        guard data16.count == 16 else { throw ToyPadReadError.invalidWriteDataLength }
        let msg = try nextMsgAvailable()
        if debugLoggingEnabled {
            print("D3 WRITE msg=\(msg) index=\(tagIndex) page=\(String(format:"%02X", startPage)) data=\(hex(data16))")
        }

        do {
            let payload = try await request55(
                kind: .other,
                dev: dev,
                cmd: createWriteTagCommand(msg: msg, index: tagIndex, page: startPage, data16: data16)
            )

            guard let status = payload.first else { throw ToyPadReadError.malformedResponse }
            guard status == 0 else { throw ToyPadReadError.deviceError(status: status) }
        } catch ToyPadReadError.deviceError(let status) where status == 0xF2 {
            // Compatibility fallback: some tags only accept 4-byte Ultralight writes.
            try await writePagesInChunks(tagIndex: tagIndex, startPage: startPage, data16: data16)
        }
    }

    private func writePagesInChunks(tagIndex: UInt8, startPage: UInt8, data16: [UInt8]) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        guard data16.count == 16 else { throw ToyPadReadError.invalidWriteDataLength }

        for chunkIndex in 0..<4 {
            let offset = chunkIndex * 4
            let page = startPage &+ UInt8(chunkIndex)
            let chunk = Array(data16[offset..<(offset + 4)])
            let msg = try nextMsgAvailable()
            if debugLoggingEnabled {
                print("D3 WRITE(4B) msg=\(msg) index=\(tagIndex) page=\(String(format:"%02X", page)) data=\(hex(chunk))")
            }

            let payload = try await request55(
                kind: .other,
                dev: dev,
                cmd: createWriteTagCommand4(msg: msg, index: tagIndex, page: page, data4: chunk)
            )

            guard let status = payload.first else { throw ToyPadReadError.malformedResponse }
            guard status == 0 else { throw ToyPadReadError.deviceError(status: status) }
        }
    }

    private func setTagPassword(mode: PortalPasswordMode, index: UInt8, customPassword: [UInt8] = [0, 0, 0, 0]) async throws {
        guard let dev = self.device else { throw ToyPadReadError.notConnected }
        guard customPassword.count == 4 else { throw ToyPadReadError.invalidPasswordLength }
        let msg = try nextMsgAvailable()

        let payload = try await request55(
            kind: .other,
            dev: dev,
            cmd: createSetTagPasswordCommand(msg: msg, mode: mode.rawValue, index: index, customPassword: customPassword)
        )

        guard let status = payload.first else { throw ToyPadReadError.malformedResponse }
        if status == 0 {
            return
        }
        // Some portals/tags reject switching back to automatic password mode even after a successful write.
        // Treat this as non-fatal so blank-tag initialization can proceed.
        if mode == .automatic, status == 0xF0 {
            if debugLoggingEnabled {
                print("E1 automatic returned F0 on index \(index); continuing.")
            }
            return
        }
        throw ToyPadReadError.deviceError(status: status)
    }

    private func setTagPasswordBestEffort(mode: PortalPasswordMode, index: UInt8) async {
        do {
            try await setTagPassword(mode: mode, index: index)
        } catch {
            if debugLoggingEnabled {
                print("E1 \(mode.rawValue) best-effort failed on index \(index): \(error)")
            }
        }
    }

    /// Send a 0x55 command frame and await the 0x55 response payload (without checksum).
    private func request55(kind: PendingKind, dev: IOHIDDevice, cmd: [UInt8], timeoutNs: UInt64 = 800_000_000) async throws -> [UInt8] {
        // cmd must already include the leading 0x55, length, opcode, msg, ...
        guard cmd.count >= 4, cmd[0] == 0x55 else { throw ToyPadReadError.malformedResponse }
        let msg = cmd[3]
        guard pending55[msg] == nil else { throw ToyPadReadError.busy }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            if pending55[msg] != nil {
                cont.resume(throwing: ToyPadReadError.malformedResponse)
                return
            }
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

    private func cancelPendingRequests() {
        let pending = pending55
        pending55.removeAll()
        for (_, item) in pending {
            item.continuation.resume(throwing: ToyPadReadError.notConnected)
        }
    }

    private func resetPads() {
        presentTagBySlot.removeAll()
        pads = PadSlots(center: PadState(present: false, uid: nil, characterID: nil, name: nil, world: nil))
    }

    private func switchPad(_ dev: IOHIDDevice, pad: Pad, r: UInt8, g: UInt8, b: UInt8) {
        // 0x55 0x06 0xC0 0x02 = "switch pad color"
        // then: pad, R, G, B
        sendCommand(dev, [0x55, 0x06, 0xC0, 0x02, pad.rawValue, r, g, b])
    }

    func sendCommand(_ dev: IOHIDDevice, _ cmd: [UInt8]) {
        var message = cmd
        message.append(checksum(cmd))        // add checksum byte

        // pad to 32 bytes
        while message.count < 32 { message.append(0x00) }

        message.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, ptr, message.count)
            if debugLoggingEnabled {
                if r == kIOReturnSuccess {
                    print("⬆️ OUT \(message.count) bytes cmd=\(cmd.map{String(format:"%02X",$0)}.joined(separator:" "))")
                } else {
                    print("IOHIDDeviceSetReport failed: \(r)")
                }
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

    private func createWriteTagCommand(msg: UInt8, index: UInt8, page: UInt8, data16: [UInt8]) -> [UInt8] {
        var cmd: [UInt8] = [0x55, 0x14, 0xD3, msg, index, page]
        cmd.append(contentsOf: data16)
        return cmd
    }

    private func createWriteTagCommand4(msg: UInt8, index: UInt8, page: UInt8, data4: [UInt8]) -> [UInt8] {
        var cmd: [UInt8] = [0x55, 0x08, 0xD3, msg, index, page]
        cmd.append(contentsOf: data4)
        return cmd
    }

    private func createSetTagPasswordCommand(msg: UInt8, mode: UInt8, index: UInt8, customPassword: [UInt8]) -> [UInt8] {
        var cmd: [UInt8] = [0x55, 0x08, 0xE1, msg, mode, index]
        cmd.append(contentsOf: customPassword)
        return cmd
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

    private struct VehicleVariant {
        let id: Int
        let step: Int
    }

    private func resolveVehicleVariant(vehicleID: Int, step: Int?) throws -> VehicleVariant {
        let all = DimensionPadMetadata.listVehicles()
        guard !all.isEmpty else { throw ToyPadReadError.unknownVehicle }

        if let step {
            guard step >= 0 else { throw ToyPadReadError.invalidVehicleStep }
            guard let selected = DimensionPadMetadata.getVehicleById(vehicleID) else {
                throw ToyPadReadError.unknownVehicle
            }
            let rootID = selected.parentId ?? selected.id
            let variants = all
                .filter { $0.id == rootID || $0.parentId == rootID }
                .sorted {
                    let lhsBase = $0.id == rootID ? 0 : 1
                    let rhsBase = $1.id == rootID ? 0 : 1
                    if lhsBase != rhsBase { return lhsBase < rhsBase }
                    return $0.id < $1.id
                }

            guard step < variants.count else { throw ToyPadReadError.invalidVehicleStep }
            return VehicleVariant(id: variants[step].id, step: step)
        }

        guard let selected = DimensionPadMetadata.getVehicleById(vehicleID) else {
            throw ToyPadReadError.unknownVehicle
        }
        let rootID = selected.parentId ?? selected.id
        let variants = all
            .filter { $0.id == rootID || $0.parentId == rootID }
            .sorted {
                let lhsBase = $0.id == rootID ? 0 : 1
                let rhsBase = $1.id == rootID ? 0 : 1
                if lhsBase != rhsBase { return lhsBase < rhsBase }
                return $0.id < $1.id
            }
        let stepIndex = variants.firstIndex { $0.id == selected.id } ?? 0
        return VehicleVariant(id: selected.id, step: stepIndex)
    }

    private func createVehiclePayload(vehicleID: Int, step: Int) -> [UInt8] {
        let normalizedID = UInt32(clamping: vehicleID)
        var payload = [UInt8](repeating: 0x00, count: 16)
        payload[0] = UInt8(normalizedID & 0xFF)
        payload[1] = UInt8((normalizedID >> 8) & 0xFF)
        payload[2] = UInt8((normalizedID >> 16) & 0xFF)
        payload[3] = UInt8((normalizedID >> 24) & 0xFF)
        payload[9] = 0x01
        payload[12] = upgradeFlag(step: step)
        return payload
    }

    private func upgradeFlag(step: Int) -> UInt8 {
        switch step {
        case 1:
            return 0x04
        case 2:
            return 0x08
        default:
            return 0x00
        }
    }
}
