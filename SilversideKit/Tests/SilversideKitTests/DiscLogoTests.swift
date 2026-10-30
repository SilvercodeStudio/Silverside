import Foundation
import Testing

@testable import SilversideKit

struct DiscLogoTests {
    let audio = try! TOC(audioTrackStarts: [0, 20000], leadOutLBA: 40000)

    /// One logo: the first that fits, in the order DTS, HDCD, SACD, CD+G, Enhanced CD, CD-R,
    /// CD-Text, Compact Disc.
    @Test func choosesTheMostTellingLogo() {
        #expect(DiscLogo.logo(toc: audio, format: "CD") == .compactDisc)
        #expect(DiscLogo.logo(toc: audio, format: nil, hasCDText: true) == .cdText)
        #expect(DiscLogo.logo(toc: audio, format: "CD", media: .recordable, hasCDText: true) == .recordable)
        #expect(DiscLogo.logo(toc: audio, format: "CD-R") == .recordable)
        #expect(DiscLogo.logo(toc: audio, format: "Enhanced CD", media: .recordable) == .compactDiscPlus)
        #expect(DiscLogo.logo(toc: audio, format: "CD+G") == .cdGraphics)
        #expect(DiscLogo.logo(toc: audio, format: "Hybrid SACD (CD layer)") == .sacd)
        // What the audio is goes before what the disc is.
        #expect(DiscLogo.logo(toc: audio, format: "CD", media: .recordable, probe: DiscProbe(hdcd: true)) == .hdcd)
        #expect(DiscLogo.logo(toc: audio, format: "HDCD", probe: DiscProbe(hdcd: true, dts: true)) == .dts)
    }

    /// What a look at the audio found counts; MusicBrainz's format only where nothing was read.
    @Test func trustsWhatTheAudioShows() {
        #expect(DiscLogo.logo(toc: audio, format: "HDCD") == .hdcd)
        #expect(DiscLogo.logo(toc: audio, format: "HDCD", probe: DiscProbe()) == .compactDisc)
        #expect(DiscLogo.logo(toc: audio, format: "HDCD", probe: DiscProbe(tracksRead: 0)) == .hdcd)
        #expect(DiscLogo.logo(toc: audio, format: "CD+G", probe: DiscProbe(cdGraphics: false)) == .compactDisc)
        #expect(DiscLogo.logo(toc: audio, format: "CD+G", probe: DiscProbe()) == .cdGraphics)
        #expect(DiscLogo.logo(toc: audio, format: "CD", probe: DiscProbe(cdGraphics: true)) == .cdGraphics)
    }

    /// Data after the music gets the "disc+" logo, and so does data first (Mixed Mode), by another name.
    @Test func marksAnEnhancedCD() throws {
        let enhanced = try TOC(
            tracks: [.init(number: 1, startLBA: 0), .init(number: 2, startLBA: 30000, kind: .data, session: 2)],
            leadOutLBA: 50000)
        #expect(DiscLogo.logo(toc: enhanced, format: "CD") == .compactDiscPlus)
        let mixed = try TOC(
            tracks: [.init(number: 1, startLBA: 0, kind: .data), .init(number: 2, startLBA: 20000)], leadOutLBA: 40000)
        #expect(DiscLogo.logo(toc: mixed, format: "Mixed Mode CD") == .mixedMode)
        #expect(DiscLogo.logo(toc: mixed, format: nil) == .mixedMode)
    }
}

