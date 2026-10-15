@testable import BoothCore
import XCTest

final class SessionMachineTests: XCTestCase {
    private func settings(photos: Int = 2) -> BoothSettings {
        var s = BoothSettings()
        s.photosPerSession = photos
        s.countdownMode = .eachPhoto
        s.timing.firstPhotoCountdown = 2
        s.timing.countdown = 1
        s.reviewEnabled = true
        s.maxRetakes = 1
        s.printCopies = 2
        return s
    }

    private func token(_ effects: [SessionEffect]) -> TimerToken? {
        for effect in effects {
            if case .scheduleTimer(let token, _) = effect { return token }
        }
        return nil
    }

    func testFullSessionPrintsAndReturnsToAttract() throws {
        var machine = SessionMachine(settings: settings())
        var effects = machine.handle(.touch)
        XCTAssertEqual(machine.stage, .getReady)
        XCTAssertTrue(effects.contains(.sessionStarted))

        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(machine.stage, .countdown(remaining: 2, photo: 1))
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(machine.stage, .countdown(remaining: 1, photo: 1))
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(machine.stage, .takePhoto(1))
        XCTAssertEqual(effects, [.pauseLiveView, .capture(photo: 1)])

        effects = machine.handle(.captureSucceeded(photo: 1))
        XCTAssertEqual(machine.stage, .afterPhoto(1))
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(machine.stage, .countdown(remaining: 1, photo: 2))
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(effects.last, .capture(photo: 2))

        effects = machine.handle(.captureSucceeded(photo: 2))
        XCTAssertEqual(machine.stage, .afterLastPhoto)
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(effects, [.compose(photoCount: 2)])

        effects = machine.handle(.compositionFinished)
        XCTAssertEqual(machine.stage, .review)
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(machine.stage, .endInstructions)
        XCTAssertTrue(effects.contains(.print(copies: 2)))

        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        XCTAssertEqual(machine.stage, .attract)
        guard case .sessionFinished(let summary)? = effects.last else { return XCTFail("no summary") }
        XCTAssertEqual(summary.result, .completed)
        XCTAssertEqual(summary.photosTaken, 2)
        XCTAssertEqual(summary.printCopies, 2)
    }

    func testStaleTimersAreIgnored() throws {
        var machine = SessionMachine(settings: settings())
        let first = try XCTUnwrap(token(machine.handle(.touch)))
        _ = machine.handle(.timerFired(first))
        let stage = machine.stage
        XCTAssertEqual(machine.handle(.timerFired(first)), [])
        XCTAssertEqual(machine.stage, stage)
    }

    func testCaptureFailureRetriesThenEndsSession() throws {
        var s = settings(photos: 1)
        s.countdownMode = .none
        var machine = SessionMachine(settings: s)
        let effects = machine.handle(.touch)
        XCTAssertEqual(machine.handle(.timerFired(try XCTUnwrap(token(effects)))), [.pauseLiveView, .capture(photo: 1)])

        let retry = machine.handle(.captureFailed(photo: 1, reason: "busy"))
        XCTAssertTrue(retry.contains(.capture(photo: 1)))
        XCTAssertEqual(machine.retakesUsed, 1)

        let end = machine.handle(.captureFailed(photo: 1, reason: "busy"))
        XCTAssertEqual(machine.stage, .attract)
        guard case .sessionFinished(let summary)? = end.last else { return XCTFail("no summary") }
        XCTAssertEqual(summary.result, .failed)
    }

    func testRetakeFromReviewRestartsCapture() throws {
        var s = settings(photos: 1)
        s.countdownMode = .none
        var machine = SessionMachine(settings: s)
        var effects = machine.handle(.touch)
        _ = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        effects = machine.handle(.captureSucceeded(photo: 1))
        effects = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        _ = machine.handle(.compositionFinished)
        XCTAssertEqual(machine.stage, .review)

        effects = machine.handle(.command(.retake))
        XCTAssertEqual(effects.first, .discardPhotos)
        XCTAssertEqual(machine.stage, .takePhoto(1))
        // No retakes left.
        _ = machine.handle(.captureSucceeded(photo: 1))
        XCTAssertEqual(machine.retakesUsed, 1)
    }

    func testCopiesPromptClampsToMaximum() throws {
        var s = settings(photos: 1)
        s.countdownMode = .none
        s.reviewEnabled = false
        s.copiesPrompt = true
        s.maxCopies = 3
        var machine = SessionMachine(settings: s)
        var effects = machine.handle(.touch)
        _ = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        effects = machine.handle(.captureSucceeded(photo: 1))
        _ = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        _ = machine.handle(.compositionFinished)
        XCTAssertEqual(machine.stage, .copiesPrompt)
        effects = machine.handle(.copiesChosen(9))
        XCTAssertTrue(effects.contains(.print(copies: 3)))
    }

    func testCreditsGateSessionStart() {
        var s = settings()
        s.creditsRequiredToStart = 2
        var machine = SessionMachine(settings: s)
        XCTAssertEqual(machine.handle(.touch), [.insufficientCredits(have: 0, need: 2)])
        _ = machine.handle(.command(.addCredit))
        _ = machine.handle(.command(.addCredit))
        let effects = machine.handle(.command(.startSession))
        XCTAssertTrue(effects.contains(.sessionStarted))
        XCTAssertTrue(effects.contains(.creditsChanged(0)))
    }

    func testCancelReturnsToAttract() throws {
        var machine = SessionMachine(settings: settings())
        let effects = machine.handle(.touch)
        _ = machine.handle(.timerFired(try XCTUnwrap(token(effects))))
        let cancel = machine.handle(.command(.cancelSession))
        XCTAssertEqual(machine.stage, .attract)
        guard case .sessionFinished(let summary)? = cancel.last else { return XCTFail("no summary") }
        XCTAssertEqual(summary.result, .cancelled)
    }

    func testColorCommandsAndSettingsLock() {
        var machine = SessionMachine(settings: settings())
        XCTAssertEqual(machine.handle(.command(.sepia)), [.colorEffectChanged(.sepia)])
        _ = machine.handle(.touch)
        XCTAssertFalse(machine.updateSettings(BoothSettings()))
    }

    func testOutOfServiceBlocksStart() {
        var machine = SessionMachine(settings: settings())
        _ = machine.handle(.setOutOfService(reason: "Paper out"))
        XCTAssertEqual(machine.stage, .outOfService(reason: "Paper out"))
        XCTAssertEqual(machine.handle(.touch), [])
        _ = machine.handle(.setOutOfService(reason: nil))
        XCTAssertEqual(machine.stage, .attract)
    }
}
