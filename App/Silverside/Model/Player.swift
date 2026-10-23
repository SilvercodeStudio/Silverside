import AVFoundation
import Foundation
import Observation
import SilversideKit

/// Plays one track at a time, to check a disc or an earlier rip: a file from a rip or the
/// library, or a track of the disc in a drive, read as a rip reads it. One player serves
/// the whole app, so starting a track anywhere stops the one playing.
@Observable
final class Player {
    /// What plays: a file, or a track of the disc in a drive.
    enum Source: Equatable {
        case file(URL)
        case disc(slotID: String, track: Int)
    }

    struct Item: Equatable {
        var source: Source
        var title: String
        var subtitle: String
        /// The length in seconds.
        var seconds: Double
    }

    private(set) var item: Item?
    private(set) var isPlaying = false
    /// Where playback is, in seconds from the item's start.
    private(set) var position: Double = 0
    /// Why the item stopped early, if it did.
    private(set) var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var disc: (makeDrive: @Sendable () throws -> any CDDrive, toc: TOC, track: TOC.Track)?
    @ObservationIgnored private var feeder: DiscFeeder?
    /// The node counts its time from the last start; this is where that start was, in seconds.
    @ObservationIgnored private var startSeconds: Double = 0
    @ObservationIgnored private var sampleRate: Double = 44100
    /// Tells a stale completion, from an item that was stopped, from the current item's.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clock: Task<Void, Never>?

    /// The disc's audio, as the engine delivers it: 44.1 kHz stereo, as floats for the mixer.
    nonisolated static let discFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    init() {
        engine.attach(node)
    }

    func isCurrent(_ source: Source) -> Bool { item?.source == source }

    /// Plays a file: a rip's WAV file, or an encoded file in the library.
    func play(file url: URL, title: String, subtitle: String) {
        stop()
        do {
            let audio = try AVAudioFile(forReading: url)
            file = audio
            item = Item(
                source: .file(url), title: title, subtitle: subtitle,
                seconds: Double(audio.length) / audio.processingFormat.sampleRate)
            try connect(format: audio.processingFormat)
            try start(fromFrame: 0)
        } catch {
            fail("\(url.lastPathComponent) cannot be played: \(error.localizedDescription)")
        }
    }

    /// Plays a track of the disc in a drive, read as a rip reads it.
    func play(disc slot: DriveSlot, track: TOC.Track, title: String, subtitle: String) {
        guard let info = slot.disc else { return }
        stop()
        disc = (slot.makeDrive, info.toc, track)
        item = Item(
            source: .disc(slotID: slot.id, track: track.number), title: title, subtitle: subtitle,
            seconds: Double(info.toc.sectorRange(of: track).count) / Double(CDDA.sectorsPerSecond))
        do {
            try connect(format: Self.discFormat)
            try start(fromFrame: 0)
        } catch {
            fail("The track cannot be played: \(error.localizedDescription)")
        }
    }

    func togglePause() {
        guard let item else { return }
        if isPlaying {
            node.pause()
            isPlaying = false
        } else if position >= item.seconds - 0.05 || error != nil {
            try? start(fromFrame: 0)
        } else {
            do {
                if !engine.isRunning { try engine.start() }
                node.play()
                isPlaying = true
            } catch {
                fail("Playback cannot start: \(error.localizedDescription)")
            }
        }
    }

    func seek(to seconds: Double) {
        guard let item else { return }
        let frame = Int(min(max(seconds, 0), item.seconds) * sampleRate)
        do {
            try start(fromFrame: frame)
        } catch {
            fail("Playback cannot start: \(error.localizedDescription)")
        }
    }

    func stop() {
        generation += 1
        clock?.cancel()
        clock = nil
        feeder?.stop()
        feeder = nil
        node.stop()
        if engine.isRunning { engine.stop() }
        file = nil
        disc = nil
        item = nil
        isPlaying = false
        position = 0
        error = nil
    }

    /// Stops playback from a drive, before a rip or a repair reads it, or when its disc is gone.
    func stop(drive slotID: String) {
        if case .disc(let id, _) = item?.source, id == slotID { stop() }
    }

    private func connect(format: AVAudioFormat) throws {
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sampleRate = format.sampleRate
    }

