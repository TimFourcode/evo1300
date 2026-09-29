import Foundation
import Testing
@testable import EVO1300

/// Expected strings are captured frames from karoo-magicshine-controls (MagicshineProtocol.kt).
struct MagicshineProtocolTests {
    @Test func telemetryRequests() {
        #expect(MagicshineProtocol.telemetryRequests.map(\.hexString) == ["DE06A400A2ED", "DE06A100A7ED"])
    }

    @Test func offFrame() {
        #expect(MagicshineProtocol.offFrame.hexString == "DE14A20101010100000000000000000000BB0DED")
    }

    @Test func module1Levels() {
        #expect(MagicshineProtocol.outputFrame(.low, profile: .module1).hexString
                == "DE14A20101010114000150000000000000BB48ED")
        #expect(MagicshineProtocol.outputFrame(.medium, profile: .module1).hexString
                == "DE14A2010101013C000150000000000000BB60ED")
        #expect(MagicshineProtocol.outputFrame(.max, profile: .module1).hexString
                == "DE14A20101010163000150000000000000BB3FED")
    }

    @Test func module1Modes() {
        #expect(MagicshineProtocol.modeFrame(.steady, profile: .module1).hexString
                == "DE14A2010101010A000150000000000000BB56ED")
        #expect(MagicshineProtocol.modeFrame(.sos, profile: .module1).hexString
                == "DE14A20101010263000150000000000000BB3CED")
        #expect(MagicshineProtocol.modeFrame(.blitz, profile: .module1).hexString
                == "DE14A20101010363000150000000000000BB3DED")
    }

    @Test func module2Levels() {
        #expect(MagicshineProtocol.outputFrame(.low, profile: .module2).hexString
                == "DE14A2010200010A010114000000000000BB11ED")
        #expect(MagicshineProtocol.outputFrame(.medium, profile: .module2).hexString
                == "DE14A2010200010A010132000000000000BB37ED")
        #expect(MagicshineProtocol.outputFrame(.max, profile: .module2).hexString
                == "DE14A2010200010A010164000000000000BB61ED")
    }

    @Test func horiChecksum() {
        // Hori frames were generated (not captured) upstream – verify framing only.
        let bytes = [UInt8](MagicshineProtocol.outputFrame(.low, profile: .hori))
        #expect(bytes.count == 20 && bytes.first == 0xDE && bytes.last == 0xED)
        #expect(bytes[1..<18].reduce(0, ^) == bytes[18])
    }

    @Test func lightProfileCommands() {
        #expect(MagicshineProtocol.lightControlClaim.hexString == "00")
        #expect(MagicshineProtocol.lightControlBeam(high: true).hexString == "0401")
        #expect(MagicshineProtocol.lightControlBeam(high: false).hexString == "0400")
        #expect(MagicshineProtocol.highBeamFrame(.lightProfile, lowBeam: .medium) == nil)
    }

    @Test func channelFrameLayout() {
        // Captured M2 preset: group 0 disabled (00 01 0A), group 1 enabled at 50 %.
        #expect(MagicshineProtocol.outputFrame(.medium, profile: .module2).hexString
                == "DE14A2010200010A010132000000000000BB37ED")
        // Same layout with group 0 enabled for the low beam and group 1 disabled.
        #expect(MagicshineProtocol.channelFrame(lowBeam: 0x32, highBeam: 0).hexString
                == "DE14A20102010132000100000000000000BB3DED")
        #expect(MagicshineProtocol.channelFrame(lowBeam: 0x32, highBeam: 0x64).hexString
                == "DE14A20102010132010164000000000000BB58ED")
    }

    @Test func evo1300Beams() {
        #expect(MagicshineProtocol.outputFrame(.medium, profile: .evo1300)
                == MagicshineProtocol.channelFrame(lowBeam: 0x32, highBeam: 0))
        #expect(MagicshineProtocol.outputFrame(.medium, profile: .evo1300, lowBeamChannel: 1)
                == MagicshineProtocol.channelFrame(lowBeam: 0, highBeam: 0x32))
        #expect(MagicshineProtocol.outputFrame(.off, profile: .evo1300) == MagicshineProtocol.offFrame)
        #expect(MagicshineProtocol.highBeamFrame(.twoChannel, lowBeam: .medium)
                == MagicshineProtocol.channelFrame(lowBeam: 0x32, highBeam: 0x64))
    }

    @Test func highBeamFrames() {
        for method in HighBeamMethod.allCases where method != .lightProfile {
            let bytes = [UInt8](MagicshineProtocol.highBeamFrame(method, lowBeam: .medium)!)
            #expect(bytes.count == 20 && bytes.first == 0xDE && bytes.last == 0xED)
            #expect(bytes[1..<18].reduce(0, ^) == bytes[18])
        }
    }

    @Test func transientClearsSaveFlag() {
        let saved = MagicshineProtocol.outputFrame(.medium, profile: .evo1300)
        let bytes = [UInt8](MagicshineProtocol.transient(saved))
        #expect(bytes.count == 20 && bytes[17] == 0x00 && bytes.last == 0xED)
        #expect(bytes[1..<18].reduce(0, ^) == bytes[18])
        #expect(Array(bytes[0..<17]) == Array([UInt8](saved)[0..<17]))
        // Queries are left alone.
        #expect(MagicshineProtocol.transient(MagicshineProtocol.telemetryRequests[0])
                == MagicshineProtocol.telemetryRequests[0])
    }

    @Test func parseBattery() {
        let frame = Data([0xDE, 0x13, 0xB4, 0, 0, 0, 0, 0, 0x32, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0xED])
        #expect(MagicshineProtocol.parseBattery(frame) == 50)
        #expect(MagicshineProtocol.parseBattery(Data(hexString: "DE06A400A2ED")!) == nil)
    }

    @Test func autoProfile() {
        #expect(LampProfile.auto.resolved(forName: "M1-B0 1234") == .module1)
        #expect(LampProfile.auto.resolved(forName: "M2-B0 1234") == .module2)
        #expect(LampProfile.auto.resolved(forName: "M2-B0 EVO1300") == .evo1300)
        #expect(LampProfile.auto.resolved(forName: "M2-B0 EVO_1300") == .evo1300)
        #expect(LampProfile.auto.resolved(forName: nil) == .module2)
        #expect(LampProfile.module1.resolved(forName: "M2-B0") == .module1)
    }

    @Test func hexParsing() {
        #expect(Data(hexString: "de 06 a4")?.hexString == "DE06A4")
        #expect(Data(hexString: "ABC") == nil)
    }
}
