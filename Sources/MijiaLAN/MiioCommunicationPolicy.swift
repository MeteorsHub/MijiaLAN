import Foundation

/// Explicit independent axes. The GUI uses revised only for reviewed dc1545 sessions; CLI experiments
/// must select every axis. No process environment variable can switch a device to an experimental policy.
public struct MiioCommunicationPolicy: Codable, Equatable, Sendable {
    public enum Socket: String, Codable, Sendable { case fresh, stable }
    public enum Layout: String, Codable, Sendable { case full, adaptive, single }
    public enum Hello: String, Codable, Sendable { case silence, periodic }
    public enum Stamp: String, Codable, Sendable { case replyPlusOne, helloAnchored }
    public let socket: Socket
    public let layout: Layout
    public let hello: Hello
    public let stamp: Stamp
    public static let legacy = Self(socket: .fresh, layout: .full, hello: .silence, stamp: .replyPlusOne)
    public static let revised = Self(socket: .stable, layout: .adaptive, hello: .periodic, stamp: .helloAnchored)
    public init(socket: Socket, layout: Layout, hello: Hello, stamp: Stamp) {
        self.socket = socket; self.layout = layout; self.hello = hello; self.stamp = stamp
    }
}
public struct MiioTimeSource: Sendable {
    let now: @Sendable () -> Duration
    public init() {
        let origin = ContinuousClock.now
        now = { origin.duration(to: .now) }
    }
    public init(now: @escaping @Sendable () -> Duration) { self.now = now }
}
struct MiioClockDiscontinuity: LocalizedError {
    var errorDescription: String? { "Device clock differs from verified hello anchor; communication paused without retry." }
}

public struct MiioPropertyAddress: Codable, Equatable, Sendable {
    public let siid: UInt16
    public let piid: UInt16
    public init(siid: UInt16, piid: UInt16) { self.siid = siid; self.piid = piid }
}
