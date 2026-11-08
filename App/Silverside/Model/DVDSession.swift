import AppKit
import Foundation
import Observation
import SilversideKit

/// One inserted DVD, independent of the CD TOC/AccurateRip workflow.
@Observable
final class DVDSession {
    let bsdName: String
    private(set) var isPresent = true
    private(set) var hasInspected = false
    var inventory: DVDInventory?
    var metadata: DVDMetadata?
    var selectedProgram = ""
    private(set) var isInspecting = false
    private(set) var isRipping = false
    private(set) var isStopping = false
    private(set) var status = "Ready to inspect DVD-Audio"
    private(set) var fraction: Double?
    private(set) var log: [String] = []
    private(set) var output: URL?
    private(set) var report: DVDRipReport?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stop = StopToken()
    @ObservationIgnored private var operation = UUID()

    init(bsdName: String) { self.bsdName = bsdName }
    var isAccessingDrive: Bool { isInspecting || isRipping }
    var presentation: DVDPresentation? { inventory?.presentations.first { $0.id == selectedProgram } }
    var selectedMetadata: DVDMetadata.Program? { metadata?.programs.first { $0.id == selectedProgram } }
    var title: String { metadata?.albumName.isEmpty == false ? metadata!.albumName : inventory?.volume ?? "DVD-Audio" }

    var cannotRip: String? {
        if !isPresent { return "This disc is no longer in the drive." }
        if isAccessingDrive { return "Wait for the current operation to finish." }
        guard let inventory, let metadata, !selectedProgram.isEmpty else { return "Choose an audio program." }
        do {
            _ = try DVDExtraction.select(inventory, title: selectedProgram)
            try metadata.validate(inventory: inventory, selected: [selectedProgram])
            return nil
        } catch { return String(describing: error) }
    }

    func inspect() {
        guard isPresent, !isAccessingDrive else { return }
        stop = StopToken()
        let token = stop
        let source = "/dev/r" + bsdName
        let id = UUID()
        operation = id
        isInspecting = true
        hasInspected = true
        error = nil
        status = "Inspecting DVD-Audio…"
        task = Task {
            defer {
                if operation == id {
                    isInspecting = false
                    isStopping = false
                }
            }
            do {
                let found = try await DVDWorkflow.inspect(source: source, stop: token)
                try token.check()
                guard operation == id else { return }
                inventory = found
                var names = DVDMetadata(inventory: found)
                try names.set("album=\(found.volume)")
                metadata = names
                selectedProgram = ""
                let saved = try metadataURL(fingerprint: found.fingerprint)
                if FileManager.default.fileExists(atPath: saved.path) {
                    let restored = try DVDMetadata.read(from: saved)
                    try restored.validate(inventory: found)
                    metadata = restored
                }
                status = "Choose a program and review its names."
            } catch is CancellationError {
                if operation == id { status = "Inspection stopped" }
            } catch {
                if operation == id {
                    self.error = String(describing: error)
                    status = "DVD inspection needs attention"
                }
            }
        }
    }

    func importMetadata(from url: URL) {
        guard !isAccessingDrive, let inventory else { return }
        do {
            let imported = try DVDMetadata.read(from: url)
            try imported.validate(inventory: inventory)
            metadata = imported
            try saveMetadata()
            error = nil
        } catch { self.error = String(describing: error) }
    }

    func edit(_ key: String, value: String) {
        guard !isAccessingDrive, var edited = metadata else { return }
        do {
            try edited.set("\(key)=\(value)", program: selectedProgram)
            metadata = edited
            try saveMetadata()
            error = nil
        } catch { self.error = String(describing: error) }
    }

    func name(of track: DVDMetadata.Track, artist: Bool = false) -> String {
        guard let names = try? metadata?.names(track) else { return "" }
        return artist ? names.artist : names.title
    }

    func saveMetadata() throws {
        guard let metadata else { return }
        let url = try metadataURL(fingerprint: metadata.fingerprint)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metadata.write(to: url, replacing: true)
    }

    private func metadataURL(fingerprint: String) throws -> URL {
        guard fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit) else {
            throw DVDError("Invalid DVD fingerprint for saved metadata.")
        }
        return Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("DVD Metadata")
            .appendingPathComponent(fingerprint + ".json")
    }

    func chooseDestination(agreed: Bool) {
        guard cannotRip == nil else { return }
        guard agreed else {
            error = "Please accept the personal-use agreement in Settings → General before ripping."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save DVD-Audio Rip"
        panel.message = "Choose a new folder for verified FLAC tracks and the rip report."
        panel.nameFieldStringValue = NameTemplate.safeComponent(
            title + " - " + selectedProgram.replacingOccurrences(of: ":", with: "-"))
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.start(output: url)
        }
    }

    private func start(output: URL) {
        guard cannotRip == nil, let metadata else { return }
        do {
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw DVDError("Choose a new folder; an existing destination is never overwritten.")
            }
            try saveMetadata()
        } catch {
            self.error = String(describing: error)
            return
        }
        let program = selectedProgram
        let source = "/dev/r" + bsdName
        stop = StopToken()
        let token = stop
        let id = UUID()
        operation = id
        isRipping = true
        isStopping = false
        self.output = output
        report = nil
        error = nil
        log = []
        fraction = nil
        status = "Starting DVD-Audio rip…"
        task = Task {
            defer {
                if operation == id {
                    isRipping = false
                    isStopping = false
                    fraction = nil
                }
            }
            do {
                let result = try await DVDWorkflow.rip(
                    source: source, output: output, title: program, metadata: metadata,
                    stop: token
                ) { [weak self = self] event in
                    DispatchQueue.main.async {
                        guard let self, self.operation == id, self.isRipping else { return }
                        self.receive(event)
                    }
                }
                guard operation == id else { return }
                report = result
                status = "Rip complete — \(result.programs.flatMap(\.tracks).count) tracks verified"
                log.append(status)
            } catch {
                guard operation == id else { return }
                status = error is CancellationError ? "Rip stopped" : "Rip failed"
                self.error = error is CancellationError ? nil : String(describing: error)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let data = try? Data(contentsOf: output.appendingPathComponent("dvd-rip.json")) {
                    report = try? decoder.decode(DVDRipReport.self, from: data)
                }
                log.append(status + ". Any partial output and diagnostics remain in the chosen folder.")
            }
        }
    }

    func cancel() {
        guard isAccessingDrive else { return }
        isStopping = true
        stop.stop()
        task?.cancel()
        status = "Stopping…"
    }

    func disconnect() {
        isPresent = false
        cancel()
    }

    private func receive(_ progress: DVDProgress) {
        guard !isStopping else { return }
        fraction = nil
        switch progress {
        case .inspecting: status = "Rechecking the disc…"
        case .reading(let program, let sectors, let total):
            fraction = total > 0 ? min(1, Double(sectors) / Double(total)) : nil
            status = "Reading program \(program) · \(Int((fraction ?? 0) * 100))%"
        case .decoding(_, let first, let last): status = "Decoding tracks \(first)–\(last)…"
        case .checking(_, let track, let total): status = "Verifying track \(track) of \(total)…"
        case .published: status = "Verified tracks saved"
        case .finished: status = "Finishing rip report…"
        }
        if log.last != status { log.append(status) }
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
