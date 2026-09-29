import Foundation

/// Frame layout used by Magicshine lamps on the legacy FFE1/FFE0 GATT pair:
///
///     DE <len> <cmd> <payload…> <xor(len…payload)> ED
///
/// `len` is the total frame length. Verified byte sequences come from the
/// open-source Karoo extension `xrsprint/karoo-magicshine-controls`
/// (MagicshineProtocol.kt); the unit tests pin our builders to those captures.
enum MagicshineProtocol {
    static let start: UInt8 = 0xDE
    static let end: UInt8 = 0xED

    enum Command: UInt8 {
        /// Set output (brightness/mode).
        case output = 0xA2
        /// Read-only telemetry query (battery). Also serves as the keep-alive handshake.
        case telemetryBattery = 0xA4
        /// Read-only telemetry query (temperature).
        case telemetryTemperature = 0xA1
    }

    static func frame(_ command: Command, payload: [UInt8]) -> Data {
        let length = UInt8(payload.count + 5)
        let checksum = ([length, command.rawValue] + payload).reduce(0, ^)
        return Data([start, length, command.rawValue] + payload + [checksum, end])
    }

    /// Read-only queries, safe to send on every connect. The lamp answers via notify.
    /// Never send A2/A6 as a "handshake" – A2 changes the light output.
    static let telemetryRequests: [Data] = [
        frame(.telemetryBattery, payload: [0x00]),     // DE06A400A2ED
        frame(.telemetryTemperature, payload: [0x00]), // DE06A100A7ED
    ]

    // MARK: - Output frames

    /// `lowBeamChannel` only matters for `.evo1300` (0 or 1, see `channelFrame`).
    static func outputFrame(_ level: LightLevel, profile: LampProfile, lowBeamChannel: UInt8 = 0) -> Data {
        switch profile {
        case .evo1300:
            level == .off ? offFrame : channelFrame(lowBeam: module2Value(level), highBeam: 0,
                                                    lowBeamChannel: lowBeamChannel)
        case .module2: module2Frame(level)
        case .hori: horiFrame(level)
        case .module1, .auto: module1Frame(level)
        }
    }

    static func modeFrame(_ mode: LightMode, profile: LampProfile) -> Data {
        switch profile {
        case .module2, .evo1300:
            return module2Body(mode: mode.code, value: 0x64)
        case .module1, .hori, .auto:
            // Steady uses the captured 10 % value, SOS/Blitz run at full output.
            let value: UInt8 = mode == .steady ? 0x0A : 0x63
            return frame(.output, payload: [0x01, 0x01, 0x01, mode.code, value, 0x00, 0x01, 0x50,
                                            0, 0, 0, 0, 0, 0, 0xBB])
        }
    }

    /// Identical for every profile (captured for M1 and M2).
    static let offFrame = frame(.output, payload: [0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
                                                   0, 0, 0, 0, 0, 0, 0xBB])

    private static func module1Frame(_ level: LightLevel) -> Data {
        guard level != .off else { return offFrame }
        let value: UInt8 = switch level {
        case .low: 0x14
        case .medium: 0x3C
        case .high: 0x4B
        case .max, .off: 0x63
        }
        return frame(.output, payload: [0x01, 0x01, 0x01, 0x01, value, 0x00, 0x01, 0x50,
                                        0, 0, 0, 0, 0, 0, 0xBB])
    }

    private static func module2Frame(_ level: LightLevel) -> Data {
        guard level != .off else { return offFrame }
        return module2Body(mode: 0x01, value: module2Value(level))
    }

    private static func module2Value(_ level: LightLevel) -> UInt8 {
        switch level {
        case .off: 0x00
        case .low: 0x14
        case .medium: 0x32
        case .high: 0x4B
        case .max: 0x64
        }
    }

    /// Layout from the official app (via derstrassi/karoofirefly): `01 <preset>` followed
    /// by one `(enabled, mode, brightness)` triple per lamp group. The captured M2 presets
    /// disable group 0 and drive group 1 – on the EVO 1300 group 1 is the high beam and
    /// group 0 the low beam. A group with brightness 0 is sent disabled.
    static func channelFrame(lowBeam: UInt8, highBeam: UInt8, lowBeamChannel: UInt8 = 0) -> Data {
        let (channel0, channel1) = lowBeamChannel == 0 ? (lowBeam, highBeam) : (highBeam, lowBeam)
        func group(_ value: UInt8) -> [UInt8] { [value > 0 ? 0x01 : 0x00, 0x01, value] }
        return frame(.output, payload: [0x01, 0x02] + group(channel0) + group(channel1)
                                       + [0, 0, 0, 0, 0, 0, 0xBB])
    }

    private static func module2Body(mode: UInt8, value: UInt8) -> Data {
        frame(.output, payload: [0x01, 0x02, 0x00, 0x01, 0x0A, 0x01, mode, value,
                                 0, 0, 0, 0, 0, 0, 0xBB])
    }

