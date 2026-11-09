import Testing
@testable import MijiaLANApp

@MainActor struct NumberDraftPollingTests {
    @Test("Polling cannot replace a focused partial numeric input, including when its numeric value matches the sample")
    func focusedAndDirtyText() {
        let draft = PanelNumberDraft()
        draft.receive("64", focused: false)
        draft.text = "64."; draft.isEditing = true
        draft.receive("64", focused: true)
        #expect(draft.text == "64.")
        draft.receive("65", focused: false)
        #expect(draft.text == "64.")
        draft.isEditing = false; draft.receive("65", focused: false)
        #expect(draft.text == "65")
        draft.text = "65." // A focused field is protected even before its dirty flag updates.
        draft.receive("66", focused: true)
        #expect(draft.text == "65.")
    }
}
