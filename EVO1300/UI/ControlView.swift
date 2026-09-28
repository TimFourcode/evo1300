import SwiftUI

/// Main screen, modelled on the iPhone flashlight: one tall slider for the low
/// beam (bottom = off) and a round high-beam button below. Pure black so OLED
/// pixels stay off. The light state lives in UserDefaults (see `LampSettings`),
/// so `@AppStorage` also picks up changes made by the Action button or Siri.
struct ControlView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var manager = MagicshineBLEManager.shared
    @AppStorage("isOn") private var isOn = false
    @AppStorage("isHighBeam") private var isHighBeam = false
    @AppStorage("lastOnLevel") private var lastOnLevelRaw = LightLevel.medium.rawValue
    @AppStorage("pairedName") private var pairedName: String?
    @State private var previewStep: Int?
    @State private var lastError: String?
    @State private var showSettings = false

    /// Slider steps from bottom to top.
    private static let steps: [LightLevel] = [.off, .low, .medium, .high, .max]

    private var lastOnLevel: LightLevel { LightLevel(rawValue: lastOnLevelRaw) ?? .medium }
    private var currentStep: Int { isOn ? Self.steps.firstIndex(of: lastOnLevel) ?? 0 : 0 }
    private var shownStep: Int { previewStep ?? currentStep }
    private var highBeamActive: Bool { isOn && isHighBeam }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            status
            BrightnessSlider(step: shownStep, stepCount: Self.steps.count) { step in
                previewStep = step
            } onCommit: { step in
                guard step != currentStep else { previewStep = nil; return }
                run { try await manager.setLevel(Self.steps[step]) }
            }
            .frame(width: 150, height: 380)
            .padding(.top, 24)
            Spacer(minLength: 24)
            highBeamButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: shownStep)
        .sensoryFeedback(.error, trigger: lastError) { _, new in new != nil }
        .sheet(isPresented: $showSettings) { ContentView() }
        .onAppear {
            if pairedName == nil { showSettings = true }
            manager.startPresenceMonitor()
        }
        .onDisappear { manager.stopPresenceMonitor() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.startPresenceMonitor() } else { manager.stopPresenceMonitor() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("EVO Licht").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    connectionLabel(reachable: manager.isLampReachable(at: context.date))
                }
            }
            Spacer()
            Button {
                run { _ = try await manager.readBattery() }
            } label: {
                Label(manager.battery.map { "\($0) %" } ?? "Akku", systemImage: "battery.75percent")
                    .font(.subheadline)
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill").font(.title3)
            }
            .accessibilityLabel("Einstellungen")
        }
        .tint(.secondary)
        .padding(.top, 8)
    }

    private var status: some View {
        VStack(spacing: 4) {
            Text(statusText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(isOn || previewStep != nil ? .white : .secondary)
                .contentTransition(.opacity)
                .animation(.default, value: statusText)
            Group {
                if let lastError {
                    Text(lastError).foregroundStyle(.red)
                } else if manager.isBusy {
                    Text("Verbinde …").foregroundStyle(.secondary)
                } else {
                    Text(highBeamActive ? "Fernlicht an" : "Abblendlicht").foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .frame(minHeight: 18)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if pairedName != nil, manager.bluetoothState == .poweredOn, !manager.isBusy,
                   !manager.isLampReachable(at: context.date) {
                    Button("Verbinden") {
                        run { _ = try await manager.readBattery() }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.white)
                    .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionLabel(reachable: Bool) -> some View {
        let (text, color): (String, Color) = if pairedName == nil {
            ("Keine Lampe gekoppelt", .secondary)
        } else if manager.bluetoothState == .poweredOff {
            ("Bluetooth ist aus", .orange)
        } else if reachable || manager.isBusy {
            ("Verbunden", .green)
        } else {
            ("Keine Verbindung", .red)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let level = Self.steps[shownStep]
        return level == .off ? "Aus" : level.label
    }

    private var highBeamButton: some View {
        VStack(spacing: 8) {
            Button {
                run { try await manager.setHighBeam(!highBeamActive) }
            } label: {
                Image(systemName: highBeamActive ? "headlight.high.beam.fill" : "headlight.high.beam")
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 76, height: 76)
                    .foregroundStyle(highBeamActive ? .black : .white)
                    .background(highBeamActive ? Color.white : Color(white: 0.16), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(manager.isBusy)
            .accessibilityLabel("Fernlicht")
            .accessibilityValue(highBeamActive ? "An" : "Aus")
            Text("Fernlicht")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            previewStep = nil
        }
    }
}

/// Control Center style slider: drag or tap anywhere to pick a step, the fill
/// grows from the bottom. The step is committed when the finger lifts.
private struct BrightnessSlider: View {
    let step: Int
    let stepCount: Int
    let onChange: (Int) -> Void
    let onCommit: (Int) -> Void

    private var maxStep: Int { stepCount - 1 }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color(white: 0.16))
                Rectangle()
                    .fill(.white)
                    .frame(height: height * CGFloat(step) / CGFloat(maxStep))
                Image(systemName: step > 0 ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(step > 0 ? Color.black : Color(white: 0.55))
                    .padding(.bottom, 30)
            }
            .clipShape(.rect(cornerRadius: 44, style: .continuous))
            .contentShape(.rect)
            .animation(.snappy(duration: 0.18), value: step)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChange(stepAt($0.location.y, height: height)) }
                    .onEnded { onCommit(stepAt($0.location.y, height: height)) }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Helligkeit")
        .accessibilityValue("Stufe \(step) von \(maxStep)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(step + 1, maxStep))
            case .decrement: onCommit(max(step - 1, 0))
            @unknown default: break
            }
        }
    }

    private func stepAt(_ y: CGFloat, height: CGFloat) -> Int {
        let fraction = 1 - y / height
        return min(maxStep, max(0, Int((fraction * CGFloat(maxStep)).rounded())))
    }
}

#Preview {
    ControlView()
}
