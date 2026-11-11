import Foundation
import Testing

@testable import SilversideKit

struct CommandLineInstallTests {
    /// A folder with an app that has the command and its completions, and a prefix to link into.
    private func makeApp(named name: String = "Silverside.app", in root: URL) throws -> URL {
        let app = root.appending(path: name)
        let files = CommandLineInstall(app: app, prefix: root).links.map(\.source)
        for file in files {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files[0].path)
        return app
    }

    private func run(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func temporaryFolder() throws -> URL {
        // A name with a space and a quote, which the scripts must quote.
        let root = FileManager.default.temporaryDirectory.appending(path: "Silverside's CLI \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func linksTheCommandAndCompletionsAsMakeInstallLaysThemOut() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root)
        let prefix = root.appending(path: "local")
        let install = CommandLineInstall(app: app, prefix: prefix)
        #expect(CommandLineInstall.hasCommand(inApp: app))
        #expect(
            install.links.map { $0.destination.path.replacingOccurrences(of: prefix.path + "/", with: "") } == [
                "bin/silverside", "share/zsh/site-functions/_silverside", "etc/bash_completion.d/silverside",
                "share/fish/vendor_completions.d/silverside.fish",
            ])
        #expect(install.commandState == .missing)
        #expect(install.removeScript == nil)

        try run(install.installScript)
        #expect(install.links.allSatisfy { CommandLineInstall.state(of: $0) == .linked })
        // Running it again changes nothing.
        try run(install.installScript)
        #expect(install.commandState == .linked)

        try run(try #require(install.removeScript))
        #expect(install.links.allSatisfy { CommandLineInstall.state(of: $0) == .missing })
    }

    @Test func knowsALinkToAnotherCopyAndLeavesOtherFilesAlone() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root)
        let other = try makeApp(named: "Old Silverside.app", in: root)
        let prefix = root.appending(path: "local")
        try run(CommandLineInstall(app: other, prefix: prefix).installScript)

        let install = CommandLineInstall(app: app, prefix: prefix)
        #expect(install.commandState == .linkedToOtherApp(other.appending(path: "Contents/Helpers/silverside").path))
        // The other copy was deleted: its links still count as Silverside's.
        try FileManager.default.removeItem(at: other)
        #expect(install.commandState == .linkedToOtherApp(other.appending(path: "Contents/Helpers/silverside").path))

        // A copy from make install is not Silverside's link, and removing leaves it.
        let command = install.command.destination
        try FileManager.default.removeItem(at: command)
        try Data("copy".utf8).write(to: command)
        #expect(install.commandState == .other)
        try run(try #require(install.removeScript))
        #expect(install.commandState == .other)
        #expect(CommandLineInstall.state(of: install.links[1]) == .missing)

        // Installing puts the link in place of the copy.
        try run(install.installScript)
        #expect(install.commandState == .linked)
    }

    @Test func quotesForTheShell() {
        #expect(CommandLineInstall.quoted("a b") == "'a b'")
        #expect(CommandLineInstall.quoted("it's") == "'it'\\''s'")
    }
}
