import AVFoundation

/// Whether audio about to play holds a DTS stream, which plays as static without a decode.
/// The look is at the first second with sound: a track can start with seconds of digital
/// silence, and a piece of it can end just after the stream starts.
public enum DTSPlaybackCheck {
    /// Samples of sound to look at: a second.
    public static let soundToLook = 44_100
    /// Silence to read past, at most, for the sound of a file.
    public static let silenceToSkip = 60 * 44_100
    /// Frames that make the look a stream: fewer than a whole track's `DTSStream.minimumFrames`,
    /// as a second holds about 43.
    public static let minimumFrames = 4

    /// True if a file's first second with sound is a DTS stream. `read` gives up to `count`
    /// samples from `start`, or nil at the file's end (or for a file that is not 16-bit stereo).
    public static func holdsStream(read: (_ start: Int, _ count: Int) throws -> [UInt32]?) -> Bool {
        var start = 0
        while start < silenceToSkip {
            guard let piece = try? read(start, 44_100), !piece.isEmpty else { return false }
            if let first = piece.firstIndex(where: { $0 != 0 }) {
                guard let sound = try? read(start + first, soundToLook) else { return false }
                return DTSStream.isStream(sound, minimumFrames: minimumFrames)
            }
            start += piece.count
        }
        return false
    }

    /// True if the file's first second with sound is a DTS stream. Only a stereo file at
    /// 44.1 kHz, as a rip has it, is read: a decoded album's 5.1 is not.
    public static func holdsStream(file url: URL) -> Bool {
        holdsStream { try read(url, from: $0, frames: $1) }
    }

    /// Up to `frames` samples of the file from `start`, as Silverside samples. Nil for a file
    /// that is not stereo at 44.1 kHz, or at its end.
    static func read(_ url: URL, from start: Int, frames: Int) throws -> [UInt32]? {
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

    /// The pieces of a track as it is read from a disc, to play in order, and the decision
    /// once a second of sound (or the track's end) is there. Silence before any sound plays at
    /// once.
    public struct Pieces: Sendable {
        public enum Step: Equatable, Sendable {
            /// Hold the piece: too little sound yet.
            case wait
            /// Play these pieces as they are (silence before the decision, or any piece after it).
            case play([[UInt32]])
            /// The decision, and the pieces held for it, to play the way it says.
            case decided(isStream: Bool, pieces: [[UInt32]])
        }

        private var waiting = [[UInt32]]()
        public private(set) var isDecided = false

        public init() {}

        /// Takes the next piece; `isLast` for the track's last one.
        public mutating func add(_ piece: [UInt32], isLast: Bool) -> Step {
            guard !isDecided else { return .play([piece]) }
            waiting.append(piece)
            let all = waiting.flatMap { $0 }
            guard let first = all.firstIndex(where: { $0 != 0 }) else {
                defer { waiting = [] }
                return .play(waiting)
            }
            if !isLast, all.count - first < soundToLook { return .wait }
            isDecided = true
            defer { waiting = [] }
            return .decided(
                isStream: DTSStream.isStream(Array(all[first...]), minimumFrames: minimumFrames), pieces: waiting)
        }
    }
}
