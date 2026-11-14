import Foundation

// MARK: - Customizable Global Hotkey (#43)

/// Modifier keys of a global shortcut, stored as a plain bit mask in `UserDefaults`.
///
/// MijiaCore stays Foundation-only (the core test suite also runs on Linux), so this mirrors the
/// Carbon flags instead of importing `Carbon`.
public struct HotkeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// Masks away bits this build does not know about (e.g. caps lock / fn left in storage).
    public static let supported: HotkeyModifiers = [.command, .option, .control, .shift]

    /// Display order matches macOS (`⌃⌥⇧⌘`).
    public var symbolString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A recorded global shortcut: a macOS virtual key code plus the modifier bits.
public struct HotkeyShortcut: Equatable, Sendable {
    public var keyCode: UInt16
    /// Layout-respecting label captured at record time (e.g. "M", "F5", "←").
    public var keyLabel: String
    public var modifiers: HotkeyModifiers

    /// `kVK_ANSI_M` (Carbon). The default stays ⌥M for existing users.
    public static let defaultKeyCode: UInt16 = 46
    public static let defaultShortcut = HotkeyShortcut(keyCode: defaultKeyCode, keyLabel: "M", modifiers: .option)

    /// F1–F20 key codes; these work without a modifier on macOS.
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107,
        113, 106, 64, 79, 80, 90,
    ]

    public init(keyCode: UInt16, keyLabel: String, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }

    /// A shortcut must be printable and either carry a modifier or be a function key; otherwise the
    /// global registration would swallow an ordinary letter system-wide.
    public var isValid: Bool {
        let label = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        return !modifiers.isEmpty || Self.functionKeyCodes.contains(keyCode)
    }

    /// e.g. "⌃⌥M".
    public var displayString: String {
        modifiers.symbolString + keyLabel
    }

    public var isDefault: Bool {
        keyCode == Self.defaultKeyCode && modifiers == .option
    }
}

/// Persistence for the global shortcut (#43). Keys are part of the public contract so a reinstall
/// and the settings UI agree on where the choice lives.
public enum HotkeyPreferences {
    public static let keyCodeKey = "menubar_hotkey_key_code"
    public static let modifiersKey = "menubar_hotkey_modifiers"
    public static let keyLabelKey = "menubar_hotkey_key_label"

    /// Falls back to ⌥M when nothing (or something unusable) was stored.
    public static func load(from defaults: UserDefaults = .standard) -> HotkeyShortcut {
        guard defaults.object(forKey: keyCodeKey) != nil else { return .defaultShortcut }
        let stored = HotkeyShortcut(
            keyCode: UInt16(clamping: defaults.integer(forKey: keyCodeKey)),
            keyLabel: defaults.string(forKey: keyLabelKey) ?? "",
            modifiers: HotkeyModifiers(rawValue: defaults.integer(forKey: modifiersKey))
                .intersection(.supported)
        )
        return stored.isValid ? stored : .defaultShortcut
    }

    public static func save(_ shortcut: HotkeyShortcut, to defaults: UserDefaults = .standard) {
        guard shortcut.isValid else { return }
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(shortcut.modifiers.rawValue, forKey: modifiersKey)
        defaults.set(shortcut.keyLabel, forKey: keyLabelKey)
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyCodeKey)
        defaults.removeObject(forKey: modifiersKey)
        defaults.removeObject(forKey: keyLabelKey)
    }
}
