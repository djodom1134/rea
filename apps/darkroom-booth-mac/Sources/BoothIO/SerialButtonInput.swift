import BoothCore
import BoothHardware
import Darwin
import Foundation

public enum TriggerInputError: Error, Equatable {
    case openFailed(String, String)
    case libraryUnavailable(String)
}

/// Dry-contact buttons on an RS-232 port, as in the Windows app's
/// "Serial Port Setup": DTR (DE-9 pin 4) is asserted and a button bridges it to
/// CD (pin 1), DSR (pin 6), CTS (pin 8) or RI (pin 9). Each line maps to a booth
/// command (`Controls\SerialCommandCD/CTS/DSR/RING`). No serial data is read.
public final class SerialButtonInput: TriggerInput, @unchecked Sendable {
    public enum Line: String, CaseIterable, Codable, Sendable {
        case cd = "CD"
        case cts = "CTS"
        case dsr = "DSR"
        case ring = "RING"

        var mask: Int32 {
            switch self {
            case .cd: return 0x040   // TIOCM_CAR
            case .cts: return 0x020  // TIOCM_CTS
            case .dsr: return 0x100  // TIOCM_DSR
            case .ring: return 0x080 // TIOCM_RNG
            }
        }
    }

    // _IOR('t', 106, int) and _IOW('t', 108, int): the macros are not imported into Swift.
    private static let tiocmget: UInt = 0x4004_746A
    private static let tiocmbis: UInt = 0x8004_746C
    private static let tiocmDTR: Int32 = 0x002

    public let devicePath: String
    public let bindings: [Line: BoothCommand]
    public var name: String { "Serial buttons (\(devicePath))" }

    private let lock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var pollTask: Task<Void, Never>?

    /// - Parameter devicePath: e.g. `/dev/cu.usbserial-A10KXYZ`.
    public init(devicePath: String, bindings: [Line: BoothCommand]) {
        self.devicePath = devicePath
        self.bindings = bindings
    }

    /// Serial ports present now (`/dev/cu.*`).
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/\($0)" }
    }

    public func start() async throws -> AsyncStream<BoothCommand> {
        await stop()
        let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TriggerInputError.openFailed(devicePath, String(cString: strerror(errno))) }
        var dtr = Self.tiocmDTR
        _ = ioctl(fd, Self.tiocmbis, &dtr)
        lock.withLock { fileDescriptor = fd }

        let bindings = self.bindings
        let (stream, continuation) = AsyncStream<BoothCommand>.makeStream()
        let task = Task.detached {
            var previous: Int32 = 0
            while !Task.isCancelled {
                var bits: Int32 = 0
                if ioctl(fd, Self.tiocmget, &bits) != 0 { break }
                for (line, command) in bindings {
                    // Fire on the rising edge only.
                    if bits & line.mask != 0 && previous & line.mask == 0 {
                        continuation.yield(command)
                    }
                }
                previous = bits
                try? await Task.sleep(for: .milliseconds(20))
            }
            continuation.finish()
        }
        lock.withLock { pollTask = task }
        return stream
    }

    public func stop() async {
        let (task, fd) = lock.withLock { () -> (Task<Void, Never>?, Int32) in
            defer {
                pollTask = nil
                fileDescriptor = -1
            }
            return (pollTask, fileDescriptor)
        }
        task?.cancel()
        _ = await task?.value
        if fd >= 0 { close(fd) }
    }
}
