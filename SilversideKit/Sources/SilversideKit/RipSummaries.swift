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
                // With no rounds, the later reads of the whole track settled the sectors.
                rereads +=
                    rounds == 0
                    ? ", which settled \(suspectSectors.count) suspect sectors"
                    : " and \(rounds) rounds of re-reads of \(suspectSectors.count) sectors"
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
                cacheFlushIncomplete && suspectSectors.isEmpty
                ? "not confirmed: no cache flush could be made, so the re-reads may have come from the cache" + rereads
                : "NOT accurate: \(unresolvedSectors.count) of \(suspectSectors.count) suspect sectors unresolved"
                    + rereads + "; up to \(most) versions of a sector"
        }
        return text + shifted + (cacheFlushIncomplete ? "; some re-reads may have come from the cache" : "")
    }
}

extension RipReport.Track {
    /// The control bits that are set, for the track's line in the log: ", pre-emphasis (Q
    /// subchannel only)", ", digital copy permitted", ", four-channel audio". Empty if none is.
    public var controlBitsSummary: String {
        var text = ""
        for flag in RipReport.ControlBit.allCases {
            let (toc, q) = (flag.inTOC(self), flag.inSubchannel(self))
            guard toc == true || q == true else { continue }
            text += ", " + flag.name
            if toc != true {
                text += " (Q subchannel only)"
            } else if q == false {
                text += " (TOC only)"
            }
        }
        if let subchannel, subchannel.isMixed {
            text +=
                ", Q frames disagree on a control bit (\(subchannel.frames) frames: pre-emphasis \(subchannel.preEmphasis),"
                + " copy permitted \(subchannel.copyPermitted), data \(subchannel.data), four-channel \(subchannel.fourChannel))"
        }
        return text
    }
}

extension RipReport {
    /// "Pre-emphasis: tracks 1-11, 28-29 (23 of 99).", or nil if no track has it.
    public var preEmphasisText: String? {
        preEmphasisTracks.map { "Pre-emphasis: \($0)." }
    }

    /// The tracks with pre-emphasis: "tracks 1-11, 28-29 (23 of 99)", "every track", or nil if none has it.
    public var preEmphasisTracks: String? {
        let numbers = tracks.filter(\.preEmphasis).map(\.number)
        guard !numbers.isEmpty else { return nil }
        return numbers.count == tracks.count
            ? "every track"
            : (numbers.count == 1 ? "track " : "tracks ") + Self.list(numbers)
                + " (\(numbers.count) of \(tracks.count))"
    }

    /// A control bit of a track, in the TOC and in the Q subchannel.
    public enum ControlBit: CaseIterable, Sendable {
        case preEmphasis
        case copyPermitted
        case fourChannel

        public var name: String {
            switch self {
            case .preEmphasis: "pre-emphasis"
            case .copyPermitted: "digital copy permitted"
            case .fourChannel: "four-channel audio"
            }
        }

        /// Whether the TOC sets the bit for the track. Nil if the report does not say (before 0.8).
        public func inTOC(_ track: Track) -> Bool? {
            guard let flags = track.tocFlags else { return self == .preEmphasis ? track.preEmphasis : nil }
            return switch self {
            case .preEmphasis: flags.preEmphasis
            case .copyPermitted: flags.copyPermitted
            case .fourChannel: flags.fourChannel
            }
        }

        /// Whether most of the track's Q frames set the bit. Nil if they were not read.
        public func inSubchannel(_ track: Track) -> Bool? {
            guard let control = track.subchannel else { return nil }
            return switch self {
            case .preEmphasis: control.hasPreEmphasis
            case .copyPermitted: control.isCopyPermitted
            case .fourChannel: control.isFourChannel
            }
        }
    }

