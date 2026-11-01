import Darwin
import Foundation

/// "Focusing" under the user's name in Discord while a session runs
/// (Settings › Integrations › Status in Slack and Discord, Pro).
///
/// Discord has no web API for a user's status, so this talks to the Discord
/// app on this Mac the way games show Rich Presence: over its local IPC
/// socket (`DiscordIPC`). Nothing signs in and nothing leaves the Mac.
/// Discord drops the activity when the socket closes; FocusGuard clears it
/// first. While there's something to show it checks every 30 seconds, so
/// opening Discord mid-session (or Discord restarting) brings it back.
///
/// Every socket call runs on its own queue; `show` returns at once.
final class DiscordPresence: @unchecked Sendable {
    /// FocusGuard's Discord application ID (Info.plist `FGDiscordApplicationID`);
    /// nil hides Discord.
    let applicationID: String?
    var isConfigured: Bool { applicationID != nil }

    private let directories: [String]
    private let retryInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.anar.focusguard.discord")
    /// Queue-only state: what should show, what Discord has from this
    /// connection, and the connection.
    private var wanted: DiscordIPC.Activity?
    private var shown: DiscordIPC.Activity?
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?

    init(applicationID: String? = DiscordPresence.bundledApplicationID,
         directories: [String] = DiscordIPC.directories(ProcessInfo.processInfo.environment),
         retryInterval: TimeInterval = 30) {
        self.applicationID = applicationID
        self.directories = directories
        self.retryInterval = retryInterval
    }

    deinit {
        timer?.cancel()
        if fd >= 0 { close(fd) }
    }

    static var bundledApplicationID: String? { StatusSync.infoValue("FGDiscordApplicationID") }

    /// Shows `activity`, or clears it with nil.
    func show(_ activity: DiscordIPC.Activity?) {
        guard isConfigured else { return }
        queue.async {
            self.wanted = activity
            self.sync()
        }
    }

    /// Waits until everything asked so far has been sent; for tests.
    func settle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: - On the queue

    private func sync() {
        guard let wanted else {
            if fd >= 0 {
                _ = sendFrame(DiscordIPC.Frame(opcode: .frame, payload: DiscordIPC.setActivity(nil, pid: getpid())))
                disconnect()
            }
            timer?.cancel()
            timer = nil
            return
        }
        if fd >= 0 && !isAlive() { disconnect() }
        if fd < 0 { connect() }
        if fd >= 0 && shown != wanted {
            guard sendFrame(DiscordIPC.Frame(opcode: .frame, payload: DiscordIPC.setActivity(wanted, pid: getpid()))),
                  let answer = reply() else {
                disconnect()
                return startTimer()
            }
            // An error leaves it to the next check.
            if !DiscordIPC.isError(answer) { shown = wanted }
        }
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + retryInterval, repeating: retryInterval)
        source.setEventHandler { [weak self] in self?.sync() }
        source.resume()
        timer = source
    }

    /// Opens the first socket that answers, says hello and waits for READY.
    private func connect() {
        guard let applicationID else { return }
        for path in directories.flatMap(DiscordIPC.socketPaths(in:)) {
            guard let opened = Self.openSocket(path) else { continue }
            fd = opened
            shown = nil
            if sendFrame(DiscordIPC.Frame(opcode: .handshake, payload: DiscordIPC.handshake(applicationID: applicationID))),
               let ready = reply(), DiscordIPC.isReady(ready) {
                return
            }
            disconnect()
        }
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        shown = nil
    }

    /// Whether Discord still has the other end; answers its pings on the way.
    private func isAlive() -> Bool {
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if peeked == 0 { return false }
        if peeked < 0 { return errno == EAGAIN || errno == EWOULDBLOCK }
        return reply() != nil
    }

    private func sendFrame(_ frame: DiscordIPC.Frame) -> Bool {
        let data = DiscordIPC.encode(frame)
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// The next frame from Discord, past any pings; nil when it closed the
    /// socket, sent garbage or took longer than the 2-second timeout.
    private func reply() -> DiscordIPC.Frame? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            switch Result(catching: { try DiscordIPC.decode(buffer) }) {
            case .failure:
                return nil
            case .success(let decoded?):
                buffer.removeFirst(decoded.length)
                switch decoded.frame.opcode {
                case .ping:
                    guard sendFrame(DiscordIPC.Frame(opcode: .pong, payload: decoded.frame.payload)) else { return nil }
                case .close:
                    return nil
                default:
                    return decoded.frame
                }
            case .success(nil):
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
    }

    /// A connected socket at `path`, with 2-second timeouts; nil when
    /// nothing listens there.
    private static func openSocket(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let handle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(handle)
            return nil
        }
        return handle
    }
}

