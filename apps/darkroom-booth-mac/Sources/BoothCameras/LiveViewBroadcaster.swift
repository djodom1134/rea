import CoreGraphics
import Foundation

/// Fans live view frames out to every `liveView()` stream, newest frame only,
/// and drops frames while paused.
final class LiveViewBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<CGImage>.Continuation] = [:]
    private var paused = false

    func stream() -> AsyncStream<CGImage> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
            }
        }
    }

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    var hasSubscribers: Bool { lock.withLock { !subscribers.isEmpty } }

    func yield(_ frame: CGImage) {
        let targets = lock.withLock { paused ? [] : Array(subscribers.values) }
        for target in targets { target.yield(frame) }
    }

    func finishAll() {
        let targets = lock.withLock { () -> [AsyncStream<CGImage>.Continuation] in
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for target in targets { target.finish() }
    }
}
