import Foundation

/// A decoded inbound SL Link message body. Only cases that can actually be
/// sent by the SLMK2 for the message categories implemented in this
/// milestone (identification, system/session, buttons, encoders) are
/// represented. Display/LED/RGB-LED are Device -> SL only, and Hardware
/// Settings / Master Volume are out of scope (see CLAUDE.md).
nonisolated enum SLLinkInbound: Equatable {
    /// Firmware/model payload is optional on the wire: real SL88 MK2
    /// hardware (firmware 1.1.2) sends it here (`MAJ MIN REV SL`, 4 extra
    /// bytes) rather than on Login Confirmation as the spec documents. See
    /// CLAUDE.md's "SL Link protocol (as implemented)" section.
    case identificationApproved(firmware: (UInt8, UInt8, UInt8)?, model: SLModel?)
    case identificationRejected(reason: SLLinkRejectReason)
    case identificationQueryResult(SLLinkIdentificationQueryResult)
    /// Firmware/model payload is optional here too: real hardware sends a
    /// bare 10-byte Login Confirmation with no payload at all, even though
    /// the spec documents one. Login Recall's payload has never been
    /// observed on hardware; treat it as optional as well.
    case loginConfirmed(firmware: (UInt8, UInt8, UInt8)?, model: SLModel?)
    case loginRecall(firmware: (UInt8, UInt8, UInt8)?, model: SLModel?)
    case logoutRequest
    case logoutConfirmation
    case standby
    case restart
    case button(id: SLButtonID, event: SLButtonEvent)
    case encoder(id: SLEncoderID, delta: Int)

    /// Tuple types can't conform to `Equatable`, so `Optional<(UInt8, UInt8,
    /// UInt8)>` can't use the synthesized `==` even though the bare tuple
    /// can. Compare by hand instead.
    private static func firmwareEqual(_ a: (UInt8, UInt8, UInt8)?, _ b: (UInt8, UInt8, UInt8)?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a == b
        default:
            return false
        }
    }

    static func == (lhs: SLLinkInbound, rhs: SLLinkInbound) -> Bool {
        switch (lhs, rhs) {
        case let (.identificationApproved(fwA, modelA), .identificationApproved(fwB, modelB)):
            return firmwareEqual(fwA, fwB) && modelA == modelB
        case let (.identificationRejected(a), .identificationRejected(b)):
            return a == b
        case let (.identificationQueryResult(a), .identificationQueryResult(b)):
            return a == b
        case let (.loginConfirmed(fwA, modelA), .loginConfirmed(fwB, modelB)):
            return firmwareEqual(fwA, fwB) && modelA == modelB
        case let (.loginRecall(fwA, modelA), .loginRecall(fwB, modelB)):
            return firmwareEqual(fwA, fwB) && modelA == modelB
        case (.logoutRequest, .logoutRequest),
             (.logoutConfirmation, .logoutConfirmation),
             (.standby, .standby),
             (.restart, .restart):
            return true
        case let (.button(idA, evtA), .button(idB, evtB)):
            return idA == idB && evtA == evtB
        case let (.encoder(idA, deltaA), .encoder(idB, deltaB)):
            return idA == idB && deltaA == deltaB
        default:
            return false
        }
    }
}

/// A fully decoded inbound message, carrying the DeviceID pair it was
/// addressed to so the session layer can filter without re-parsing bytes.
nonisolated struct SLLinkMessage: Equatable {
    let id1: UInt8
    let id2: UInt8
    let inbound: SLLinkInbound
}