extension DiscLogoTests {
    /// A DVD-Video disc often has an empty AUDIO_TS folder; a DVD-Audio disc has its titles there.
    @Test func tellsADVDAudioDiscFromADVD() throws {
        let volume = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: volume) }
        try FileManager.default.createDirectory(
            at: volume.appending(path: "AUDIO_TS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: volume.appending(path: "VIDEO_TS"), withIntermediateDirectories: true)
        #expect(DiscLogo.otherDisc(isBluRay: false, volume: volume) == .dvd)
        try Data().write(to: volume.appending(path: "AUDIO_TS/AUDIO_TS.IFO"))
        #expect(DiscLogo.otherDisc(isBluRay: false, volume: volume) == .dvdAudio)
        #expect(DiscLogo.otherDisc(isBluRay: false, volume: nil) == .dvd)
        #expect(DiscLogo.otherDisc(isBluRay: true, volume: volume) == .bluRay)
    }

    /// An Ultra HD Blu-ray disc's index.bdmv says version 0300; a Blu-ray disc's 0100 or 0200.
    @Test func tellsAnUltraHDBluRayDisc() throws {
        let volume = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: volume) }
        try FileManager.default.createDirectory(at: volume.appending(path: "BDMV"), withIntermediateDirectories: true)
        let index = volume.appending(path: "BDMV/index.bdmv")
        try Data("INDX0200".utf8 + [0, 0, 0, 0x4E]).write(to: index)
        #expect(DiscLogo.otherDisc(isBluRay: true, volume: volume) == .bluRay)
        try Data("INDX0300".utf8 + [0, 0, 0, 0x4E]).write(to: index)
        #expect(DiscLogo.otherDisc(isBluRay: true, volume: volume) == .ultraHDBluRay)
        #expect(DiscLogo.otherDisc(isBluRay: true, volume: nil) == .bluRay)
    }
}

struct DiscProbeTests {
    /// Three tracks of 20 seconds; `fill` gives each its samples.
    func drive(_ fill: (Int) -> [UInt32]) throws -> (SimulatedDrive, TOC) {
        let toc = try TOC(audioTrackStarts: [0, 1500, 3000], leadOutLBA: 4500)
        let samples = (0..<3).flatMap { fill($0) }
        return (SimulatedDrive(toc: toc, samples: samples), toc)
    }

    @Test func findsNothingInPlainAudio() throws {
        let (drive, toc) = try self.drive { _ in [UInt32](repeating: 0x0100_0100, count: 1500 * 588) }
        let probe = DiscProbe.probe(drive, toc: toc)
        #expect(probe == DiscProbe(cdGraphics: false, tracksRead: 3))
    }

    @Test func findsHDCDCodesAndADTSStream() throws {
        let hdcd = HDCDTests().track(.a(0), seconds: 20)
        let (drive, toc) = try self.drive { _ in Array(hdcd.prefix(1500 * 588)) }
        let plain = DiscProbe.probe(drive, toc: toc)
        #expect(plain.hdcd && plain.hdcdCodes.count == 3 && plain.hdcdFeatures == "nothing")
        // What the codes ask for shows before a rip: peak extend and a gain of -3.0 dB.
        let extended = HDCDTests().track(.a(0x10 | 3), seconds: 20)
        let (extendedDrive, _) = try self.drive { _ in Array(extended.prefix(1500 * 588)) }
        #expect(DiscProbe.probe(extendedDrive, toc: toc).hdcdFeatures == "peak extend, gain")
        let stream = DTSTests.samples(DTSTests.stream(frames: 1500 * 588 * 4 / 4096 + 1))
        let (dtsDrive, dtsTOC) = try self.drive { _ in Array(stream.prefix(1500 * 588)) }
        let found = DiscProbe.probe(dtsDrive, toc: dtsTOC)
        #expect(found.dts && !found.hdcd)
    }

    /// The subchannel of a real CD+G disc (2026-10-29, ASUS), 100 sectors of it, under the
    /// second track's probe; a drive that refuses the subchannel cannot tell.
    @Test func findsCDGraphicsInTheSubchannel() throws {
        let url = try #require(
            Bundle.module.url(forResource: "cdg-subchannel", withExtension: "bin", subdirectory: "Resources"))
        let pw = [UInt8](try Data(contentsOf: url))
        let (drive, toc) = try self.drive { _ in [UInt32](repeating: 0, count: 1500 * 588) }
        #expect(CDGraphics.holdsGraphics(pw))
        #expect(!CDGraphics.holdsGraphics([UInt8](repeating: 0, count: pw.count)))
        var generator = SplitMix64(state: 7)
        #expect(!CDGraphics.holdsGraphics((0..<pw.count).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        // The probe reads from 500 (a third of 1500) in the second track.
        for sector in 0..<100 { drive.subchannelPW?[2000 + sector] = Array(pw[(sector * 96)..<((sector + 1) * 96)]) }
        #expect(DiscProbe.probe(drive, toc: toc).cdGraphics == true)
        drive.subchannelPW = nil
        #expect(DiscProbe.probe(drive, toc: toc).cdGraphics == nil)
    }
}

