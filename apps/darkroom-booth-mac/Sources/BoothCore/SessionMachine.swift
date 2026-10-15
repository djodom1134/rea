import Foundation

/// Inputs to the booth session state machine.
public enum SessionEvent: Equatable, Sendable {
    case command(BoothCommand)
    /// The guest touched the screen or clicked (the default start trigger).
    case touch
    case timerFired(TimerToken)
    case captureSucceeded(photo: Int)
    case captureFailed(photo: Int, reason: String)
    case compositionFinished
    case compositionFailed(reason: String)
    case copiesChosen(Int)
    case setOutOfService(reason: String?)
}

/// Identifies a scheduled timer so stale timers are ignored after a state change.
public struct TimerToken: Hashable, Sendable {
    public let generation: Int
    public init(generation: Int) { self.generation = generation }
}

public enum SessionResult: String, Codable, Sendable {
    case completed
    case cancelled
    case failed
}

/// Per-session statistics, mirroring the columns of the Windows app's
/// `SessionData` table that the session flow itself determines.
public struct SessionSummary: Equatable, Sendable {
    public var result: SessionResult
    public var photosTaken: Int
    public var photoRetakes: Int
    public var colorChoice: ColorEffect
    public var printCopies: Int
    public var stageReached: String
}

/// Side effects the host (UI + hardware) performs on the machine's behalf.
public enum SessionEffect: Equatable, Sendable {
    case scheduleTimer(TimerToken, seconds: Double)
    case sessionStarted
    case playCountdownSound(Int)
    case capture(photo: Int)
    case pauseLiveView
    case resumeLiveView
    /// Compose the output from the captured photos in order.
    case compose(photoCount: Int)
    case discardPhotos
    case print(copies: Int)
    case colorEffectChanged(ColorEffect)
    case creditsChanged(Int)
    case insufficientCredits(have: Int, need: Int)
    case reprintLast
    case sessionFinished(SessionSummary)
}

/// The booth session flow recovered from the Windows app (see
/// docs/reverse-engineering/features.md section 2): attract, get ready,
/// countdown and capture per photo, review/retake, copies prompt, output,
/// thank-you, back to attract. Pure and synchronous so it is fully testable;
/// the host owns timers, cameras and printers.
public struct SessionMachine: Sendable {
    public private(set) var stage: BoothStage = .attract
    public private(set) var settings: BoothSettings
    public private(set) var colorEffect: ColorEffect
    public private(set) var credits = 0
    public private(set) var capturedPhotos = 0
    public private(set) var retakesUsed = 0
    private var copies = 0
    private var timerGeneration = 0
    private var activeTimer: TimerToken?

    public init(settings: BoothSettings) {
        self.settings = settings
        self.colorEffect = settings.defaultColorEffect
    }

    /// Settings changes apply between sessions only.
    public mutating func updateSettings(_ newSettings: BoothSettings) -> Bool {
        guard !stage.isInSession else { return false }
        settings = newSettings
        if !newSettings.keepLastEffect { colorEffect = newSettings.defaultColorEffect }
        return true
    }

    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .touch:
            return stage == .attract ? startSession() : []

        case .command(let command):
            return handle(command)

        case .timerFired(let token):
            guard token == activeTimer else { return [] }
            activeTimer = nil
            return timerFired()

        case .captureSucceeded(let photo):
            guard case .takePhoto(let n) = stage, n == photo else { return [] }
            capturedPhotos = n
            var effects: [SessionEffect] = [.resumeLiveView]
            if n < settings.photosPerSession {
                stage = .afterPhoto(n)
                effects.append(schedule(settings.timing.nextPhotoDelay))
            } else {
                stage = .afterLastPhoto
                effects.append(schedule(settings.timing.lastPhotoDelay))
            }
            return effects

        case .captureFailed(let photo, _):
            guard case .takePhoto(let n) = stage, n == photo else { return [] }
            var effects: [SessionEffect] = [.resumeLiveView]
            if retakesUsed < settings.maxRetakes {
                retakesUsed += 1
                effects += beginPhoto(n)
            } else if capturedPhotos > 0 {
                stage = .afterLastPhoto
                effects.append(schedule(settings.timing.lastPhotoDelay))
            } else {
                effects += finish(.failed)
            }
            return effects

        case .compositionFinished:
            guard stage == .processing else { return [] }
            if settings.reviewEnabled {
                stage = .review
                return [schedule(settings.timing.reviewDelay)]
            }
            return afterReview()

        case .compositionFailed:
            guard stage == .processing else { return [] }
            return finish(.failed)

        case .copiesChosen(let requested):
            guard stage == .copiesPrompt else { return [] }
            return output(copies: min(max(requested, 0), settings.maxCopies))

