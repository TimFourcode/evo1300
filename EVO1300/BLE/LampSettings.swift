import Foundation

/// Persisted lamp configuration and the last known light state.
/// The lamp doesn't report its output reliably, so toggle relies on `isOn`.
enum LampSettings {
    private static var defaults: UserDefaults { .standard }

    static var pairedIdentifier: UUID? {
        get { defaults.string(forKey: "pairedIdentifier").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "pairedIdentifier") }
    }

    static var pairedName: String? {
        get { defaults.string(forKey: "pairedName") }
        set { defaults.set(newValue, forKey: "pairedName") }
    }

    static var profile: LampProfile {
        get { defaults.string(forKey: "profile").flatMap(LampProfile.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "profile") }
    }

    /// Whether A2 frames keep the save flag (0xBB) and overwrite the lamp's presets.
    /// Off by default: saving replaces the modes the lamp's own buttons cycle through.
    static var saveToLamp: Bool {
        get { defaults.object(forKey: "saveToLamp") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "saveToLamp") }
    }

    static var isOn: Bool {
        get { defaults.bool(forKey: "isOn") }
        set { defaults.set(newValue, forKey: "isOn") }
    }

    static var isHighBeam: Bool {
        get { defaults.bool(forKey: "isHighBeam") }
        set { defaults.set(newValue, forKey: "isHighBeam") }
    }

    static var highBeamMethod: HighBeamMethod {
        get { defaults.string(forKey: "highBeamMethod").flatMap(HighBeamMethod.init(rawValue:)) ?? .twoChannel }
        set { defaults.set(newValue.rawValue, forKey: "highBeamMethod") }
    }

    /// Channel of the two-channel frame that drives the low beam (0 or 1).
    /// Versioned key: swaps saved before the enable-flag fix were workarounds.
    static var lowBeamChannel: UInt8 {
        get { defaults.integer(forKey: "lowBeamChannel.v2") == 1 ? 1 : 0 }
        set { defaults.set(Int(newValue), forKey: "lowBeamChannel.v2") }
    }

    static var lastOnLevel: LightLevel {
        get {
            let level = defaults.string(forKey: "lastOnLevel").flatMap(LightLevel.init(rawValue:)) ?? .medium
            return level == .off ? .medium : level
        }
        set { defaults.set(newValue.rawValue, forKey: "lastOnLevel") }
    }
}
