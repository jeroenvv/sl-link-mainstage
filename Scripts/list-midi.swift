import CoreMIDI
import Foundation

func str(_ obj: MIDIObjectRef, _ prop: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(obj, prop, &out) == noErr, let out else { return "—" }
    return out.takeRetainedValue() as String
}

func describe(_ endpoint: MIDIEndpointRef, _ label: String, _ index: Int) {
    var entity = MIDIEntityRef()
    MIDIEndpointGetEntity(endpoint, &entity)
    var device = MIDIDeviceRef()
    if entity != 0 { MIDIEntityGetDevice(entity, &device) }

    let name = str(endpoint, kMIDIPropertyName)
    let display = str(endpoint, kMIDIPropertyDisplayName)

    // What the current code does: trimmed, case-insensitive equality with "LINK"
    let equalsLINK = name.trimmingCharacters(in: .whitespacesAndNewlines)
        .compare("LINK", options: .caseInsensitive) == .orderedSame
    // What the plan proposes: case-insensitive contains on the display name
    let containsLINK = display.range(of: "LINK", options: .caseInsensitive) != nil
        || name.range(of: "LINK", options: .caseInsensitive) != nil

    print("\(label) [\(index)]")
    print("    name         : \(name)")
    print("    displayName  : \(display)")
    print("    manufacturer : \(str(endpoint, kMIDIPropertyManufacturer))")
    print("    model        : \(str(endpoint, kMIDIPropertyModel))")
    if device != 0 { print("    device       : \(str(device, kMIDIPropertyName))") }
    if entity != 0 { print("    entity       : \(str(entity, kMIDIPropertyName))") }
    print("    == \"LINK\"    : \(equalsLINK ? "YES" : "no")   (current code path)")
    print("    contains LINK: \(containsLINK ? "YES" : "no")   (planned code path)")
    print("")
}

print("CoreMIDI endpoints\n" + String(repeating: "=", count: 60) + "\n")

let sources = MIDIGetNumberOfSources()
print("SOURCES: \(sources)\n")
for i in 0..<sources { describe(MIDIGetSource(i), "SOURCE", i) }

let dests = MIDIGetNumberOfDestinations()
print("DESTINATIONS: \(dests)\n")
for i in 0..<dests { describe(MIDIGetDestination(i), "DEST", i) }
