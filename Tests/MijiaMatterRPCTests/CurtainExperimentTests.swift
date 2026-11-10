import Testing
@testable import mijia_lan

struct CurtainExperimentTests {
    let base = ["--socket","stable","--layout","adaptive","--hello","periodic","--stamp","helloAnchored","--slot","1","--reads","48","--interval","30"]
    @Test("Experiment plans are inert and require every independent axis and explicit arming flags")
    func plans() throws {
        #expect(try !CurtainExperiment.parse(base).execute)
        #expect(try CurtainExperiment.parse(base).statusReadProperties == [2,3,4,9,10])
        #expect(try CurtainExperiment.parse(base + ["--diagnostic-six"]).statusReadProperties == [2,3,4,5,9,10])
        #expect(throws: (any Error).self) { try CurtainExperiment.parse(base + ["--execute"]) }
        #expect(throws: (any Error).self) { try CurtainExperiment.parse(base + ["--execute","--baseline-normal"]) }
        #expect(try CurtainExperiment.parse(base + ["--execute","--baseline-normal","--log-directory","/tmp/new-experiment"]).execute)
        #expect(throws: (any Error).self) { try CurtainExperiment.parse([]) }
        #expect(throws: (any Error).self) { try CurtainExperiment.parse(base + ["--token","never-accepted"]) }
    }
}
