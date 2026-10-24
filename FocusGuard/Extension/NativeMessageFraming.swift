import Darwin
import Foundation

/// Chromium's native-messaging framing: each message is a 32-bit length in
/// native byte order (little-endian on every Mac), then that many bytes of
/// UTF-8 JSON. The browser helper relays these frames unchanged between the
/// extension (stdin/stdout) and the app (a Unix socket), so both ends share
/// this one implementation. It's compiled into the helper too: keep it to
/// Foundation and Darwin.
enum NativeMessageFraming {
    /// Chromium refuses host → extension messages over 1 MB. Larger frames
    /// from the other side are treated as a broken stream.
    static let maxMessageBytes = 1024 * 1024

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Splits complete frames off the front of `buffer`, leaving any partial
    /// frame in place for the next read.
    ///
    /// - Throws: `FrameError.tooLarge` when a header announces more than
    ///   `maxMessageBytes`; the stream can't be trusted after that.
    static func takeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = buffer[offset..<offset + 4].enumerated().reduce(UInt32(0)) {
                $0 | UInt32($1.element) << (8 * UInt32($1.offset))
            }
            guard length <= maxMessageBytes else { throw FrameError.tooLarge(Int(length)) }
            let start = offset + 4
            guard buffer.endIndex - start >= Int(length) else { break }
            frames.append(Data(buffer[start..<start + Int(length)]))
            offset = start + Int(length)
        }
        if offset > buffer.startIndex {
            buffer = Data(buffer[offset...])
        }
        return frames
    }

    enum FrameError: Error, Equatable {
        case tooLarge(Int)
    }
}

/// Where the app listens for browser helpers. A Unix socket in the user's
/// Application Support folder: only this user can reach it, and nothing
/// leaves the Mac. Shared by the app and the helper.
enum BrowserSocketLocation {
    /// `sun_path` holds 104 bytes, NUL included.
    static let maxPathBytes = 103

    /// Overrides the socket path; the tests run the helper against their own.
    static let overrideVariable = "FOCUSGUARD_BROWSER_SOCKET"

    static func path(home: String = NSHomeDirectory(), uid: uid_t = getuid(),
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[overrideVariable], !override.isEmpty { return override }
        let preferred = home + "/Library/Application Support/FocusGuard/browser.sock"
        if preferred.utf8.count <= maxPathBytes { return preferred }
        // Very long home folders: fall back to a short per-user name.
        return "/tmp/focusguard-\(uid).sock"
    }

    static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8.prefix(maxPathBytes))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return addr
    }
}
