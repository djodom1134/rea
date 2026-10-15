import BoothCore
import Foundation

/// A source of booth commands: Phidgets inputs, RS-232 modem-status buttons,
/// keyboard, web buttons. Inputs map to command names as in the Windows app's
/// `DeviceControl\inputs.json`.
public protocol TriggerInput: AnyObject, Sendable {
    var name: String { get }
    func start() async throws -> AsyncStream<BoothCommand>
    func stop() async
}
