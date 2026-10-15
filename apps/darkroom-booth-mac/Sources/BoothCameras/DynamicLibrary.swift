import BoothHardware
import Darwin
import Foundation

/// A vendor or third-party library loaded at runtime, so the app builds and
/// runs without it and the user supplies it (Homebrew libgphoto2, Canon EDSDK).
/// Handles are never closed: these libraries start threads and register
/// Objective-C classes, which makes unloading unsafe.
final class DynamicLibrary: @unchecked Sendable {
    let path: String
    private let handle: UnsafeMutableRawPointer

    private init(path: String, handle: UnsafeMutableRawPointer) {
        self.path = path
        self.handle = handle
    }

    /// Opens the first candidate that loads. The error lists every attempt.
    static func open(_ name: String, candidates: [String]) -> Result<DynamicLibrary, CameraError> {
        var attempts: [String] = []
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                return .success(DynamicLibrary(path: path, handle: handle))
            }
            let reason = dlerror().map { String(cString: $0) } ?? "not loadable"
            attempts.append(reason)
        }
        return .failure(.backendUnavailable("\(name) not found. Tried: \(attempts.joined(separator: "; "))"))
    }

    func symbol<T>(_ name: String, as type: T.Type = T.self) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw CameraError.backendUnavailable("\(path) has no symbol \(name)")
        }
        return unsafeBitCast(pointer, to: type)
    }
}

/// Where to look for a runtime-loaded library: an explicit override from the
/// environment first, then the standard install locations.
enum LibraryLocator {
    static func candidates(override variable: String, environment: [String: String], binaryInBundle: String? = nil,
                           defaults: [String]) -> [String] {
        var result: [String] = []
        if let value = environment[variable], !value.isEmpty {
            // Accept a framework directory as well as the binary itself.
            if value.hasSuffix(".framework") {
                let name = (value as NSString).lastPathComponent.replacingOccurrences(of: ".framework", with: "")
                result.append((value as NSString).appendingPathComponent(name))
            } else {
                result.append(value)
            }
        }
        if let binaryInBundle { result.append(binaryInBundle) }
        for path in defaults where !result.contains(path) { result.append(path) }
        return result
    }
}
