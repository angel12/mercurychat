import Foundation

#if os(macOS)
    import AppKit
#endif

/// A global keyboard shortcut: a virtual key code plus modifiers.
struct VoiceHotKey: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt8
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// A virtual key code (`kVK_*`).
    var keyCode: UInt32
    var modifiers: Modifiers

    /// ⌥⌘M (`kVK_ANSI_M`).
    static let defaultMute = VoiceHotKey(keyCode: 46, modifiers: [.option, .command])

    /// macOS 15+ refuses hot keys whose only modifiers are ⌥ and ⇧, and
    /// a bare key would swallow typing: require ⌘ or ⌃.
    var isValid: Bool { !modifiers.isDisjoint(with: [.command, .control]) }

    /// The Carbon mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= 0x100 }
        if modifiers.contains(.shift) { mask |= 0x200 }
        if modifiers.contains(.option) { mask |= 0x800 }
        if modifiers.contains(.control) { mask |= 0x1000 }
        return mask
    }

    /// Menu order: ⌃⌥⇧⌘ then the key.
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The key's label on a US layout (key codes are positional).
    static func keyName(_ keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

#if os(macOS)
    extension VoiceHotKey {
        /// From a recorded key-down; device-dependent flags are ignored.
        init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
        }
    }
#endif

/// Where the mute shortcut is kept. Nothing stored = the default; a stored
/// nil = the user cleared it.
struct VoiceHotKeyStore {
    static let key = "voice.muteHotKey"
    let defaults: UserDefaults

    private struct Stored: Codable {
        var hotKey: VoiceHotKey?
    }

    func load() -> VoiceHotKey? {
        guard let data = defaults.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return .defaultMute }
        return stored.hotKey
    }

    func save(_ hotKey: VoiceHotKey?) {
        guard let data = try? JSONEncoder().encode(Stored(hotKey: hotKey)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
