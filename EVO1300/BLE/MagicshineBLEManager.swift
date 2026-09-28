import CoreBluetooth
import Observation
import OSLog
import UIKit

/// Central BLE controller. Every public command runs one short session:
/// power-on check → locate → connect (3 s budget) → discover → subscribe →
/// telemetry handshake → write → disconnect.
@MainActor
@Observable
final class MagicshineBLEManager: NSObject {
    static let shared = MagicshineBLEManager()

    /// Verified layout is service FFE1 / characteristic FFE0; the reverse
    /// (classic HM-10 FFE0/FFE1) is accepted as fallback.
    static let serviceUUIDs = [CBUUID(string: "FFE1"), CBUUID(string: "FFE0")]
    static let characteristicUUIDs = [CBUUID(string: "FFE0"), CBUUID(string: "FFE1")]
    /// Bluetooth Light Profile (HORI 1300), used for the high beam.
    static let lightProfileService = CBUUID(string: "ADB425D4-B1C6-11ED-AFA1-0242AC120002")
    static let lightControlCharacteristic = CBUUID(string: "8CE5DD03-0A4D-11E9-AB14-D663BD873D93")
    static let namePrefixes = ["M1-B", "M2-B", "M1-BO", "M2-BO", "EVO", "MJ-", "MAGICSHINE"]

    var connectTimeout: Duration = .seconds(3)
    var transferTimeout: Duration = .seconds(3)

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var discoveredLamps: [DiscoveredLamp] = []
    private(set) var isPairingScan = false
    private(set) var isBusy = false
    private(set) var battery: Int?
    private(set) var temperature: Int?
    private(set) var log: [LogEntry] = []
    /// Last time the paired lamp advertised or completed a session.
    private(set) var lampLastSeen: Date?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var activePeripheral: CBPeripheral?
    @ObservationIgnored private var activeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var activeLightControl: CBCharacteristic?
    @ObservationIgnored private var sessionScan = false
    @ObservationIgnored private var isMonitoring = false

    @ObservationIgnored private var poweredOnWaiter: Waiter?
    @ObservationIgnored private var discoverWaiter: Waiter?
    @ObservationIgnored private var connectWaiter: Waiter?
    @ObservationIgnored private var servicesWaiter: Waiter?
    @ObservationIgnored private var characteristicsWaiter: Waiter?
    @ObservationIgnored private var notifyWaiter: Waiter?
    @ObservationIgnored private var writeWaiter: Waiter?

    private static let logger = Logger(subsystem: "de.fourcode.evo1300", category: "BLE")

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Toggles between off and the last used level. Returns the new level.
    @discardableResult
    func toggleLight() async throws -> LightLevel {
        let target: LightLevel = LampSettings.isOn ? .off : LampSettings.lastOnLevel
        try await setLevel(target)
        return target
    }

    /// Emulates the physical mode button: low → medium → high → max → low.
    @discardableResult
    func cycleLevel() async throws -> LightLevel {
        let target = LampSettings.isOn ? LampSettings.lastOnLevel.next : LampSettings.lastOnLevel
        try await setLevel(target)
        return target
    }

    func setLevel(_ level: LightLevel) async throws {
        let frame = MagicshineProtocol.outputFrame(level, profile: resolvedProfile,
                                                   lowBeamChannel: LampSettings.lowBeamChannel)
        // A level always means low beam; the Light Profile keeps its beam state separately.
        let leaveHighBeam = LampSettings.isHighBeam && LampSettings.highBeamMethod == .lightProfile && level != .off
        try await runSession(frames: [frame],
                             controlWrites: leaveHighBeam ? Self.beamWrites(high: false) : [])
        LampSettings.isOn = level != .off
        LampSettings.isHighBeam = false
        if level != .off { LampSettings.lastOnLevel = level }
    }

    /// Toggles between low beam (last used level) and high beam. Returns true for high beam.
    @discardableResult
    func toggleHighBeam() async throws -> Bool {
        let target = !(LampSettings.isOn && LampSettings.isHighBeam)
        try await setHighBeam(target)
        return target
    }

