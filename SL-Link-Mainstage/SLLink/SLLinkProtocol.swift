import Foundation

// MARK: - Header

nonisolated enum SLLinkHeader {
    static let sysexStart: UInt8 = 0xF0
    static let sysexEnd: UInt8 = 0xF7
    static let manufacturerID: [UInt8] = [0x00, 0x20, 0x1A]
    static let productID: UInt8 = 0x16

    /// Default host ID byte, matching Studiologic's own reference implementations
    /// (`SysexComponent.cpp` / `SysexService.cpp`), which treat ID#1/ID#2 as
    /// (HOST_ID, DEVICE_ID) rather than one 14-bit random value.
    static let defaultHostID: UInt8 = 0x03

    /// (0x00, 0x00) and (0x01, 0x00) are reserved by Studiologic and must never
    /// be used as a DeviceID pair.
    static func isReservedIDPair(_ id1: UInt8, _ id2: UInt8) -> Bool {
        (id1 == 0x00 && id2 == 0x00) || (id1 == 0x01 && id2 == 0x00)
    }
}

// MARK: - Item Types

nonisolated enum SLLinkItemType: UInt8 {
    case identification = 0x7F
    case system = 0x00
    case button = 0x01
    case led = 0x02
    case encoder = 0x03
    case display = 0x04
    case rgbLED = 0x05
    case hardwareSettings = 0x06
    case masterVolume = 0x07
}

// MARK: - Identification Messages (ItemType 0x7F)

nonisolated enum SLLinkIdentificationFunction: UInt8 {
    case request = 0x00
    case approved = 0x01
    case rejected = 0x02
    case query = 0x03
}

nonisolated enum SLLinkRejectReason: UInt8 {
    case deviceIDTakenOrReserved = 0x00
    case noSpaceInList = 0x01
}

nonisolated enum SLLinkIdentificationQueryResult: UInt8 {
    case notIdentified = 0x00
    case identified = 0x01
}

// MARK: - System Messages (ItemType 0x00)

nonisolated enum SLLinkSystemFunction: UInt8 {
    case deviceNotification = 0x00
    case loginConfirmation = 0x01
    case logoutRequest = 0x02
    case logoutConfirmation = 0x03
    case standby = 0x04
    case restart = 0x05
    case loginRecall = 0x06
    // 0x07-0x09 (device icon upload/ack/nack) are out of scope for this
    // milestone; kept out of this enum entirely since nothing encodes or
    // decodes them.
}

nonisolated enum SLModel: UInt8 {
    case sl88GT = 0x00
    case sl88 = 0x01
    case sl73 = 0x02
}

// MARK: - Display Messages (ItemType 0x04)

nonisolated enum SLLinkDisplayFunction: UInt8 {
    case writeText = 0x00
    case clearScreen = 0x01
    case drawRectangle = 0x02
    case plotBitmap = 0x03
}

nonisolated enum SLTextAlign: UInt8 {
    case left = 0x00
    case center = 0x01
    case right = 0x02
}

nonisolated enum SLTextSize: UInt8 {
    case small = 0x00
    case medium = 0x01
    case big = 0x02
}

// MARK: - Hardware I/O (ItemType 0x01, 0x02, 0x03, 0x05, 0x06, 0x07)
//
// Note: Master Volume (0x07) and Hardware/Pedal Settings (0x06) queries are
// intentionally out of scope for this milestone (see CLAUDE.md / project
// plan). Their ItemType constants are kept below purely as an accurate
// reference to the spec; nothing encodes or decodes them.

nonisolated enum SLWhiteLED: UInt8 {
    case zone1Button = 0x00
    case zone2Button = 0x01
    case zone3Button = 0x02
    case zone4Button = 0x03
    case appButton = 0x04
    case applyButton = 0x05
    case cancelButton = 0x06
    case homeButton = 0x07
    case globalButton = 0x08
    case dawButton = 0x09
    case aEncoder = 0x0A
    case bEncoder = 0x0B
}

nonisolated enum SLEncoderID: UInt8 {
    case zone1 = 0x00
    case zone2 = 0x01
    case zone3 = 0x02
    case zone4 = 0x03
    case joystick = 0x04
    case aEncoder = 0x05
    case bEncoder = 0x06
}

nonisolated enum SLButtonID: UInt8 {
    case zone1EncoderButton = 0x00
    case zone2EncoderButton = 0x01
    case zone3EncoderButton = 0x02
    case zone4EncoderButton = 0x03
    case zone1SelectButton = 0x04
    case zone2SelectButton = 0x05
    case zone3SelectButton = 0x06
    case zone4SelectButton = 0x07
    case globalButton = 0x09
    case dawButton = 0x0A
    case aEncoderButton = 0x0B
    case bEncoderButton = 0x0C
    case applyButton = 0x0E
    case cancelButton = 0x0F
    case homeButton = 0x10
    case joystickUp = 0x11
    case joystickLeft = 0x12
    case joystickDown = 0x13
    case joystickRight = 0x14
    case joystickMain = 0x15
}

nonisolated enum SLButtonEvent: UInt8 {
    case short = 0x01
    case long = 0x02
}

// MARK: - Colors

/// 8-bit-per-channel RGB, the natural representation on the macOS side.
/// SL Link messages carry 7-bit-per-channel color; conversion happens in
/// `SLLinkEncoder.rgb7(_:)`.
nonisolated struct SLColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let black = SLColor(r: 0, g: 0, b: 0)
    static let white = SLColor(r: 255, g: 255, b: 255)
}
