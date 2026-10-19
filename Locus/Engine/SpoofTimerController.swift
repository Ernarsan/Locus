import CoreLocation
import Foundation
import UIKit

// MARK: - Protocols for Dependency Injection & Unit Testing

protocol ClockProtocol {
    func now() -> Date
}

struct SystemClock: ClockProtocol {
    init() {}
    func now() -> Date { Date() }
}

protocol AudioKeepAliveProtocol: AnyObject {
    func start()
    func stop()
}

extension SilentAudioKeepAlive: AudioKeepAliveProtocol {}

protocol SimulationServiceProtocol: AnyObject {
    func setLocation(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async throws
    func clearLocation() async throws
}

final class RealSimulationService: SimulationServiceProtocol {
    func setLocation(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async throws {
        let result = LocationEngine.set(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
        switch result {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func clearLocation() async throws {
        let result = LocationEngine.clear()
        switch result {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Timer State

enum SpoofTimerState: Equatable {
    case idle
    case running(endDate: Date, totalDuration: TimeInterval)
    case paused(remaining: TimeInterval, totalDuration: TimeInterval)
    case finished
    case failed(error: String)

    var titleRussian: String {
        switch self {
        case .idle: return "Ожидание"
        case .running: return "Активен"
        case .paused: return "На паузе"
        case .finished: return "Завершён"
        case .failed: return "Ошибка"
        }
    }

    var titleEnglish: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Error"
        }
    }
}

// MARK: - SpoofTimerController

@MainActor
final class SpoofTimerController: ObservableObject {
    @Published private(set) var state: SpoofTimerState = .idle
    @Published private(set) var remainingSeconds: TimeInterval = 0
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var activeCoordinate: CLLocationCoordinate2D?
    @Published var userSelectedDuration: TimeInterval = 300 // default 5 minutes
    @Published var finishedMessage: String?
    @Published var isClearing = false

    private let clock: ClockProtocol
    private let simulationService: SimulationServiceProtocol
    private let audioKeepAlive: AudioKeepAliveProtocol
    private let notificationManager: NotificationManagerProtocol
    private let userDefaults: UserDefaults

    private var tickTask: Task<Void, Never>?
    private let minDuration: TimeInterval = 5
    private let maxDuration: TimeInterval = 43200 // 12 hours

    // Persistence keys
    private let keyState = "locus.timer.state"
    private let keyEndDate = "locus.timer.endDate"
    private let keyRemaining = "locus.timer.remaining"
    private let keyTotalDuration = "locus.timer.totalDuration"
    private let keyLatitude = "locus.timer.latitude"
    private let keyLongitude = "locus.timer.longitude"
    private let keyHasCoords = "locus.timer.hasCoords"
    private let keyLastDuration = "locus.timer.lastDuration"

    init(
        clock: ClockProtocol = SystemClock(),
        simulationService: SimulationServiceProtocol = RealSimulationService(),
        audioKeepAlive: AudioKeepAliveProtocol = SilentAudioKeepAlive(),
        notificationManager: NotificationManagerProtocol = TimerNotificationManager.shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.clock = clock
        self.simulationService = simulationService
        self.audioKeepAlive = audioKeepAlive
        self.notificationManager = notificationManager
        self.userDefaults = userDefaults

        let savedDuration = userDefaults.double(forKey: keyLastDuration)
        if savedDuration >= minDuration && savedDuration <= maxDuration {
            self.userSelectedDuration = savedDuration
        } else {
            self.userSelectedDuration = 300
        }
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Public Controls

    func setDuration(_ duration: TimeInterval) {
        let clamped = min(max(duration, minDuration), maxDuration)
        userSelectedDuration = clamped
        userDefaults.set(clamped, forKey: keyLastDuration)
        if state == .idle {
            remainingSeconds = clamped
            progress = 0.0
        }
    }

    func start(
        duration: TimeInterval? = nil,
        coordinate: CLLocationCoordinate2D,
        pairingPath: String,
        deviceIP: String
    ) async throws {
        let targetDuration = min(max(duration ?? userSelectedDuration, minDuration), maxDuration)
        setDuration(targetDuration)
        finishedMessage = nil

        // 1. Set location via existing simulation engine
        try await simulationService.setLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairingPath,
            deviceIP: deviceIP
        )

        // 2. Set absolute end date
        let now = clock.now()
        let endDate = now.addingTimeInterval(targetDuration)
        activeCoordinate = coordinate
        state = .running(endDate: endDate, totalDuration: targetDuration)
        remainingSeconds = targetDuration
        progress = 0.0

        // 3. Keep-alive & notification
        audioKeepAlive.start()
        notificationManager.scheduleTimerExpiry(
            at: endDate,
            body: "Время вышло, открой приложение, чтобы вернуть локацию"
        )

        // 4. Persist and start ticker
        persistState()
        startTicker()
    }

    func pause() {
        guard case .running(let endDate, let totalDuration) = state else { return }
        let now = clock.now()
        let remaining = max(0, endDate.timeIntervalSince(now))

        state = .paused(remaining: remaining, totalDuration: totalDuration)
        remainingSeconds = remaining
        let elapsed = max(0, totalDuration - remaining)
        progress = totalDuration > 0 ? min(1.0, elapsed / totalDuration) : 0.0

        audioKeepAlive.stop()
        notificationManager.cancelTimerExpiry()
        stopTicker()
        persistState()
    }

    func resume(pairingPath: String, deviceIP: String) {
        guard case .paused(let remaining, let totalDuration) = state else { return }
        let now = clock.now()
        let endDate = now.addingTimeInterval(remaining)

        state = .running(endDate: endDate, totalDuration: totalDuration)
        remainingSeconds = remaining

        audioKeepAlive.start()
        notificationManager.scheduleTimerExpiry(
            at: endDate,
            body: "Время вышло, открой приложение, чтобы вернуть локацию"
        )
        persistState()
        startTicker()
    }

    func stop() async {
        stopTicker()
        audioKeepAlive.stop()
        notificationManager.cancelTimerExpiry()
        clearPersistedState()

        isClearing = true
        _ = try? await simulationService.clearLocation()
        isClearing = false

        activeCoordinate = nil
        state = .idle
        remainingSeconds = userSelectedDuration
        progress = 0.0
        finishedMessage = nil
    }

    func adjustRemaining(by deltaSeconds: TimeInterval) {
        switch state {
        case .running(let endDate, let totalDuration):
            let now = clock.now()
            let currentRemaining = endDate.timeIntervalSince(now)
            let newRemaining = max(minDuration, currentRemaining + deltaSeconds)
            let newEndDate = now.addingTimeInterval(newRemaining)
            let newTotal = max(newRemaining, totalDuration + deltaSeconds)

            state = .running(endDate: newEndDate, totalDuration: newTotal)
            remainingSeconds = newRemaining
            let elapsed = max(0, newTotal - newRemaining)
            progress = newTotal > 0 ? min(1.0, elapsed / newTotal) : 0.0

            notificationManager.scheduleTimerExpiry(
                at: newEndDate,
                body: "Время вышло, открой приложение, чтобы вернуть локацию"
            )
            persistState()

        case .paused(let remaining, let totalDuration):
            let newRemaining = max(minDuration, remaining + deltaSeconds)
            let newTotal = max(newRemaining, totalDuration + deltaSeconds)

            state = .paused(remaining: newRemaining, totalDuration: newTotal)
            remainingSeconds = newRemaining
            let elapsed = max(0, newTotal - newRemaining)
            progress = newTotal > 0 ? min(1.0, elapsed / newTotal) : 0.0
            persistState()

        default:
            break
        }
    }

    func updateSimulatedCoordinate(
        to newCoord: CLLocationCoordinate2D,
        pairingPath: String,
        deviceIP: String
    ) async throws {
        try await simulationService.setLocation(
            latitude: newCoord.latitude,
            longitude: newCoord.longitude,
            pairingPath: pairingPath,
            deviceIP: deviceIP
        )
        activeCoordinate = newCoord
        persistState()
    }

    func retryClearManual() async {
        isClearing = true
        do {
            try await simulationService.clearLocation()
            isClearing = false
            state = .finished
            finishedMessage = "Реальная локация восстановлена"
            clearPersistedState()
            triggerHapticFeedback()
        } catch {
            isClearing = false
            state = .failed(error: error.localizedDescription)
        }
    }

    // MARK: - App Lifecycle Handlers

    func handleAppForeground() {
        guard case .running(let endDate, _) = state else { return }
        let now = clock.now()
        if now >= endDate {
            Task { @MainActor in
                await onExpiry()
            }
        } else {
            updateDisplayValues()
        }
    }

    func checkPersistedStateOnLaunch() async {
        guard let savedState = userDefaults.string(forKey: keyState) else { return }

        if savedState == "running" {
            let endTimestamp = userDefaults.double(forKey: keyEndDate)
            let total = userDefaults.double(forKey: keyTotalDuration)
            let endDate = Date(timeIntervalSince1970: endTimestamp)
            let now = clock.now()

            if userDefaults.bool(forKey: keyHasCoords) {
                let lat = userDefaults.double(forKey: keyLatitude)
                let lon = userDefaults.double(forKey: keyLongitude)
                activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }

            if now >= endDate {
                // Expired while app was closed -> clear simulation immediately!
                await onExpiry()
            } else {
                // Still valid -> resume
                let remaining = endDate.timeIntervalSince(now)
                state = .running(endDate: endDate, totalDuration: total)
                remainingSeconds = remaining
                audioKeepAlive.start()
                startTicker()
            }
        } else if savedState == "paused" {
            let remaining = userDefaults.double(forKey: keyRemaining)
            let total = userDefaults.double(forKey: keyTotalDuration)
            if userDefaults.bool(forKey: keyHasCoords) {
                let lat = userDefaults.double(forKey: keyLatitude)
                let lon = userDefaults.double(forKey: keyLongitude)
                activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            state = .paused(remaining: remaining, totalDuration: total)
            remainingSeconds = remaining
            let elapsed = max(0, total - remaining)
            progress = total > 0 ? min(1.0, elapsed / total) : 0.0
        }
    }

    // MARK: - Private Methods

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000) // ~0.25s
                guard let self else { break }
                await self.tick()
            }
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() async {
        guard case .running(let endDate, _) = state else {
            stopTicker()
            return
        }

        let now = clock.now()
        if now >= endDate {
            await onExpiry()
        } else {
            updateDisplayValues()
        }
    }

    private func updateDisplayValues() {
        switch state {
        case .running(let endDate, let totalDuration):
            let now = clock.now()
            let remaining = max(0, endDate.timeIntervalSince(now))
            remainingSeconds = remaining
            let elapsed = max(0, totalDuration - remaining)
            progress = totalDuration > 0 ? min(1.0, elapsed / totalDuration) : 0.0

        case .paused(let remaining, let totalDuration):
            remainingSeconds = remaining
            let elapsed = max(0, totalDuration - remaining)
            progress = totalDuration > 0 ? min(1.0, elapsed / totalDuration) : 0.0

        case .idle:
            remainingSeconds = userSelectedDuration
            progress = 0.0

        case .finished, .failed:
            remainingSeconds = 0
            progress = 1.0
        }
    }

    private func onExpiry() async {
        stopTicker()
        audioKeepAlive.stop()
        notificationManager.cancelTimerExpiry()
        clearPersistedState()

        remainingSeconds = 0
        progress = 1.0
        isClearing = true

        // Retry clear up to 3 times with 1-second delay
        var clearSuccess = false
        var lastClearError: Error?

        for attempt in 1...3 {
            do {
                try await simulationService.clearLocation()
                clearSuccess = true
                break
            } catch {
                lastClearError = error
                NSLog("[Locus] Clear attempt %d failed: %@", attempt, error.localizedDescription)
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        isClearing = false

        if clearSuccess {
            activeCoordinate = nil
            state = .finished
            finishedMessage = "Реальная локация восстановлена"
            triggerHapticFeedback()
        } else {
            let errorMsg = lastClearError?.localizedDescription ?? "Не удалось сбросить симуляцию"
            state = .failed(error: errorMsg)
        }
    }

    private func triggerHapticFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    // MARK: - State Persistence

    private func persistState() {
        switch state {
        case .running(let endDate, let totalDuration):
            userDefaults.set("running", forKey: keyState)
            userDefaults.set(endDate.timeIntervalSince1970, forKey: keyEndDate)
            userDefaults.set(totalDuration, forKey: keyTotalDuration)
            if let coord = activeCoordinate {
                userDefaults.set(true, forKey: keyHasCoords)
                userDefaults.set(coord.latitude, forKey: keyLatitude)
                userDefaults.set(coord.longitude, forKey: keyLongitude)
            } else {
                userDefaults.set(false, forKey: keyHasCoords)
            }

        case .paused(let remaining, let totalDuration):
            userDefaults.set("paused", forKey: keyState)
            userDefaults.set(remaining, forKey: keyRemaining)
            userDefaults.set(totalDuration, forKey: keyTotalDuration)
            if let coord = activeCoordinate {
                userDefaults.set(true, forKey: keyHasCoords)
                userDefaults.set(coord.latitude, forKey: keyLatitude)
                userDefaults.set(coord.longitude, forKey: keyLongitude)
            } else {
                userDefaults.set(false, forKey: keyHasCoords)
            }

        case .idle, .finished, .failed:
            clearPersistedState()
        }
    }

    private func clearPersistedState() {
        userDefaults.removeObject(forKey: keyState)
        userDefaults.removeObject(forKey: keyEndDate)
        userDefaults.removeObject(forKey: keyRemaining)
        userDefaults.removeObject(forKey: keyTotalDuration)
        userDefaults.removeObject(forKey: keyLatitude)
        userDefaults.removeObject(forKey: keyLongitude)
        userDefaults.removeObject(forKey: keyHasCoords)
    }
}