    /// Switches the beam and turns the lamp on if needed. Low beam restores the last used level.
    func setHighBeam(_ high: Bool) async throws {
        let method = LampSettings.highBeamMethod
        let level = LampSettings.lastOnLevel
        let channel = LampSettings.lowBeamChannel
        let lowBeam = MagicshineProtocol.outputFrame(level, profile: resolvedProfile, lowBeamChannel: channel)
        if let frame = MagicshineProtocol.highBeamFrame(method, lowBeam: level, lowBeamChannel: channel) {
            try await runSession(frames: [high ? frame : lowBeam])
        } else {
            try await runSession(frames: [lowBeam], controlWrites: Self.beamWrites(high: high))
        }
        LampSettings.isOn = true
        LampSettings.isHighBeam = high
    }

    private var resolvedProfile: LampProfile {
        LampSettings.profile.resolved(forName: LampSettings.pairedName)
    }

    private static func beamWrites(high: Bool) -> [Data] {
        [MagicshineProtocol.lightControlClaim, MagicshineProtocol.lightControlBeam(high: high)]
    }

    func setMode(_ mode: LightMode) async throws {
        try await runSession(frames: [MagicshineProtocol.modeFrame(mode, profile: resolvedProfile)])
        LampSettings.isOn = true
    }

    /// Drives both channels of the two-channel frame directly, to find out which is which.
    func testChannels(_ channel0: UInt8, _ channel1: UInt8) async throws {
        try await runSession(frames: [MagicshineProtocol.channelFrame(lowBeam: channel0, highBeam: channel1)])
        LampSettings.isOn = channel0 > 0 || channel1 > 0
    }

    /// Sends raw bytes, e.g. "DE06A400A2ED". Used for protocol experiments.
    func sendCommand(hexString: String) async throws {
        guard let data = Data(hexString: hexString) else { throw EVOError.invalidHex }
        try await runSession(frames: [data])
    }

    /// Connects, sends only the read-only telemetry queries and returns the battery value.
    func readBattery() async throws -> Int? {
        battery = nil
        try await runSession(frames: [], waitForTelemetry: true)
        return battery
    }

    /// Logs every service and characteristic of the lamp, for protocol research.
    func inspectGATT() async throws {
        try await session(transferTimeout: .seconds(8), settle: .zero) {
            try await self.logGATT()
        }
    }

    // MARK: - Presence (foreground)

    /// While the main screen is visible, listen for the paired lamp's advertisements
    /// to show whether it is reachable. Scanning never connects to the lamp.
    func startPresenceMonitor() {
        ensureCentral()
        isMonitoring = true
        refreshScan()
    }

    func stopPresenceMonitor() {
        isMonitoring = false
        refreshScan()
    }

    /// The lamp advertises about once a second while it is powered and not connected.
    func isLampReachable(at date: Date) -> Bool {
        guard let lampLastSeen else { return false }
        return date.timeIntervalSince(lampLastSeen) < 6
    }

    // MARK: - Pairing (foreground)

    func startPairingScan() {
        ensureCentral()
        discoveredLamps.removeAll()
        isPairingScan = true
        if central.state == .poweredOn { append("Suche nach Lampen …") }
        refreshScan()
    }

    func stopPairingScan() {
        guard isPairingScan else { return }
        isPairingScan = false
        refreshScan()
    }