extension DiscLogoTests {
    /// An earlier rip's logo comes from its report: the tracks' HDCD codes and DTS stream,
    /// CD+G graphics found before the rip, the medium, and CD-Text.
    @Test func choosesTheLogoOfARip() throws {
        let drive = RipReport.Drive(
            vendor: "SIM", product: "DRIVE", revision: "1.0", readOffset: 6, offsetSource: "--offset")
        let tracks = [
            RipReport.Track(
                number: 1, file: "Track 01.wav", startLBA: 0, sectors: 20000, preEmphasis: false,
                accurateRip: .accurate),
            RipReport.Track(
                number: 2, file: "Track 02.wav", startLBA: 20000, sectors: 20000, preEmphasis: false,
                accurateRip: .accurate),
        ]
        var report = RipReport(drive: drive, secure: true, toc: audio, tracks: tracks, ctdb: .init(status: .verified))
        #expect(DiscLogo.logo(for: report) == .compactDisc)
        var cdText = CDText()
        cdText.titles = [0: "Paris '49"]
        report.cdText = cdText
        #expect(DiscLogo.logo(for: report) == .cdText)
        report.media = .recordable
        #expect(DiscLogo.logo(for: report) == .recordable)
        report.cdGraphics = true
        #expect(DiscLogo.logo(for: report) == .cdGraphics)
        report.tracks[1].dts = true
        #expect(DiscLogo.logo(for: report) == .dts)

        let mixed = try TOC(
            tracks: [.init(number: 1, startLBA: 0, kind: .data), .init(number: 2, startLBA: 20000)],
            leadOutLBA: 40000)
        let data = RipReport(
            drive: drive, secure: true, toc: mixed, tracks: [tracks[1]], ctdb: .init(status: .verified))
        #expect(DiscLogo.logo(for: data) == .mixedMode)
        #expect(DiscLogo.medium(of: data) == "Mixed Mode")
    }

    /// The column says what HDCD codes ask for, and whether the files hold the HDCD or DTS decode.
    @Test func namesTheMediumOfARip() {
        let drive = RipReport.Drive(
            vendor: "SIM", product: "DRIVE", revision: "1.0", readOffset: 6, offsetSource: "--offset")
        let tracks = [1, 2].map {
            RipReport.Track(
                number: $0, file: "Track 0\($0).wav", startLBA: ($0 - 1) * 20000, sectors: 20000, preEmphasis: false,
                accurateRip: .accurate)
        }
        var report = RipReport(drive: drive, secure: true, toc: audio, tracks: tracks, ctdb: .init(status: .verified))
        #expect(DiscLogo.medium(of: report) == "CD")
        report.tracks[0].hdcd = HDCDCodes(packets: 200)
        #expect(DiscLogo.medium(of: report) == "HDCD")
        report.tracks[1].hdcd = HDCDCodes(packets: 200, peakExtend: .always, maxGainAdjustment: -3)
        #expect(DiscLogo.medium(of: report) == "HDCD, peak extend, gain")
        report.encoding = .init(format: .flac, encoder: "Apple AudioToolbox", folder: "Album", files: [])
        report.encoding?.hdcdDecoded = true
        #expect(DiscLogo.medium(of: report) == "HDCD, decoded")

        report.tracks[0].hdcd = nil
        report.tracks[1].hdcd = nil
        report.encoding?.hdcdDecoded = nil
        report.tracks[0].dts = true
        #expect(DiscLogo.medium(of: report) == "DTS")
        report.encoding?.dtsDecoded = "5.1"
        #expect(DiscLogo.medium(of: report) == "DTS, decoded")
    }
}