    /// The control bits of every track, for the log and the report: "Pre-emphasis: tracks
    /// 1-11, 28-29 (Q subchannel only, not the TOC). Digital copy permitted: no track.
    /// Four-channel audio: no track." Nil for a report from before 0.8, which kept only pre-emphasis.
    public static func controlBitsSummary(of tracks: [Track]) -> String? {
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.tocFlags != nil }) else { return nil }
        let readQ = tracks.contains { $0.subchannel != nil }
        var sentences = [String]()
        for flag in ControlBit.allCases {
            let toc = tracks.filter { flag.inTOC($0) == true }.map(\.number)
            let q = tracks.filter { flag.inSubchannel($0) == true }.map(\.number)
            let all = Array(Set(toc + q)).sorted()
            var sentence = flag.name.prefix(1).uppercased() + flag.name.dropFirst() + ": "
            if all.isEmpty {
                sentence += "no track"
            } else {
                sentence +=
                    all.count == tracks.count
                    ? "every track" : (all.count == 1 ? "track " : "tracks ") + list(all)
                if toc.isEmpty {
                    sentence += " (Q subchannel only, not the TOC)"
                } else if readQ && q.isEmpty {
                    sentence += " (TOC only, not the Q subchannel)"
                } else if Set(toc) != Set(q) && readQ {
                    sentence +=
                        " (TOC: " + (toc.isEmpty ? "none" : list(toc)) + "; Q subchannel: "
                        + (q.isEmpty ? "none" : list(q)) + ")"
                }
            }
            sentences.append(sentence + ".")
        }
        let mixed = tracks.filter { $0.subchannel?.isMixed == true }.map(\.number)
        if !mixed.isEmpty {
            sentences.append(
                "The Q frames of " + (mixed.count == 1 ? "track " : "tracks ") + list(mixed)
                    + " disagree on a control bit.")
        }
        if !readQ { sentences.append("The drive did not read the Q subchannel, so these are the TOC's.") }
        return sentences.joined(separator: " ")
    }

    /// "AccurateRip has no checksum for tracks 34 and 35 (it keeps none for a silent track)", or
    /// nil when it has one for every track, or does not have the disc.
    public var noChecksumNote: String? {
        let numbers = tracks.filter { $0.accurateRip == .noChecksum }.map(\.number)
        guard !numbers.isEmpty else { return nil }
        return "AccurateRip has no checksum for \(numbers.count == 1 ? "track" : "tracks") \(RipSet.list(numbers))"
            + " (it keeps none for a silent track)"
    }

    /// The next step that is most likely to help, when the rip is not verified: for the
    /// app's result banner and the CLI. Nil when the rip is verified.
    public var advice: String? {
        guard !isVerified, let text = adviceText else { return nil }
        guard tracks.contains(where: { $0.cacheFlushIncomplete == true }) else { return text }
        return text
            + " Some re-reads may have come from the drive's cache, not the disc, so reads that agree prove less there."
    }

    private var adviceText: String? {
        let notInAccurateRip = tracks.allSatisfy { $0.accurateRip == .notInDatabase }
        let unresolved = tracks.filter { !$0.unresolvedSectors.isEmpty }
        if notInAccurateRip && ctdb.status == .notInDatabase {
            let reads =
                unresolved.isEmpty
                ? "and they did."
                : "and in \(unresolved.count == 1 ? "1 track" : "\(unresolved.count) tracks") they did not: "
                    + "clean the disc and rip it again, or rip it in another drive."
            return
                "No database knows this disc, so the rip cannot be proved. Silverside can only show that reads agree, "
                + reads
        }
        if !secure {
            return
                "Fast mode read each track once. Rip the disc again in Secure mode: it re-reads the sectors that differ, and tries a repair with CTDB's data."
        }
        if ctdb.status == .notChecked {
            return
                "CTDB did not check this rip: it was offline, or not every track was ripped. Repair checks the rip against CTDB, and can repair it when every track is there."
        }
        var text = ""
        switch ctdb.status {
        case .notVerified:
            text =
                ctdb.entriesWithoutRepairData > 0
                ? "The entries in CTDB that match this pressing have no repair data. "
                : "CTDB knows this disc, but the errors are too many for its repair data. "
        case .partlyRepaired: text = "CTDB repaired some tracks, not the whole disc. "
        default: break
        }
        text +=
            "Another rip of the disc gives more versions of the damaged sectors, and Repair pools the rips. A rip in another drive helps most, because each drive reads damage differently."
        if unresolved.count >= 3 { text += " The errors are in many places, so clean the disc first." }
        return text
    }
}
