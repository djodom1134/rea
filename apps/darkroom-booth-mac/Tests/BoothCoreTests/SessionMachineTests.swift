@testable import BoothCore
import Foundation
import Testing

@Suite struct SessionMachineTests {
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

    @Test func testFullSessionPrintsAndReturnsToAttract() throws {
        var machine = SessionMachine(settings: settings())
        var effects = machine.handle(.touch)
        #expect(machine.stage == .getReady)
        #expect(effects.contains(.sessionStarted))

        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(machine.stage == .countdown(remaining: 2, photo: 1))
        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(machine.stage == .countdown(remaining: 1, photo: 1))
        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(machine.stage == .takePhoto(1))
        #expect(effects == [.pauseLiveView, .capture(photo: 1)])

        effects = machine.handle(.captureSucceeded(photo: 1))
        #expect(machine.stage == .afterPhoto(1))
        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(machine.stage == .countdown(remaining: 1, photo: 2))
        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(effects.last == .capture(photo: 2))

        effects = machine.handle(.captureSucceeded(photo: 2))
        #expect(machine.stage == .afterLastPhoto)
        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(effects == [.compose(photoCount: 2)])

        effects = machine.handle(.compositionFinished)
        #expect(machine.stage == .review)
        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(machine.stage == .endInstructions)
        #expect(effects.contains(.print(copies: 2)))

        effects = machine.handle(.timerFired(try #require(token(effects))))
        #expect(machine.stage == .attract)
        guard case .sessionFinished(let summary)? = effects.last else { Issue.record("no summary"); return }
        #expect(summary.result == .completed)
        #expect(summary.photosTaken == 2)
        #expect(summary.printCopies == 2)
    }

    @Test func testStaleTimersAreIgnored() throws {
        var machine = SessionMachine(settings: settings())
        let first = try #require(token(machine.handle(.touch)))
        _ = machine.handle(.timerFired(first))
        let stage = machine.stage
        let result1 = machine.handle(.timerFired(first))
        #expect(result1 == [])
        #expect(machine.stage == stage)
    }

    @Test func testCaptureFailureRetriesThenEndsSession() throws {
        var s = settings(photos: 1)
        s.countdownMode = .none
        var machine = SessionMachine(settings: s)
        let effects = machine.handle(.touch)
        let result2 = machine.handle(.timerFired(try #require(token(effects))))
        #expect(result2 == [.pauseLiveView, .capture(photo: 1)])

        let retry = machine.handle(.captureFailed(photo: 1, reason: "busy"))
        #expect(retry.contains(.capture(photo: 1)))
        #expect(machine.retakesUsed == 1)

        let end = machine.handle(.captureFailed(photo: 1, reason: "busy"))
        #expect(machine.stage == .attract)
        guard case .sessionFinished(let summary)? = end.last else { Issue.record("no summary"); return }
        #expect(summary.result == .failed)
    }

    @Test func testRetakeFromReviewRestartsCapture() throws {
        var s = settings(photos: 1)
        s.countdownMode = .none
        var machine = SessionMachine(settings: s)
        var effects = machine.handle(.touch)
        _ = machine.handle(.timerFired(try #require(token(effects))))
        effects = machine.handle(.captureSucceeded(photo: 1))
        effects = machine.handle(.timerFired(try #require(token(effects))))
        _ = machine.handle(.compositionFinished)
        #expect(machine.stage == .review)

        effects = machine.handle(.command(.retake))
        #expect(effects.first == .discardPhotos)
        #expect(machine.stage == .takePhoto(1))
        // No retakes left.
        _ = machine.handle(.captureSucceeded(photo: 1))
        #expect(machine.retakesUsed == 1)
    }

    @Test func testCopiesPromptClampsToMaximum() throws {
        var s = settings(photos: 1)
        s.countdownMode = .none
        s.reviewEnabled = false
        s.copiesPrompt = true
        s.maxCopies = 3
        var machine = SessionMachine(settings: s)
        var effects = machine.handle(.touch)
        _ = machine.handle(.timerFired(try #require(token(effects))))
        effects = machine.handle(.captureSucceeded(photo: 1))
        _ = machine.handle(.timerFired(try #require(token(effects))))
        _ = machine.handle(.compositionFinished)
        #expect(machine.stage == .copiesPrompt)
        effects = machine.handle(.copiesChosen(9))
        #expect(effects.contains(.print(copies: 3)))
    }

    @Test func testCreditsGateSessionStart() {
        var s = settings()
        s.creditsRequiredToStart = 2
        var machine = SessionMachine(settings: s)
        let result3 = machine.handle(.touch)
        #expect(result3 == [.insufficientCredits(have: 0, need: 2)])
        _ = machine.handle(.command(.addCredit))
        _ = machine.handle(.command(.addCredit))
        let effects = machine.handle(.command(.startSession))
        #expect(effects.contains(.sessionStarted))
        #expect(effects.contains(.creditsChanged(0)))
    }

    @Test func testCancelReturnsToAttract() throws {
        var machine = SessionMachine(settings: settings())
        let effects = machine.handle(.touch)
        _ = machine.handle(.timerFired(try #require(token(effects))))
        let cancel = machine.handle(.command(.cancelSession))
        #expect(machine.stage == .attract)
        guard case .sessionFinished(let summary)? = cancel.last else { Issue.record("no summary"); return }
        #expect(summary.result == .cancelled)
    }

    @Test func testColorCommandsAndSettingsLock() {
        var machine = SessionMachine(settings: settings())
        let result4 = machine.handle(.command(.sepia))
        #expect(result4 == [.colorEffectChanged(.sepia)])
        _ = machine.handle(.touch)
        let result5 = machine.updateSettings(BoothSettings())
        #expect(!result5)
    }

    @Test func testOutOfServiceBlocksStart() {
        var machine = SessionMachine(settings: settings())
        _ = machine.handle(.setOutOfService(reason: "Paper out"))
        #expect(machine.stage == .outOfService(reason: "Paper out"))
        let result6 = machine.handle(.touch)
        #expect(result6 == [])
        _ = machine.handle(.setOutOfService(reason: nil))
        #expect(machine.stage == .attract)
    }
}