        case .setOutOfService(let reason):
            guard !stage.isInSession else { return [] }
            if let reason {
                invalidateTimer()
                stage = .outOfService(reason: reason)
            } else if case .outOfService = stage {
                stage = .attract
            }
            return []
        }
    }

    // MARK: - Commands

    private mutating func handle(_ command: BoothCommand) -> [SessionEffect] {
        if let effect = ColorEffect(command: command) {
            colorEffect = effect
            return [.colorEffectChanged(effect)]
        }
        switch command {
        case .startSession:
            return stage == .attract ? startSession() : []
        case .cancelSession:
            return stage.isInSession ? [.resumeLiveView, .discardPhotos] + finish(.cancelled) : []
        case .takePhoto:
            // Skip the rest of the countdown.
            if case .countdown(_, let n) = stage { return capture(n) }
            return []
        case .retake:
            guard stage == .review, retakesUsed < settings.maxRetakes else { return [] }
            retakesUsed += 1
            capturedPhotos = 0
            return [.discardPhotos] + beginPhoto(1)
        case .addCredit:
            credits += 1
            return [.creditsChanged(credits)]
        case .clearCredits:
            credits = 0
            return [.creditsChanged(0)]
        case .reprintLast:
            return stage.isInSession ? [] : [.reprintLast]
        default:
            // Video, burst, graphic lists, print alternates and filters are
            // handled by later milestones.
            return []
        }
    }

    // MARK: - Flow

    private mutating func startSession() -> [SessionEffect] {
        let need = settings.creditsRequiredToStart
        if need > 0 && credits < need {
            return [.insufficientCredits(have: credits, need: need)]
        }
        guard settings.photosPerSession > 0 else { return [] }
        if need > 0 {
            credits -= need
        }
        capturedPhotos = 0
        retakesUsed = 0
        copies = 0
        if !settings.keepLastEffect { colorEffect = settings.defaultColorEffect }
        stage = .getReady
        var effects: [SessionEffect] = [.sessionStarted]
        if need > 0 { effects.append(.creditsChanged(credits)) }
        effects.append(schedule(settings.timing.getReadyDelay))
        return effects
    }

    private mutating func timerFired() -> [SessionEffect] {
        switch stage {
        case .getReady:
            return beginPhoto(1)
        case .countdown(let remaining, let n):
            if remaining > 1 {
                stage = .countdown(remaining: remaining - 1, photo: n)
                return [.playCountdownSound(remaining - 1), schedule(1)]
            }
            return capture(n)
        case .afterPhoto(let n):
            return beginPhoto(n + 1)
        case .afterLastPhoto:
            stage = .processing
            return [.compose(photoCount: capturedPhotos)]
        case .review:
            return afterReview()
        case .copiesPrompt:
            return output(copies: settings.printCopies)
        case .endInstructions:
            return finish(.completed)
        default:
            return []
        }
    }

    private mutating func beginPhoto(_ n: Int) -> [SessionEffect] {
        let seconds = settings.countdownSeconds(beforePhoto: n)
        guard seconds > 0 else { return capture(n) }
        stage = .countdown(remaining: seconds, photo: n)
        return [.playCountdownSound(seconds), schedule(1)]
    }

    private mutating func capture(_ n: Int) -> [SessionEffect] {
        invalidateTimer()
        stage = .takePhoto(n)
        var effects: [SessionEffect] = []
        if settings.liveViewCaptureMode == .pauseToCapture { effects.append(.pauseLiveView) }
        effects.append(.capture(photo: n))
        return effects
    }

    private mutating func afterReview() -> [SessionEffect] {
        if settings.printEnabled && settings.copiesPrompt {
            stage = .copiesPrompt
            return [schedule(settings.timing.copiesPromptDelay)]
        }
        return output(copies: settings.printEnabled ? settings.printCopies : 0)
    }

    private mutating func output(copies requested: Int) -> [SessionEffect] {
        copies = requested
        stage = .endInstructions
        var effects: [SessionEffect] = []
        if requested > 0 { effects.append(.print(copies: requested)) }
        effects.append(schedule(settings.timing.endTextDelay))
        return effects
    }

    private mutating func finish(_ result: SessionResult) -> [SessionEffect] {
        let summary = SessionSummary(
            result: result,
            photosTaken: capturedPhotos,
            photoRetakes: retakesUsed,
            colorChoice: colorEffect,
            printCopies: copies,
            stageReached: stage.legacyLabel
        )
        invalidateTimer()
        stage = .attract
        return [.sessionFinished(summary)]
    }

    private mutating func schedule(_ seconds: Double) -> SessionEffect {
        timerGeneration += 1
        let token = TimerToken(generation: timerGeneration)
        activeTimer = token
        return .scheduleTimer(token, seconds: max(0, seconds))
    }

    private mutating func invalidateTimer() {
        activeTimer = nil
    }
}
