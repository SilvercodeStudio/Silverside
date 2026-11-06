import CryptoKit
import Darwin
import Foundation
import SilversideKit

/// Only public, opaque-handle function signatures from dvd_reader.h are used.
/// No DVD library, private ABI structs, cipher code or keys are linked or copied.
final class DVDLibrary {
    typealias Open =
        @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafePointer<CChar>) -> OpaquePointer?
    typealias Close = @convention(c) (OpaquePointer) -> Void
    typealias OpenFile = @convention(c) (OpaquePointer, Int32, Int32) -> OpaquePointer?
    typealias Read = @convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int
    typealias Blocks = @convention(c) (OpaquePointer, Int32, Int, UnsafeMutableRawPointer) -> Int
    typealias Size = @convention(c) (OpaquePointer) -> Int
    typealias Volume =
        @convention(c) (OpaquePointer, UnsafeMutablePointer<CChar>, UInt32, UnsafeMutablePointer<UInt8>?, UInt32) ->
        Int32
    let handle: UnsafeMutableRawPointer
    let path: String
    let open: Open
    let close: Close
    let openFile: OpenFile
    let closeFile: Close
    let readBytes: Read
    let readBlocks: Blocks
    let size: Size
    let volume: Volume

    init() throws {
        let override = ProcessInfo.processInfo.environment["SILVERSIDE_DVDREAD"]
        let candidates =
            override.map { [$0] } ?? [
                "/opt/homebrew/opt/libdvdread/lib/libdvdread.8.dylib",
                "/usr/local/opt/libdvdread/lib/libdvdread.8.dylib",
            ]
        var selected: (UnsafeMutableRawPointer, String)?
        var errors = [String]()
        for candidate in candidates where candidate != "none" {
            guard candidate.hasPrefix("/"), FileManager.default.fileExists(atPath: candidate) else { continue }
            if let library = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) {
                selected = (library, candidate)
                break
            }
            errors.append(dlerror().map { String(cString: $0) } ?? "Loading failed.")
        }
        guard let (library, candidate) = selected else {
            throw DVDError(
                "DVD support needs compatible Homebrew libdvdread/libdvdcss. Install with: brew install libdvdread. "
                    + errors.joined(separator: " "))
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(library, name) else {
                throw DVDError("libdvdread is missing \(name); update it with Homebrew.")
            }
            return unsafeBitCast(address, to: type)
        }
        do {
            open = try symbol("DVDOpenAudio", as: Open.self)
            close = try symbol("DVDClose", as: Close.self)
            openFile = try symbol("DVDOpenFile", as: OpenFile.self)
            closeFile = try symbol("DVDCloseFile", as: Close.self)
            readBytes = try symbol("DVDReadBytes", as: Read.self)
            readBlocks = try symbol("DVDReadBlocks", as: Blocks.self)
            size = try symbol("DVDFileSize", as: Size.self)
            volume = try symbol("DVDUDFVolumeInfo", as: Volume.self)
            guard dlsym(library, "dvdcpxm_init") != nil else {
                throw DVDError("The installed DVD libraries lack CPPM support; update them with Homebrew.")
            }
        } catch {
            dlclose(library)
            throw error
        }
        handle = library
        path = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
    }
    deinit { dlclose(handle) }

    func withDisc<T>(_ source: String, body: (OpaquePointer) throws -> T) throws -> T {
        alarm(120)
        guard let disc = source.withCString({ open(nil, nil, $0) }) else {
            throw DVDError("Cannot open DVD-Audio source \(source).")
        }
        defer {
            alarm(120)
            close(disc)
            alarm(0)
        }
        return try body(disc)
    }

    func information(_ disc: OpaquePointer, titleSet: Int) throws -> Data {
        alarm(120)
        guard let file = openFile(disc, Int32(titleSet), 0) else {
            throw DVDError("Missing DVD-Audio information file for title set \(titleSet).")
        }
        defer { closeFile(file) }
        let blocks = size(file)
        guard blocks > 0, blocks <= 8192 else { throw DVDError("Invalid or oversized DVD information file.") }
        var data = Data(count: blocks * 2048)
        let read = data.withUnsafeMutableBytes { readBytes(file, $0.baseAddress!, $0.count) }
        guard read == data.count else { throw DVDError("Short read of DVD navigation.") }
        return data
    }

    func inventory(_ disc: OpaquePointer, source: String) throws -> DVDInventory {
        let manager = try information(disc, titleSet: 0)
        let count = try DVDNavigation.titleSetCount(manager: manager)
        var hash = SHA256()
        hash.update(data: manager)
        var presentations = [DVDPresentation]()
        var issues = [DVDTitleSetIssue]()
        for title in 1...count {
            do {
                let data = try information(disc, titleSet: title)
                hash.update(data: data)
                let references = try DVDNavigation.videoReferences(manager: manager, ifo: data, titleSet: title)
                var sectors = 0
                if references.isEmpty {
                    guard let file = openFile(disc, Int32(title), 3) else {
                        throw DVDError("Missing audio files for title set \(title).")
                    }
                    sectors = size(file)
                    closeFile(file)
                }
                presentations += try DVDNavigation.presentations(
                    ifo: data, titleSet: title, audioSectors: sectors, videoReferences: references)
            } catch {
                issues.append(.init(titleSet: title, reason: String(describing: error)))
            }
        }
        var name = [CChar](repeating: 0, count: 256)
        _ = volume(disc, &name, UInt32(name.count), nil, 0)
        let label = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        var inventory = DVDInventory(
            source: source, volume: String(bytes: label, encoding: .isoLatin1) ?? "DVD-Audio",
            fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), libraryPath: path,
            presentations: presentations)
        inventory.titleSetIssues = issues
        return inventory
    }

    func copy(_ disc: OpaquePointer, titleSet: Int, first: Int, count: Int, output: String) throws {
        guard titleSet > 0, titleSet <= 99, first >= 0, count > 0, first <= Int(Int32.max) - count else {
            throw DVDError("Invalid audio read range.")
        }
        guard let file = openFile(disc, Int32(titleSet), 3) else { throw DVDError("Cannot open audio title set.") }
        defer { closeFile(file) }
        guard first + count <= size(file) else { throw DVDError("Audio read exceeds title-set size.") }
        let fd = Darwin.open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DVDError("Cannot create new audio file: \(String(cString: strerror(errno))).") }
        let destination = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var buffer = [UInt8](repeating: 0, count: 128 * 2048)
        var done = 0
        var progress = Date()
        while done < count {
            alarm(120)
            let requested = min(128, count - done)
            let got = buffer.withUnsafeMutableBytes {
                readBlocks(file, Int32(first + done), requested, $0.baseAddress!)
            }
            guard got == requested else {
                throw DVDError(
                    "Short DVD read at sector \(first + done): \(got)/\(requested). Check drive access and authentication. libdvdread 7.1.1/libdvdcss 1.6.0 also fail on some unprotected sources without an MKB; see docs/internal/DVD.md."
                )
            }
            try DVDPackets.checkAudio(buffer.prefix(got * 2048))
            try destination.write(contentsOf: buffer.prefix(got * 2048))
            done += got
            if Date().timeIntervalSince(progress) >= 2 || done == count {
                FileHandle.standardError.write(Data("Read \(done)/\(count) sectors\n".utf8))
                progress = Date()
            }
        }
        try destination.synchronize()
        try destination.close()
    }
}
