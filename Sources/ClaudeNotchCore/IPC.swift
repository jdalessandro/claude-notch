import Darwin
import Foundation

// MARK: - Low-level helpers (all bounded by deadlines: nothing here may block forever)

func makeAddr(_ path: String) -> (sockaddr_un, socklen_t)? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= cap else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
    }
    return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
}

private func remainingMs(until deadline: Date) -> Int32 {
    Int32(max(0, min(Double(Int32.max), deadline.timeIntervalSinceNow * 1000)))
}

private func setNonBlocking(_ fd: Int32) {
    let f = fcntl(fd, F_GETFL, 0)
    if f >= 0 { _ = fcntl(fd, F_SETFL, f | O_NONBLOCK) }
}

/// Reads until the first newline (or EOF), in large chunks, within one total deadline.
/// Returns nil on timeout with no complete message, on error, or when the message exceeds `maxBytes`.
func readMessage(
    fd: Int32, deadline initialDeadline: Date, extendBy window: TimeInterval = 0, hardDeadline: Date? = nil, maxBytes: Int = 8_000_000
) -> Data? {
    var deadline = initialDeadline
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, remainingMs(until: deadline))
        if r < 0 { if errno == EINTR { continue }; return nil }
        if r == 0 { return nil }  // total deadline hit
        let n = read(fd, &buf, buf.count)
        if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; return nil }
        if n == 0 { return out.isEmpty ? nil : out }  // EOF: whatever we have
        if let nl = buf[0..<n].firstIndex(of: 0x0A) {
            out.append(contentsOf: buf[0..<nl])
            return out
        }
        out.append(contentsOf: buf[0..<n])
        if out.count > maxBytes { return nil }
        // A client making real progress (a sizeable chunk) earns more time, up to a hard cap; a trickle of tiny
        // writes does not, so it can't hold up everything queued behind it.
        if window > 0, n >= 16 * 1024, let hard = hardDeadline {
            deadline = min(hard, max(deadline, Date().addingTimeInterval(window)))
        }
    }
}

/// Writes everything within a total deadline; false if the peer is not draining or has gone.
func writeAll(fd: Int32, _ data: Data, deadline initialDeadline: Date, extendBy window: TimeInterval = 0, hardDeadline: Date? = nil) -> Bool
{
    var sent = 0
    var deadline = initialDeadline
    return data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
        guard let base = p.baseAddress else { return true }
        while sent < data.count {
            let n = write(fd, base + sent, data.count - sent)
            if n > 0 {
                sent += n
                // A peer that keeps draining earns more time (up to a hard cap); a stuck one does not.
                if window > 0, n >= 16 * 1024, let hard = hardDeadline {
                    deadline = min(hard, max(deadline, Date().addingTimeInterval(window)))
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, remainingMs(until: deadline)) <= 0 { return false }
                continue
            }
            return false
        }
        return true
    }
}

// MARK: - Client (used by claude-notch-hook)

public enum NotchClient {
    /// Budget for connect + write. The hook runs inside the user's Claude session, so a wedged or absent
    /// app must cost at most this long.
    public static let sendBudget: TimeInterval = 1.0
    /// Cap for a large message that keeps being accepted; tiny payloads never get near it.
    public static let sendHardLimit: TimeInterval = 20.0

    /// Sends one envelope. Returns the app's reply when `env.expectsReply`, else nil.
    /// Never throws and never blocks longer than `sendBudget` (plus `replyTimeoutSec` when a reply is awaited).
    public static func send(_ env: HookEnvelope, replyTimeoutSec: Double = 0, path: String = Paths.socketPath) -> HookReply? {
        guard let (addr, len) = makeAddr(path), let line = try? env.encodedLine() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)
        let deadline = Date().addingTimeInterval(sendBudget)

        var a = addr
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, remainingMs(until: deadline)) > 0 else { return nil }
            var err: Int32 = 0
            var elen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen)
            guard err == 0 else { return nil }
        }
        guard writeAll(fd: fd, line, deadline: deadline, extendBy: sendBudget, hardDeadline: Date().addingTimeInterval(sendHardLimit))
        else { return nil }
        guard env.expectsReply else { return nil }

        let replyDeadline = Date().addingTimeInterval(max(replyTimeoutSec, 0))
        guard let data = readMessage(fd: fd, deadline: replyDeadline), let reply = try? JSONDecoder().decode(HookReply.self, from: data)
        else { return nil }
        return reply
    }

    /// True when something is already accepting connections on `path`.
    static func isServerListening(path: String) -> Bool {
        guard let (addr, len) = makeAddr(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd)
        var a = addr
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return rc == 0 || errno == EINPROGRESS || errno == EAGAIN
    }
}

