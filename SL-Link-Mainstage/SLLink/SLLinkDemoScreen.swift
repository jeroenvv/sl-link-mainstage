import Foundation

/// The on-keyboard demo UI that proves the protocol stack works end to end:
/// a title bar and four zone panels, each showing a value.
///
/// Interaction model:
/// - Each zone's own rotary encoder always adjusts that zone's value.
/// - Exactly one zone can be the "selected" zone (`selectedZone`, `nil` =
///   none). A zone's select button SHORT-presses toggle it
///   selected/deselected; LONG-pressing it instead resets that zone's
///   value to 0. The Joystick's Left/Right directions move the selection
///   between zones (wrapping), and its Up/Down directions and its
///   built-in encoder all adjust the *selected* zone's value. Selection is
///   shown by a white outline plus the zone's RGB ring and white button
///   LED lighting up - see `selectZone`.
/// - Each zone's encoder push button SHORT-presses reset that zone's value
///   to 0; LONG-pressing it instead toggles that zone's selection (the two
///   events swapped relative to the select button above).
/// - The A and B encoders both adjust all four values together (see the
///   note below on A); either encoder's push button, and the Joystick's
///   main button, all reset every value to 0.
/// - The Home button forces a full repaint, exercising `redrawAll` without
///   needing a real Restart.
///
/// Note on the A encoder/button: hardware-io.md claims the Host never
/// receives A Encoder (`EID 0x05`) / A Encoder Button (`BID 0x0B`)
/// messages, reserved instead for the USB audio board's volume/mute, and
/// is silent on whether LONG_PRESSION is delivered at all. Both claims are
/// contradicted by a live capture from a physically attached SL88 MK2
/// (firmware 1.1.2): A Encoder/A Encoder Button messages arrive as
/// ordinary SL Link messages indistinguishable in form from the zone/B
/// ones (no Master Volume or channel-voice CC/pitch-bend traffic
/// accompanies them), and LONG_PRESSION arrives for ordinary buttons too.
/// This is a spec deviation on the same footing as the two documented in
/// CLAUDE.md (the swapped firmware/model payloads) - see CLAUDE.md's
/// "Hardware-confirmed deviations" list. Accordingly this file does not
/// special-case or drop A traffic: it is handled identically to B (see the
/// `.aEncoder`/`.bEncoder` and `.aEncoderButton`/`.bEncoderButton` cases
/// below), and no button event type is ever silently discarded.
///
/// Content is entirely hardcoded - no MainStage integration of any kind
/// (out of scope for this milestone; see CLAUDE.md's Scope boundary).
///
/// Threading: every method here must only be called from
/// `SLLinkSession.queue` (i.e. from `SLLinkSession.onEvent` handling, or via
/// `SLLinkSession.perform(_:)`), since it mutates plain (non-synchronized)
/// instance state and drives `SLLinkDisplay`, which has the same
/// requirement.
nonisolated final class SLLinkDemoScreen {
    private let display: SLLinkDisplay

    private var zoneValues: [Int] = [0, 0, 0, 0]

    /// The single currently-selected zone, or `nil` if none is selected.
    /// `handleButton`/`handleEncoder` route the Joystick's directional and
    /// rotary input to whichever zone this points at.
    private var selectedZone: Int? = nil

    private static let zoneColor: [SLColor] = [
        SLColor(r: 220, g: 60, b: 60),
        SLColor(r: 60, g: 200, b: 90),
        SLColor(r: 70, g: 130, b: 220),
        SLColor(r: 230, g: 190, b: 40)
    ]

    init(display: SLLinkDisplay) {
        self.display = display
    }

    /// Full redraw. Called on login/recall and after every Restart, since
    /// the SLMK2 retains no screen state across Standby
    /// (system-messages.md's Standby/Restart section).
    func redrawAll() {
        display.clear(color: .black)
        display.text(
            id: "title", "SL Link MainStage - Demo",
            x: 8, y: 6, maxWidth: 304, align: .left, size: .medium,
            foreground: .white, background: .black
        )
        for zone in 0..<4 {
            drawZoneBorder(zone)
            drawZoneFill(zone)
            drawZoneLabel(zone)
            drawZoneValue(zone)
        }
    }

    private static let borderThickness = 3

    private func zoneFrame(_ zone: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        (x: 8 + zone * 78, y: 44, width: 70, height: 150)
    }

    /// The panel interior, inset past the outline. Everything drawn inside a
    /// panel - the fill and both texts - must be bounded by this, never by
    /// `zoneFrame`. Text writes are opaque: the SLMK2 repaints the full
    /// background of the area a string occupies (display-messages.md's Write
    /// Text section), so a text spanning the whole `zoneFrame` width erases
    /// the left and right edge strips at that height. That showed up on
    /// hardware as a bar cutting through the borders whenever values changed.
    private func zoneContentFrame(_ zone: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let frame = zoneFrame(zone)
        let inset = Self.borderThickness
        return (x: frame.x + inset, y: frame.y + inset,
                width: frame.width - 2 * inset, height: frame.height - 2 * inset)
    }

    // MARK: - Panel drawing
    //
    // A panel tiles four non-overlapping regions: a 3px outline made of
    // four edge strips (top/bottom span the full width; left/right span
    // only the middle, between the top and bottom strips, so no two edges
    // cover the same pixel), an inset fill, and two texts bounded by
    // zoneContentFrame so they stay within the fill and never reach the
    // edge strips. Every id therefore owns pixels no other id touches,
    // so any one of them can be redrawn alone - e.g. a selection toggle
    // only needs to resend the outline - without corrupting the others.
    // See SLLinkDisplay's type-level doc comment for why that matters: the
    // previous version drew a single filled "border" rect under the fill,
    // and redrawing just that rect (as a selection toggle does) painted
    // over the fill/label/value it had layered on top of.

    private func drawZoneBorder(_ zone: Int) {
        let frame = zoneFrame(zone)
        let thickness = Self.borderThickness
        let borderColor = selectedZone == zone ? SLColor.white : Self.zoneColor[zone]
        display.rect(
            id: "zoneBorderTop\(zone)", x: frame.x, y: frame.y,
            width: frame.width, height: thickness, color: borderColor
        )
        display.rect(
            id: "zoneBorderBottom\(zone)", x: frame.x, y: frame.y + frame.height - thickness,
            width: frame.width, height: thickness, color: borderColor
        )
        display.rect(
            id: "zoneBorderLeft\(zone)", x: frame.x, y: frame.y + thickness,
            width: thickness, height: frame.height - 2 * thickness, color: borderColor
        )
        display.rect(
            id: "zoneBorderRight\(zone)", x: frame.x + frame.width - thickness, y: frame.y + thickness,
            width: thickness, height: frame.height - 2 * thickness, color: borderColor
        )
    }

    private func drawZoneFill(_ zone: Int) {
        let content = zoneContentFrame(zone)
        display.rect(
            id: "zoneFill\(zone)", x: content.x, y: content.y, width: content.width, height: content.height,
            color: .black
        )
    }

    private func drawZoneLabel(_ zone: Int) {
        let content = zoneContentFrame(zone)
        display.text(
            id: "zoneLabel\(zone)", "ZONE \(zone + 1)",
            x: content.x, y: content.y + 9, maxWidth: content.width, align: .center, size: .small,
            foreground: Self.zoneColor[zone], background: .black
        )
    }

    private func drawZoneValue(_ zone: Int) {
        let content = zoneContentFrame(zone)
        display.text(
            id: "zoneValue\(zone)", "\(zoneValues[zone])",
            x: content.x, y: content.y + 67, maxWidth: content.width, align: .center, size: .big,
            foreground: .white, background: .black
        )
    }

    // MARK: - Selection

    /// Selects `zone` (or clears the selection if `nil`), redrawing only
    /// the outline and LEDs of whichever zone(s) actually changed
    /// selection state - never the fill/label/value.
    private func selectZone(_ zone: Int?) {
        guard selectedZone != zone else { return }
        let previous = selectedZone
        selectedZone = zone
        if let previous {
            drawZoneBorder(previous)
            updateZoneIndicators(previous)
        }
        if let zone {
            drawZoneBorder(zone)
            updateZoneIndicators(zone)
        }
    }

    private func updateZoneIndicators(_ zone: Int) {
        let selected = selectedZone == zone
        display.ledRGB(index: UInt8(zone), color: selected ? Self.zoneColor[zone] : .black)
        // Zone 1-4 button white LEDs are WLID 0x00-0x03, i.e. the same
        // 0-based index as the zone itself.
        if let whiteLED = SLWhiteLED(rawValue: UInt8(zone)) {
            display.ledWhite(whiteLED, on: selected)
        }
    }

    private func toggleSelection(_ zone: Int) {
        selectZone(selectedZone == zone ? nil : zone)
    }

    /// Moves the selection left/right by `step` (+1 = right, -1 = left),
    /// wrapping across the 4 zones. If nothing is selected yet, treats the
    /// "current" position as just off one end so the first press lands on
    /// zone 0 (moving right) or zone 3 (moving left).
    private func moveSelection(by step: Int) {
        let base = selectedZone ?? (step > 0 ? -1 : 0)
        let next = ((base + step) % 4 + 4) % 4
        selectZone(next)
    }

    private func adjustSelectedZoneValue(by delta: Int) {
        guard let zone = selectedZone else { return }
        zoneValues[zone] += delta
        drawZoneValue(zone)
    }

    private func resetZoneValue(_ zone: Int) {
        zoneValues[zone] = 0
        drawZoneValue(zone)
    }

    private func resetAllValues() {
        zoneValues = [0, 0, 0, 0]
        for zone in 0..<4 { drawZoneValue(zone) }
    }

    // MARK: - Session events

    func handleEncoder(id: SLEncoderID, delta: Int) {
        switch id {
        case .zone1: zoneValues[0] += delta; drawZoneValue(0)
        case .zone2: zoneValues[1] += delta; drawZoneValue(1)
        case .zone3: zoneValues[2] += delta; drawZoneValue(2)
        case .zone4: zoneValues[3] += delta; drawZoneValue(3)

        case .joystick:
            adjustSelectedZoneValue(by: delta)

        case .aEncoder, .bEncoder:
            // Global control: nudges every zone's value together. hardware-io.md
            // says the Host shouldn't see A Encoder messages at all (reserved
            // for USB audio volume), but that has been observed not to hold on
            // real hardware - see the type-level doc comment. Treating A the
            // same as B costs nothing and means we don't silently drop
            // messages that do arrive.
            for zone in 0..<4 { zoneValues[zone] += delta }
            for zone in 0..<4 { drawZoneValue(zone) }
        }
    }

    func handleButton(id: SLButtonID, event: SLButtonEvent) {
        switch id {
        case .zone1SelectButton: handleZoneSelectButton(0, event: event)
        case .zone2SelectButton: handleZoneSelectButton(1, event: event)
        case .zone3SelectButton: handleZoneSelectButton(2, event: event)
        case .zone4SelectButton: handleZoneSelectButton(3, event: event)

        case .zone1EncoderButton: handleZoneEncoderButton(0, event: event)
        case .zone2EncoderButton: handleZoneEncoderButton(1, event: event)
        case .zone3EncoderButton: handleZoneEncoderButton(2, event: event)
        case .zone4EncoderButton: handleZoneEncoderButton(3, event: event)

        // No distinct LONG behaviour for these - short and long do the same
        // thing - but both are handled unconditionally so neither event
        // type is ever silently swallowed (confirmed on real hardware: both
        // SHORT and LONG_PRESSION arrive for ordinary buttons).
        case .joystickLeft: moveSelection(by: -1)
        case .joystickRight: moveSelection(by: 1)
        case .joystickUp: adjustSelectedZoneValue(by: 1)
        case .joystickDown: adjustSelectedZoneValue(by: -1)
        case .joystickMain: resetAllValues()

        case .aEncoderButton, .bEncoderButton:
            // Global control: mirrors joystickMain as a second "reset
            // everything" button. See the type-level doc comment for why A
            // is treated the same as B here rather than being ignored.
            resetAllValues()

        case .homeButton:
            // Cheap way to exercise the full-redraw path from the panel
            // itself, without needing a real Standby/Restart cycle.
            display.invalidateAll()
            redrawAll()

        case .globalButton, .dawButton, .applyButton, .cancelButton:
            // Available (with white LEDs) but intentionally left unused -
            // wiring every remaining button isn't worth the screen
            // clutter for this demo.
            break
        }
    }

    /// SHORT toggles the zone's selection; LONG resets its value to 0 -
    /// giving LONG_PRESSION (confirmed working on real hardware) a
    /// distinct, visible effect instead of being silently dropped.
    private func handleZoneSelectButton(_ zone: Int, event: SLButtonEvent) {
        switch event {
        case .short: toggleSelection(zone)
        case .long: resetZoneValue(zone)
        }
    }

    /// SHORT resets the zone's value to 0; LONG instead toggles its
    /// selection (mirroring `handleZoneSelectButton` with the two events
    /// swapped) - LONG_PRESSION on this exact button (Zone 1 Encoder
    /// Button, BID 0x00) was one of the specific hardware captures that
    /// confirmed LONG_PRESSION delivery, so it gets a real, visible effect
    /// rather than being dropped.
    private func handleZoneEncoderButton(_ zone: Int, event: SLButtonEvent) {
        switch event {
        case .short: resetZoneValue(zone)
        case .long: toggleSelection(zone)
        }
    }
}
