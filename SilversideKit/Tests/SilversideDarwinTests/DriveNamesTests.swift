import Testing

@testable import SilversideDarwin

/// The names that `-d` takes for a drive, so nobody has to type "HL-DT-ST BD-RE BU50N".
struct DriveNamesTests {
    func drive(_ vendor: String, _ product: String) -> OpticalDrive {
        OpticalDrive(vendor: vendor, product: product, revision: "1.0", interconnect: "USB", location: "External")
    }

    /// The vendor where only one drive has it, else the model; a second drive of a model gets "-2".
    @Test func namesEachDriveShortly() {
        let drives = [
            drive("MATSHITA", "BD-MLT UJ260AF"), drive("HL-DT-ST", "BD-RE BU50N"), drive("ASUS", "BW-16D1HT"),
            drive("HL-DT-ST", "DVDRAM GUC0N"), drive("ASUS", "BW-16D1HT"),
        ]
        #expect(OpticalDrive.shortNames(of: drives) == ["matshita", "bu50n", "bw-16d1ht", "guc0n", "bw-16d1ht-2"])
        // HL-DT-ST is not one plain word: its drives go by their models, with or without the other.
        #expect(OpticalDrive.shortNames(of: Array(drives.prefix(3))) == ["matshita", "bu50n", "asus"])
    }

    /// A short name, or a part of one drive's name, in any case; a part that two names have is not enough.
    @Test func findsTheDriveANameMeans() {
        let drives = [
            drive("MATSHITA", "BD-MLT UJ260AF"), drive("HL-DT-ST", "BD-RE BU50N"), drive("ASUS", "BW-16D1HT"),
        ]
        #expect(OpticalDrive.indices(named: "asus", in: drives) == [2])
        #expect(OpticalDrive.indices(named: "BU50N", in: drives) == [1])
        #expect(OpticalDrive.indices(named: "uj260", in: drives) == [0])
        #expect(OpticalDrive.indices(named: "bd-", in: drives) == [0, 1])
        #expect(OpticalDrive.indices(named: "pioneer", in: drives).isEmpty)
    }
}