nonisolated enum SLLinkDecoder {

    /// Decodes one complete `F0 ... F7` SysEx byte stream. Returns `nil` for
    /// anything malformed (bad header, MSB set on a data byte, truncated
    /// message, wrong length for the given function, unknown function) or
    /// for message types that only ever flow Device -> SL.
    static func decode(_ bytes: [UInt8]) -> SLLinkMessage? {
        guard bytes.count >= 10 else { return nil }
        guard bytes.first == SLLinkHeader.sysexStart, bytes.last == SLLinkHeader.sysexEnd else { return nil }
        guard Array(bytes[1...3]) == SLLinkHeader.manufacturerID, bytes[4] == SLLinkHeader.productID else { return nil }

        // Every data byte between F0 and F7 must have its MSB clear.
        let dataBytes = bytes[1..<(bytes.count - 1)]
        guard dataBytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }

        let id1 = bytes[5]
        let id2 = bytes[6]
        guard let itemType = SLLinkItemType(rawValue: bytes[7]) else { return nil }

        switch itemType {
        case .identification:
            return decodeIdentification(bytes, id1: id1, id2: id2)
        case .system:
            return decodeSystem(bytes, id1: id1, id2: id2)
        case .button:
            return decodeButton(bytes, id1: id1, id2: id2)
        case .encoder:
            return decodeEncoder(bytes, id1: id1, id2: id2)
        case .display, .led, .rgbLED:
            // Device -> SL only; the SLMK2 never sends these back.
            return nil
        case .hardwareSettings, .masterVolume:
            // Out of scope for this milestone (see CLAUDE.md / project
            // plan); not decoded even though the wire format is bidirectional.
            return nil
        }
    }

    // MARK: - Identification (0x7F)

    private static func decodeIdentification(_ bytes: [UInt8], id1: UInt8, id2: UInt8) -> SLLinkMessage? {
        guard let function = SLLinkIdentificationFunction(rawValue: bytes[8]) else { return nil }
        switch function {
        case .approved:
            // Spec documents a bare 10-byte approval. Real SL88 MK2 hardware
            // (firmware 1.1.2) instead sends 14 bytes, carrying `MAJ MIN REV
            // SL` where the spec would put it on Login Confirmation. Accept
            // both known forms.
            switch bytes.count {
            case 10:
                return SLLinkMessage(id1: id1, id2: id2, inbound: .identificationApproved(firmware: nil, model: nil))
            case 14:
                guard let model = SLModel(rawValue: bytes[12]) else { return nil }
                let firmware = (bytes[9], bytes[10], bytes[11])
                return SLLinkMessage(id1: id1, id2: id2, inbound: .identificationApproved(firmware: firmware, model: model))
            default:
                return nil
            }
        case .rejected:
            guard bytes.count == 11, let reason = SLLinkRejectReason(rawValue: bytes[9]) else { return nil }
            return SLLinkMessage(id1: id1, id2: id2, inbound: .identificationRejected(reason: reason))
        case .query:
            guard bytes.count == 11, let result = SLLinkIdentificationQueryResult(rawValue: bytes[9]) else { return nil }
            return SLLinkMessage(id1: id1, id2: id2, inbound: .identificationQueryResult(result))
        case .request:
            return nil
        }
    }

    // MARK: - System (0x00)

    private static func decodeSystem(_ bytes: [UInt8], id1: UInt8, id2: UInt8) -> SLLinkMessage? {
        guard let function = SLLinkSystemFunction(rawValue: bytes[8]) else { return nil }
        switch function {
        case .loginConfirmation, .loginRecall:
            // Spec documents a 14-byte payload (`MAJ MIN REV SL`) here. Real
            // hardware sends a bare 10-byte Login Confirmation with no
            // payload at all - the firmware/model info arrives on
            // Identification Approved instead (see above). Login Recall's
            // payload has never been observed on hardware; accept both
            // forms for it too.
            var firmware: (UInt8, UInt8, UInt8)?
            var model: SLModel?
            switch bytes.count {
            case 10:
                break
            case 14:
                guard let m = SLModel(rawValue: bytes[12]) else { return nil }
                firmware = (bytes[9], bytes[10], bytes[11])
                model = m
            default:
                return nil
            }
            let inbound: SLLinkInbound = function == .loginConfirmation
                ? .loginConfirmed(firmware: firmware, model: model)
                : .loginRecall(firmware: firmware, model: model)
            return SLLinkMessage(id1: id1, id2: id2, inbound: inbound)
        case .logoutRequest:
            guard bytes.count == 10 else { return nil }
            return SLLinkMessage(id1: id1, id2: id2, inbound: .logoutRequest)
        case .logoutConfirmation:
            guard bytes.count == 10 else { return nil }
            return SLLinkMessage(id1: id1, id2: id2, inbound: .logoutConfirmation)
        case .standby:
            guard bytes.count == 10 else { return nil }
            return SLLinkMessage(id1: id1, id2: id2, inbound: .standby)
        case .restart:
            guard bytes.count == 10 else { return nil }
            return SLLinkMessage(id1: id1, id2: id2, inbound: .restart)
        case .deviceNotification:
            // Device -> SL only.
            return nil
        }
    }

    // MARK: - Button (0x01)

    private static func decodeButton(_ bytes: [UInt8], id1: UInt8, id2: UInt8) -> SLLinkMessage? {
        guard bytes.count == 11 else { return nil }
        guard let buttonID = SLButtonID(rawValue: bytes[8]), let event = SLButtonEvent(rawValue: bytes[9]) else { return nil }
        return SLLinkMessage(id1: id1, id2: id2, inbound: .button(id: buttonID, event: event))
    }

    // MARK: - Encoder (0x03)

    private static func decodeEncoder(_ bytes: [UInt8], id1: UInt8, id2: UInt8) -> SLLinkMessage? {
        guard bytes.count == 11 else { return nil }
        guard let encoderID = SLEncoderID(rawValue: bytes[8]) else { return nil }
        let tick = Int(bytes[9])
        let delta = tick - 64
        return SLLinkMessage(id1: id1, id2: id2, inbound: .encoder(id: encoderID, delta: delta))
    }
}
