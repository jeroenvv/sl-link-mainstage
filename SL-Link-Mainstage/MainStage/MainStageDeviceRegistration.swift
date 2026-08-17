import Foundation
import CoreMIDI

/// Attempts to register a proper virtual MIDI *device* (an owning
/// `MIDIDeviceRef`/`MIDIEntityRef`, not just the bare endpoints
/// `MainStageEndpoint` already publishes) so that `MIDIEndpointGetEntity` /
/// `MIDIEntityGetDevice` resolve for our endpoints the way they do for the
/// real SL88 - see the "device"/"entity" columns in
/// `docs/mainstage-integration.md`'s probing table.
///
/// **This is a spike, and it does not work on this machine.** See the
/// "Virtual device registration" section of `docs/mainstage-integration.md`
/// for the full writeup. Short version: `MIDIDeviceCreate(owner: nil, ...)`
/// - the *only* entry point a non-driver process has into this API, per
/// Apple's own `MIDIDriver.h` comment ("Non-drivers may call this function
/// ... to create external devices") - returns `paramErr` (-50) immediately,
/// before `MIDIDeviceAddEntity` or `MIDISetupAddDevice` are ever reached.
/// Confirmed identically from a bare, unsigned, unsandboxed command-line
/// probe and from this app's actual sandboxed Debug build, so this is not
/// an App Sandbox restriction (no entitlement would fix it) - it is
/// CoreMIDI itself refusing the call for a process that isn't a registered
/// MIDI driver. `MIDISetupAddDevice` is separately documented in
/// `MIDISetup.h` as "Only MIDI drivers may make this call", so even a
/// hypothetical fix to `MIDIDeviceCreate` would still dead-end there for
/// the non-external-device path this task asked for.
///
/// This still implements the full requested `MIDIDeviceCreate` ->
/// `MIDIDeviceAddEntity` -> `MIDISetupAddDevice` chain end-to-end (rather
/// than stopping at the probe) and logs every `OSStatus`, so that if Apple
/// ever loosens this restriction it starts working with no further code
/// changes - and so the dev console always shows the real, current status
/// rather than a guess. `MainStageEndpoint`'s bare `MIDISourceCreate`/
/// `MIDIDestinationCreate` endpoints remain the sole working publishing
/// mechanism; nothing here touches them.
///
/// `nonisolated` per CLAUDE.md's `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` project setting: this type has no stored instance state (all
/// members are `static`), but under that build setting it would otherwise
/// be inferred main-actor-isolated, which is wrong since `MainStageEndpoint`
/// calls it from `serialQueue`, never the main actor.
nonisolated enum MainStageDeviceRegistration {

    /// Deliberately distinct from `MainStageEndpoint.endpointName` ("SL
    /// MainStage") so a registered device and its bare-endpoint sibling are
    /// distinguishable in Audio MIDI Setup / logs if this ever starts
    /// working. Manufacturer/model match `MainStageEndpoint` exactly since
    /// `config.lua`'s `controller_info()` must match both.
    ///
    /// "Bridge" rather than "Link" in the device's own *name* (as opposed
    /// to manufacturer, which is allowed to say "SL Link Bridge") is
    /// deliberate: `SLLinkTransport.matchesSLLink` matches case-insensitive
    /// *contains* "LINK" on `kMIDIPropertyDisplayName` of enumerated
    /// sources/destinations, and the real SL88's port is "SL LINK". Naming
    /// our device/entity/endpoints anything containing "link" risks a false
    /// match there - see CLAUDE.md and the project plan's constraint 1.
    static let deviceName = "SL MainStage Bridge"
    static let entityName = "SL MainStage"
    static let manufacturer = MainStageEndpoint.manufacturer
    static let model = MainStageEndpoint.model

    struct AttemptResult {
        var device: MIDIDeviceRef
        var succeeded: Bool
        /// Short human-readable outcome for the dev console.
        var summary: String
    }

    // MARK: - Stale-device cleanup

    /// Scans the current MIDI setup for a device matching our name/
    /// manufacturer/model (a stale `MIDIDeviceRef` *value* from a previous
    /// process is meaningless across launches - matching on identity is the
    /// only reliable way to find "ours") and removes it via
    /// `MIDISetupRemoveDevice`. Meant to run once at startup, before
    /// attempting a fresh registration, so a crash or force-quit of a
    /// previous run never leaves duplicates in the user's MIDI setup - see
    /// the project plan's constraint 2. Also exposed as the dev console's
    /// manual "Remove Device" escape hatch. Idempotent and safe to call even
    /// when nothing matches.
    @discardableResult
    static func removeStaleDevices(onLog: (String) -> Void) -> Int {
        var removedCount = 0
        for index in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(index)
            guard isOurs(device) else { continue }
            let status = MIDISetupRemoveDevice(device)
            onLog("MainStage device registration: found a device from a previous run; MIDISetupRemoveDevice -> \(status).")
            if status == noErr { removedCount += 1 }
        }
        return removedCount
    }

    private static func isOurs(_ device: MIDIDeviceRef) -> Bool {
        stringProperty(device, kMIDIPropertyName) == deviceName
            && stringProperty(device, kMIDIPropertyManufacturer) == manufacturer
            && stringProperty(device, kMIDIPropertyModel) == model
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - Registration attempt

    /// Runs `MIDIDeviceCreate` -> `MIDIDeviceAddEntity` -> `MIDISetupAddDevice`
    /// in sequence, logging every `OSStatus`. Stops and cleans up at the
    /// first failure: a device not yet added to the setup must be disposed
    /// with `MIDIDeviceDispose`, never `MIDISetupRemoveDevice` (CoreMIDI's
    /// own header is explicit about this - the latter is only valid once
    /// `MIDISetupAddDevice` has actually succeeded).
    static func attempt(onLog: (String) -> Void) -> AttemptResult {
        var device = MIDIDeviceRef()
        var status = MIDIDeviceCreate(nil, deviceName as CFString, manufacturer as CFString, model as CFString, &device)
        onLog("MainStage device registration: MIDIDeviceCreate -> \(status).")
        guard status == noErr, device != 0 else {
            onLog("MainStage device registration: stopped after MIDIDeviceCreate (paramErr is expected here on current macOS - see docs/mainstage-integration.md). Falling back to bare endpoints only.")
            return AttemptResult(device: MIDIDeviceRef(), succeeded: false, summary: "MIDIDeviceCreate failed (\(status))")
        }

        var entity = MIDIEntityRef()
        status = MIDIDeviceAddEntity(device, entityName as CFString, true, 1, 1, &entity)
        onLog("MainStage device registration: MIDIDeviceAddEntity -> \(status).")
        guard status == noErr, entity != 0 else {
            _ = MIDIDeviceDispose(device)
            return AttemptResult(device: MIDIDeviceRef(), succeeded: false, summary: "MIDIDeviceAddEntity failed (\(status))")
        }

        status = MIDISetupAddDevice(device)
        onLog("MainStage device registration: MIDISetupAddDevice -> \(status).")
        guard status == noErr else {
            _ = MIDIDeviceDispose(device)
            return AttemptResult(device: MIDIDeviceRef(), succeeded: false, summary: "MIDISetupAddDevice failed (\(status))")
        }

        let source = MIDIEntityGetSource(entity, 0)
        let destination = MIDIEntityGetDestination(entity, 0)
        onLog("MainStage device registration: device + entity published (source=\(source), destination=\(destination)).")
        return AttemptResult(device: device, succeeded: true, summary: "registered")
    }

    // MARK: - Teardown

    /// Explicit shutdown, mirroring `MainStageEndpoint.shutdown()`'s and
    /// `SLLinkTransport.shutdown()`'s discipline of tearing down CoreMIDI
    /// state explicitly on the app's own shutdown path rather than relying
    /// on process exit or `deinit` ordering.
    static func remove(_ device: MIDIDeviceRef, onLog: (String) -> Void) {
        guard device != 0 else { return }
        let status = MIDISetupRemoveDevice(device)
        onLog("MainStage device registration: MIDISetupRemoveDevice -> \(status).")
    }
}
