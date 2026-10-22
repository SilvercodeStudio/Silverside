import Foundation
import IOKit
import IOKit.storage

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
    /// What the registry says of the drive, as text: its device and protocol characteristics
    /// (such as "CD Features" and "Retry Count"), and the USB bridge's names, IDs, and speed.
    /// Serial numbers are left out.
    public var registry: [String: String] = [:]

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
        }
        return drives
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

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
