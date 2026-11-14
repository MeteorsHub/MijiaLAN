import Foundation

/// One device's pre-normalised searchable text for the menu-bar panel (#60).
///
/// Entries are built once per device list, not once per keystroke, so typing stays cheap. Every
/// field is already lower-case and free of spaces/punctuation; the pinyin fields are empty when the
/// platform cannot transliterate Chinese, which only removes pinyin matches.
public struct DeviceSearchEntry: Equatable, Sendable {
    public let deviceId: String
    /// Display name (local alias applied), normalised.
    public let name: String
    /// Room name in both its raw and localised forms, normalised and space separated.
    public let room: String
    /// Full pinyin without separators, e.g. `shufangdeng`.
    public let pinyin: String
    /// Pinyin initials, e.g. `sfd`.
    public let initials: String
    public let roomPinyin: String
    public let roomInitials: String

    public init(
        deviceId: String,
        name: String,
        room: String = "",
        pinyin: String = "",
        initials: String = "",
        roomPinyin: String = "",
        roomInitials: String = ""
    ) {
        self.deviceId = deviceId
        self.name = name
        self.room = room
        self.pinyin = pinyin
        self.initials = initials
        self.roomPinyin = roomPinyin
        self.roomInitials = roomInitials
    }
}

/// Whether Return on the query toggles the selected device or hands the text to the assistant.
public enum PanelQueryKind: Equatable, Sendable {
    case filter
    case command
}

/// A key press reduced to what the search field cares about, so the decision rules stay in
/// `MijiaCore` and are testable without AppKit.
public struct PanelSearchKey: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Printable text the key produces. Shift is already applied; every other modifier is in
        /// the flags below and cancels the character.
        case character(String)
        case up
        case down
        case left
        case right
        case `return`
        case escape
        case tab
        case delete
        case other
    }

    public var kind: Kind
    public var hasCommand: Bool
    public var hasControl: Bool
    public var hasOption: Bool

    public init(
        kind: Kind,
        hasCommand: Bool = false,
        hasControl: Bool = false,
        hasOption: Bool = false
    ) {
        self.kind = kind
        self.hasCommand = hasCommand
        self.hasControl = hasControl
        self.hasOption = hasOption
    }
}

/// What the panel should do with a key press.
public enum PanelSearchAction: Equatable, Sendable {
    case ignore
    /// Open the search bar and put the caret in it (⌘F).
    case focusField
    /// Clear the query and leave search mode; the next Esc closes the panel.
    case clearQuery
    case moveSelection(Int)
    case toggleSelection
    case expandSelection
    /// Hand the query to the assistant (local parser first, then the model with its usual consent
    /// and demo-mode guards).
    case runCommand
    case appendQuery(String)
    case deleteBackward
}

/// Everything the key rules need to know about the current search.
public struct PanelSearchContext: Equatable, Sendable {
    public var query: String
    /// The search bar is on screen.
    public var isSearching: Bool
    /// The bar's text field is first responder, so AppKit inserts printable text itself.
    public var isFieldFocused: Bool
    public var hasSelection: Bool
    /// The user moved the selection with ↑↓ or a click, so Return acts on it even for a command query.
    public var hasExplicitSelection: Bool
    public var queryKind: PanelQueryKind

    public init(
        query: String,
        isSearching: Bool,
        isFieldFocused: Bool,
        hasSelection: Bool,
        hasExplicitSelection: Bool = false,
        queryKind: PanelQueryKind = .filter
    ) {
        self.query = query
        self.isSearching = isSearching
        self.isFieldFocused = isFieldFocused
        self.hasSelection = hasSelection
        self.hasExplicitSelection = hasExplicitSelection
        self.queryKind = queryKind
    }
}

/// Deterministic search over the devices the panel shows (#60).
///
/// Matching and the keyboard rules live in `MijiaCore`, so the panel and the tests cannot disagree:
/// * a device matches on its name, its room, its full pinyin and its pinyin initials;
/// * `sfd` finds 书房灯, `shufangdeng` finds it too, `书房` lists the whole room;
/// * best rank wins, and ties keep the order the caller passed in.
///
/// Chinese→Latin transliteration is a platform service (ICU via `CFStringTransform`), so it is
/// injectable: matching stays fully testable where transliteration data may be absent.
public enum PanelSearch {
    // MARK: - Normalisation

