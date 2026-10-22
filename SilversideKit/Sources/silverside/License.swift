import ArgumentParser
import SilversideKit

struct License: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the license, and the code from others that silverside includes.")

    func run() {
        print(SilversideLicense.text)
        print(
            """

            silverside includes Swift Argument Parser (https://github.com/apple/swift-argument-parser),
            Copyright Apple Inc. and the Swift project authors, under the Apache License 2.0 with
            the Runtime Library Exception.
            """)
    }
}
