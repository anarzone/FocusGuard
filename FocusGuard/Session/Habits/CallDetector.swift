import CoreAudio
import Foundation

/// Apps and sites for calls. Built-in rules count them as neutral, so a
/// meeting is neither focus nor drift.
enum MeetingApps {
    static let bundleIds: [String] = [
        "us.zoom.xos",            // Zoom
        "com.apple.FaceTime",
        "com.microsoft.teams2",   // Teams
        "com.microsoft.teams",    // Teams (classic)
        "Cisco-Systems.Spark",    // Webex
    ]

    /// Calls in the browser.
    static let hosts: [String] = [
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "app.zoom.us",
    ]

    /// Processes that carry a call's microphone, by bundle-id prefix, and
    /// the app they stand for: the apps above, their helpers
    /// ("us.zoom.CptHost"), macOS's FaceTime service, and chat apps that
    /// also make calls. Only the apps above are neutral; the chat apps just
    /// hold nudges.
    static let microphoneOwners: [(prefix: String, bundleId: String, name: String)] = [
        ("us.zoom.", "us.zoom.xos", "Zoom"),
        ("com.apple.FaceTime", "com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "com.apple.FaceTime", "FaceTime"),
        ("com.microsoft.teams", "com.microsoft.teams2", "Teams"),
        ("Cisco-Systems.Spark", "Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "net.whatsapp.WhatsApp", "WhatsApp"),
        ("ru.keepcoder.Telegram", "ru.keepcoder.Telegram", "Telegram"),
    ]

    /// What the call sites are called.
    static func siteName(_ host: String) -> String {
        switch host {
        case "meet.google.com": return "Google Meet"
        case "app.zoom.us":     return "Zoom"
        default:                return "Teams"
        }
    }

    static var seeds: [DefaultRules.Seed] {
        bundleIds.map { DefaultRules.Seed(pattern: $0, kind: .bundleId, classification: .neutral) }
            + hosts.map { DefaultRules.Seed(pattern: $0, kind: .host, classification: .neutral) }
    }

    static func isCallSite(_ url: String?) -> Bool {
        callSite(url) != nil
    }

    /// "Google Meet" for a Meet page; nil for anything else.
    static func callSite(_ url: String?) -> String? {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        return hosts.first { Classifier.host(host, matches: $0) }.map(siteName)
    }
}

/// Decides whether the user is in a call, and which, from who's using the
/// microphone.
///
/// A call app (or its helper) recording counts. A browser recording counts
/// once a call site was seen in front while the microphone was on, since
/// the call can then sit in a background tab. On Macs that can't say which
/// app is recording, any microphone use counts while a call app is open.
struct CallDetector: Equatable {
    /// What the Mac reports at one moment.
    struct Reading {
        /// Bundle ids of the processes recording from a microphone; nil
        /// when macOS can't say (before 14.2).
        let recording: [String]?
        /// Whether any microphone is in use.
        let microphoneInUse: Bool
        /// Open apps, for when `recording` is nil.
        let runningApps: Set<String>
        /// The page in front, if a browser is.
        let frontURL: String?
    }

    /// Which call it is.
    struct Call: Equatable {
        /// "Zoom", "Google Meet".
        let name: String
        /// The app's bundle id; nil for a call in the browser.
        let bundleId: String?
    }

    /// A call site that was in front while the microphone was on.
    private(set) var webCall: String?

    mutating func update(_ reading: Reading) -> Call? {
        guard reading.microphoneInUse else {
            webCall = nil
            return nil
        }
        if let site = MeetingApps.callSite(reading.frontURL) { webCall = site }

        guard let recording = reading.recording else {
            if let id = MeetingApps.bundleIds.first(where: reading.runningApps.contains),
               let owner = MeetingApps.microphoneOwners.first(where: { id.hasPrefix($0.prefix) }) {
                return Call(name: owner.name, bundleId: owner.bundleId)
            }
            return webCall.map { Call(name: $0, bundleId: nil) }
        }
        for id in recording {
            if let owner = MeetingApps.microphoneOwners.first(where: { id.hasPrefix($0.prefix) }) {
                return Call(name: owner.name, bundleId: owner.bundleId)
            }
        }
        guard let webCall, recording.contains(where: Self.isBrowserProcess) else { return nil }
        return Call(name: webCall, bundleId: nil)
    }

    /// "com.google.Chrome.helper" records for Chrome.
    static func isBrowserProcess(_ bundleId: String) -> Bool {
        BrowserTabReader.browserBundleIDs.contains { bundleId == $0 || bundleId.hasPrefix($0 + ".") }
    }
}

/// Microphone use, read from Core Audio. Needs no microphone permission:
/// it only asks whether recording is happening, never for the sound.
enum MicrophoneActivity {
    static func isInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return readFlag(device, &address)
    }

    /// Bundle ids of the processes recording right now; nil before macOS 14.2.
    static func recordingProcesses() -> [String]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }

        return processes.compactMap { process in
            var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard readFlag(process, &input) else { return nil }
            var bundle = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &bundle, 0, nil, &nameSize, &name) == noErr,
                  let id = name?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
            return id
        }
    }

    private static func readFlag(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}
