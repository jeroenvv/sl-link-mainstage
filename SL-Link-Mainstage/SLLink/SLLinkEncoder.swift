import Foundation

/// Pure, side-effect-free builders for outbound SL Link SysEx messages.
/// Every function returns a complete `F0 ... F7` byte array for a given
/// (id1, id2) device identity pair. No CoreMIDI, no state.
nonisolated enum SLLinkEncoder {

    // MARK: - Shared helpers

    /// Splits a value wider than 7 bits into MSB/LSB per the spec's rule:
    /// `msb = v >> 7`, `lsb = v & 0x7F`.
    static func msbLsb(_ value: Int) -> (msb: UInt8, lsb: UInt8) {
        let clamped = UInt16(clamping: max(0, value))
        return (UInt8((clamped >> 7) & 0x7F), UInt8(clamped & 0x7F))
    }

    /// Converts an 8-bit-per-channel color to the 7-bit-per-channel format
    /// used by every SL Link color field, by dropping the least significant
    /// bit of each channel (`shifting one bit right`, per the spec prose and
    /// confirmed by both reference implementations' `r = r >> 1`).
    ///
    /// Note: the spec's own "About the Colors" code sample instead shows
    /// `red8 >> 3`, `green8 >> 2`, `blue8 >> 3` — that is the RGB565 icon
    /// conversion pasted into the wrong section. We follow the prose and the
    /// reference implementations, not that code sample.
    static func rgb7(_ color: SLColor) -> (r: UInt8, g: UInt8, b: UInt8) {
        (color.r >> 1, color.g >> 1, color.b >> 1)
    }

    private static func header(_ id1: UInt8, _ id2: UInt8) -> [UInt8] {
        [SLLinkHeader.sysexStart] + SLLinkHeader.manufacturerID + [SLLinkHeader.productID, id1, id2]
    }

    private static func finish(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [SLLinkHeader.sysexEnd]
    }

    /// ASCII-clamps a string to the SLMK2 font range (`0x20`...`0x80`) and
    /// appends the required `0x00` terminator. Characters outside the range
    /// become spaces, per spec.
    private static func asciiTerminated(_ text: String, maxLength: Int = 32) -> [UInt8] {
        var bytes: [UInt8] = text.unicodeScalars.prefix(maxLength).map { scalar in
            let value = scalar.value
            if value >= 0x20, value <= 0x80 {
                return UInt8(value)
            }
            return 0x20
        }
        bytes.append(0x00)
        return bytes
    }

    // MARK: - Identification Messages (0x7F)

    static func identificationRequest(id1: UInt8, id2: UInt8, name: String) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.identification.rawValue)
        message.append(SLLinkIdentificationFunction.request.rawValue)
        message.append(contentsOf: asciiTerminated(name))
        return finish(message)
    }

    static func identificationQuery(id1: UInt8, id2: UInt8) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.identification.rawValue)
        message.append(SLLinkIdentificationFunction.query.rawValue)
        return finish(message)
    }

    // MARK: - System Messages (0x00)

    static func systemDeviceNotification(id1: UInt8, id2: UInt8) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.system.rawValue)
        message.append(SLLinkSystemFunction.deviceNotification.rawValue)
        return finish(message)
    }

    /// Non-spec variant of the keepalive, matching both official reference
    /// implementations (`SysexComponent.cpp` / `SysexService.cpp`), which
    /// append the app name to every System+`00 00` message instead of (or as
    /// well as) putting it in the Identification Request. Kept behind a
    /// runtime toggle in case the spec path never gets us listed on real
    /// hardware.
    static func systemDeviceNotification(id1: UInt8, id2: UInt8, name: String) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.system.rawValue)
        message.append(SLLinkSystemFunction.deviceNotification.rawValue)
        message.append(contentsOf: asciiTerminated(name))
        return finish(message)
    }

    static func systemLogoutRequest(id1: UInt8, id2: UInt8) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.system.rawValue)
        message.append(SLLinkSystemFunction.logoutRequest.rawValue)
        return finish(message)
    }

    static func systemLogoutConfirmation(id1: UInt8, id2: UInt8) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.system.rawValue)
        message.append(SLLinkSystemFunction.logoutConfirmation.rawValue)
        return finish(message)
    }

    // MARK: - Display Messages (0x04)

    static func displayClearScreen(id1: UInt8, id2: UInt8, color: SLColor) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.display.rawValue)
        message.append(SLLinkDisplayFunction.clearScreen.rawValue)
        let (r, g, b) = rgb7(color)
        message.append(r)
        message.append(g)
        message.append(b)
        return finish(message)
    }

    static func displayDrawRectangle(id1: UInt8, id2: UInt8, x: Int, y: Int, width: Int, height: Int, color: SLColor) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.display.rawValue)
        message.append(SLLinkDisplayFunction.drawRectangle.rawValue)
        let xSplit = msbLsb(x)
        let ySplit = msbLsb(y)
        let wSplit = msbLsb(width)
        let hSplit = msbLsb(height)
        message.append(xSplit.msb)
        message.append(xSplit.lsb)
        message.append(ySplit.msb)
        message.append(ySplit.lsb)
        message.append(wSplit.msb)
        message.append(wSplit.lsb)
        message.append(hSplit.msb)
        message.append(hSplit.lsb)
        let (r, g, b) = rgb7(color)
        message.append(r)
        message.append(g)
        message.append(b)
        return finish(message)
    }

    static func displayWriteText(
        id1: UInt8,
        id2: UInt8,
        text: String,
        x: Int,
        y: Int,
        maxWidth: Int,
        align: SLTextAlign,
        size: SLTextSize,
        foreground: SLColor,
        background: SLColor
    ) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.display.rawValue)
        message.append(SLLinkDisplayFunction.writeText.rawValue)
        let xSplit = msbLsb(x)
        let ySplit = msbLsb(y)
        let wSplit = msbLsb(maxWidth)
        message.append(xSplit.msb)
        message.append(xSplit.lsb)
        message.append(ySplit.msb)
        message.append(ySplit.lsb)
        message.append(wSplit.msb)
        message.append(wSplit.lsb)
        message.append(align.rawValue)
        message.append(size.rawValue)
        let (fr, fg, fb) = rgb7(foreground)
        let (br, bg, bb) = rgb7(background)
        message.append(fr)
        message.append(fg)
        message.append(fb)
        message.append(br)
        message.append(bg)
        message.append(bb)
        // No protocol-mandated cap on Write Text's string length (unlike the
        // 32-byte-capped Identification name) - the SL truncates visually to
        // `maxWidth` pixels anyway. 96 is a generous bound just to keep the
        // SysEx message itself finite.
        message.append(contentsOf: asciiTerminated(text, maxLength: 96))
        return finish(message)
    }

    static func displayPlotBitmap(
        id1: UInt8,
        id2: UInt8,
        x: Int,
        y: Int,
        groupIndex: UInt8,
        iconIndex: UInt8,
        foreground: SLColor,
        background: SLColor
    ) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.display.rawValue)
        message.append(SLLinkDisplayFunction.plotBitmap.rawValue)
        let xSplit = msbLsb(x)
        let ySplit = msbLsb(y)
        message.append(xSplit.msb)
        message.append(xSplit.lsb)
        message.append(ySplit.msb)
        message.append(ySplit.lsb)
        message.append(groupIndex)
        message.append(iconIndex)
        let (fr, fg, fb) = rgb7(foreground)
        let (br, bg, bb) = rgb7(background)
        message.append(fr)
        message.append(fg)
        message.append(fb)
        message.append(br)
        message.append(bg)
        message.append(bb)
        return finish(message)
    }

    // MARK: - Hardware I/O (0x01, 0x02, 0x03, 0x05)

    static func ledWhite(id1: UInt8, id2: UInt8, led: SLWhiteLED, on: Bool) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.led.rawValue)
        message.append(led.rawValue)
        message.append(on ? 0x01 : 0x00)
        return finish(message)
    }

    static func ledRGB(id1: UInt8, id2: UInt8, ledIndex: UInt8, color: SLColor, brightness: UInt8) -> [UInt8] {
        var message = header(id1, id2)
        message.append(SLLinkItemType.rgbLED.rawValue)
        message.append(ledIndex)
        let (r, g, b) = rgb7(color)
        message.append(r)
        message.append(g)
        message.append(b)
        message.append(min(brightness, 0x7F))
        return finish(message)
    }
}
