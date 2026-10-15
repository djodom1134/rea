@testable import BoothPrinting
import Foundation
import Testing

@Suite struct CUPSConnectionTests {
    @Test func defaultsToTheMacOSDomainSocket() {
        #expect(CUPSConnection.fromEnvironment([:]) == .domainSocket(path: "/private/var/run/cupsd"))
        #expect(CUPSConnection.fromEnvironment(["CUPS_SERVER": "/tmp/cups.sock"]) == .domainSocket(path: "/tmp/cups.sock"))
        #expect(CUPSConnection.fromEnvironment(["CUPS_SERVER": "printhost"]) == .http(URL(string: "http://printhost:631")!))
        #expect(CUPSConnection.fromEnvironment(["CUPS_SERVER": "printhost:8631"]) == .http(URL(string: "http://printhost:8631")!))
    }

    @Test func requestCarriesLengthAndClosesTheConnection() {
        let text = String(decoding: DomainSocketHTTP.request(path: "/", contentType: "application/ipp", body: Data([1, 2, 3])),
                          as: UTF8.self)
        #expect(text.hasPrefix("POST / HTTP/1.1\r\n"))
        #expect(text.contains("Content-Length: 3\r\n"))
        #expect(text.contains("Connection: close\r\n\r\n"))
    }

    @Test func parsesContentLengthAndChunkedBodies() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: 3\r\n\r\nabcEXTRA".utf8)
        let parsed = try HTTPResponseParser.parse(plain)
        #expect(parsed.status == 200)
        #expect(parsed.body == Data("abc".utf8))

        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\n\r\n".utf8)
        #expect(try HTTPResponseParser.parse(chunked).body == Data("Wikipedia".utf8))

        let error = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect(try HTTPResponseParser.parse(error).status == 403)
    }

    @Test func rejectsTruncatedResponses() {
        #expect(throws: (any Error).self) { try HTTPResponseParser.parse(Data("HTTP/1.1 200 OK\r\nContent".utf8)) }
        let truncated = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nshort".utf8)
        #expect(throws: (any Error).self) { try HTTPResponseParser.parse(truncated) }
    }
}
