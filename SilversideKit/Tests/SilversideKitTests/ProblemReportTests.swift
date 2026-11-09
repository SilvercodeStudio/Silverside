import Foundation
import Testing

@testable import SilversideKit

struct ProblemReportTests {
    @Test func listsTheSystemAndEachDrive() {
        var confirmed = DriveProfile(vendor: "MATSHITA", product: "BD-MLT UJ260AF", revision: "1.00")
        confirmed.record(disc: "a", offsets: [103])
        confirmed.record(disc: "b", offsets: [103, 773])
        var manual = DriveProfile(vendor: "ASUS", product: "BW-16D1HT", revision: "3.10")
        manual.manualOffset = -6
        var listed = DriveProfile(vendor: "HL-DT-ST", product: "BD-RE BU50N", revision: "1.03")
        listed.listedOffset = 6
        let unknown = DriveProfile(vendor: "PLDS", product: "DS8A5SH", revision: "")
        let drives = [confirmed, manual, listed, unknown].map { ProblemReport.Drive(profile: $0, interconnect: "USB") }

        let body = ProblemReport.body(drives: drives, system: "macOS 26.2 (Build 25C56), Mac15,8, Apple silicon")
        #expect(body.hasPrefix("### What happened\n"))
        #expect(body.contains("Settings › Drives › Save Report"))
        #expect(
            body.contains("\n---\n\(SilversideVersion.program)\nmacOS 26.2 (Build 25C56), Mac15,8, Apple silicon\n"))
        #expect(
            body.hasSuffix(
                """
                Drives:
                - MATSHITA BD-MLT UJ260AF 1.00, USB, read offset +103 (confirmed by rips)
                - ASUS BW-16D1HT 3.10, USB, read offset -6 (set by hand)
                - HL-DT-ST BD-RE BU50N 1.03, USB, read offset +6 (from AccurateRip's list)
                - PLDS DS8A5SH, USB, read offset not known
                """))
        #expect(ProblemReport.body(drives: [], system: "x").hasSuffix("Drives: none\n"))
    }

    @Test func opensANewIssueWithTheText() throws {
        let url = ProblemReport.issueURL(drives: [], system: "macOS 26.2, Mac15,8, Apple silicon")
        #expect(url.absoluteString.hasPrefix("https://github.com/SilvercodeStudio/Silverside/issues/new?body="))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(
            components.queryItems?.first?.value
                == ProblemReport.body(drives: [], system: "macOS 26.2, Mac15,8, Apple silicon"))
    }

    @Test func opensANewDiscussionForFeedback() throws {
        let system = "macOS 26.2, Mac15,8, Apple silicon"
        let url = ProblemReport.feedbackURL(system: system)
        #expect(url.absoluteString.hasPrefix("https://github.com/SilvercodeStudio/Silverside/discussions/new?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "category" }?.value == "general")
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body == ProblemReport.feedbackBody(system: system))
        #expect(body.hasSuffix("---\n\(SilversideVersion.program)\n\(system)"))
        #expect(!body.contains("Drives"))
    }

    @Test func namesTheMac() {
        #expect(ProblemReport.system.hasPrefix("macOS "))
        #expect(ProblemReport.system.contains("Mac"))
    }
}
