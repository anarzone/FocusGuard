import Foundation

/// What a licence check found.
enum LicenceCheck: Equatable {
    case valid
    case invalid(reason: String)
}

/// Checks a Pro licence key. No payment provider is chosen yet; when one is,
/// its verifier replaces `PlaceholderLicenceVerifier`.
protocol LicenceVerifier {
    func verify(_ key: String) async -> LicenceCheck
}

/// Turns every key down, so nothing unlocks Pro until real keys exist.
struct PlaceholderLicenceVerifier: LicenceVerifier {
    func verify(_ key: String) async -> LicenceCheck {
        .invalid(reason: "Licence keys aren't available yet.")
    }
}