    /// HORI 1300 layout (M1-B0 two-channel). `max` selects the high-beam model code.
    private static func horiFrame(_ level: LightLevel) -> Data {
        let (model, value): (UInt8, UInt8) = switch level {
        case .off: (0x01, 0x00)
        case .low: (0x01, 0x14)
        case .medium: (0x01, 0x3C)
        case .high: (0x01, 0x63)
        case .max: (0x02, 0x63)
        }
        return frame(.output, payload: [0x01, 0x01, 0x00, 0x00, 0x00, 0x01, model, value,
                                        0, 0, 0, 0, 0, 0, 0xBB])
    }

    /// The official app names the last content byte of A2 frames `FLAG_SAVE` (0xBB):
    /// with it the lamp stores the output in the preset slot, which is what the
    /// physical mode button cycles through. This returns the same frame with the
    /// flag cleared, so the lamp only applies it. Other frames are returned unchanged.
    static func transient(_ frame: Data) -> Data {
        var bytes = [UInt8](frame)
        guard bytes.count == 20, bytes[2] == Command.output.rawValue, bytes[17] == 0xBB else { return frame }
        bytes[17] = 0x00
        bytes[18] = bytes[1..<18].reduce(0, ^)
        return Data(bytes)
    }

    // MARK: - High beam

    /// Bluetooth Light Profile control point (HORI 1300): `00` claims control,
    /// `04 01` / `04 00` selects high / low beam.
    static let lightControlClaim = Data([0x00])

    static func lightControlBeam(high: Bool) -> Data {
        Data([0x04, high ? 0x01 : 0x00])
    }

    /// High-beam frame for the legacy characteristic; the low beam stays at `lowBeam`.
    /// Returns nil for methods that use the Light Profile control point instead.
    static func highBeamFrame(_ method: HighBeamMethod, lowBeam: LightLevel, lowBeamChannel: UInt8 = 0) -> Data? {
        switch method {
        case .twoChannel: channelFrame(lowBeam: module2Value(lowBeam), highBeam: 0x64, lowBeamChannel: lowBeamChannel)
        case .lightProfile: nil
        }
    }

    // MARK: - Telemetry parsing

    /// Battery frame: `DE 13 B4 …`, value at payload index 5.
    static func parseBattery(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 11, bytes[0] == start, bytes[1] == 0x13, bytes[2] == 0xB4 else { return nil }
        let value = Int(bytes[8])
        return (0...100).contains(value) ? value : nil
    }

    /// Temperature frame: `DE 0D B1 …`, value follows the marker `17 03`.
    static func parseTemperature(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] == start, bytes[1] == 0x0D, bytes[2] == 0xB1 else { return nil }
        for i in 3..<(bytes.count - 2) where bytes[i] == 0x17 && bytes[i + 1] == 0x03 {
            let value = Int(bytes[i + 2])
            return (0...120).contains(value) ? value : nil
        }
        return nil
    }
}

// MARK: - Model types

enum LightLevel: String, CaseIterable, Codable, Sendable {
    case off, low, medium, high, max

    var label: String {
        switch self {
        case .off: "Aus"
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        case .max: "Max"
        }
    }

    /// Next level when emulating the physical mode button (skips "off").
    var next: LightLevel {
        switch self {
        case .off, .max: .low
        case .low: .medium
        case .medium: .high
        case .high: .max
        }
    }
}

enum LightMode: String, CaseIterable, Sendable {
    case steady, sos, blitz

    var code: UInt8 {
        switch self {
        case .steady: 0x01
        case .sos: 0x02
        case .blitz: 0x03
        }
    }
}

/// How the high beam is switched. `twoChannel` drives lamp group 1 of the M2
/// frame, `lightProfile` is the HORI 1300 control point. (The HORI legacy frame
/// is not offered: on M2 lamps its mode byte 02 means SOS.)
enum HighBeamMethod: String, CaseIterable, Codable, Sendable {
    case twoChannel, lightProfile

    var label: String {
        switch self {
        case .twoChannel: "Zwei Kanäle (EVO 1300)"
        case .lightProfile: "Light Profile (8CE5DD03)"
        }
    }
}

/// Which captured frame family the lamp understands. The EVO 1300 is not in the
/// reference captures – try `module2` (EVO 1700) first, then `module1`.
enum LampProfile: String, CaseIterable, Codable, Sendable {
    case auto, evo1300, module1, module2, hori

    var label: String {
        switch self {
        case .auto: "Automatisch (nach Name)"
        case .evo1300: "EVO 1300 (Abblend-/Fernlicht getrennt)"
        case .module1: "Modul 1 (M1-B0)"
        case .module2: "Modul 2 (M2-B0 / EVO 1700)"
        case .hori: "HORI 1300"
        }
    }

    func resolved(forName name: String?) -> LampProfile {
        guard self == .auto else { return self }
        let normalized = (name ?? "").uppercased()
        if normalized.filter { $0.isLetter || $0.isNumber }.contains("EVO1300") { return .evo1300 }
        if normalized.hasPrefix("M1-") { return .module1 }
        return .module2
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }

    init?(hexString: String) {
        let clean = hexString.filter(\.isHexDigit)
        guard !clean.isEmpty, clean.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
