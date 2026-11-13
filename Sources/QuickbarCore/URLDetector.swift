import Foundation

public enum URLDetector {
    public struct Detected: Equatable, Sendable {
        public let url: URL
        /// Strong: unmistakably a URL (has a scheme, a path, or a common TLD).
        /// Weak: could be a file name like "notes.txt"; rank it below index hits.
        public let isStrong: Bool
    }

    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "uk", "de", "fr", "nl", "eu", "us", "ca",
        "au", "jp", "ch", "at", "se", "no", "dk", "fi", "es", "it", "pl", "ie", "nz", "in", "br",
        "edu", "gov", "info", "me", "tv", "ai", "xyz", "so", "sh", "gg", "fm", "to", "is", "ly",
        "rs", "page", "blog", "cloud", "tech", "site", "online", "wiki", "social", "news",
    ]

    public static func detect(_ input: String) -> Detected? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= 4096, !s.contains(where: \.isWhitespace) else { return nil }

        // Explicit scheme.
        if let range = s.range(of: "://"), range.lowerBound > s.startIndex {
            let scheme = s[..<range.lowerBound]
            guard scheme.first!.isLetter,
                  scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }),
                  range.upperBound < s.endIndex,
                  let url = URL(string: s) ?? encoded(s)
            else { return nil }
            return Detected(url: url, isStrong: true)
        }
        if s.lowercased().hasPrefix("mailto:"), s.contains("@"), let url = URL(string: s) {
            return Detected(url: url, isStrong: true)
        }

        // Bare host: host[:port][/path]
        let hostEnd = s.firstIndex(where: { "/?#".contains($0) }) ?? s.endIndex
        var host = String(s[..<hostEnd])
        let hasPath = hostEnd < s.endIndex
        var hasPort = false
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber), port.count <= 5 else { return nil }
            host = String(host[..<colon])
            hasPort = true
        }
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        let lowerHost = host.lowercased()

        if lowerHost == "localhost" {
            guard hasPort || hasPath else { return nil }
            return URL(string: "http://" + s).map { Detected(url: $0, isStrong: true) }
        }
        let isIPv4 = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        if isIPv4 {
            return URL(string: "http://" + s).map { Detected(url: $0, isStrong: true) }
        }

        guard labels.count >= 2, let tld = labels.last?.lowercased(),
              tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return nil }
        guard let url = URL(string: "https://" + s) ?? encoded("https://" + s) else { return nil }
        let strong = commonTLDs.contains(tld) || lowerHost.hasPrefix("www.") || (hasPath && hasPort)
        return Detected(url: url, isStrong: strong)
    }

    private static func encoded(_ s: String) -> URL? {
        s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.init(charactersIn: "#%")))
            .flatMap(URL.init(string:))
    }
}
