/// Reviewed dc1545/fw1.1.3 normal reads exclude the motor-reverse getter after cumulative field failures.
/// Diagnostic six remains explicitly labelled and never grants control permission.
public enum CurtainReadProfile: String, Codable, Sendable {
    case normalFive = "dc1545-fw1.1.3-normal-five"
    case diagnosticSix = "dc1545-explicit-diagnostic-six"
    public var propertyIDs: [Int] {
        switch self { case .normalFive: [2,3,4,9,10]; case .diagnosticSix: [2,3,4,5,9,10] }
    }
}
