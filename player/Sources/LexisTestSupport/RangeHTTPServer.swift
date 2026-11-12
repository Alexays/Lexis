import Foundation

/// A localhost HTTP server that answers Range requests from an in-memory body.
/// Hermetic: an OS-assigned port, one connection at a time, no keep-alive.
public final class RangeHTTPServer {
    public let port: UInt16
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    private let listener: Int32
    private let body: Data
    /// Every request is refused, as it is with a stale token.
    private let unauthorized: Bool
    private let lock = NSLock()
    /// Signalled once the serve thread is out of its accept loop for good.
    private let finished = DispatchSemaphore(value: 0)
    private var isStopping = false
    private var isFailing = false
    private var isRejecting = false
    private var stall: TimeInterval = 0
    private var bodyStall: TimeInterval = 0
    private var jitterRange: ClosedRange<TimeInterval>?
    private var startedBodyStalls = 0
    private var seenRequests: [String] = []
    /// Set by `serveMeasuredProfile`; nil means the server behaves exactly as
    /// it always has, one connection closed per request.
    private var measuredProfile: MeasuredStreamProfile?
    private var coldFirstConnectionEnabled = false
    private var acceptedConnections = 0

    public init(body: Data, unauthorized: Bool = false) throws {
        self.body = body
        self.unauthorized = unauthorized
        // a local until the end: the setup closures below would otherwise
        // capture a self that is not fully initialized
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &assigned) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        self.listener = listener
        port = UInt16(bigEndian: assigned.sin_port)

