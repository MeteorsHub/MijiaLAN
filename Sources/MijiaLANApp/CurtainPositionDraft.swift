import Foundation

/// View-only editing state. Receiving readings or ending focus never creates a device command.
struct CurtainPositionDraft {
    private(set) var slider = 0.0
    private(set) var text = ""
    private(set) var actual: Int?
    private(set) var dragging = false
    private(set) var typing = false
    private var unsubmittedText = false
    var target: Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    mutating func receive(_ position: Int?) {
        actual = position
        synchronize()
    }
    mutating func editText(_ value: String) {
        text = value
        unsubmittedText = true
    }
    // Blurring must not consume a draft before a confirmation button receives its click.
    mutating func focus(_ value: Bool) {
        typing = value
        synchronize()
    }
    mutating func drag(_ value: Double) {
        slider = value
        text = String(Int(value.rounded()))
    }
    mutating func setDragging(_ value: Bool) {
        dragging = value
        if !value { unsubmittedText = false }
    }
    /// Explicit submission consumes the edit, even if macOS keeps the TextField focused.
    mutating func submitted() {
        unsubmittedText = false
    }
    /// Open/Close/Stop supersede any draft; future readings must update both controls.
    mutating func discard() {
        unsubmittedText = false
        synchronize()
    }
    private mutating func synchronize() {
        guard !dragging, let actual else { return }
        slider = Double(actual)
        if !unsubmittedText { text = String(actual) }
    }
}
