import CoreLocation
import XCTest
@testable import Locus

final class MockClock: ClockProtocol {
    var currentTime: Date

    init(initialTime: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentTime = initialTime
    }

    func now() -> Date {
        return currentTime
    }

    func advance(by seconds: TimeInterval) {
        currentTime = currentTime.addingTimeInterval(seconds)
    }
}

final class MockAudioKeepAlive: AudioKeepAliveProtocol {
    var isStarted = false
    var startCount = 0
    var stopCount = 0

    func start() {
        isStarted = true
        startCount += 1
    }

    func stop() {
        isStarted = false
        stopCount += 1
    }
}

final class MockNotificationManager: NotificationManagerProtocol {
    var requestedAuth = false
    var scheduledDates: [Date] = []
    var scheduledBodies: [String] = []
    var cancelCount = 0

    func requestAuthorization() async -> Bool {
        requestedAuth = true
        return true
    }

    func scheduleTimerExpiry(at date: Date, body: String) {
        scheduledDates.append(date)
        scheduledBodies.append(body)
    }

    func cancelTimerExpiry() {
        cancelCount += 1
    }
}

final class MockSimulationService: SimulationServiceProtocol {
    enum MockError: LocalizedError {
        case simulatedFailure

        var errorDescription: String? { "Simulated failure" }
    }

    var setLocationCalls: [(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String)] = []
    var clearLocationCallCount = 0

    var shouldFailSet = false
    var shouldFailClear = false
    var failClearAttemptsRemaining = 0

    func setLocation(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async throws {
        if shouldFailSet {
            throw MockError.simulatedFailure
        }
        setLocationCalls.append((latitude, longitude, pairingPath, deviceIP))
    }

    func clearLocation() async throws {
        clearLocationCallCount += 1
        if failClearAttemptsRemaining > 0 {
            failClearAttemptsRemaining -= 1
            throw MockError.simulatedFailure
        }
        if shouldFailClear {
            throw MockError.simulatedFailure
        }
    }
}

@MainActor
final class SpoofTimerControllerTests: XCTestCase {
    private var clock: MockClock!
    private var simulationService: MockSimulationService!
    private var audioKeepAlive: MockAudioKeepAlive!
    private var notificationManager: MockNotificationManager!
    private var testDefaults: UserDefaults!
    private var controller: SpoofTimerController!

    private let sampleCoordinate = CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173)

    override func setUp() async throws {
        try await super.setUp()
        clock = MockClock()
        simulationService = MockSimulationService()
        audioKeepAlive = MockAudioKeepAlive()
        notificationManager = MockNotificationManager()
        testDefaults = UserDefaults(suiteName: "SpoofTimerControllerTests-\(UUID().uuidString)")!

        controller = SpoofTimerController(
            clock: clock,
            simulationService: simulationService,
            audioKeepAlive: audioKeepAlive,
            notificationManager: notificationManager,
            userDefaults: testDefaults
        )
    }

    override func tearDown() async throws {
        await controller.stop()
        testDefaults.removePersistentDomain(forName: testDefaults.description)
        controller = nil
        try await super.tearDown()
    }

