import Foundation
import IOKit
import IOKit.storage
import SilversideKit

/// An optical drive that macOS knows about, from the IOKit registry.
public struct OpticalDrive: Equatable, Sendable {
    public var vendor: String
    public var product: String
    public var revision: String
    /// How the drive is connected, such as "USB" or "SATA".
    public var interconnect: String
    /// "Internal" or "External".
    public var location: String
    /// The BSD name of the CD in the drive, such as "disk14". Nil if there is no CD.
    public var discBSDName: String?
    /// A disc in the drive that is not a CD (a DVD, DVD-Audio, or Blu-ray disc), which
    /// Silverside does not rip, and its BSD name, for Eject.
    public var otherDisc: DiscLogo?
    public var otherDiscBSDName: String?
    /// What the registry says of the drive, as text: its device and protocol characteristics
    /// (such as "CD Features" and "Retry Count"), and the USB bridge's names, IDs, and speed.
    /// Serial numbers are left out.
    public var registry: [String: String] = [:]
    /// The drive's path in the I/O Registry's service plane, which Disc Recording knows it by.
    public var registryPath: String?

    public init(
        vendor: String, product: String, revision: String, interconnect: String, location: String,
        discBSDName: String? = nil, registry: [String: String] = [:]
    ) {
        self.vendor = vendor
        self.product = product
        self.revision = revision
        self.interconnect = interconnect
        self.location = location
        self.discBSDName = discBSDName
        self.registry = registry
    }

    /// All CD, DVD, and Blu-ray drives, in registry order.
    public static func all() -> [OpticalDrive] {
        var iterator: io_iterator_t = 0
        // IOCompactDiscServices, IODVDServices, and IOBDServices are all subclasses of this class.
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOCDBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var drives = [OpticalDrive]()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let device = property(service, "Device Characteristics") as? [String: Any] ?? [:]
            let protocolInfo = property(service, "Protocol Characteristics") as? [String: Any] ?? [:]
            drives.append(
                OpticalDrive(
                    vendor: device["Vendor Name"] as? String ?? "",
                    product: device["Product Name"] as? String ?? "",
                    revision: device["Product Revision Level"] as? String ?? "",
                    interconnect: protocolInfo["Physical Interconnect"] as? String ?? "",
                    location: protocolInfo["Physical Interconnect Location"] as? String ?? "",
                    discBSDName: cdBSDName(below: service), registry: registry(device, protocolInfo, service)))
            drives[drives.count - 1].registryPath = path(of: service)
            if drives[drives.count - 1].discBSDName == nil, let other = otherMedia(below: service) {
                drives[drives.count - 1].otherDiscBSDName = other.bsdName
                drives[drives.count - 1].otherDisc = DiscLogo.otherDisc(
                    isBluRay: other.isBluRay, volume: mountPoint(of: other.bsdName))
            }
        }
        return drives
    }

    /// The DVD or Blu-ray medium below a drive, if one is in it.
    private static func otherMedia(below service: io_service_t) -> (bsdName: String, isBluRay: Bool)? {
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryCreateIterator(
                service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let isBluRay = IOObjectConformsTo(entry, "IOBDMedia") != 0
            if isBluRay || IOObjectConformsTo(entry, "IODVDMedia") != 0,
                let name = property(entry, kIOBSDNameKey) as? String
            {
                return (name, isBluRay)
            }
        }
        return nil
    }

    /// Where the disc's file system is mounted, if it is: the whole disc, or its first slice.
    private static func mountPoint(of bsdName: String) -> URL? {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return nil }
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard from == "/dev/\(bsdName)" || from.hasPrefix("/dev/\(bsdName)s") else { continue }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return URL(filePath: on, directoryHint: .isDirectory)
        }
        return nil
    }

    /// Finds the IOCDMedia object below a drive. DVD and Blu-ray media are other classes.
    private static func cdBSDName(below service: io_service_t) -> String? {
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryCreateIterator(
                service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, kIOCDMediaClass) != 0 {
                return property(entry, kIOBSDNameKey) as? String
            }
        }
        return nil
    }

    private static func registry(_ device: [String: Any], _ protocolInfo: [String: Any], _ service: io_service_t)
        -> [String: String]
    {
        var result = [String: String]()
        for (key, value) in device { result["Device: \(key)"] = "\(value)" }
        for (key, value) in protocolInfo { result["Protocol: \(key)"] = "\(value)" }
        // The USB device above the drive: the enclosure's bridge.
        var entry = service
        IOObjectRetain(entry)
        for _ in 0..<12 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry)
            entry = parent
            if property(entry, "idVendor") != nil {
                for key in [
                    "USB Vendor Name", "USB Product Name", "idVendor", "idProduct", "bcdDevice", "Device Speed",
                ] {
                    guard let value = property(entry, key) else { continue }
                    // USB IDs are looked up in hex, as 0x13FD.
                    let isID = key.hasPrefix("id") || key == "bcdDevice"
                    result["USB bridge: \(key)"] =
                        isID ? (value as? Int).map { String(format: "0x%04X", $0) } ?? "\(value)" : "\(value)"
                }
                break
            }
        }
        IOObjectRelease(entry)
        return result
    }

    private static func path(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_string_t>.size)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension OpticalDrive {
    /// "MATSHITA BD-MLT UJ260AF".
    public var name: String { [vendor, product].filter { !$0.isEmpty }.joined(separator: " ") }

    /// Names to type for a drive, one for each of `drives`: its vendor in lowercase ("asus",
    /// "matshita") where it is one plain word that no other drive has, else its model, the
    /// product's last word ("bu50n" for HL-DT-ST's). A second drive of the same model gets "-2".
    public static func shortNames(of drives: [OpticalDrive]) -> [String] {
        let vendors = drives.map { $0.vendor.lowercased() }
        var names = drives.enumerated().map { index, drive in
            let vendor = vendors[index]
            if vendor.wholeMatch(of: /[a-z]+/) != nil, vendors.filter({ $0 == vendor }).count == 1 { return vendor }
            return (drive.product.split(separator: " ").last.map(String.init) ?? drive.product).lowercased()
        }
        var seen = [String: Int]()
        for index in names.indices {
            let count = seen[names[index], default: 0] + 1
            seen[names[index]] = count
            if count > 1 { names[index] += "-\(count)" }
        }
        return names
    }

    /// The drives that `text` names: the drive whose short name it is, else every drive whose
    /// name holds it ("bu50n", "lg" does not: the vendor is "HL-DT-ST"), ignoring case.
    public static func indices(named text: String, in drives: [OpticalDrive]) -> [Int] {
        let wanted = text.lowercased()
        if let exact = shortNames(of: drives).firstIndex(of: wanted) { return [exact] }
        return drives.indices.filter { drives[$0].name.lowercased().contains(wanted) }
    }
}
