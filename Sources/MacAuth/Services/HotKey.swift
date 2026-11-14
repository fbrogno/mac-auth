import AppKit
import Carbon.HIToolbox

/// One system-wide keyboard shortcut via Carbon `RegisterEventHotKey` (no accessibility permission, no third-party code).
@MainActor
final class HotKeyService {
    enum Failure: Error, Equatable {
        /// Carbon would accept a bare key; the app requires ⌘, ⌥ or ⌃ so normal typing never triggers it.
        case needsModifier
        /// Another app or the system already uses this combination.
        case taken
        case other(Int32)
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType
    private var onPress: (@MainActor () -> Void)?

    init(signature: String = "MAUT") {
        self.signature = signature.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    /// `modifiers` are `NSEvent.ModifierFlags` raw bits; only ⌘ ⌥ ⌃ ⇧ count.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// At least one of ⌘ ⌥ ⌃ is required.
    static func isAcceptable(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control]).isEmpty
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers flags: NSEvent.ModifierFlags, onPress: @escaping @MainActor () -> Void) -> Result<Void, Failure> {
        unregister()
        guard Self.isAcceptable(flags) else { return .failure(.needsModifier) }
        self.onPress = onPress

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { service.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return .failure(.other(status)) }

        let id = EventHotKeyID(signature: signature, id: 1)
        let result = RegisterEventHotKey(keyCode, Self.carbonModifiers(from: flags), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard result == noErr else {
            unregister()
            return .failure(result == OSStatus(eventHotKeyExistsErr) ? .taken : .other(result))
        }
        return .success(())
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onPress = nil
    }
}

/// Text for a recorded shortcut, for example "⌃⌥M".
enum HotKeyLabel {
    private static let special: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    static func text(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += special[keyCode] ?? (characters ?? "?").uppercased()
        return out
    }
}