        // the semaphore is signalled even if self is gone before the thread
        // runs, so a stop that waits on it can never wait forever
        let thread = Thread { [weak self, finished] in
            defer { finished.signal() }
            self?.serve()
        }
        thread.name = "org.lexis.range-http"
        thread.start()
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        let wasStopping = isStopping
        isStopping = true
        lock.unlock()
        guard !wasStopping else { return }
        // shutdown does not wake a blocked accept on Darwin, it fails
        // ENOTCONN, so the loop is woken with a connection of our own. Waiting
        // for the thread before closing is what keeps it from re-entering
        // accept on an fd number the kernel has already handed to someone else.
        wake()
        finished.wait()
        close(listener)
    }

    /// One connection to our own port, enough to end a blocked accept.
    private func wake() {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(client)
    }

    /// Delays every later response. A stall longer than the client's read
    /// timeout is a server that never answers at all.
    public func stallFromNow(_ seconds: TimeInterval) {
        lock.lock()
        stall = seconds
        lock.unlock()
    }

    /// Sends every later response's head and its first bytes, then holds the
    /// rest back. A client that asked for a range is left blocked inside a read
    /// it has already begun, which no cancellation can reach.
    public func stallBodyFromNow(_ seconds: TimeInterval) {
        lock.lock()
        bodyStall = seconds
        lock.unlock()
    }

    /// How many responses have entered a body stall. Once this moves, the
    /// client that asked for the last one is inside its read.
    public var bodyStalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedBodyStalls
    }

    /// Delays every later response by a random amount in `range`, drawn fresh
    /// per request: a real Plex server's own hiccups, not one clean stall.
    public func jitterFromNow(_ range: ClosedRange<TimeInterval>) {
        lock.lock()
        jitterRange = range
        lock.unlock()
    }

    /// Fails every later request, as a server dying mid-stream does.
    public func failFromNow() {
        lock.lock()
        isFailing = true
        lock.unlock()
    }

    /// Refuses every later request, as a server whose token was revoked does.
    public func rejectFromNow() {
        lock.lock()
        isRejecting = true
        lock.unlock()
    }

    /// Every request head the server saw, in order.
    public var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seenRequests
    }

    /// Serves every later response at `profile`: per-request first-byte
    /// latency derived from whether this connection is fresh (the cold
    /// per-request rate) or reused (the reused rate), and an optional
    /// one-time cold-connect delay on the FIRST connection only. Unlike the
    /// server's default behaviour, a connection stays open across requests,
    /// which is what lets reuse happen at all.
    public func serveMeasuredProfile(_ profile: MeasuredStreamProfile, coldFirstConnection: Bool) {
        lock.lock()
        measuredProfile = profile
        coldFirstConnectionEnabled = coldFirstConnection
        lock.unlock()
    }

    /// How many distinct TCP connections have been accepted since start.
    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedConnections
    }

    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            lock.lock()
            let stopped = isStopping
            lock.unlock()
            if stopped {
                if connection >= 0 { close(connection) }
                return
            }
            if connection < 0 {
                // a signal interrupting accept is not the end of the server
                if errno == EINTR { continue }
                return
            }
            // A kept-alive connection's next request may never come - the
            // client got what it needed and simply holds the socket open.
            // Without a receive timeout this thread would block in recv()
            // forever, and stop()'s own wake-up only reaches a blocked
            // accept(), never a connection already handed out by one.
            var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(
                connection, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            )
            // A client that seeks drops the response it was reading, and a
            // send into that closed socket must fail rather than raise SIGPIPE
            // and kill the test process.
            var noSigpipe: Int32 = 1
            setsockopt(
                connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            lock.lock()
            acceptedConnections += 1
            let isFirstConnection = acceptedConnections == 1
            lock.unlock()
            var requestsOnThisConnection = 0
            while let request = readHead(connection) {
                lock.lock()
                seenRequests.append(request)
                let profile = measuredProfile
                let stopping = isStopping
                lock.unlock()
                if stopping { break }
                requestsOnThisConnection += 1
                let freshConnection = requestsOnThisConnection == 1
                let coldFirstConnectionDelay = isFirstConnection && freshConnection && coldFirstConnectionEnabled
                deliver(
                    response(
                        to: request, freshConnection: freshConnection,
                        coldFirstConnectionDelay: coldFirstConnectionDelay
                    ),
                    over: connection
                )
                // Only the measured-profile mode keeps a connection open past
                // its first request; every other mode's behaviour, and every
                // test that relies on it, stays exactly as it was.
                guard profile != nil else { break }
            }
            close(connection)
        }
    }

    /// The request head, up to the blank line that ends it.
    private func readHead(_ connection: Int32) -> String? {
        let terminator = Data("\r\n\r\n".utf8)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while received.range(of: terminator) == nil {
            let count = recv(connection, &chunk, chunk.count, 0)
            if count <= 0 { return nil }
            received.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }

    private func response(
        to request: String, freshConnection: Bool, coldFirstConnectionDelay: Bool
    ) -> Data {
        lock.lock()
        let failing = isFailing
        let rejecting = isRejecting
        let stall = self.stall
        let jitterRange = self.jitterRange
        let profile = measuredProfile
        lock.unlock()
        if stall > 0 { Thread.sleep(forTimeInterval: stall) }
        if let jitterRange { Thread.sleep(forTimeInterval: TimeInterval.random(in: jitterRange)) }
        if coldFirstConnectionDelay, let profile { Thread.sleep(forTimeInterval: profile.coldConnectSeconds) }
        if unauthorized || rejecting { return status(401) }
        if failing { return status(500) }
        guard let range = header("Range", in: request)?.replacingOccurrences(of: "bytes=", with: ""),
              let dash = range.firstIndex(of: "-")
        else {
            return status(400)
        }
        let start = Int(range[range.startIndex..<dash]) ?? 0
        let asked = Int(range[range.index(after: dash)...]) ?? body.count - 1
        let end = min(asked, body.count - 1)
        guard start <= end, start < body.count else { return status(416) }
        let slice = body[start...end]
        if let profile {
            let rate = freshConnection ? profile.coldPerRequestBitsPerSecond : profile.reusedBitsPerSecond
            Thread.sleep(forTimeInterval: Double(slice.count) * 8 / rate)
        }
        let head = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
            + "Content-Length: \(slice.count)\r\n"
            + "Connection: \(profile != nil ? "keep-alive" : "close")\r\n\r\n"
        var response = Data(head.utf8)
        response.append(slice)
        return response
    }

    private func status(_ code: Int) -> Data {
        Data("HTTP/1.1 \(code) x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private func header(_ name: String, in request: String) -> String? {
        for line in request.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Enough to carry the head and leave the client waiting on a body it has
    /// been promised a Content-Length for.
    private static let stallPrefix = 512

    private func deliver(_ response: Data, over connection: Int32) {
        lock.lock()
        let stall = bodyStall
        lock.unlock()
        guard stall > 0, response.count > RangeHTTPServer.stallPrefix else {
            write(connection, response)
            return
        }
        write(connection, response.prefix(RangeHTTPServer.stallPrefix))
        lock.lock()
        startedBodyStalls += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: stall)
        write(connection, response.dropFirst(RangeHTTPServer.stallPrefix))
    }

    private func write(_ connection: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = send(connection, bytes.baseAddress! + sent, bytes.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
