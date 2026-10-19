import SwiftUI
import NetworkExtension

struct RootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var timerController: SpoofTimerController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showPlaces = false
    @State private var showTimer = false

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
            MapHomeView()

            BottomControlsView(
                showSettings: $showSettings,
                showPlaces: $showPlaces,
                showTimer: $showTimer
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .sheet(isPresented: $showTimer) {
            NavigationStack {
                ScrollView {
                    SpoofTimerView()
                        .padding()
                }
                .navigationTitle("Таймер спуфинга")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { showTimer = false }
                    }
                }
            }
            .presentationDetents([.fraction(0.72), .large])
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                timerController.handleAppForeground()
            }
        }
        .onChange(of: timerController.state) { _, newState in
            if newState == .finished {
                if session.isSpoofing {
                    session.simulated = nil
                    session.status = .idle
                }
            }
        }
        .alert("Locus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var timerController: SpoofTimerController
    @Environment(\.scenePhase) private var scenePhase

    @State private var tunnelConnected = LocalDevVPN.isConnected

    private enum Display {
        case notSpoofing
        case connectVPN
        case status(String)
    }

    private var display: Display {
        switch timerController.state {
        case .running:
            return .status("Таймер: \(formatTime(timerController.remainingSeconds))")
        case .paused:
            return .status("Пауза: \(formatTime(timerController.remainingSeconds))")
        default:
            break
        }

        switch session.status {
        case .idle:
            return tunnelConnected ? .notSpoofing : .connectVPN
        case .connecting:
            return .status("Connecting…")
        case .active:
            return .status("Spoofing")
        case .reconnecting:
            return .status("Reconnecting…")
        case .dropped(let reason):
            return .status(reason.isEmpty ? "Disconnected" : "Disconnected — \(reason)")
        }
    }

    private var color: Color {
        switch timerController.state {
        case .running:
            return LocusTheme.statusGood
        case .paused:
            return LocusTheme.statusWarn
        default:
            break
        }

        switch display {
        case .notSpoofing:
            return Color.primary.opacity(0.55)
        case .connectVPN:
            return LocusTheme.statusWarn
        case .status:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var title: String {
        switch display {
        case .notSpoofing: return "Not Spoofing"
        case .connectVPN: return "Connect LocalDevVPN"
        case .status(let text): return text
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        Group {
            if case .connectVPN = display {
                Button(action: LocalDevVPN.openOrInstall) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else {
                statusContent
            }
        }
        .onAppear { refreshTunnel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTunnel() }
        }
        .onChange(of: session.status) { _, _ in
            refreshTunnel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            // LocalDevVPN connection changes show up here even though we don’t own the VPN.
            refreshTunnel()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshTunnel()
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if case .connectVPN = display {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .active = session.status, let sim = session.simulated {
                Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func refreshTunnel() {
        tunnelConnected = LocalDevVPN.isConnected
    }
}

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var timerController: SpoofTimerController
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool
    @Binding var showTimer: Bool

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    private var isTimerActive: Bool {
        switch timerController.state {
        case .running, .paused: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if isTimerActive {
                compactTimerBanner
            }

            HStack(spacing: 8) {
                ForEach(TravelMode.allCases) { mode in
                    let selected = session.travelMode == mode
                    Button {
                        session.travelMode = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(selected ? .black : .primary)
                            .frame(width: 44, height: 40)
                            .background(
                                Capsule().fill(selected ? LocusTheme.accent : Color.primary.opacity(0.08))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                trayIcon("gearshape.fill") { showSettings = true }
                trayIcon("star.fill") { showPlaces = true }
                trayIcon("timer") { showTimer = true }

                Button {
                    if session.joystickActive {
                        session.stopJoystick()
                    } else {
                        session.startJoystick(pairing: pairing)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                        Text(session.joystickActive ? "On" : "Joy")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.joystickActive ? .black : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(session.joystickActive ? LocusTheme.accentSecondary : Color.primary.opacity(0.08))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if session.isSpoofing {
                    Button {
                        if isTimerActive {
                            Task { await timerController.stop() }
                        }
                        session.stop(pairing: pairing)
                    } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 72)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(LocusTheme.danger))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        guard let pin = session.pin else {
                            session.lastError = "Tap the map to drop a pin first."
                            return
                        }
                        session.teleport(to: pin, pairing: pairing)
                    } label: {
                        Text("Teleport")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(minWidth: 96)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .background(Capsule().fill(LocusTheme.accent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isBusy)
                }
            }
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
    }

    private var compactTimerBanner: some View {
        Button {
            showTimer = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(timerController.state == .running ? LocusTheme.statusGood : LocusTheme.statusWarn)

                Text(formatRemaining(timerController.remainingSeconds))
                    .font(.subheadline.weight(.bold).monospaced())
                    .foregroundStyle(.primary)

                Spacer()

                if case .running = timerController.state {
                    Button {
                        timerController.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(6)
                            .background(Circle().fill(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                } else if case .paused = timerController.state {
                    Button {
                        timerController.resume(
                            pairingPath: pairing.pairingPath,
                            deviceIP: TunnelConfig.targetIP
                        )
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundStyle(.black)
                            .padding(6)
                            .background(Circle().fill(LocusTheme.accent))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await timerController.stop() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(LocusTheme.danger))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func trayIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
    }
}
