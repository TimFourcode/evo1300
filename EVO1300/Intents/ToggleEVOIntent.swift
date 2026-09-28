import AppIntents

// All intents run in the app process without opening the UI (`openAppWhenRun = false`),
// so komoot stays in the foreground. BLE failures are returned as a status string
// instead of being thrown: a thrown error would stop the shortcut and skip a
// following "App öffnen: komoot" action.

struct ToggleEVOIntent: AppIntent {
    static let title: LocalizedStringResource = "EVO 1300 umschalten"
    static let description = IntentDescription(
        "Sendet einen Bluetooth-Befehl an die Magicshine EVO 1300, um das Licht ein- oder auszuschalten."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let status = await runLampCommand {
            let level = try await MagicshineBLEManager.shared.toggleLight()
            return level.label
        }
        return .result(value: status)
    }
}

struct CycleEVOLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "EVO 1300 nächste Stufe"
    static let description = IntentDescription(
        "Schaltet wie die Modustaste zur nächsten Helligkeitsstufe (Niedrig → Mittel → Hoch → Max)."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let status = await runLampCommand {
            try await MagicshineBLEManager.shared.cycleLevel().label
        }
        return .result(value: status)
    }
}

struct SetEVOLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "EVO 1300 Helligkeit setzen"
    static let description = IntentDescription("Setzt die EVO 1300 direkt auf eine Helligkeitsstufe.")
    static let openAppWhenRun = false

    @Parameter(title: "Stufe", default: .medium)
    var level: LightLevel

    static var parameterSummary: some ParameterSummary {
        Summary("EVO 1300 auf \(\.$level) setzen")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let level = level
        let status = await runLampCommand {
            try await MagicshineBLEManager.shared.setLevel(level)
            return level.label
        }
        return .result(value: status)
    }
}

struct ToggleEVOHighBeamIntent: AppIntent {
    static let title: LocalizedStringResource = "EVO 1300 Fernlicht umschalten"
    static let description = IntentDescription(
        "Wechselt zwischen Abblendlicht (zuletzt genutzte Stufe) und Fernlicht. Schaltet die Lampe bei Bedarf ein."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let status = await runLampCommand {
            try await MagicshineBLEManager.shared.toggleHighBeam() ? "Fernlicht" : "Abblendlicht"
        }
        return .result(value: status)
    }
}

struct SetEVOHighBeamIntent: AppIntent {
    static let title: LocalizedStringResource = "EVO 1300 Fernlicht setzen"
    static let description = IntentDescription("Schaltet die EVO 1300 gezielt auf Fernlicht oder Abblendlicht.")
    static let openAppWhenRun = false

    @Parameter(title: "Fernlicht", default: true)
    var highBeam: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("EVO 1300 Fernlicht \(\.$highBeam)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let highBeam = highBeam
        let status = await runLampCommand {
            try await MagicshineBLEManager.shared.setHighBeam(highBeam)
            return highBeam ? "Fernlicht" : "Abblendlicht"
        }
        return .result(value: status)
    }
}

struct EVOBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "EVO 1300 Akkustand"
    static let description = IntentDescription(
        "Fragt den Akkustand der EVO 1300 ab. Manche Modelle melden nur 100/50/30 (Hoch/Mittel/Niedrig)."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        do {
            if let battery = try await MagicshineBLEManager.shared.readBattery() {
                return .result(value: battery, dialog: "EVO 1300: \(battery) %")
            }
            return .result(value: -1, dialog: "Die Lampe hat keinen Akkustand gemeldet.")
        } catch {
            return .result(value: -1, dialog: "\(error.localizedDescription)")
        }
    }
}

@MainActor
private func runLampCommand(_ command: @MainActor () async throws -> String) async -> String {
    do {
        return try await command()
    } catch {
        return "Fehler: \(error.localizedDescription)"
    }
}

extension LightLevel: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Helligkeit"
    static let caseDisplayRepresentations: [LightLevel: DisplayRepresentation] = [
        .off: "Aus",
        .low: "Niedrig",
        .medium: "Mittel",
        .high: "Hoch",
        .max: "Max",
    ]
}

struct EVOShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleEVOIntent(),
            phrases: ["Licht umschalten mit \(.applicationName)", "\(.applicationName) umschalten"],
            shortTitle: "Licht umschalten",
            systemImageName: "flashlight.on.fill"
        )
        AppShortcut(
            intent: CycleEVOLevelIntent(),
            phrases: ["Nächste Lichtstufe mit \(.applicationName)"],
            shortTitle: "Nächste Stufe",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: SetEVOLevelIntent(),
            phrases: ["Helligkeit setzen mit \(.applicationName)"],
            shortTitle: "Helligkeit setzen",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: ToggleEVOHighBeamIntent(),
            phrases: ["Fernlicht umschalten mit \(.applicationName)"],
            shortTitle: "Fernlicht",
            systemImageName: "headlight.high.beam.fill"
        )
        AppShortcut(
            intent: EVOBatteryIntent(),
            phrases: ["Akkustand mit \(.applicationName)"],
            shortTitle: "Akkustand",
            systemImageName: "battery.75percent"
        )
    }
}
