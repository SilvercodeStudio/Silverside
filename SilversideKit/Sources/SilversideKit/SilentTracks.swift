/// What encoding does with tracks that are all digital silence, such as the 91 tracks of one
/// second before the hidden songs of Nine Inch Nails *Broken* (tracks 98 and 99). The rip
/// reads and verifies them in any case: CTDB checks the whole disc, and a disc image keeps them.
public enum SilentTrackChoice: String, Codable, CaseIterable, Sendable {
    /// The app asks when such a disc is about to be encoded; the command line asks at a
    /// terminal, and leaves them out otherwise.
    case ask
    /// No files for them; the other tracks keep the disc's numbers.
    case leaveOut = "leave-out"
    /// A file for each, as for any track.
    case keep
}

extension RipReport.Track {
    /// True if every sample of the track is zero. Such a track leaves nothing for the CRC-32
    /// that skips silent samples, which is then the CRC-32 of nothing: 00000000. The encoder
    /// checks the samples again before it leaves a track out (`DiscEncoder.leavesOutSilentTracks`).
    public var isSilent: Bool { crc32SkipZero == "00000000" }
}

extension RipReport {
    /// The audio tracks that are all digital silence, which an encoding can leave out. None if
    /// every track is: then there would be nothing left.
    public var silentTracks: [Int] {
        let silent = tracks.filter { $0.number > 0 && $0.isSilent }.map(\.number)
        return silent.count == tracks.count ? [] : silent
    }

    /// "Tracks 7-97 are digital silence (91 of 99 tracks, 1:31 in all).", or nil if none is.
    public var silentTracksText: String? {
        let numbers = silentTracks
        guard !numbers.isEmpty else { return nil }
        let sectors = tracks.filter { numbers.contains($0.number) }.map(\.sectors).reduce(0, +)
        let seconds = (sectors + CDDA.sectorsPerSecond / 2) / CDDA.sectorsPerSecond
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return numbers.count == 1
            ? "Track \(numbers[0]) is digital silence (\(length))."
            : "Tracks \(Self.list(numbers)) are digital silence (\(numbers.count) of \(tracks.count) tracks,"
                + " \(length) in all)."
    }
}