// MARK: - Server (used by the app)

/// Handle to answer a blocked hook. Owns the connection: the descriptor is closed in exactly one place
/// (the watcher's cancel handler), whether the user answered, the hook went away, or the handle is dropped.
public final class ReplyHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let fd: Int32
    private var watcher: DispatchSourceRead?
    public var onClose: (@Sendable () -> Void)?

    fileprivate init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        let w = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        w.setCancelHandler { close(fd) }
        watcher = w
        // Fires when the hook closes its end (timeout, Ctrl-C) while we wait for the human.
        w.setEventHandler { [weak self] in
            // Drain and discard anything the peer sends (a hook sends nothing after its request), so stray
            // bytes can never mask the EOF that tells us the hook went away.
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 { continue }
                if n == 0 || (errno != EAGAIN && errno != EINTR) { self?.peerClosed() }
                return
            }
        }
        w.resume()
    }

    deinit { watcher?.cancel() }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    /// Delivers the decision once. Later calls (and calls after the hook left) are harmless no-ops.
    public func send(_ reply: HookReply) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let w = watcher
        lock.unlock()
        if let d = try? JSONEncoder().encode(reply) {
            _ = writeAll(fd: fd, d + Data("\n".utf8), deadline: Date().addingTimeInterval(1))
        }
        w?.cancel()  // closes the fd
    }

    fileprivate func peerClosed() {
        lock.lock()
        let was = finished
        finished = true
        let w = watcher
        lock.unlock()
        guard !was else { return }
        w?.cancel()
        onClose?()
    }
}

public final class NotchServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEnvelope, ReplyHandle?) -> Void
    /// Total time a connection gets to deliver its message. A silent or trickling client costs at most this
    /// much before later events are released.
    static let readBudget: TimeInterval = 0.3
    /// Upper bound for a message that keeps making progress (large but steady uploads).
    static let readHardLimit: TimeInterval = 20

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "claude-notch.accept")
    private let readQueue = DispatchQueue(label: "claude-notch.read", attributes: .concurrent)
    private let deliverQueue = DispatchQueue(label: "claude-notch.deliver")  // serial: the single place handlers run

    // Connections are read concurrently but delivered strictly in accept order.
    private let orderLock = NSLock()
    private var nextAccept = 0
    private var nextDeliver = 0
    private var ready: [Int: (@Sendable () -> Void)?] = [:]

    public init(path: String = Paths.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        // Don't steal the socket from a running instance.
        if NotchClient.isServerListening(path: path) { throw POSIXError(.EADDRINUSE) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(path)
        guard let (addr, len) = makeAddr(path) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var a = addr
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0, listen(fd, 256) == 0 else {
            let e = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        chmod(path, 0o600)  // only this user can talk to the island
        setNonBlocking(fd)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    /// Accepts everything currently queued (a burst arrives as one readiness event).
    private func acceptPending() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }  // EAGAIN: drained
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setNonBlocking(c)
            orderLock.lock()
            let seq = nextAccept
            nextAccept += 1
            orderLock.unlock()
            readQueue.async { [weak self] in self?.serve(c, seq: seq) }
        }
    }

    private func serve(_ c: Int32, seq: Int) {
        let start = Date()
        let line = readMessage(
            fd: c, deadline: start.addingTimeInterval(Self.readBudget), extendBy: Self.readBudget,
            hardDeadline: start.addingTimeInterval(Self.readHardLimit))
        guard let line, let env = try? HookEnvelope.decode(line) else {
            close(c)
            finish(seq: seq, nil)
            return
        }
        guard env.expectsReply else {
            close(c)
            finish(seq: seq) { [handler] in handler(env, nil) }
            return
        }
        let handle = ReplyHandle(fd: c, queue: readQueue)
        finish(seq: seq) { [handler] in handler(env, handle) }
    }

    /// Marks `seq` ready and hands every now-contiguous message to the single serial delivery queue.
    /// The enqueue happens under the lock so batches can never interleave or invert.
    private func finish(seq: Int, _ work: (@Sendable () -> Void)?) {
        orderLock.lock()
        defer { orderLock.unlock() }
        ready[seq] = .some(work)
        var batch: [@Sendable () -> Void] = []
        while let item = ready[nextDeliver] {
            ready[nextDeliver] = nil
            nextDeliver += 1
            if let w = item { batch.append(w) }
        }
        if !batch.isEmpty { deliverQueue.async { for w in batch { w() } } }
    }
}
