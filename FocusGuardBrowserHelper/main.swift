import AppKit
import Darwin
import Foundation

// FocusGuard's native-messaging host. A Chromium browser starts one of these
// per extension connection (FocusGuard.app/Contents/Helpers, registered by
// NativeHostInstaller). It relays frames between the extension (stdin and
// stdout) and the running app (a Unix socket only this user can open), and
// answers for the app while it's closed: the popup can then say "FocusGuard
// isn't running" and open it. Nothing goes over the network.
//
// stdout carries only framed messages; anything else would corrupt the
// stream, so logging goes to stderr.

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let relay = Relay(origin: CommandLine.arguments.dropFirst().first { $0.hasPrefix("chrome-extension://") },
                  browser: Relay.launchingBrowser())
relay.run()

final class Relay {
    private let origin: String?
    private let browser: String?
    private let socketPath = BrowserSocketLocation.path()
    /// Guards `socketFD` and `reportedRunning`.
    private let queue = DispatchQueue(label: "FocusGuardBrowserHelper.state")
    private let stdoutLock = NSLock()
    private var socketFD: Int32 = -1
    private var reportedRunning: Bool?
    private var retryTimer: DispatchSourceTimer?

    init(origin: String?, browser: String?) {
        self.origin = origin
        self.browser = browser
    }

    func run() -> Never {
        queue.async { self.connect() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.socketFD < 0 else { return }
            self.connect()
        }
        timer.resume()
        retryTimer = timer
        readExtension()
    }

    // MARK: - Extension (stdin)

    /// Blocks on stdin until the browser closes it, then exits.
    private func readExtension() -> Never {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(STDIN_FILENO, &chunk, chunk.count)
            if n == 0 { exit(0) }
            if n < 0 {
                if errno == EINTR { continue }
                exit(0)
            }
            buffer.append(contentsOf: chunk[0..<n])
            guard let frames = try? NativeMessageFraming.takeFrames(from: &buffer) else { exit(1) }
            for frame in frames {
                queue.sync { self.fromExtension(frame) }
            }
        }
    }

    private func fromExtension(_ frame: Data) {
        if socketFD >= 0 {
            if writeAll(socketFD, NativeMessageFraming.frame(frame)) { return }
            disconnect()
        }
        answerWhileClosed(frame)
    }

    /// The app isn't running: open it on request, refuse everything else.
    private func answerWhileClosed(_ frame: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "openApp":
            launchApp()
        case "hello":
            sendStatus(running: false, force: true)
        default:
            if let id = message["id"] as? String {
                toExtension(["type": "reply", "id": id, "ok": false, "error": "notRunning"])
            }
        }
    }

    // MARK: - App (socket)

    private func connect() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = BrowserSocketLocation.address(for: socketPath)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            sendStatus(running: false)
            return
        }
        socketFD = fd
        var hello: [String: Any] = ["type": "helperHello"]
        hello["browser"] = browser
        hello["origin"] = origin
        if let data = try? JSONSerialization.data(withJSONObject: hello) {
            _ = writeAll(fd, NativeMessageFraming.frame(data))
        }
        sendStatus(running: true)
        Thread.detachNewThread { [weak self] in self?.readApp(fd) }
    }

    /// Relays the app's frames to the extension until the socket closes.
    private func readApp(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            guard let frames = try? NativeMessageFraming.takeFrames(from: &buffer) else { break }
            for frame in frames { writeFrameToExtension(frame) }
        }
        queue.async {
            if self.socketFD == fd { self.disconnect() }
        }
    }

    private func disconnect() {
        guard socketFD >= 0 else { return }
        shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
        socketFD = -1
        sendStatus(running: false)
    }

    private func sendStatus(running: Bool, force: Bool = false) {
        guard force || reportedRunning != running else { return }
        reportedRunning = running
        var status: [String: Any] = ["type": "appStatus", "running": running]
        status["appPath"] = Relay.appBundlePath()
        toExtension(status)
    }

    // MARK: - Writing

    private func toExtension(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        writeFrameToExtension(data)
    }

    private func writeFrameToExtension(_ payload: Data) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        if !writeAll(STDOUT_FILENO, NativeMessageFraming.frame(payload)) { exit(0) }
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    // MARK: - Finding things

    private func launchApp() {
        guard let app = Relay.appBundlePath() else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [app]
        try? open.run()
    }

    /// The FocusGuard.app this helper lives in.
    static func appBundlePath(executable: String = CommandLine.arguments[0]) -> String? {
        var url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Bundle id of the browser that started us: the nearest ancestor
    /// process that is an app.
    static func launchingBrowser() -> String? {
        var pid = getppid()
        for _ in 0..<6 where pid > 1 {
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return id }
            pid = parent(of: pid)
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}
