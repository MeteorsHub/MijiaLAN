import Foundation

/// Only the account service and the six supported Xiaomi Home API regions may receive login/API traffic.
public enum XiaomiEndpointPolicy {
    public static func validate(_ url: URL) throws {
        let apiHosts: Set<String> = ["api.io.mi.com", "sts.api.io.mi.com", "de.api.io.mi.com",
                                     "us.api.io.mi.com", "sg.api.io.mi.com", "ru.api.io.mi.com", "i2.api.io.mi.com"]
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              host == "account.xiaomi.com" || host.hasSuffix(".account.xiaomi.com") || apiHosts.contains(host) else {
            // Do not echo a login URL: it may contain a ticket or account token.
            throw URLError(.unsupportedURL)
        }
    }
}

