import Foundation
import Testing

@testable import SilversideKit

struct LicenseTests {
    @Test func textMatchesTheLicenseFile() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appending(path: "LICENSE"), encoding: .utf8)
        #expect(SilversideLicense.text == file.trimmingCharacters(in: .newlines))
    }

    @Test func hdcdTextMatchesTheVendoredLicense() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = try String(contentsOf: root.appending(path: "Vendor/HDCD/LICENSE"), encoding: .utf8)
        #expect(SilversideLicense.hdcdDecoder == file.trimmingCharacters(in: .newlines))
    }
}
