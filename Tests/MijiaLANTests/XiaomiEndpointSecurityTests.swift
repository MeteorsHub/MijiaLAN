import Foundation
import Testing
@testable import MijiaLAN

struct XiaomiEndpointSecurityTests {
    @Test("Account and regional APIs accept only HTTPS without URL credentials", arguments: [
        "https://account.xiaomi.com/longPolling/loginUrl", "https://account.xiaomi.com:443/pass",
        "https://sts.api.io.mi.com/sts", "https://api.io.mi.com/app/home/device_list",
        "https://de.api.io.mi.com/app", "https://us.api.io.mi.com/app", "https://sg.api.io.mi.com/app",
        "https://ru.api.io.mi.com/app", "https://i2.api.io.mi.com/app",
    ])
    func allowed(_ text: String) throws { try XiaomiEndpointPolicy.validate(#require(URL(string: text))) }

    @Test("Lookalike domains, insecure schemes, credentials and unexpected ports fail closed", arguments: [
        "http://account.xiaomi.com/pass", "https://account.xiaomi.com.evil.invalid/pass",
        "https://evil-account.xiaomi.com/pass", "https://api.io.mi.com.evil.invalid/app",
        "https://account.xiaomi.com@evil.invalid/", "https://name:secret@account.xiaomi.com/",
        "https://account.xiaomi.com:8443/", "file:///tmp/session", "https://127.0.0.1/",
    ])
    func rejected(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(throws: URLError.self) { try XiaomiEndpointPolicy.validate(url) }
    }

    @Test("Every redirect is checked, including HTTPS downgrade and redirect limits")
    func redirects() throws {
        let url = try #require(URL(string: "https://sts.api.io.mi.com/sts"))
        let guardDelegate = XiaomiRedirectGuard(followRedirects: true)
        #expect(!guardDelegate.permits(try #require(URL(string: "https://evil.invalid/"))))
        #expect(!guardDelegate.permits(try #require(URL(string: "http://account.xiaomi.com/"))))
        for _ in 0..<5 { #expect(guardDelegate.permits(url)) }
        #expect(!guardDelegate.permits(url))
        #expect(!XiaomiRedirectGuard(followRedirects: false).permits(url))
    }
}
