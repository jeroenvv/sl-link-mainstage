import Foundation

/// Drawing API over `SLLinkEncoder`, routed through `SLLinkSession.send(_:)`
/// so callers never touch the DeviceID pair or CoreMIDI directly.
///
/// Includes simple dirty-region memoization: `rect`/`text`/`bitmap` calls
/// are keyed by a caller-supplied `id` and skipped if the last call with
/// that id was identical. This is the "only send what changed" batching the
/// project plan calls for, kept intentionally simple (no automatic screen
/// diffing) since the on-keyboard UI in this milestone is a small, fixed
/// set of named regions. `invalidateAll()` clears the memo so the next call
/// for every id is resent - used after `clear()` and after a Restart, since
/// the SLMK2 forgets everything it displayed across Standby
/// (system-messages.md).
///
/// **Non-overlap requirement:** per-id memoization is only sound for
/// regions of the screen that do not overlap. Because `rect`/`text` skip
/// sending when a given id's content is unchanged, a caller that composes
/// a panel by layering draws (e.g. a filled "border" rect underneath a
/// smaller fill rect and some text) will corrupt the screen the moment
/// only the bottom layer changes: the bottom layer gets resent and every
/// unchanged layer stacked on top of it - which the device needs resent
/// too, since the SLMK2 has no concept of layers and simply paints in
/// message order - gets skipped, so the redraw paints over its own
/// contents. Give every id a screen region that does not overlap any other
/// id's region (e.g. a true outline made of edge strips instead of a
/// filled rect, tiled flush against an inset fill) so each id can be
/// redrawn independently and safely. If overlap is genuinely unavoidable,
/// use `invalidate(ids:)` to force every id sharing that overlapping
/// region to be resent together.
nonisolated final class SLLinkDisplay {

    private struct RectState: Equatable {
        var x: Int, y: Int, width: Int, height: Int
        var color: SLColor
    }

    private struct TextState: Equatable {
        var text: String
        var x: Int, y: Int, maxWidth: Int
        var align: SLTextAlign
        var size: SLTextSize
        var foreground: SLColor
        var background: SLColor
    }

    private let session: SLLinkSession
    private var lastRects: [String: RectState] = [:]
    private var lastTexts: [String: TextState] = [:]

    init(session: SLLinkSession) {
        self.session = session
    }

    /// Forces the next call for every id to be resent, regardless of
    /// whether its content changed. Call this after `clear()` and after a
    /// `.restartRequiresRepaint` session event.
    func invalidateAll() {
        lastRects.removeAll()
        lastTexts.removeAll()
    }

    /// Forces the next `rect`/`text` call for each of the given ids to be
    /// resent regardless of whether its content changed. For the rare case
    /// where a caller has an unavoidable overlap between regions (see the
    /// type-level doc comment) and needs to force every id sharing that
    /// overlap to repaint together, rather than restructuring the layout.
    func invalidate(ids: [String]) {
        for id in ids {
            lastRects.removeValue(forKey: id)
            lastTexts.removeValue(forKey: id)
        }
    }

    func clear(color: SLColor = .black) {
        invalidateAll()
        session.send { id1, id2 in SLLinkEncoder.displayClearScreen(id1: id1, id2: id2, color: color) }
    }

    func rect(id: String, x: Int, y: Int, width: Int, height: Int, color: SLColor) {
        let newState = RectState(x: x, y: y, width: width, height: height, color: color)
        guard lastRects[id] != newState else { return }
        lastRects[id] = newState
        session.send { id1, id2 in
            SLLinkEncoder.displayDrawRectangle(id1: id1, id2: id2, x: x, y: y, width: width, height: height, color: color)
        }
    }

    func text(
        id: String,
        _ string: String,
        x: Int,
        y: Int,
        maxWidth: Int = 0,
        align: SLTextAlign = .left,
        size: SLTextSize = .small,
        foreground: SLColor = .white,
        background: SLColor = .black
    ) {
        let newState = TextState(
            text: string, x: x, y: y, maxWidth: maxWidth, align: align, size: size,
            foreground: foreground, background: background
        )
        guard lastTexts[id] != newState else { return }
        lastTexts[id] = newState
        session.send { id1, id2 in
            SLLinkEncoder.displayWriteText(
                id1: id1, id2: id2, text: string, x: x, y: y, maxWidth: maxWidth,
                align: align, size: size, foreground: foreground, background: background
            )
        }
    }

    func bitmap(x: Int, y: Int, groupIndex: UInt8, iconIndex: UInt8, foreground: SLColor, background: SLColor) {
        session.send { id1, id2 in
            SLLinkEncoder.displayPlotBitmap(
                id1: id1, id2: id2, x: x, y: y, groupIndex: groupIndex, iconIndex: iconIndex,
                foreground: foreground, background: background
            )
        }
    }

    func ledWhite(_ led: SLWhiteLED, on: Bool) {
        session.send { id1, id2 in SLLinkEncoder.ledWhite(id1: id1, id2: id2, led: led, on: on) }
    }

    func ledRGB(index: UInt8, color: SLColor, brightness: UInt8 = 127) {
        session.send { id1, id2 in SLLinkEncoder.ledRGB(id1: id1, id2: id2, ledIndex: index, color: color, brightness: brightness) }
    }
}
