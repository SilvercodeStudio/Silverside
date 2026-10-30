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