/// Discord's local IPC, as its RPC docs and the official discord-rpc
/// library have it. A socket `discord-ipc-0` to `-9` in the first of
/// `XDG_RUNTIME_DIR`, `TMPDIR`, `TMP`, `TEMP` and `/tmp`. Each message is a
/// frame: the opcode and the payload's length as little-endian UInt32s,
/// then the JSON. The client says hello (opcode 0, `{v: 1, client_id}`),
/// Discord answers with a READY dispatch, then commands go as opcode 1.
enum DiscordIPC {
    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    struct Frame: Equatable {
        let opcode: Opcode
        let payload: Data
    }

    enum DecodeError: Error {
        case unknownOpcode(UInt32)
        case tooLong(Int)
    }

    /// What Discord shows: "Playing FocusGuard · Focusing", with the time
    /// left (or, open-ended, the time so far).
    struct Activity: Equatable {
        var details: String
        var start: Date?
        var end: Date?
    }

    /// The RPC version the handshake asks for.
    static let version = 1
    /// Discord's library reads nothing longer.
    static let maxFrame = 64 * 1024

    /// The folders Discord's socket can be in, in the order it picks them,
    /// with this Mac's own temporary folder last before `/tmp`.
    static func directories(_ environment: [String: String]) -> [String] {
        let named = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }
        var seen = Set<String>()
        return (named + [NSTemporaryDirectory(), "/tmp"]).compactMap { folder in
            var trimmed = folder
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    static func socketPaths(in directory: String) -> [String] {
        (0..<10).map { "\(directory)/discord-ipc-\($0)" }
    }

    static func encode(_ frame: Frame) -> Data {
        var data = Data(capacity: 8 + frame.payload.count)
        withUnsafeBytes(of: frame.opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(frame.payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    /// The first whole frame in `buffer` and how many bytes it took; nil
    /// until all of it has arrived.
    static func decode(_ buffer: Data) throws -> (frame: Frame, length: Int)? {
        guard buffer.count >= 8 else { return nil }
        let bytes = [UInt8](buffer.prefix(8))
        let raw = littleEndian(bytes[0..<4])
        let length = Int(littleEndian(bytes[4..<8]))
        guard let opcode = Opcode(rawValue: raw) else { throw DecodeError.unknownOpcode(raw) }
        guard length <= maxFrame else { throw DecodeError.tooLong(length) }
        guard buffer.count >= 8 + length else { return nil }
        let start = buffer.startIndex + 8
        return (Frame(opcode: opcode, payload: Data(buffer[start..<start + length])), 8 + length)
    }

    static func handshake(applicationID: String) -> Data {
        json(["v": version, "client_id": applicationID])
    }

    /// SET_ACTIVITY for this process; a nil activity clears it.
    static func setActivity(_ activity: Activity?, pid: Int32, nonce: String = UUID().uuidString) -> Data {
        var args: [String: Any] = ["pid": Int(pid)]
        if let activity {
            var timestamps: [String: Int] = [:]
            if let start = activity.start { timestamps["start"] = Int(start.timeIntervalSince1970) }
            if let end = activity.end { timestamps["end"] = Int(end.timeIntervalSince1970) }
            var object: [String: Any] = ["details": activity.details]
            if !timestamps.isEmpty { object["timestamps"] = timestamps }
            args["activity"] = object
        } else {
            args["activity"] = NSNull()
        }
        return json(["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce])
    }

    /// A command's answer that says it failed: `{evt: ERROR}`.
    static func isError(_ frame: Frame) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return true }
        return object["evt"] as? String == "ERROR"
    }

    /// Discord's answer to the handshake: `{cmd: DISPATCH, evt: READY}`.
    static func isReady(_ frame: Frame) -> Bool {
        guard frame.opcode == .frame,
              let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return false }
        return object["cmd"] as? String == "DISPATCH" && object["evt"] as? String == "READY"
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
