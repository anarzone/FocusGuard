import Carbon.HIToolbox
import Foundation

/// The global ⌃⌥R. `RegisterEventHotKey` needs no permission: macOS hands
/// over only this one key combination, and sees no other typing.
@MainActor
@Observable
final class PickUpHotKey {
    /// What the card's chip and Settings show.
    static let label = "⌃⌥R"

    @ObservationIgnored var onPress: (() -> Void)?
    /// Another app holds the combination.
    private(set) var isTaken = false

    @ObservationIgnored private var reference: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    /// Only one hot key exists, so the C callback reaches it through this.
    private static weak var current: PickUpHotKey?
    private static let id = EventHotKeyID(signature: OSType(0x4647_5055), id: 1)   // "FGPU"

    /// Registers or unregisters.
    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard reference == nil else { return }
        Self.current = self
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PickUpHotKey.current?.onPress?() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), Self.id,
                                         GetEventDispatcherTarget(), 0, &registered)
        reference = status == noErr ? registered : nil
        isTaken = status != noErr
    }

    private func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        isTaken = false
    }
}
