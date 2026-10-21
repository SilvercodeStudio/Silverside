/// Short descriptions of rip results, for people to read: the CLI prints them, and the app can show them.

extension Int {
    /// The number with its sign: "+6", "-269", "0".
    public var signedDescription: String { self > 0 ? "+\(self)" : "\(self)" }
}

extension DriveProfile.OffsetSource {
    public var description: String {
        switch self {
        case .manual: "set by hand"
        case .confirmed: "confirmed by rips"
        case .accurateRipList: "from AccurateRip's drive list"
        }
    }
}

extension TrackRip {
    /// "accurate (v1 28, v2 58 submissions)", or why not.
    public var summary: String {
        switch verification {
        case .accurate(let v1, let v2):
            return "accurate (v1 \(v1), v2 \(v2) submissions)"
        case .notAccurate:
            let others = matchingOffsets.map(\.signedDescription).joined(separator: ", ")
            return "NOT accurate" + (others.isEmpty ? "" : " (matches at offsets \(others))")
        case .notChecked:
            return "not checked"
        }
    }
}

extension SecureTrackRip {
    /// "accurate (v1 28, v2 58 submissions), after 2 reads of the track ...", or why not.
    public var summary: String {
        var rereads = ""
        if fullReads > 1 || rounds > 0 {
            rereads = ", after \(fullReads) reads of the track"
            if !suspectSectors.isEmpty {
                rereads += " and \(rounds) re-reads of \(suspectSectors.count) sectors"
            }
        }
        var shifted = ""
        if !shiftedReads.isEmpty {
            let shifts = shiftedReads.map(\.signedDescription).joined(separator: ", ")
            shifted =
                firstReadWasShifted
                ? "; the first read lost its place (\(shifts) samples) and was replaced"
                : "; \(shiftedReads.count) reads lost their place (\(shifts) samples) and were left out"
        }
        let text: String
        switch status {
        case .accurate(let v1, let v2):
            text = "accurate (v1 \(v1), v2 \(v2) submissions)" + rereads
        case .matchesOtherPressings(let offsets):
            text =
                "free of errors, but matches only other pressings (offsets "
                + offsets.map(\.signedDescription).joined(separator: ", ") + ")"
        case .consistent:
            text = "not in AccurateRip; reads agree" + rereads
        case .consistentButNotAccurate:
            text =
                "NOT accurate, but \(fullReads) reads agree: this pressing may not be in AccurateRip,"
                + " or an error reads the same each time"
        case .suspect:
            let most = versionCounts.values.max() ?? 0
            text =
                "NOT accurate: \(unresolvedSectors.count) of \(suspectSectors.count) suspect sectors unresolved"
                + rereads + "; up to \(most) versions of a sector"
        }
        return text + shifted
    }
}
