import BoothHardware
import Darwin
import Foundation

/// How to reach the CUPS scheduler. macOS's cupsd listens on a local domain
/// socket by default and only opens TCP port 631 when printer sharing or
/// remote administration is on, so the socket is the default.
public enum CUPSConnection: Equatable, Sendable {
    case domainSocket(path: String)
    case http(URL)

    public static let macOSSocketPath = "/private/var/run/cupsd"

    /// Honours `CUPS_SERVER` the way the CUPS tools do: a path is a domain
    /// socket, anything else is a host (optionally `host:port`).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CUPSConnection {
        guard let server = environment["CUPS_SERVER"]?.trimmingCharacters(in: .whitespaces), !server.isEmpty else {
            return .domainSocket(path: macOSSocketPath)
        }
        if server.hasPrefix("/") { return .domainSocket(path: server) }
        let hostAndPort = server.contains(":") ? server : "\(server):631"
        return URL(string: "http://\(hostAndPort)").map(CUPSConnection.http) ?? .domainSocket(path: macOSSocketPath)
    }
}

/// One HTTP/1.1 POST over a Unix domain socket, which URLSession cannot do.
enum DomainSocketHTTP {
    static func post(socketPath: String, path: String, contentType: String, body: Data,
                     timeoutSeconds: Int = 15) async throws -> (status: Int, body: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let raw = try exchange(socketPath: socketPath, request: request(path: path, contentType: contentType, body: body),
                                           timeoutSeconds: timeoutSeconds)
                    return try HTTPResponseParser.parse(raw)
                })
            }
        }
    }

    static func request(path: String, contentType: String, body: Data) -> Data {
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func exchange(socketPath: String, request: Data, timeoutSeconds: Int) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("socket", errno) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw PrintError.submitFailed("CUPS socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw failure("connect to \(socketPath)", errno) }

        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("write", errno)
                }
                offset += written
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read", errno)
            }
            if count == 0 { break }
            response.append(contentsOf: chunk[0 ..< count])
        }
        return response
    }

    private static func failure(_ step: String, _ code: Int32) -> PrintError {
        .submitFailed("CUPS \(step) failed: \(String(cString: strerror(code)))")
    }
}

/// Parses a complete HTTP/1.1 response, de-chunking the body when needed.
enum HTTPResponseParser {
    static func parse(_ data: Data) throws -> (status: Int, body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            throw PrintError.submitFailed("CUPS sent an incomplete HTTP response")
        }
        let head = String(decoding: data[data.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw PrintError.submitFailed("CUPS sent a malformed status line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[headerEnd.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let length = headers["content-length"].flatMap(Int.init), length <= body.count {
            body = body.prefix(length)
        }
        return (status, body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index ..< data.endIndex) else {
                throw PrintError.submitFailed("CUPS sent a truncated chunked body")
            }
            let sizeText = String(decoding: data[index ..< lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                throw PrintError.submitFailed("CUPS sent a malformed chunk size")
            }
            if size == 0 { return result }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else {
                throw PrintError.submitFailed("CUPS sent a truncated chunk")
            }
            let end = data.index(start, offsetBy: size)
            result.append(data[start ..< end])
            index = data.index(end, offsetBy: 2)
        }
    }
}
