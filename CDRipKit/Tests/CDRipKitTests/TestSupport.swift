import Foundation

@testable import CDRipKit

/// A small, fast pseudo-random generator, so test images are the same on every run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An audio-only disc image with random samples.
func makeDisc(trackSectors: [Int], seed: UInt64 = 1) throws -> (toc: TOC, samples: [UInt32]) {
    var starts = [Int]()
    var lba = 0
    for count in trackSectors {
        starts.append(lba)
        lba += count
    }
    let toc = try TOC(audioTrackStarts: starts, leadOutLBA: lba)
    var generator = SplitMix64(state: seed)
    let samples = (0..<(lba * CDDA.samplesPerSector)).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
    return (toc, samples)
}

extension TOC {
    /// Makes a TOC from MusicBrainz offsets, which include the 150-sector lead-in.
    init(musicBrainzOffsets offsets: [Int], sectors: Int) throws {
        try self.init(
            audioTrackStarts: offsets.map { $0 - CDDA.leadInSectors }, leadOutLBA: sectors - CDDA.leadInSectors)
    }
}

/// A web that answers each URL that starts with a known prefix, and 404 to any other. With
/// `failsEverything`, every request fails as if there were no network. Keeps the requests.
actor FakeWeb: HTTPTransport {
    var answers: [(prefix: String, data: Data)]
    var failsEverything = false
    private(set) var requests: [String] = []

    init(_ answers: [(prefix: String, data: Data)] = [], failsEverything: Bool = false) {
        self.answers = answers
        self.failsEverything = failsEverything
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        requests.append(url)
        if failsEverything { throw URLError(.cannotConnectToHost) }
        let status = answers.contains { url.hasPrefix($0.prefix) } ? 200 : 404
        let body = answers.first { url.hasPrefix($0.prefix) }?.data ?? Data()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }

    /// A client that uses this web, with no waits between requests, and its own cache folder.
    func client(in directory: URL) -> WebClient {
        let hosts = [
            "musicbrainz.org", "coverartarchive.org", "www.accuraterip.com", "db.cuetools.net", "p.cuetools.net",
        ]
        let policies = hosts.map { ($0, WebClient.HostPolicy(interval: .zero, lifetime: .seconds(60))) }
        return WebClient(
            directory: directory, transport: self, policies: Dictionary(uniqueKeysWithValues: policies),
            firstRetryDelay: .milliseconds(10))
    }
}

/// Bytes from hex digits. Spaces and new lines are ignored.
func hexBytes(_ text: String) -> [UInt8] {
    let digits = text.filter(\.isHexDigit)
    return stride(from: 0, to: digits.count, by: 2).map {
        let start = digits.index(digits.startIndex, offsetBy: $0)
        return UInt8(digits[start...digits.index(after: start)], radix: 16)!
    }
}
