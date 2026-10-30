import AVFoundation
import Foundation
import Observation
import SilversideKit

/// Plays one track at a time, to check a disc or an earlier rip: a file from a rip or the
/// library, or a track of the disc in a drive, read as a rip reads it. One player serves
/// the whole app, so starting a track anywhere stops the one playing. A DTS-CD's stream plays
/// through ffmpeg, mixed down to stereo, if it is installed.
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
    /// A file that holds a DTS stream, which plays through ffmpeg.
    @ObservationIgnored private var dtsFile: URL?
    @ObservationIgnored private var dtsFeeder: DTSFileFeeder?
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

    /// What the player says about a DTS stream when ffmpeg is not there to decode it.
    nonisolated static let dtsWithoutFFmpeg =
        "A DTS stream, which plays as static. To hear it, install ffmpeg (in Terminal: brew install ffmpeg)."

    /// Plays a file: a rip's WAV file, or an encoded file in the library. `holdsDTS` is true
    /// when the rip says the file holds a DTS stream; else the file's audio tells.
    func play(file url: URL, title: String, subtitle: String, holdsDTS: Bool = false) {
        stop()
        do {
            let audio = try AVAudioFile(forReading: url)
            if holdsDTS || DTSFileFeeder.holdsStream(url) {
                item = Item(
                    source: .file(url), title: title, subtitle: subtitle,
                    seconds: Double(audio.length) / audio.processingFormat.sampleRate)
                guard FFmpeg.program() != nil else {
                    error = Self.dtsWithoutFFmpeg
                    return
                }
                dtsFile = url
                try connect(format: Self.discFormat)
                try start(fromFrame: 0)
                return
            }
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
        dtsFeeder?.stop()
        dtsFeeder = nil
        node.stop()
        if engine.isRunning { engine.stop() }
        file = nil
        disc = nil
        dtsFile = nil
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
        dtsFeeder?.stop()
        dtsFeeder = nil
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
        } else if let dtsFile, let ffmpeg = FFmpeg.program() {
            let feeder = DTSFileFeeder(
                file: dtsFile, startFrame: frame, ffmpeg: ffmpeg, node: node, format: Self.discFormat, onEnd: finish)
            dtsFeeder = feeder
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
        dtsFeeder?.stop()
        dtsFeeder = nil
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
    private let lock = NSLock()
    /// The decode of a DTS stream, once the track turns out to hold one.
    private var playback: DTSPlayback?

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
        lock.withLock { playback }?.terminate()
    }

    private func run() {
        do {
            let drive = try makeDrive()
            var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
            reader.unreadableRetries = 0
            reader.stop = stopToken
            var stream = DiscAudioStream(reader: reader, track: track, startingAtSector: startSector)
            // The first second with sound says whether the track is a DTS stream (`DTSPlaybackCheck`).
            var check = DTSPlaybackCheck.Pieces()
            while !stopToken.isStopped {
                guard let next = try stream.next() else { return }
                let pieces: [[UInt32]]
                switch check.add(next, isLast: stream.isAtEnd) {
                case .wait: continue
                case .play(let some): pieces = some
                case .decided(let isStream, let held):
                    if isStream {
                        guard let ffmpeg = FFmpeg.program() else {
                            onEnd(Player.dtsWithoutFFmpeg)
                            return
                        }
                        let started = try DTSPlayback(
                            ffmpeg: ffmpeg, node: node, format: format, queued: queued, stopToken: stopToken,
                            onEnd: onEnd)
                        lock.withLock { playback = started }
                    }
                    pieces = held
                }
                if try !play(pieces, isLastAtEnd: stream.isAtEnd) { return }
            }
        } catch is CancellationError {
        } catch {
            if !stopToken.isStopped { onEnd("\(error)") }
        }
    }

    /// Plays the pieces, through the DTS decode if the track holds a stream; the last one ends
    /// the track if `isLastAtEnd`. False after a stop.
    private func play(_ pieces: [[UInt32]], isLastAtEnd: Bool) throws -> Bool {
        for (index, piece) in pieces.enumerated() {
            let isLast = isLastAtEnd && index == pieces.count - 1
            if let playback = lock.withLock({ playback }) {
                try playback.feed(piece)
                if isLast { playback.finish() }
                continue
            }
            // Wait for room in the node's queue, but not past a stop.
            while queued.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                if stopToken.isStopped { return false }
            }
            if stopToken.isStopped { return false }
            node.scheduleBuffer(Self.buffer(piece, format: format), completionCallbackType: .dataPlayedBack) {
                [self] _ in
                queued.signal()
                if isLast, !stopToken.isStopped { onEnd(nil) }
            }
        }
        return !stopToken.isStopped
    }

    /// The samples (left in the low half, right in the high half) as the engine's floats.
    static func buffer(_ samples: [UInt32], format: AVAudioFormat) -> AVAudioPCMBuffer {
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

/// Decodes a DTS stream with ffmpeg as it is read, mixed down to stereo, into the player
/// node: the stream goes in on the reading thread, and the decode comes out on a thread of
/// its own. ffmpeg's pipes keep the reading in step with the playing.
nonisolated final class DTSPlayback: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let queued: DispatchSemaphore
    private let stopToken: StopToken
    private let onEnd: @Sendable (String?) -> Void

    init(
        ffmpeg: URL, node: AVAudioPlayerNode, format: AVAudioFormat, queued: DispatchSemaphore, stopToken: StopToken,
        onEnd: @escaping @Sendable (String?) -> Void
    ) throws {
        self.node = node
        self.format = format
        self.queued = queued
        self.stopToken = stopToken
        self.onEnd = onEnd
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-f", "dts", "-i", "pipe:0", "-ac", "2", "-c:a", "pcm_f32le", "-f",
            "f32le", "pipe:1",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A write after ffmpeg has gone must fail, not end the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let thread = Thread { [self] in readDecode() }
        thread.name = "Silverside DTS playback"
        thread.start()
    }

    /// Gives ffmpeg more of the stream; it waits while ffmpeg is a few seconds ahead.
    func feed(_ samples: [UInt32]) throws {
        try input.fileHandleForWriting.write(contentsOf: samples.withUnsafeBytes { Data($0) })
    }

    /// The stream has ended: ffmpeg decodes the rest, and the last of it ends the item.
    func finish() {
        try? input.fileHandleForWriting.close()
    }

    /// Stops ffmpeg at once, so that neither thread waits on it.
    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Reads the decode, about a tenth of a second at least at a time, and keeps one piece back
    /// so that the last one can end the item.
    private func readDecode() {
        let handle = output.fileHandleForReading
        let bytesPerFrame = 8
        var pending = Data()
        var held: AVAudioPCMBuffer?
        while !stopToken.isStopped {
            let chunk = (try? handle.read(upToCount: 44_100 * bytesPerFrame)) ?? nil
            let ended = chunk?.isEmpty ?? true
            if let chunk { pending.append(chunk) }
            let whole = pending.count / bytesPerFrame * bytesPerFrame
            if whole >= 4_410 * bytesPerFrame || (ended && whole > 0) {
                let buffer = Self.buffer(pending.prefix(whole), format: format)
                pending.removeFirst(whole)
                if let held, !schedule(held, isLast: false) { return }
                held = buffer
            }
            if ended {
                if let held { _ = schedule(held, isLast: true) } else if !stopToken.isStopped { onEnd(nil) }
                return
            }
        }
    }

    /// Schedules a piece once the node has room; false if playback stopped first.
    private func schedule(_ buffer: AVAudioPCMBuffer, isLast: Bool) -> Bool {
        while queued.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            if stopToken.isStopped { return false }
        }
        if stopToken.isStopped { return false }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            queued.signal()
            if isLast, !stopToken.isStopped { onEnd(nil) }
        }
        return true
    }

    /// Interleaved stereo floats as the engine's buffer.
    private static func buffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = data.count / 8
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for frame in 0..<frames {
                left[frame] = values[2 * frame]
                right[frame] = values[2 * frame + 1]
            }
        }
        return buffer
    }
}

