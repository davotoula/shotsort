import Foundation

public enum Domains {
    // A dot-separated host whose final label is 2+ letters. Requiring letters
    // in the TLD keeps monetary amounts like 4,680,590.31 out.
    // Regex<Output> does NOT conform to Sendable on this toolchain (Swift
    // 6.3.1 / swiftlang-6.3.1.1.2), even though Output here is a tuple of
    // Substring. `swift build -Xswiftc -strict-concurrency=complete` fails
    // with:
    //   error: static property 'pattern' is not concurrency-safe because
    //   non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared
    //   mutable state [#MutableGlobalVariable]
    //   note: generic struct 'Regex' does not conform to the 'Sendable'
    //   protocol
    // Computed, not stored: Regex is not Sendable on this toolchain, and
    // extract matches from 8 concurrent tasks. A fresh value per access
    // removes the race by construction rather than by annotation.
    private static var pattern: Regex<(Substring, Substring)> {
        /\b((?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,})\b/
    }

    /// TLD allowlist — the honest fix from TODO item 9. The regex alone
    /// accepts any dotted token ending in 2+ letters, which harvested
    /// book.php, chatfileuploaddialog.kt and the OCR truncation alex.mor as
    /// "domains"; a file-extension denylist would leak (truncations are not
    /// extensions). Generous but curated: common gTLDs, the ccTLDs plausible
    /// in this collection, and the novelty TLDs it actually contains
    /// (.one, .land, .build, .lol). `.local` is included deliberately —
    /// mDNS hosts like umbrel.local are genuine sources for grouping.
    /// Domains are the grouping basis, so a missing entry costs a group;
    /// extend the list when a real domain is observed to be dropped.
    static let tlds: Set<String> = [
        // gTLDs
        "com", "net", "org", "edu", "gov", "mil", "int", "info", "biz",
        "name", "pro", "io", "ai", "app", "dev", "cloud", "online", "site",
        "store", "shop", "blog", "news", "social", "network", "xyz", "me",
        "tv", "cc", "fm", "one", "land", "build", "lol", "local",
        // Verified against the real index after the first cut: these are
        // genuine TLDs this collection uses (nostr infrastructure, gov.scot,
        // .co sites) that the initial list wrongly dropped — nostr.mom alone
        // carried 8 records, a would-be group.
        "mom", "wine", "band", "co", "download", "scot", "to", "today",
        "stream", "earth", "host", "cat", "pub", "media",
        // ccTLDs plausible for this collection
        "uk", "de", "at", "ch", "se", "no", "dk", "fi", "fr", "it", "es",
        "pt", "nl", "be", "ie", "pl", "cz", "sk", "hu", "gr", "eu", "us",
        "ca", "au", "nz", "jp", "kr", "in", "br", "mx", "ru", "ua", "is",
        "li", "lu", "za",
    ]

    /// A domain in the OCR text is a stronger topic signal than the
    /// surrounding prose: news.sky.com identifies a news article outright.
    public static func harvest(from text: String) -> [String] {
        var found: Set<String> = []
        for m in text.matches(of: pattern) {
            let host = String(m.1).lowercased()
            let labels = host.split(separator: ".")
            guard labels.count >= 2,
                  let last = labels.last, tlds.contains(String(last))
            else { continue }
            found.insert(host)
        }
        return found.sorted()
    }
}
