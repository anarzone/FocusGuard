import Darwin
import Foundation

/// Listens on a Unix socket for browser helpers (one per browser profile
/// with the extension) and moves framed messages in and out. Everything runs
/// on the main queue: the traffic is a few small JSON messages a second.
@MainActor
final class BrowserSocketServer {
    struct ClientID: Hashable, CustomStringConvertible {
        let raw: Int
        var description: String { "client#\(raw)" }
    }

    var onConnect: ((ClientID) -> Void)?
    var onMessage: ((ClientID, Data) -> Void)?
    var onDisconnect: ((ClientID) -> Void)?

    let path: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]
    private var nextID = 1

    /// A client that stops reading gets dropped rather than buffered forever.
    private static let maxPendingBytes = 4 * 1024 * 1024

    private final class Client {
        let fd: Int32
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var inbox = Data()
        var outbox = Data()
        /// Sources not yet cancelled; the descriptor closes once none are
        /// left, never under a source that's still running.
        private var liveSources = 0

        init(fd: Int32) {
            self.fd = fd
        }

        func sourceStarted() { liveSources += 1 }

        func sourceCancelled() {
            liveSources -= 1
            if liveSources == 0 { close(fd) }
        }
    }

    init(path: String) {
        self.path = path
    }

    var isListening: Bool { listenFD >= 0 }
    var clientIDs: [ClientID] { Array(clients.keys) }

    enum ServerError: Error {
        case socket(Int32), bind(Int32), listen(Int32), pathTooLong
    }

    func start() throws {
        guard listenFD < 0 else { return }
        guard path.utf8.count <= BrowserSocketLocation.maxPathBytes else { throw ServerError.pathTooLong }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        // A socket left by a crash or an earlier copy of the app.
        unlink(path)
        var addr = BrowserSocketLocation.address(for: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ServerError.bind(err)
        }
        // Only this user can connect.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ServerError.listen(err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        for id in Array(clients.keys) { drop(id, notify: false) }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(path)
        }
    }

    func send(_ payload: Data, to id: ClientID) {
        guard let client = clients[id] else { return }
        client.outbox.append(NativeMessageFraming.frame(payload))
        guard client.outbox.count <= Self.maxPendingBytes else {
            drop(id)
            return
        }
        flush(id)
    }

    // MARK: - Accepting

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }  // EAGAIN: nothing more waiting
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            // A helper that went away must not kill the app with SIGPIPE.
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let id = ClientID(raw: nextID)
            nextID += 1
            let client = Client(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.readAvailable(id) }
            }
            source.setCancelHandler {
                MainActor.assumeIsolated { client.sourceCancelled() }
            }
            client.readSource = source
            client.sourceStarted()
            clients[id] = client
            source.resume()
            onConnect?(id)
        }
    }

    // MARK: - Reading

    private func readAvailable(_ id: ClientID) {
        guard let client = clients[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(client.fd, &chunk, chunk.count)
            if n > 0 {
                client.inbox.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                drop(id)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
            drop(id)
            return
        }
        let frames: [Data]
        do {
            frames = try NativeMessageFraming.takeFrames(from: &client.inbox)
        } catch {
            drop(id)
            return
        }
        for frame in frames {
            onMessage?(id, frame)
            // The handler may have dropped this client.
            if clients[id] == nil { return }
        }
    }

    // MARK: - Writing

    private func flush(_ id: ClientID) {
        guard let client = clients[id] else { return }
        while !client.outbox.isEmpty {
            let written = client.outbox.withUnsafeBytes { buffer in
                write(client.fd, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                client.outbox.removeFirst(written)
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
            drop(id)
            return
        }
        if client.outbox.isEmpty {
            client.writeSource?.cancel()
            client.writeSource = nil
        } else if client.writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.flush(id) }
            }
            source.setCancelHandler {
                MainActor.assumeIsolated { client.sourceCancelled() }
            }
            client.sourceStarted()
            source.resume()
            client.writeSource = source
        }
    }

    private func drop(_ id: ClientID, notify: Bool = true) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.writeSource?.cancel()
        client.writeSource = nil
        client.readSource?.cancel()  // the last cancel closes the descriptor
        client.readSource = nil
        if notify { onDisconnect?(id) }
    }
}
