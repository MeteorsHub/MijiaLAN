import Testing
@testable import MijiaLANApp

struct CurtainPositionDraftTests {
    @Test("Submitting while focus remains follows actual 29 to 64, Open 100, Close 0 in both controls")
    func focusedSubmissionAndButtons() {
        var draft = CurtainPositionDraft()
        draft.receive(29)
        draft.focus(true)
        draft.editText("64")
        #expect(draft.target == 64 && draft.slider == 29)
        draft.submitted()
        draft.receive(64); draft.finishedSubmission(succeeded: true)
        #expect(draft.typing && draft.slider == 64 && draft.text == "64")
        draft.editText("72")
        draft.discard() // Open supersedes the unsubmitted edit.
        draft.receive(100)
        #expect(draft.slider == 100 && draft.text == "100")
        draft.discard() // Close, with the TextField still focused.
        draft.receive(0)
        #expect(draft.slider == 0 && draft.text == "0")
    }
    @Test("Fresh actual samples update the slider while preserving actively edited unsubmitted text")
    func preserveUnsubmittedText() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.focus(true); draft.editText("64")
        draft.receive(35)
        #expect(draft.slider == 35 && draft.text == "64" && draft.target == 64)
        draft.focus(false)
        #expect(draft.slider == 35 && draft.text == "64")
        draft.submitted(); draft.receive(64); draft.finishedSubmission(succeeded: true)
        #expect(draft.slider == 64 && draft.text == "64")
    }
    @Test("Readings arriving during a drag do not replace the drag target; submission follows later actual readings")
    func dragging() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.focus(true); draft.editText("64")
        draft.setDragging(true); draft.drag(67)
        draft.receive(40)
        #expect(draft.slider == 67 && draft.text == "67")
        let releasedTarget = draft.target
        draft.setDragging(false); draft.submitted()
        #expect(releasedTarget == 67)
        draft.receive(67); draft.finishedSubmission(succeeded: true)
        #expect(draft.slider == 67 && draft.text == "67")
    }
    @Test("A new unsubmitted edit survives readings and focus changes; explicit discard uses the latest sample")
    func editsDuringConfirmation() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.focus(true); draft.editText("64"); draft.submitted()
        draft.editText("90")
        draft.receive(64); draft.finishedSubmission(succeeded: true)
        #expect(draft.slider == 64 && draft.text == "90")
        draft.receive(65)
        draft.focus(false)
        #expect(draft.slider == 65 && draft.text == "90")
        draft.discard()
        #expect(draft.slider == 65 && draft.text == "65")
    }
    @Test("Invalid or missing readings do not invent a position or submit an edit")
    func missingReading() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.focus(true); draft.editText("101")
        draft.receive(nil)
        #expect(draft.actual == nil && draft.text == "101" && draft.slider == 29)
        draft.focus(false)
        draft.receive(42)
        #expect(draft.text == "101" && draft.slider == 42)
        draft.discard()
        #expect(draft.text == "42" && draft.slider == 42)
    }
}


struct QuietPollingDraftTests {
    @Test("A rejected release remains an unsubmitted draft when a later recovery sample arrives")
    func rejectedRelease() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.setDragging(true); draft.drag(67); draft.setDragging(false)
        // Controller rejected the request, so submitted() is deliberately not called.
        draft.receive(40); draft.focus(false)
        #expect(draft.text == "67" && draft.target == 67 && draft.pendingTarget == nil)
    }
    @Test("A queued target survives focus and intermediate background samples until explicit completion")
    func queuedDraft() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.editText("67"); draft.submitted()
        draft.receive(40); draft.focus(false)
        #expect(draft.text == "67" && draft.slider == 29 && draft.pendingTarget == 67)
        draft.receive(67); draft.finishedSubmission(succeeded: true)
        #expect(draft.slider == 67 && draft.text == "67" && draft.pendingTarget == nil)
    }
    @Test("A failed accepted target remains editable; incoming samples preserve the unsubmitted text")
    func failedDraft() {
        var draft = CurtainPositionDraft()
        draft.receive(29); draft.editText("67"); draft.submitted()
        draft.receive(nil); draft.finishedSubmission(succeeded: false)
        draft.receive(40)
        #expect(draft.text == "67" && draft.actual == 40 && draft.pendingTarget == nil)
    }
}