    /// Plays the item from a frame: the file from there, or the disc from that sector on.
    private func start(fromFrame frame: Int) throws {
        generation += 1
        let generation = self.generation
        feeder?.stop()
        feeder = nil
        node.stop()
        startSeconds = Double(frame) / sampleRate
        position = startSeconds
        error = nil
        let finish: @Sendable (String?) -> Void = { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(generation, error: error) } }
        }
        if let file {
            let remaining = file.length - Int64(frame)
            guard remaining > 0 else {
                finished(generation, error: nil)
                return
            }
            node.scheduleSegment(
                file, startingFrame: AVAudioFramePosition(frame), frameCount: AVAudioFrameCount(remaining), at: nil,
                completionCallbackType: .dataPlayedBack
            ) { _ in finish(nil) }
        } else if let disc {
            let feeder = DiscFeeder(
                makeDrive: disc.makeDrive, toc: disc.toc, track: disc.track,
                startSector: frame / CDDA.samplesPerSector, node: node, format: Self.discFormat, onEnd: finish)
            self.feeder = feeder
            feeder.start()
        } else {
            return
        }
        if !engine.isRunning { try engine.start() }
        node.play()
        isPlaying = true
        runClock()
    }

    private func finished(_ generation: Int, error: String?) {
        guard generation == self.generation, let item else { return }
        self.error = error
        isPlaying = false
        node.stop()
        feeder?.stop()
        feeder = nil
        position = error == nil ? item.seconds : position
        clock?.cancel()
        clock = nil
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    private func runClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                updatePosition()
            }
        }
    }

    private func updatePosition() {
        guard isPlaying, let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime) else {
            return
        }
        position = min(startSeconds + Double(time.sampleTime) / time.sampleRate, item?.seconds ?? 0)
    }
}

/// Reads a track from the disc a second at a time, on a thread of its own, and keeps a few
/// seconds queued in the player node. The node's callbacks run on the engine's threads, so
/// this stays off the main actor.
nonisolated final class DiscFeeder: @unchecked Sendable {
    private let makeDrive: @Sendable () throws -> any CDDrive
    private let toc: TOC
    private let track: TOC.Track
    private let startSector: Int
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    /// Called once, with nil when the track ends, or with the error that stopped it.
    private let onEnd: @Sendable (String?) -> Void
    private let stopToken = StopToken()
    /// Lets this many pieces wait in the node before the next read.
    private let queued = DispatchSemaphore(value: 3)

    init(
        makeDrive: @escaping @Sendable () throws -> any CDDrive, toc: TOC, track: TOC.Track, startSector: Int,
        node: AVAudioPlayerNode, format: AVAudioFormat, onEnd: @escaping @Sendable (String?) -> Void
    ) {
        self.makeDrive = makeDrive
        self.toc = toc
        self.track = track
        self.startSector = startSector
        self.node = node
        self.format = format
        self.onEnd = onEnd
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Silverside playback"
        thread.start()
    }

    func stop() {
        stopToken.stop()
        queued.signal()
    }

    private func run() {
        do {
            let drive = try makeDrive()
            var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
            reader.unreadableRetries = 0
            reader.stop = stopToken
            var stream = DiscAudioStream(reader: reader, track: track, startingAtSector: startSector)
            while !stopToken.isStopped {
                guard let piece = try stream.next() else { return }
                let isLast = stream.isAtEnd
                // Wait for room in the node's queue, but not past a stop.
                while queued.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                    if stopToken.isStopped { return }
                }
                if stopToken.isStopped { return }
                node.scheduleBuffer(Self.buffer(piece, format: format), completionCallbackType: .dataPlayedBack) {
                    [self] _ in
                    queued.signal()
                    if isLast, !stopToken.isStopped { onEnd(nil) }
                }
            }
        } catch is CancellationError {
        } catch {
            if !stopToken.isStopped { onEnd("\(error)") }
        }
    }

    /// The samples (left in the low half, right in the high half) as the engine's floats.
    private static func buffer(_ samples: [UInt32], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for (index, sample) in samples.enumerated() {
            left[index] = Float(Int16(truncatingIfNeeded: sample & 0xFFFF)) / 32768
            right[index] = Float(Int16(truncatingIfNeeded: sample >> 16)) / 32768
        }
        return buffer
    }
}
