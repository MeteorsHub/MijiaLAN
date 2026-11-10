import Foundation
import Testing
@testable import MijiaCore

struct LGCertificateTrustTests {
    @Test("A changed TV certificate is refused across restarts until explicit re-pair")
    func changedCertificateRequiresReset() throws {
        let suite = "test.lg.trust.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("original-tv-certificate".utf8)
        let replacement = Data("replacement-tv-certificate".utf8)
        let firstRun = LGCertificateTrust(defaults: defaults)
        #expect(firstRun.accepts(certificate: original, host: " TV.local. "))

        let nextRun = LGCertificateTrust(defaults: defaults)
        #expect(nextRun.accepts(certificate: original, host: "tv.local"))
        #expect(!nextRun.accepts(certificate: replacement, host: "tv.local"))
        #expect(nextRun.failure(for: "TV.local") == .changed)
        #expect(nextRun.accepts(certificate: original, host: "tv.local"))
        #expect(nextRun.reset(host: "tv.local"))
        #expect(nextRun.accepts(certificate: replacement, host: "tv.local"))
        #expect(!nextRun.accepts(certificate: original, host: "tv.local"))
    }

    @Test("TV identities are isolated by host and empty certificates never establish trust")
    func hostIsolationAndMissingIdentity() throws {
        let suite = "test.lg.trust.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = LGCertificateTrust(defaults: defaults)
        let first = Data("tv-one".utf8)
        let second = Data("tv-two".utf8)
        #expect(!trust.accepts(certificate: Data(), host: "tv-one.local"))
        #expect(!trust.accepts(certificate: first, host: " "))
        #expect(trust.accepts(certificate: first, host: "tv-one.local"))
        #expect(trust.accepts(certificate: second, host: "tv-two.local"))
        #expect(!trust.accepts(certificate: second, host: "tv-one.local"))
        #expect(trust.reset(host: "tv-two.local"))
        #expect(!trust.accepts(certificate: second, host: "tv-one.local"))
    }

    @Test("A corrupt stored identity fails closed instead of silently trusting a replacement")
    func corruptStorageFailsClosed() throws {
        let suite = "test.lg.trust.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = LGCertificateTrust(defaults: defaults)
        #expect(trust.accepts(certificate: Data("original".utf8), host: "tv.local"))
        let account = try #require(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("lg_certificate_sha256_") })
        defaults.set(123, forKey: account)
        #expect(!trust.accepts(certificate: Data("replacement".utf8), host: "tv.local"))
        #expect(trust.failure(for: "tv.local") == .unavailable)
        #expect(defaults.integer(forKey: account) == 123)
    }
}
