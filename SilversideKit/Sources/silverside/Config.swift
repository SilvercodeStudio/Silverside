import ArgumentParser
import Foundation
import SilversideKit

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change the settings that silverside and the app share.",
        discussion: """
            The settings are a JSON file (see silverside config path). An option on the command line overrides its \
            setting. Keys with a dot are in a group, such as aac.bitRate. Values are JSON (192, true, \
            ["-q", "0"]) or plain text.

            Examples:
              silverside config set library /Volumes/storage/Music
              silverside config set format alac
              silverside config set plainPunctuation true
              silverside config set aac.mode cbr
              silverside config unset aac.mode
            """,
        subcommands: [Show.self, Path.self, Get.self, Set.self, Unset.self, Reset.self],
        defaultSubcommand: Show.self)

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print every setting, as the file has them.")

        func run() throws {
            print(try Settings.load().value(of: ""))
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the settings file's path.")

        func run() {
            print(Settings.defaultURL.path)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one setting.")

        @Argument(help: "The setting, such as format or aac.bitRate.")
        var key: String

        func run() throws {
            print(try Settings.load().value(of: key))
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one setting.")

        @Argument(help: "The setting, such as format or aac.bitRate.")
        var key: String

        @Argument(help: "The value: JSON (192, true, [\"-q\", \"0\"]) or plain text.")
        var value: String

        func run() throws {
            let settings = try Settings.load().setting(key, to: value)
            try settings.save()
            print("\(key) = \(try settings.value(of: key))")
        }
    }

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put one setting back to its default.")

        @Argument(help: "The setting, such as format or aac.bitRate.")
        var key: String

        func run() throws {
            let settings = try Settings.load().resetting(key)
            try settings.save()
            print("\(key) = \(try settings.value(of: key))")
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put every setting back to its default.")

        func run() throws {
            try Settings().save()
            print("Every setting is back to its default, in \(Settings.defaultURL.path).")
        }
    }
}