    /// Pairing, presence and session lookups share one scan: CoreBluetooth keeps only
    /// the latest scan parameters, so every flag change goes through here.
    private func refreshScan() {
        guard let central, central.state == .poweredOn else { return }
        guard sessionScan || isPairingScan || isMonitoring else {
            central.stopScan()
            return
        }
        // iOS only allows filtered scans in the background, and the lamp may not
        // advertise its service UUID – pair once in the app for reliability.
        let inBackground = UIApplication.shared.applicationState == .background
        central.scanForPeripherals(withServices: inBackground ? Self.serviceUUIDs : nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: isMonitoring])
    }

    func pair(_ lamp: DiscoveredLamp) {
        LampSettings.pairedIdentifier = lamp.id
        LampSettings.pairedName = lamp.name
        stopPairingScan()
        append("Gekoppelt: \(lamp.name)")
    }

    func forgetLamp() {
        LampSettings.pairedIdentifier = nil
        LampSettings.pairedName = nil
    }

    func clearLog() { log.removeAll() }

    // MARK: - Session

    private func runSession(frames: [Data], controlWrites: [Data] = [],
                            waitForTelemetry: Bool = false) async throws {
        // Let the lamp process the last frame before the link drops.
        try await session(transferTimeout: transferTimeout,
                          settle: waitForTelemetry ? .milliseconds(500) : .milliseconds(100)) {
            try await self.discoverAndWrite(frames, controlWrites: controlWrites)
        }
    }

    private func session(transferTimeout: Duration, settle: Duration,
                         _ body: @escaping @Sendable @MainActor () async throws -> Void) async throws {
        // Serialize: intents may fire back-to-back from the Action button.
        while isBusy { try await Task.sleep(for: .milliseconds(50)) }
        isBusy = true
        defer { isBusy = false }

        let wasPairing = isPairingScan
        stopPairingScan()
        defer { if wasPairing { startPairingScan() } }

        do {
            try await withTimeout(connectTimeout, stage: "Suchen/Verbinden") {
                try await self.locateAndConnect()
            }
            try await withTimeout(transferTimeout, stage: "Übertragung", body)
            try? await Task.sleep(for: settle)
            teardown()
            lampLastSeen = Date()
        } catch {
            append("Fehler: \(error.localizedDescription)")
            teardown()
            lampLastSeen = nil
            throw error
        }
    }

    private func locateAndConnect() async throws {
        ensureCentral()
        if central.state != .poweredOn {
            if let error = EVOError(state: central.state) { throw error }
            let waiter = Waiter()
            poweredOnWaiter = waiter
            try await waiter.wait()
        }

        let peripheral = try await locatePeripheral()
        activePeripheral = peripheral
        peripheral.delegate = self

        if peripheral.state != .connected {
            append("Verbinde mit \(peripheral.name ?? "Lampe") …")
            let waiter = Waiter()
            connectWaiter = waiter
            central.connect(peripheral)
            try await waiter.wait()
        }
        append("Verbunden")
    }

    private func locatePeripheral() async throws -> CBPeripheral {
        // 1. Known lamp: works in the background without scanning.
        if let id = LampSettings.pairedIdentifier,
           let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            return peripheral
        }
        // 2. Already connected by the system (rare, but free).
        if let peripheral = central.retrieveConnectedPeripherals(withServices: Self.serviceUUIDs)
            .first(where: { Self.isLampName($0.name) }) {
            return peripheral
        }
        // 3. Scan (see `refreshScan` for the background limitation).
        let inBackground = UIApplication.shared.applicationState == .background
        append(inBackground ? "Suche (Hintergrund, gefiltert) …" : "Suche …")
        let waiter = Waiter()
        discoverWaiter = waiter
        sessionScan = true
        refreshScan()
        defer {
            sessionScan = false
            refreshScan()
        }
        try await waiter.wait()
        guard let peripheral = activePeripheral else { throw EVOError.notFound }
        return peripheral
    }

    private func discoverAndWrite(_ frames: [Data], controlWrites: [Data]) async throws {
        guard let peripheral = activePeripheral else { throw EVOError.notFound }

        let characteristic: CBCharacteristic
        if let cached = activeCharacteristic, cached.service?.peripheral === peripheral {
            characteristic = cached
        } else {
            characteristic = try await discoverCharacteristic(on: peripheral)
            activeCharacteristic = characteristic
        }

        if characteristic.properties.contains(.notify) && !characteristic.isNotifying {
            let waiter = Waiter()
            notifyWaiter = waiter
            peripheral.setNotifyValue(true, for: characteristic)
            // Telemetry is optional – don't fail the command if notify is refused.
            try? await waiter.wait()
        }

        // Handshake: read-only A4/A1 queries keep the lamp from dropping the link
        // and deliver battery/temperature via notify.
        for frame in MagicshineProtocol.telemetryRequests + frames {
            try await write(frame, to: characteristic, on: peripheral)
            try await Task.sleep(for: .milliseconds(60))
        }

        guard !controlWrites.isEmpty else { return }
        let control = try await lightControl(on: peripheral)
        for command in controlWrites {
            try await write(command, to: control, on: peripheral)
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    private func lightControl(on peripheral: CBPeripheral) async throws -> CBCharacteristic {
        if let cached = activeLightControl, cached.service?.peripheral === peripheral { return cached }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.lightProfileService }) else {
            throw EVOError.lightProfileMissing
        }
        let waiter = Waiter()
        characteristicsWaiter = waiter
        peripheral.discoverCharacteristics([Self.lightControlCharacteristic], for: service)
        try await waiter.wait()
        guard let control = service.characteristics?.first(where: { $0.uuid == Self.lightControlCharacteristic }) else {
            throw EVOError.lightProfileMissing
        }
        activeLightControl = control
        return control
    }

    private func logGATT() async throws {
        guard let peripheral = activePeripheral else { throw EVOError.notFound }
        let servicesWaiter = Waiter()
        self.servicesWaiter = servicesWaiter
        peripheral.discoverServices(nil)
        try await servicesWaiter.wait()

        for service in peripheral.services ?? [] {
            let waiter = Waiter()
            characteristicsWaiter = waiter
            peripheral.discoverCharacteristics(nil, for: service)
            try await waiter.wait()
            append("Service \(service.uuid.uuidString)")
            for characteristic in service.characteristics ?? [] {
                append("  Char \(characteristic.uuid.uuidString) \(characteristic.properties.debugDescription)")
            }
        }
    }

    private func discoverCharacteristic(on peripheral: CBPeripheral) async throws -> CBCharacteristic {
        let servicesWaiter = Waiter()
        self.servicesWaiter = servicesWaiter
        peripheral.discoverServices(Self.serviceUUIDs + [Self.lightProfileService])
        try await servicesWaiter.wait()

        // Verified layout first (service FFE1).
        let all = (peripheral.services ?? []).filter { Self.serviceUUIDs.contains($0.uuid) }
        let services = all.filter { $0.uuid == Self.serviceUUIDs[0] } + all.filter { $0.uuid != Self.serviceUUIDs[0] }
        for service in services {
            let waiter = Waiter()
            characteristicsWaiter = waiter
            peripheral.discoverCharacteristics(Self.characteristicUUIDs, for: service)
            try await waiter.wait()

            let writable = (service.characteristics ?? []).filter {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
            if let match = writable.first(where: { $0.uuid == Self.characteristicUUIDs[0] }) ?? writable.first {
                append("Characteristic \(service.uuid.uuidString)/\(match.uuid.uuidString) \(match.properties.debugDescription)")
                return match
            }
        }
        throw EVOError.characteristicMissing
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) async throws {
        // The reference implementation uses write-with-response; fall back if unsupported.
        if characteristic.properties.contains(.write) {
            let waiter = Waiter()
            writeWaiter = waiter
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            try await waiter.wait()
        } else {
            while !peripheral.canSendWriteWithoutResponse {
                try await Task.sleep(for: .milliseconds(10))
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
        append("TX \(data.hexString)")
    }

    private func teardown() {
        if sessionScan {
            sessionScan = false
            refreshScan()
        }
        if let peripheral = activePeripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        activePeripheral = nil
        activeCharacteristic = nil
        activeLightControl = nil
        failAllWaiters(EVOError.disconnected)
    }

    private func failAllWaiters(_ error: Error) {
        for waiter in [poweredOnWaiter, discoverWaiter, connectWaiter, servicesWaiter,
                       characteristicsWaiter, notifyWaiter, writeWaiter] {
            waiter?.fail(error)
        }
        poweredOnWaiter = nil
        discoverWaiter = nil
        connectWaiter = nil
        servicesWaiter = nil
        characteristicsWaiter = nil
        notifyWaiter = nil
        writeWaiter = nil
    }

    // MARK: - Helpers

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    static func isLampName(_ name: String?) -> Bool {
        guard let name = name?.replacingOccurrences(of: "\u{0}", with: "").uppercased() else { return false }
        return namePrefixes.contains { name.hasPrefix($0) }
    }

    private func append(_ message: String) {
        Self.logger.debug("\(message, privacy: .public)")
        log.append(LogEntry(message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func withTimeout(_ duration: Duration, stage: String,
                             _ operation: @escaping @Sendable @MainActor () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw EVOError.timeout(stage)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MagicshineBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            bluetoothState = state
            if state == .poweredOn {
                poweredOnWaiter?.succeed()
                refreshScan()
            } else if let error = EVOError(state: state) {
                poweredOnWaiter?.fail(error)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        // Delegate queue is main, so the peripheral never actually crosses isolation.
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            let name = advertisedName ?? peripheral.name
            // Duplicates arrive several times a second while monitoring; one update per second is enough.
            if peripheral.identifier == LampSettings.pairedIdentifier,
               lampLastSeen.map({ Date().timeIntervalSince($0) > 1 }) ?? true {
                lampLastSeen = Date()
            }
            if sessionScan, Self.isLampName(name) || peripheral.identifier == LampSettings.pairedIdentifier {
                activePeripheral = peripheral
                discoverWaiter?.succeed()
                discoverWaiter = nil
            }
            if isPairingScan, let name, !name.isEmpty {
                let lamp = DiscoveredLamp(id: peripheral.identifier, name: name, rssi: rssi,
                                          looksLikeMagicshine: Self.isLampName(name))
                if let index = discoveredLamps.firstIndex(where: { $0.id == lamp.id }) {
                    discoveredLamps[index] = lamp
                } else {
                    discoveredLamps.append(lamp)
                }
                discoveredLamps.sort { ($0.looksLikeMagicshine ? 1 : 0, $0.rssi) > ($1.looksLikeMagicshine ? 1 : 0, $1.rssi) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectWaiter?.succeed()
            connectWaiter = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            connectWaiter?.fail(EVOError.connectFailed(message))
            connectWaiter = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard activePeripheral?.identifier == id else { return }
            append("Verbindung getrennt")
            activeCharacteristic = nil
            activeLightControl = nil
            failAllWaiters(EVOError.disconnected)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension MagicshineBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message { servicesWaiter?.fail(EVOError.connectFailed(message)) } else { servicesWaiter?.succeed() }
            servicesWaiter = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                characteristicsWaiter?.fail(EVOError.connectFailed(message))
            } else {
                characteristicsWaiter?.succeed()
            }
            characteristicsWaiter = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                append("Notify nicht verfügbar: \(message)")
                notifyWaiter?.fail(EVOError.connectFailed(message))
            } else {
                notifyWaiter?.succeed()
            }
            notifyWaiter = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message { writeWaiter?.fail(EVOError.writeFailed(message)) } else { writeWaiter?.succeed() }
            writeWaiter = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated {
            append("RX \(data.hexString)")
            if let value = MagicshineProtocol.parseBattery(data) { battery = value }
            if let value = MagicshineProtocol.parseTemperature(data) { temperature = value }
        }
    }
}

// MARK: - Supporting types

struct DiscoveredLamp: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let looksLikeMagicshine: Bool
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

enum EVOError: LocalizedError {
    case bluetoothOff, unauthorized, unsupported, notFound, characteristicMissing, lightProfileMissing
    case disconnected, invalidHex
    case connectFailed(String?), writeFailed(String?), timeout(String)

    init?(state: CBManagerState) {
        switch state {
        case .poweredOff: self = .bluetoothOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .bluetoothOff: "Bluetooth ist ausgeschaltet."
        case .unauthorized: "Kein Bluetooth-Zugriff. Bitte in den Einstellungen erlauben."
        case .unsupported: "Bluetooth LE wird nicht unterstützt."
        case .notFound: "Lampe nicht gefunden."
        case .characteristicMissing: "Steuer-Characteristic (FFE0/FFE1) nicht gefunden."
        case .lightProfileMissing: "Lampe bietet kein Light Profile (8CE5DD03). Andere Fernlicht-Methode wählen."
        case .disconnected: "Verbindung wurde getrennt."
        case .invalidHex: "Ungültiger Hex-String."
        case .connectFailed(let message): "Verbindung fehlgeschlagen\(message.map { ": \($0)" } ?? ".")"
        case .writeFailed(let message): "Senden fehlgeschlagen\(message.map { ": \($0)" } ?? ".")"
        case .timeout(let stage): "Zeitüberschreitung (\(stage))."
        }
    }
}

/// One-shot bridge from a delegate callback to async/await. Buffers an early
/// result and resumes with CancellationError when the awaiting task is cancelled
/// (which is how the timeouts abort a pending step).
@MainActor
final class Waiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.fail(CancellationError()) }
        }
    }

    func succeed() { finish(.success(())) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension CBCharacteristicProperties {
    var debugDescription: String {
        var parts: [String] = []
        if contains(.read) { parts.append("read") }
        if contains(.write) { parts.append("write") }
        if contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if contains(.notify) { parts.append("notify") }
        if contains(.indicate) { parts.append("indicate") }
        return "[" + parts.joined(separator: ",") + "]"
    }
}
