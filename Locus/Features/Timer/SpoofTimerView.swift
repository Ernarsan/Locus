import CoreLocation
import SwiftUI

struct SpoofTimerView: View {
    @EnvironmentObject private var timerController: SpoofTimerController
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @StateObject private var reverseGeocoder = ReverseGeocoder()

    @State private var showCustomPicker = false
    @State private var showCoordinateSheet = false
    @State private var pendingPointChange: CLLocationCoordinate2D?
    @State private var showMoveConfirmation = false
    @State private var actionError: String?

    private let presets: [(label: String, seconds: TimeInterval)] = [
        ("30 с", 30),
        ("1 мин", 60),
        ("5 мин", 300),
        ("15 мин", 900),
        ("30 мин", 1800),
        ("1 ч", 3600)
    ]

    var body: some View {
        VStack(spacing: 16) {
            headerRow

            countdownDisplay

            progressBar

            targetLocationInfo

            presetChipsSection

            actionButtonsSection

            if let errorMsg = timerError {
                errorBanner(errorMsg)
            }

            if let finishMsg = timerController.finishedMessage {
                finishedBanner(finishMsg)
            }
        }
        .padding(18)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onAppear {
            updateGeocoding()
        }
        .onChange(of: session.pin?.latitude) { _, _ in
            handlePinChanged()
        }
        .onChange(of: session.pin?.longitude) { _, _ in
            handlePinChanged()
        }
        .sheet(isPresented: $showCustomPicker) {
            CustomDurationPickerSheet(initialDuration: timerController.userSelectedDuration) { newDuration in
                timerController.setDuration(newDuration)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showCoordinateSheet) {
            ManualCoordinateSheet(initialCoordinate: session.pin) { newCoord in
                session.pin = newCoord
                handlePinChanged()
            }
        }
        .alert("Переместить симуляцию?", isPresented: $showMoveConfirmation) {
            Button("Переместить сейчас", role: .none) {
                if let target = pendingPointChange {
                    Task {
                        do {
                            try await timerController.updateSimulatedCoordinate(
                                to: target,
                                pairingPath: pairing.pairingPath,
                                deviceIP: TunnelConfig.targetIP
                            )
                            session.simulated = target
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                pendingPointChange = nil
            }
            Button("Отмена", role: .cancel) {
                if let active = timerController.activeCoordinate {
                    session.pin = active
                }
                pendingPointChange = nil
            }
        } message: {
            Text("Таймер продолжит обратный отсчёт в новой точке.")
        }
        .alert("Ошибка", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Text("Таймер спуфинга")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()

            statusBadge
        }
    }

    private var statusBadge: some View {
        let (color, text) = statusBadgeInfo
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityLabel("Статус таймера: \(text)")
    }

    private var statusBadgeInfo: (Color, String) {
        switch timerController.state {
        case .idle:
            return (.secondary, "Ожидание")
        case .running:
            return (LocusTheme.statusGood, "Активен")
        case .paused:
            return (LocusTheme.statusWarn, "На паузе")
        case .finished:
            return (LocusTheme.accent, "Завершён")
        case .failed:
            return (LocusTheme.danger, "Ошибка")
        }
    }

    private var countdownDisplay: some View {
        Text(formattedRemainingTime)
            .font(.system(size: 44, weight: .bold, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("Осталось времени: \(formattedRemainingTime)")
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 8)

                Capsule()
                    .fill(progressColor)
                    .frame(width: max(0, min(proxy.size.width, proxy.size.width * CGFloat(timerController.progress))), height: 8)
                    .animation(.easeInOut(duration: 0.25), value: timerController.progress)
            }
        }
        .frame(height: 8)
    }

    private var progressColor: Color {
        switch timerController.state {
        case .running: return LocusTheme.statusGood
        case .paused: return LocusTheme.statusWarn
        case .failed: return LocusTheme.danger
        default: return LocusTheme.accent
        }
    }

    private var targetLocationInfo: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(LocusTheme.accent)

                if let coord = targetCoordinate {
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)

                    Button {
                        showCoordinateSheet = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.caption)
                            .foregroundStyle(LocusTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Редактировать координаты вручную")
                } else {
                    Text("Выберите точку на карте")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let placeName = reverseGeocoder.placeName {
                Text(placeName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    private var presetChipsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.seconds) { preset in
                    let isSelected = abs(timerController.userSelectedDuration - preset.seconds) < 0.5
                    Button {
                        timerController.setDuration(preset.seconds)
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? .black : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isSelected ? LocusTheme.accent : Color.primary.opacity(0.08))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isTimerActive)
                    .accessibilityLabel("Установить время \(preset.label)")
                }

                Button {
                    showCustomPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Своё")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isTimerActive)
                .accessibilityLabel("Настроить своё время")
            }
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            // Adjust buttons row: -1 min, +1 min
            if isTimerActive {
                HStack(spacing: 12) {
                    Button {
                        timerController.adjustRemaining(by: -60)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "minus.circle")
                            Text("-1 мин")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(canDecreaseTime ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDecreaseTime)
                    .accessibilityLabel("Уменьшить время на 1 минуту")

                    Button {
                        timerController.adjustRemaining(by: 60)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("+1 мин")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Увеличить время на 1 минуту")
                }
            }

            // Main controls: Start, Pause/Resume, Stop
            HStack(spacing: 10) {
                switch timerController.state {
                case .idle, .finished, .failed:
                    Button {
                        startTimer()
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Старт таймера")
                        }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(LocusTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(targetCoordinate == nil || !pairing.hasPairingFile)
                    .accessibilityLabel("Запустить таймер спуфинга")

                case .running:
                    Button {
                        timerController.pause()
                    } label: {
                        HStack {
                            Image(systemName: "pause.fill")
                            Text("Пауза")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Поставить таймер на паузу")

                    Button {
                        Task { await timerController.stop() }
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Стоп")
                        }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(LocusTheme.danger))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Остановить таймер и сбросить локацию")

                case .paused:
                    Button {
                        timerController.resume(
                            pairingPath: pairing.pairingPath,
                            deviceIP: TunnelConfig.targetIP
                        )
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Продолжить")
                        }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(LocusTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Продолжить работу таймера")

                    Button {
                        Task { await timerController.stop() }
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Стоп")
                        }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(LocusTheme.danger))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Остановить таймер и сбросить локацию")
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LocusTheme.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ошибка сброса локации")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await timerController.retryClearManual()
                }
            } label: {
                Text(timerController.isClearing ? "Сброс…" : "Сбросить сейчас")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(LocusTheme.danger))
            }
            .buttonStyle(.plain)
            .disabled(timerController.isClearing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(LocusTheme.danger.opacity(0.15)))
    }

    private func finishedBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LocusTheme.statusGood)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(LocusTheme.statusGood.opacity(0.15)))
    }

    // MARK: - Helpers

    private var targetCoordinate: CLLocationCoordinate2D? {
        timerController.activeCoordinate ?? session.pin ?? session.simulated
    }

    private var isTimerActive: Bool {
        switch timerController.state {
        case .running, .paused: return true
        default: return false
        }
    }

    private var canDecreaseTime: Bool {
        timerController.remainingSeconds > 10
    }

    private var timerError: String? {
        if case .failed(let err) = timerController.state {
            return err
        }
        return nil
    }

    private var formattedRemainingTime: String {
        let total = Int(ceil(timerController.remainingSeconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private func startTimer() {
        guard let coord = targetCoordinate else {
            actionError = "Пожалуйста, выберите точку на карте"
            return
        }

        guard pairing.hasPairingFile else {
            actionError = "Импортируйте файл RPPairing в Настройках"
            return
        }

        Task {
            do {
                try await timerController.start(
                    duration: timerController.userSelectedDuration,
                    coordinate: coord,
                    pairingPath: pairing.pairingPath,
                    deviceIP: TunnelConfig.targetIP
                )
                session.simulated = coord
                session.status = .active
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func handlePinChanged() {
        guard isTimerActive, let newPin = session.pin else {
            updateGeocoding()
            return
        }

        if let active = timerController.activeCoordinate {
            let latDiff = abs(active.latitude - newPin.latitude)
            let lonDiff = abs(active.longitude - newPin.longitude)
            if latDiff > 0.0001 || lonDiff > 0.0001 {
                pendingPointChange = newPin
                showMoveConfirmation = true
            }
        }
        updateGeocoding()
    }

    private func updateGeocoding() {
        reverseGeocoder.reverseGeocode(targetCoordinate)
    }
}