/// Plays a file that holds a DTS stream (a DTS-CD's rip, or its album as the disc has it):
/// reads it a second at a time from a frame on, and gives it to `DTSPlayback`.
nonisolated final class DTSFileFeeder: @unchecked Sendable {
    private let file: URL
    private let startFrame: Int
    private let ffmpeg: URL
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let onEnd: @Sendable (String?) -> Void
    private let stopToken = StopToken()
    private let queued = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var playback: DTSPlayback?

    init(
        file: URL, startFrame: Int, ffmpeg: URL, node: AVAudioPlayerNode, format: AVAudioFormat,
        onEnd: @escaping @Sendable (String?) -> Void
    ) {
        self.file = file
        self.startFrame = startFrame
        self.ffmpeg = ffmpeg
        self.node = node
        self.format = format
        self.onEnd = onEnd
    }

    /// True if the file's first second with sound is a DTS stream: 16-bit stereo, as a rip has it.
    static func holdsStream(_ url: URL) -> Bool {
        DTSPlaybackCheck.holdsStream { try read(url, from: $0, frames: $1) }
    }

    /// Up to `frames` samples of the file from `start`, as Silverside samples. Nil for a file
    /// that is not 16-bit stereo at 44.1 kHz, or at its end.
    private static func read(_ url: URL, from start: Int, frames: Int) throws -> [UInt32]? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.fileFormat.channelCount == 2, file.fileFormat.sampleRate == 44_100 else { return nil }
        file.framePosition = AVAudioFramePosition(start)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let data = buffer.int16ChannelData else { return nil }
        return UnsafeRawPointer(data[0]).withMemoryRebound(to: UInt32.self, capacity: Int(buffer.frameLength)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(buffer.frameLength)))
        }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Silverside DTS file playback"
        thread.start()
    }

    func stop() {
        stopToken.stop()
        queued.signal()
        lock.withLock { playback }?.terminate()
    }

    private func run() {
        do {
            let playback = try DTSPlayback(
                ffmpeg: ffmpeg, node: node, format: format, queued: queued, stopToken: stopToken, onEnd: onEnd)
            lock.withLock { self.playback = playback }
            let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatInt16, interleaved: true)
            audio.framePosition = AVAudioFramePosition(startFrame)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 44_100)!
            while !stopToken.isStopped {
                try audio.read(into: buffer)
                guard buffer.frameLength > 0, let data = buffer.int16ChannelData else { break }
                let samples = UnsafeRawPointer(data[0]).withMemoryRebound(
                    to: UInt32.self, capacity: Int(buffer.frameLength)
                ) { Array(UnsafeBufferPointer(start: $0, count: Int(buffer.frameLength))) }
                try playback.feed(samples)
            }
            playback.finish()
        } catch {
            if !stopToken.isStopped { onEnd("\(error)") }
        }
    }
}