    func testTimerInitialState() {
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.userSelectedDuration, 300)
        XCTAssertFalse(audioKeepAlive.isStarted)
    }

    func testTimerStart() async throws {
        try await controller.start(
            duration: 60,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        guard case .running(let endDate, let total) = controller.state else {
            XCTFail("Expected running state")
            return
        }

        XCTAssertEqual(total, 60)
        XCTAssertEqual(endDate, clock.now().addingTimeInterval(60))
        XCTAssertEqual(simulationService.setLocationCalls.count, 1)
        XCTAssertEqual(simulationService.setLocationCalls[0].latitude, sampleCoordinate.latitude)
        XCTAssertTrue(audioKeepAlive.isStarted)
        XCTAssertEqual(notificationManager.scheduledDates.count, 1)
        XCTAssertEqual(notificationManager.scheduledDates.last, endDate)
    }

    func testTimerPauseAndResume() async throws {
        try await controller.start(
            duration: 100,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        // Advance 20s
        clock.advance(by: 20)
        controller.pause()

        guard case .paused(let remaining, let total) = controller.state else {
            XCTFail("Expected paused state")
            return
        }
        XCTAssertEqual(remaining, 80)
        XCTAssertEqual(total, 100)
        XCTAssertFalse(audioKeepAlive.isStarted)
        XCTAssertGreaterThanOrEqual(notificationManager.cancelCount, 1)

        // Wait a bit while paused (time shouldn't decrease)
        clock.advance(by: 50)
        controller.resume(pairingPath: "/path/to/pairing", deviceIP: "10.7.0.1")

        guard case .running(let newEnd, _) = controller.state else {
            XCTFail("Expected running state after resume")
            return
        }
        // newEnd should be clock.now() + 80s
        XCTAssertEqual(newEnd, clock.now().addingTimeInterval(80))
        XCTAssertTrue(audioKeepAlive.isStarted)
    }

    func testTimerAdjustRemaining() async throws {
        try await controller.start(
            duration: 60,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        // Add 60s
        controller.adjustRemaining(by: 60)
        guard case .running(let end1, let total1) = controller.state else {
            XCTFail("Expected running state")
            return
        }
        XCTAssertEqual(total1, 120)
        XCTAssertEqual(end1, clock.now().addingTimeInterval(120))

        // Subtract 110s (should leave 10s)
        controller.adjustRemaining(by: -110)
        guard case .running(let end2, _) = controller.state else {
            XCTFail("Expected running state")
            return
        }
        XCTAssertEqual(end2, clock.now().addingTimeInterval(10))

        // Subtract another 60s (should clamp to minimum 5s)
        controller.adjustRemaining(by: -60)
        guard case .running(let end3, _) = controller.state else {
            XCTFail("Expected running state")
            return
        }
        XCTAssertEqual(end3, clock.now().addingTimeInterval(5))
    }

    func testTimerStop() async throws {
        try await controller.start(
            duration: 60,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        await controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(simulationService.clearLocationCallCount, 1)
        XCTAssertFalse(audioKeepAlive.isStarted)
        XCTAssertNil(controller.activeCoordinate)
    }

    func testTimerExpiryCallsClearAndFinishes() async throws {
        try await controller.start(
            duration: 30,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        // Advance clock past expiration
        clock.advance(by: 31)
        controller.handleAppForeground()

        // Wait a moment for async expiry logic to finish
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .finished)
        XCTAssertEqual(controller.finishedMessage, "Реальная локация восстановлена")
        XCTAssertEqual(simulationService.clearLocationCallCount, 1)
        XCTAssertFalse(audioKeepAlive.isStarted)
    }

    func testTimerExpiryRetryOnError() async throws {
        // Make clearLocation fail twice then succeed on 3rd attempt
        simulationService.failClearAttemptsRemaining = 2

        try await controller.start(
            duration: 10,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        clock.advance(by: 11)
        controller.handleAppForeground()

        // Wait for retries
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(controller.state, .finished)
        XCTAssertEqual(simulationService.clearLocationCallCount, 3)
    }

    func testTimerExpiryFailsAfterThreeRetries() async throws {
        // Make clearLocation persistently fail
        simulationService.shouldFailClear = true

        try await controller.start(
            duration: 10,
            coordinate: sampleCoordinate,
            pairingPath: "/path/to/pairing",
            deviceIP: "10.7.0.1"
        )

        clock.advance(by: 11)
        controller.handleAppForeground()

        // Wait for 3 retries
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        guard case .failed = controller.state else {
            XCTFail("Expected failed state after 3 retry failures")
            return
        }

        // Manual recovery test
        simulationService.shouldFailClear = false
        await controller.retryClearManual()

        XCTAssertEqual(controller.state, .finished)
    }

    func testRelaunchAfterExpiryRestoresRealLocation() async throws {
        // Pre-populate testDefaults as if an app was running a timer and died
        testDefaults.set("running", forKey: "locus.timer.state")
        let pastEnd = clock.now().addingTimeInterval(-100).timeIntervalSince1970
        testDefaults.set(pastEnd, forKey: "locus.timer.endDate")
        testDefaults.set(300.0, forKey: "locus.timer.totalDuration")
        testDefaults.set(true, forKey: "locus.timer.hasCoords")
        testDefaults.set(sampleCoordinate.latitude, forKey: "locus.timer.latitude")
        testDefaults.set(sampleCoordinate.longitude, forKey: "locus.timer.longitude")

        let freshController = SpoofTimerController(
            clock: clock,
            simulationService: simulationService,
            audioKeepAlive: audioKeepAlive,
            notificationManager: notificationManager,
            userDefaults: testDefaults
        )

        await freshController.checkPersistedStateOnLaunch()

        XCTAssertEqual(freshController.state, .finished)
        XCTAssertEqual(simulationService.clearLocationCallCount, 1)
        XCTAssertEqual(freshController.finishedMessage, "Реальная локация восстановлена")
    }
}
