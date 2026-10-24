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

    /// Processes that carry a call's microphone: the apps above, their
    /// helpers ("us.zoom.CptHost"), macOS's FaceTime service, and chat apps
    /// that also make calls (Slack huddles, Discord, WhatsApp, Telegram).
    /// Only the apps above are neutral; these just hold nudges.
    static let microphonePrefixes: [String] = [
        "us.zoom.", "com.apple.FaceTime", "com.apple.avconferenced",
        "com.microsoft.teams", "Cisco-Systems.Spark",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
    ]

    static var seeds: [DefaultRules.Seed] {
        bundleIds.map { DefaultRules.Seed(pattern: $0, kind: .bundleId, classification: .neutral) }
            + hosts.map { DefaultRules.Seed(pattern: $0, kind: .host, classification: .neutral) }
    }

    static func isCallSite(_ url: String?) -> Bool {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return hosts.contains { Classifier.host(host, matches: $0) }
    }
}

/// Decides whether the user is in a call, from who's using the microphone.
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

    /// A call site was in front while the microphone was on.
    private(set) var webCallSeen = false

    mutating func update(_ reading: Reading) -> Bool {
        guard reading.microphoneInUse else {
            webCallSeen = false
            return false
        }
        if MeetingApps.isCallSite(reading.frontURL) { webCallSeen = true }

        guard let recording = reading.recording else {
            return webCallSeen || !reading.runningApps.isDisjoint(with: MeetingApps.bundleIds)
        }
        if recording.contains(where: { id in MeetingApps.microphonePrefixes.contains { id.hasPrefix($0) } }) {
            return true
        }
        return webCallSeen && recording.contains(where: Self.isBrowserProcess)
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
