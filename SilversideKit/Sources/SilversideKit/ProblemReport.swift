import Foundation

/// A report of a problem as a new GitHub issue: Help › Report a Problem… opens the issue form in
/// the browser, with headings for the user to fill in and what the maintainer needs to know about
/// the Mac and its drives. Nothing is sent until the user submits the form. Help › Send
/// Feedback… opens a new discussion instead, for comments and ideas that are not problems.
public enum ProblemReport {
    public static let repository = URL(string: "https://github.com/SilvercodeStudio/Silverside")!

    /// A drive as the report lists it.
    public struct Drive: Sendable {
        public var profile: DriveProfile
        /// How it connects: "USB", "SATA".
        public var interconnect: String

        public init(profile: DriveProfile, interconnect: String) {
            self.profile = profile
            self.interconnect = interconnect
        }

        /// "MATSHITA BD-MLT UJ260AF 1.00, USB, read offset +103 (confirmed by rips)".
        var line: String {
            let name = [profile.vendor, profile.product, profile.revision].filter { !$0.isEmpty }.joined(separator: " ")
            let offset =
                profile.offset.map { offset in
                    let source =
                        switch offset.source {
                        case .manual: "set by hand"
                        case .confirmed: "confirmed by rips"
                        case .accurateRipList: "from AccurateRip's list"
                        }
                    return "read offset \(offset.value > 0 ? "+" : "")\(offset.value) (\(source))"
                } ?? "read offset not known"
            return [name, interconnect, offset].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// The issue's text: the headings to fill in, then the program, the system, and the drives.
    public static func body(drives: [Drive], system: String = system) -> String {
        """
        ### What happened


        ### What you expected


        ### How to make it happen again


        <!-- For a problem with a rip, attach its "Rip Report.log" or disc.json, from the rip's \
        folder. For a problem with a drive, attach its report: Settings › Drives › Save Report. -->

        ---
        \(SilversideVersion.program)
        \(system)
        Drives:\(drives.isEmpty ? " none" : "")
        \(drives.map { "- \($0.line)" }.joined(separator: "\n"))
        """
    }

    /// The new issue's page, filled in.
    public static func issueURL(drives: [Drive], system: String = system) -> URL {
        var components = URLComponents(
            url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: body(drives: drives, system: system))]
        return components.url!
    }

    /// The text of a new discussion: room for the comment, then the program and the system.
    public static func feedbackBody(system: String = system) -> String {
        """


        <!-- Comments, ideas, and questions are welcome here. For a problem, use Help › Report a \
        Problem… instead. -->

        ---
        \(SilversideVersion.program)
        \(system)
        """
    }

    /// A new discussion's page in the General category, filled in. The repository must have
    /// Discussions on.
    public static func feedbackURL(system: String = system) -> URL {
        var components = URLComponents(
            url: repository.appending(path: "discussions/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "category", value: "general"),
            URLQueryItem(name: "body", value: feedbackBody(system: system)),
        ]
        return components.url!
    }

    /// "macOS 26.2 (Build 25C56), Mac15,8, Apple silicon".
    public static var system: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(arm64)
            let architecture = "Apple silicon"
        #else
            let architecture = "Intel"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(
            of: "Version ", with: "")
        return ["macOS \(version)", String(cString: model), architecture].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
