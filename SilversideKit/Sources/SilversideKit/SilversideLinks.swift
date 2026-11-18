import Foundation

/// The web pages that the app and the command-line tool link to.
public enum SilversideLinks {
    /// The website: Help › Silverside Website, and the About window's Website.
    public static let website = URL(string: "https://silverside.app")!

    /// The studio that makes Silverside, and its other apps: the About window's copyright line.
    public static let studio = URL(string: "https://silvercode.studio")!

    /// The studio's page for a tip: Help › Support Silverside, the About window's Leave a Tip, and
    /// `silverside --help`. The page ignores `from` today; it is there so that a later
    /// page can choose Silverside, or count where visitors come from, also for older versions.
    public static let sponsor = URL(string: "https://silvercode.studio/sponsor?from=silverside")!
}
