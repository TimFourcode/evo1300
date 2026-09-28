import CoreBluetooth
import SwiftUI

/// Settings: pairing, protocol tests and log. Presented from `ControlView`;
/// day-to-day control happens there or via Shortcuts / Action button.
struct ContentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager = MagicshineBLEManager.shared
    @State private var profile = LampSettings.profile
    @State private var highBeamMethod = LampSettings.highBeamMethod
    @State private var channelsSwapped = LampSettings.lowBeamChannel == 1
    @State private var pairedName = LampSettings.pairedName
    @State private var rawHex = "DE06A400A2ED"
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            Form {
                lampSection
                if pairedName == nil || manager.isPairingScan { scanSection }
                profileSection
                testSection
                beamSection
                rawSection
                logSection
            }
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .alert("Fehler", isPresented: .constant(lastError != nil)) {
                Button("OK") { lastError = nil }
            } message: {
                Text(lastError ?? "")
            }
        }
    }

    private var lampSection: some View {
        Section("Lampe") {
            LabeledContent("Bluetooth", value: manager.bluetoothState.label)
            if let pairedName {
                LabeledContent("Gekoppelt", value: pairedName)
                LabeledContent("Aktives Profil",
                               value: profile.resolved(forName: pairedName).label)
                if let battery = manager.battery { LabeledContent("Akku", value: "\(battery) %") }
                if let temperature = manager.temperature { LabeledContent("Temperatur", value: "\(temperature) °C") }
                Button("Neu suchen") { manager.startPairingScan() }
                Button("Kopplung entfernen", role: .destructive) {
                    manager.forgetLamp()
                    self.pairedName = nil
                }
            } else {
                Text("Lampe einschalten, Bluetooth an der Lampe aktivieren und unten auswählen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanSection: some View {
        Section {
            if manager.discoveredLamps.isEmpty {
                HStack {
                    ProgressView()
                    Text("Suche …").foregroundStyle(.secondary)
                }
            }
            ForEach(manager.discoveredLamps) { lamp in
                Button {
                    manager.pair(lamp)
                    pairedName = lamp.name
                } label: {
                    HStack {
                        Image(systemName: lamp.looksLikeMagicshine ? "lightbulb.fill" : "dot.radiowaves.left.and.right")
                        Text(lamp.name)
                        Spacer()
                        Text("\(lamp.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fontWeight(lamp.looksLikeMagicshine ? .semibold : .regular)
            }
        } header: {
            Text("Gefundene Geräte")
        } footer: {
            Text("Magicshine-Lampen melden sich meist als „M1-B0…“ oder „M2-B0…“.")
        }
        .onAppear { manager.startPairingScan() }
        .onDisappear { manager.stopPairingScan() }
    }

    private var profileSection: some View {
        Section {
            Picker("Protokoll", selection: $profile) {
                ForEach(LampProfile.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: profile) { _, newValue in LampSettings.profile = newValue }
        } header: {
            Text("Protokoll")
        } footer: {
            Text("Die EVO 1300 ist nicht in den Referenz-Mitschnitten enthalten. Reagiert die Lampe nicht, das andere Modul-Profil testen.")
        }
    }

    private var testSection: some View {
        Section("Test") {
            HStack {
                ForEach(LightLevel.allCases, id: \.self) { level in
                    Button(level.label) { run { try await manager.setLevel(level) } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.caption)
            Button("Umschalten (wie Kurzbefehl)") { run { try await manager.toggleLight() } }
            Button("Nächste Stufe") { run { try await manager.cycleLevel() } }
            Button("Akkustand abfragen") { run { _ = try await manager.readBattery() } }
        }
        .disabled(manager.isBusy)
    }

    private var beamSection: some View {
        Section {
            Picker("Methode", selection: $highBeamMethod) {
                ForEach(HighBeamMethod.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: highBeamMethod) { _, newValue in LampSettings.highBeamMethod = newValue }
            HStack {
                Button("Abblendlicht") { run { try await manager.setHighBeam(false) } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Fernlicht") { run { try await manager.setHighBeam(true) } }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            Toggle("Kanäle tauschen", isOn: $channelsSwapped)
                .onChange(of: channelsSwapped) { _, newValue in LampSettings.lowBeamChannel = newValue ? 1 : 0 }
            HStack {
                Button("Nur Kanal 0") { run { try await manager.testChannels(0x32, 0) } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Nur Kanal 1") { run { try await manager.testChannels(0, 0x32) } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            Button("Bluetooth-Dienste ins Log schreiben") { run { try await manager.inspectGATT() } }
        } header: {
            Text("Abblend- und Fernlicht")
        } footer: {
            Text("Die EVO 1300 hat zwei Lichtkanäle. Mit „Nur Kanal 0“ und „Nur Kanal 1“ prüfen, welcher Kanal das Abblendlicht ist. Normal: Kanal 0 = Abblendlicht, Kanal 1 = Fernlicht. Ist es umgekehrt, „Kanäle tauschen“ einschalten.")
        }
        .disabled(manager.isBusy)
    }

    private var rawSection: some View {
        Section {
            TextField("Hex", text: $rawHex)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Senden") { run { try await manager.sendCommand(hexString: rawHex) } }
                .disabled(manager.isBusy)
        } header: {
            Text("Roh-Befehl")
        } footer: {
            Text("Nur für Experimente. A4/A1 sind reine Abfragen, A2 ändert die Lichtausgabe.")
        }
    }

    private var logSection: some View {
        Section {
            ForEach(manager.log.reversed()) { entry in
                VStack(alignment: .leading) {
                    Text(entry.message).font(.caption.monospaced())
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Button("Leeren") { manager.clearLog() }.font(.caption)
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { lastError = error.localizedDescription }
        }
    }
}

private extension CBManagerState {
    var label: String {
        switch self {
        case .poweredOn: "An"
        case .poweredOff: "Aus"
        case .unauthorized: "Nicht erlaubt"
        case .unsupported: "Nicht unterstützt"
        case .resetting: "Wird zurückgesetzt"
        default: "Unbekannt"
        }
    }
}
