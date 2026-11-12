import Foundation
import LexisTestSupport
import XCTest

/// Exercises `RangeHTTPServer.serveMeasuredProfile` with a raw socket client
/// under direct control of connection reuse, so the server's own rate
/// modelling is proven before anything in the player reads through it.
final class MeasuredProfileServerTests: RealtimeTestCase {
    private func fixtureBody(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count { bytes[index] = UInt8(truncatingIfNeeded: index) }
        return Data(bytes)
    }

    private func connectSocket(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    /// One Range GET over an already-connected socket: the body bytes and the
    /// moment the response's first byte arrived.
    private func rangeGet(_ fd: Int32, start: Int, end: Int) throws -> (body: Data, firstByte: Date) {
        let request = "GET /clip HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=\(start)-\(end)\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        let terminator = Data("\r\n\r\n".utf8)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var firstByte: Date?
        while received.range(of: terminator) == nil {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { throw POSIXError(.EIO) }
            if firstByte == nil { firstByte = Date() }
            received.append(contentsOf: chunk[0..<count])
        }
        let headerRange = try XCTUnwrap(received.range(of: terminator))
        let head = String(decoding: received[..<headerRange.lowerBound], as: UTF8.self)
        let length = header("Content-Length", in: head).flatMap(Int.init) ?? 0
        var body = received[headerRange.upperBound...]
        while body.count < length {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { throw POSIXError(.EIO) }
            body.append(contentsOf: chunk[0..<count])
        }
        return (Data(body.prefix(length)), try XCTUnwrap(firstByte))
    }

    private func header(_ name: String, in head: String) -> String? {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func testAFreshConnectionPerRequestSustainsTheColdRate() throws {
        let bodySize = 16 * 1024 * 1024
        let server = try RangeHTTPServer(body: fixtureBody(bodySize))
        defer { server.stop() }
        server.serveMeasuredProfile(MeasuredStreamProfile(), coldFirstConnection: false)

        let requestSize = 256 * 1024
        var totalBytes = 0
        var offset = 0
        let start = Date()
        while totalBytes < 4 * 1024 * 1024 {
            let fd = try connectSocket(port: server.port)
            defer { close(fd) }
            let end = min(offset + requestSize, bodySize) - 1
            let (body, _) = try rangeGet(fd, start: offset, end: end)
            totalBytes += body.count
            offset += requestSize
        }
        let elapsed = Date().timeIntervalSince(start)
        let sustained = Double(totalBytes) * 8 / elapsed
        let profile = MeasuredStreamProfile()
        XCTAssertGreaterThanOrEqual(sustained, profile.coldPerRequestBitsPerSecond / 2)
        XCTAssertLessThanOrEqual(sustained, profile.coldPerRequestBitsPerSecond * 2)
        XCTAssertLessThan(sustained, profile.fileBitsPerSecond)
        XCTAssertGreaterThan(server.connectionCount, 1)
    }

    func testAReusedConnectionClearsTheFileBitrate() throws {
        let bodySize = 16 * 1024 * 1024
        let server = try RangeHTTPServer(body: fixtureBody(bodySize))
        defer { server.stop() }
        server.serveMeasuredProfile(MeasuredStreamProfile(), coldFirstConnection: false)
        let fd = try connectSocket(port: server.port)
        defer { close(fd) }
        // Warms the connection past its one cold-per-connection request: the
        // measurement window below only ever sees the reused rate.
        _ = try rangeGet(fd, start: 0, end: 64 * 1024 - 1)

        let requestSize = 2 * 1024 * 1024
        var totalBytes = 0
        var offset = 64 * 1024
        let start = Date()
        while totalBytes < 4 * 1024 * 1024 {
            let end = min(offset + requestSize, bodySize) - 1
            let (body, _) = try rangeGet(fd, start: offset, end: end)
            totalBytes += body.count
            offset += requestSize
        }
        let elapsed = Date().timeIntervalSince(start)
        let sustained = Double(totalBytes) * 8 / elapsed
        XCTAssertGreaterThanOrEqual(sustained, MeasuredStreamProfile().fileBitsPerSecond)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testTheColdFirstConnectionCostsItsMeasuredDelayOnce() throws {
        let server = try RangeHTTPServer(body: fixtureBody(1024 * 1024))
        defer { server.stop() }
        let measured = MeasuredStreamProfile()
        let profile = measured.scaled(by: 1.0 / measured.coldConnectSeconds)
        server.serveMeasuredProfile(profile, coldFirstConnection: true)

        let start = Date()
        let fd = try connectSocket(port: server.port)
        defer { close(fd) }
        let (_, firstByte) = try rangeGet(fd, start: 0, end: 1023)
        let elapsed = firstByte.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, profile.coldConnectSeconds * 0.9)
    }
}