    /// Lower-case text with diacritics, width differences, spaces and punctuation removed, so
    /// `"Shū Fáng"`, `"shu fang"` and `"shufang"` are the same query.
    ///
    /// Combining marks are dropped by code point after decomposition, so the result does not depend
    /// on how much diacritic folding the platform's Foundation implements.
    public static func normalize(_ raw: String) -> String {
        let folded = (raw as NSString).folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: nil
        )
        let plain = String(String.UnicodeScalarView(
            folded.decomposedStringWithCanonicalMapping.unicodeScalars.filter { scalar in
                !(0x0300...0x036F).contains(scalar.value) && !(0x1AB0...0x1AFF).contains(scalar.value)
            }
        ))
        // Full-width Latin/digits fold to ASCII here rather than relying on platform width folding.
        let halfWidth = String(String.UnicodeScalarView(plain.unicodeScalars.map { scalar in
            (0xFF01...0xFF5E).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar : scalar
        }))
        return String(halfWidth.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    // MARK: - Candidates

    /// Devices the panel may search: never hidden, and never offline while the user asked to hide
    /// offline devices. The room filter is deliberately not applied — typing `sfd` while the panel
    /// shows 客厅 must still find 书房灯.
    public static func candidates(
        in devices: [SmartDevice],
        hiddenIds: Set<String>,
        hideOffline: Bool
    ) -> [SmartDevice] {
        devices.filter { dev in
            if hiddenIds.contains(dev.id) { return false }
            if hideOffline && !dev.isOnline { return false }
            return true
        }
    }

    // MARK: - Entries

    public static func entries(
        devices: [SmartDevice],
        aliases: [String: String] = [:],
        syllables: (String) -> [String]? = Pinyin.syllables
    ) -> [DeviceSearchEntry] {
        devices.map { dev in
            let displayName = alias(for: dev, aliases: aliases) ?? dev.name
            let nameSyllables = syllables(displayName) ?? []
            let roomSyllables = syllables(dev.roomName) ?? []
            var roomForms: [String] = []
            for form in [dev.roomName, L10n.displayRoomName(dev.roomName)] {
                let normalized = normalize(form)
                if !normalized.isEmpty, !roomForms.contains(normalized) { roomForms.append(normalized) }
            }
            return DeviceSearchEntry(
                deviceId: dev.id,
                name: normalize(displayName),
                room: roomForms.joined(separator: " "),
                pinyin: nameSyllables.joined().lowercased(),
                initials: Pinyin.initials(of: nameSyllables),
                roomPinyin: roomSyllables.joined().lowercased(),
                roomInitials: Pinyin.initials(of: roomSyllables)
            )
        }
    }

    /// The name the panel draws on the card: the local alias when there is one, else the Mi Home name.
    public static func alias(for device: SmartDevice, aliases: [String: String]) -> String? {
        guard let alias = aliases[device.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty,
              alias != device.name else { return nil }
        return alias
    }

    // MARK: - Matching

    /// Rank for one entry, or `nil` when it does not match at all. Higher is a better match.
    public static func rank(of query: String, in entry: DeviceSearchEntry) -> Int? {
        score(normalizedQuery: normalize(query), entry: entry)
    }

    private static func score(normalizedQuery q: String, entry: DeviceSearchEntry) -> Int? {
        guard !q.isEmpty else { return 0 }

        func score(_ text: String, prefix: Int, contains: Int) -> Int? {
            guard !text.isEmpty else { return nil }
            if text.hasPrefix(q) { return prefix }
            if text.contains(q) { return contains }
            return nil
        }

        let scores = [
            score(entry.name, prefix: 100, contains: 96),
            score(entry.pinyin, prefix: 92, contains: 88),
            score(entry.initials, prefix: 84, contains: 80),
            score(entry.room, prefix: 72, contains: 68),
            score(entry.roomPinyin, prefix: 64, contains: 60),
            score(entry.roomInitials, prefix: 56, contains: 52)
        ]
        return scores.compactMap { $0 }.max()
    }

    /// The devices a query finds, in rank order, with the panel's visibility rules applied.
    ///
    /// Hidden devices never match, offline ones only while the user asked to see them, and the room
    /// filter is deliberately ignored: `sfd` must find 书房灯 while the panel shows 客厅. An empty
    /// query returns every searchable device in the order the caller passed in.
    public static func results(
        _ query: String,
        devices: [SmartDevice],
        hiddenIds: Set<String> = [],
        hideOffline: Bool = false,
        aliases: [String: String] = [:],
        syllables: (String) -> [String]? = Pinyin.syllables
    ) -> [SmartDevice] {
        let visible = candidates(in: devices, hiddenIds: hiddenIds, hideOffline: hideOffline)
        let byId = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = entries(devices: visible, aliases: aliases, syllables: syllables)
        return matches(query, entries: entries).compactMap { byId[$0.deviceId] }
    }

    /// Matching entries, best first; an empty query returns every entry in the given order.
    public static func matches(_ query: String, entries: [DeviceSearchEntry]) -> [DeviceSearchEntry] {
        let q = normalize(query)
        guard !q.isEmpty else { return entries }
        let scored = entries.enumerated().compactMap { index, entry -> (index: Int, rank: Int, entry: DeviceSearchEntry)? in
            guard let rank = score(normalizedQuery: q, entry: entry) else { return nil }
            return (index, rank, entry)
        }
        return scored
            .sorted { a, b in a.rank != b.rank ? a.rank > b.rank : a.index < b.index }
            .map(\.entry)
    }

    // MARK: - Return: filter or command

    /// Decides what Return does with the query: point at a device, or run it as an instruction.
    ///
    /// A name or room the panel can point at always wins, so a device literally called `调光灯`
    /// stays selectable. Anything the local parser understands — plus an undo word, a delay phrase,
    /// a command verb or a measurement (`调到 30`, `26 度`, `60%`) — is a command; the panel then
    /// hands the original text to `HomeStore.runAssistantCommand`, which keeps the existing consent
    /// and demo-mode guards.
    public static func kind(
        of rawQuery: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        aliases: [String: String] = [:]
    ) -> PanelQueryKind {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .filter }

        // A name or room the panel can point at always wins, so typing a device name never fires a
        // command; only a longer sentence ("书房灯调到 30") is read as an instruction.
        let q = normalize(query)
        let names = devices.compactMap { alias(for: $0, aliases: aliases) ?? $0.name }.map(normalize).filter { !$0.isEmpty }
        if names.contains(q) { return .filter }
        if q.count >= 2, names.contains(where: { $0.hasPrefix(q) }) { return .filter }

        let rooms = Set(devices.map { normalize($0.roomName) }).filter { !$0.isEmpty }
        if rooms.contains(q) { return .filter }
        if rooms.contains(where: { $0.hasPrefix(q) }) { return .filter }

        if LocalIntentParser.parse(query, devices: devices, scenes: scenes) != nil { return .command }
        if UndoPhrase.isUndo(query) { return .command }
        if DelayPhrase.extract(query) != nil { return .command }

        if startsWithCommandVerb(query) { return .command }
        if mentionsMeasurement(query) { return .command }
        return .filter
    }

    private static let commandPrefixes = [
        "打开", "开启", "关闭", "关掉", "关上", "熄灭", "请", "帮我", "帮忙", "把", "将",
        "调", "设", "切", "执行", "启动", "运行", "全关", "全开",
        "turn", "open", "close", "switch", "set", "make", "please", "run", "start",
        "activate", "enable", "disable", "dim", "brighten"
    ]

    private static func startsWithCommandVerb(_ query: String) -> Bool {
        let lower = query.lowercased()
        return commandPrefixes.contains { lower.hasPrefix($0) }
    }

    /// `26 度`, `60%`, `4500K`, `调到 30`: a number tied to a unit or a set-verb means an instruction.
    private static func mentionsMeasurement(_ query: String) -> Bool {
        let lower = query.lowercased()
        let unitPattern = #"[0-9]+(\.[0-9]+)?\s*(%|％|度|℃|°c|°f|°|k|档|级)"#
        let setVerbPattern = #"(调到|调成|调至|调为|调低|调高|设为|设成|设置为|切换到|切到|改成|改为)\s*[0-9]+"#
        for pattern in [unitPattern, setVerbPattern] where lower.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Keyboard rules

    /// What a key press means while the panel is open.
    ///
    /// Esc has two steps (clear the query, then let the panel close), digits stay quick-access
    /// shortcuts until there is a query, Space stays "toggle focused device" until there is a
    /// query, and ⌘/⌃/⌥ combinations are left to AppKit (paste, select-all, ⌘, ⌘F…).
    public static func action(for key: PanelSearchKey, context: PanelSearchContext) -> PanelSearchAction {
        let searching = context.isSearching || !context.query.isEmpty
        // An open bar with nothing typed yet is "searching" but has nothing to act on: Return and the
        // arrows keep their panel meaning (focused device) until the first character arrives.
        let hasQuery = !normalize(context.query).isEmpty

        if key.hasControl || key.hasOption { return .ignore }
        if key.hasCommand {
            guard case .character(let text) = key.kind, text.lowercased() == "f" else { return .ignore }
            return .focusField
        }

        switch key.kind {
        case .escape:
            // First Esc clears the query (or the empty bar); with neither the panel's own
            // Esc ladder keeps working, ending in "close the panel".
            if !context.query.isEmpty || context.isSearching { return .clearQuery }
            return .ignore

        case .up:
            return searching && hasQuery ? .moveSelection(-1) : .ignore
        case .down:
            return searching && hasQuery ? .moveSelection(1) : .ignore

        case .return:
            guard searching, hasQuery else { return .ignore }
            // A device the user picked wins; otherwise an instruction runs as an instruction.
            if context.hasExplicitSelection, context.hasSelection { return .toggleSelection }
            if context.queryKind == .command { return .runCommand }
            return context.hasSelection ? .toggleSelection : .ignore

        case .right:
            guard searching, hasQuery, context.hasSelection else { return .ignore }
            return .expandSelection

        case .delete:
            guard searching, !context.query.isEmpty, !context.isFieldFocused else { return .ignore }
            return .deleteBackward

        case .character(let text):
            guard !text.isEmpty else { return .ignore }
            // The field editor inserts text itself (that is what keeps IME and paste working).
            if context.isFieldFocused { return .ignore }
            // Space, 1–9, `/` and `v` are panel shortcuts until a search has actually begun: they are
            // the quick-index digits, toggle-focused-device, the assistant bar and dictation.
            if !searching {
                if text == " " { return .ignore }
                if text == "/" || text.lowercased() == "v" { return .ignore }
                if text.count == 1, let digit = text.first, ("1"..."9").contains(digit) { return .ignore }
            }
            return .appendQuery(text)

        case .left, .tab, .other:
            return .ignore
        }
    }
}

extension PanelSearch {
    /// Han → pinyin using ICU through Foundation (`CFStringTransform`), no extra dependency (#60).
    public enum Pinyin {
        /// Syllables of the Chinese text, lower-case and diacritic-free; `nil` when the text has no
        /// Chinese, or when the platform has no transliteration data (Linux without ICU translit).
        public static func syllables(_ text: String) -> [String]? {
            guard text.contains(where: \.isHanIdeograph) else { return nil }
            return cache.value(for: text) {
                guard let latin = (text as NSString).applyingTransform(.toLatin, reverse: false) else { return nil }
                let plain = (latin as NSString).applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
                let syllables = plain
                    .split(whereSeparator: { !$0.isLetter })
                    .map { $0.lowercased() }
                guard !syllables.isEmpty else { return nil }
                // No transliteration data leaves the ideographs untouched; treat that as
                // "unavailable" instead of building a meaningless pinyin from the original text.
                guard normalize(syllables.joined()) != normalize(text) else { return nil }
                return syllables
            }
        }

        /// First letter of every syllable: `["shu", "fang", "deng"]` → `sfd`.
        public static func initials(of syllables: [String]) -> String {
            syllables.compactMap { $0.first.map(String.init) }.joined().lowercased()
        }

        /// Transliteration is pure but not free, and every keystroke re-reads the same names.
        private final class Cache: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: [String]?] = [:]

            func value(for text: String, _ make: () -> [String]?) -> [String]? {
                lock.lock()
                if let cached = storage[text] {
                    lock.unlock()
                    return cached
                }
                lock.unlock()
                let made = make()
                lock.lock()
                if storage.count > 512 { storage.removeAll(keepingCapacity: true) }
                storage[text] = made
                lock.unlock()
                return made
            }
        }

        private static let cache = Cache()
    }
}

private extension Character {
    var isHanIdeograph: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }
}
