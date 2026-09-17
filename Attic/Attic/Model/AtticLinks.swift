import Foundation

/// Where the app points people: the source, the issue tracker, and the place to
/// support the work.
///
/// Derived from two strings rather than written out three times, so the repo
/// link and the issues link cannot drift apart, and so switching the whole lot
/// on is one edit rather than a hunt.
///
/// Every URL is optional, and the interface draws nothing for a `nil` one. A
/// button that opens a dead page is worse than an absent button: it looks like
/// the app is broken rather than like the link does not exist yet.
enum AtticLinks {

    /// `owner/repo` on GitHub, once the repository exists.
    static let repository = ""

    /// The GitHub account that receives sponsorships. Separate from the
    /// repository because Sponsors is per-account, and because someone may want
    /// the source public without asking for money.
    static let sponsorAccount = ""

    static var source: URL? {
        guard !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)")
    }

    static var issues: URL? {
        guard !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/issues")
    }

    /// Deliberately called "support" rather than "donate" throughout.
    ///
    /// The app is free and says so; asking for money is an invitation, not a
    /// toll. "Donate" in a prominent button starts to read as a nag, and this
    /// app's whole posture is that it does not oversell itself.
    static var support: URL? {
        guard !sponsorAccount.isEmpty else { return nil }
        return URL(string: "https://github.com/sponsors/\(sponsorAccount)")
    }

    /// The authoring guide, for the "how do I write a definition" link. Points
    /// at the file in the repository, so it follows whatever the repo is called.
    static var definitionsGuide: URL? {
        guard !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/blob/main/DEFINITIONS.md")
    }

    static var hasAny: Bool { source != nil || issues != nil || support != nil }
}
