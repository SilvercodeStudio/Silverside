import Foundation
import SilversideKit

/// The agreement to rip only discs the user owns (`Settings.agreedToPersonalUse`), which the
/// app asks for too. `silverside rip` asks once at a terminal; `--accept-disclaimer` agrees ahead.
enum Disclaimer {
    /// Returns when the user has agreed, now or before; the answer is saved in the settings.
    static func require() throws {
        var settings = try Settings.load()
        if settings.agreedToPersonalUse { return }
        guard isatty(STDIN_FILENO) != 0 else {
            throw CommandError(
                "\(SilversideLicense.personalUse)\n\nsilverside rips only after you agree to this. "
                    + "To agree, run silverside --accept-disclaimer.")
        }
        print(SilversideLicense.personalUse)
        print()
        print(SilversideLicense.personalUseAgreement)
        print("Type yes to agree (asked only once): ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "yes" || answer == "y" else {
            throw CommandError("Not agreed, so nothing is ripped.")
        }
        settings.agreedToPersonalUse = true
        try settings.save()
        print()
    }

    /// Agrees ahead of time, as for a script or another account.
    static func accept() throws {
        var settings = try Settings.load()
        settings.agreedToPersonalUse = true
        try settings.save()
        print(SilversideLicense.personalUse)
        print()
        print("Agreed: \(SilversideLicense.personalUseAgreement)")
        print("silverside config set agreedToPersonalUse false takes it back.")
    }
}
