import Foundation
import Testing

@testable import SilversideKit

struct HDCDTests {
    /// Audio with HDCD codes in the lowest bit of both channels, as an HDCD master hides them.
    /// The decoder reads the bits through a descrambler (bit k of its window XOR bits k + 5
    /// and k + 23), so the bits are scrambled here to match. Each packet is a sync word and a
    /// control code: type A has an 8-bit code, type B a 16-bit code (the code, then its
    /// inverse, which `check` replaces to make the packet damaged).
    struct Encoder {
        enum Packet {
            case a(UInt8)
            case b(UInt8, check: UInt8? = nil)
        }

        private var lsb = [Bool]()
        private var plain = [Bool]()

        /// `count` bits that ask for nothing.
        mutating func pause(_ count: Int) {
            for _ in 0..<count { add(false) }
        }

        mutating func add(_ packet: Packet) {
            switch packet {
            case .a(let code):
                add(0x7e0f_a005, bits: 32)
                add(UInt32(code), bits: 8)
            case .b(let code, let check):
                add(0x7e0f_a006, bits: 32)
                add(UInt32(code), bits: 8)
                add(UInt32(check ?? ~code), bits: 8)
            }
        }

        private mutating func add(_ value: UInt32, bits: Int) {
            for bit in (0..<bits).reversed() { add(value >> bit & 1 == 1) }
        }

        private mutating func add(_ bit: Bool) {
            plain.append(bit)
            let n = lsb.count
            let earlier = (n >= 5 && lsb[n - 5]) != (n >= 23 && lsb[n - 23])
            lsb.append(bit != earlier)
        }

        /// A quiet 440 Hz tone, the same in both channels, with the bits in its lowest bit.
        var samples: [UInt32] {
            lsb.enumerated().map { index, bit in
                let tone = Int16(3000 * sin(2 * .pi * 440 * Double(index) / 44100)) & ~1 | (bit ? 1 : 0)
                return UInt32(UInt16(bitPattern: tone)) * 0x1_0001
            }
        }
    }

    /// Ten seconds of `packet`, ten times a second, which is how often HDCD masters send them.
    func track(_ packet: Encoder.Packet) -> [UInt32] {
        var encoder = Encoder()
        for _ in 0..<100 {
            encoder.pause(4410 - 40)
            encoder.add(packet)
        }
        return encoder.samples
    }

    @Test func findsCodesThatAskForNothing() throws {
        let codes = try #require(HDCDCodes.scan(track(.a(0))))
        // Both channels count each packet.
        #expect(codes == HDCDCodes(packets: 200))
        #expect(!codes.changesAudio)
        #expect(codes.featuresText == "nothing")
    }

    /// Type A doubles its 3-bit gain into half-dB steps: 3 is -3.0 dB.
    @Test func readsPeakExtendAndGainFromTypeA() throws {
        let codes = try #require(HDCDCodes.scan(track(.a(0x10 | 3))))
        #expect(codes == HDCDCodes(packets: 200, peakExtend: .always, maxGainAdjustment: -3))
        #expect(codes.changesAudio)
        #expect(codes.featuresText == "peak extend, gain down to -3.0 dB")
    }

    /// Type B has a 4-bit gain in half-dB steps (5 is -2.5 dB), and the transient filter bit.
    @Test func readsTypeBAndCountsDamagedPackets() throws {
        var encoder = Encoder()
        for index in 0..<100 {
            encoder.pause(4410 - 48)
            encoder.add(index % 10 == 9 ? .b(0x25, check: 0x00) : index < 50 ? .b(0x05) : .b(0x20))
        }
        let codes = try #require(HDCDCodes.scan(encoder.samples))
        #expect(codes == HDCDCodes(packets: 180, maxGainAdjustment: -2.5, transientFilter: true, errors: 20))
        #expect(codes.featuresText == "gain down to -2.5 dB")
    }

    @Test func findsNoCodesInPlainAudio() {
        var random = SplitMix64(state: 7)
        let noise = (0..<441_000).map { _ in UInt32(truncatingIfNeeded: random.next()) }
        #expect(HDCDCodes.scan(noise) == nil)
        #expect(HDCDCodes.scan([UInt32](repeating: 0, count: 44100)) == nil)
        // Codes in one channel only are not HDCD.
        let left = track(.a(0)).map { $0 & 0xFFFF }
        #expect(HDCDCodes.scan(left) == nil)
    }

    @Test func sumsUpTheTracksOfARip() {
        func track(_ number: Int, _ codes: HDCDCodes?) -> RipReport.Track {
            var track = RipReport.Track(
                number: number, file: "Track 0\(number).wav", startLBA: 0, sectors: 1, preEmphasis: false,
                accurateRip: .accurate)
            track.hdcd = codes
            return track
        }
        var report = RipReport(
            drive: .init(vendor: "", product: "", revision: "", readOffset: 0, offsetSource: ""), secure: true,
            toc: try! TOC(ctdbTOCString: "0:15000:30000"), tracks: [track(1, nil), track(2, nil)],
            ctdb: .init(status: .notChecked))
        #expect(report.hdcdText == nil)
        report.hdcd = HDCDStatus(report.tracks)
        #expect(report.hdcd == .noCodes && report.hdcdText == nil)

        report.tracks = [track(1, HDCDCodes(packets: 9)), track(2, HDCDCodes(packets: 9))]
        report.hdcd = HDCDStatus(report.tracks)
        #expect(report.hdcd == .codesOnly)
        #expect(report.hdcdText?.hasPrefix("HDCD: every track has HDCD codes, but") == true)

        report.tracks[1].hdcd?.peakExtend = .sometimes
        report.tracks.append(track(3, nil))
        report.hdcd = HDCDStatus(report.tracks)
        #expect(report.hdcd == .featuresUsed)
        #expect(report.hdcdText?.contains("2 of 3 tracks have HDCD codes") == true)
        #expect(report.hdcdText?.contains("track 2: peak extend in places") == true)
    }
}
