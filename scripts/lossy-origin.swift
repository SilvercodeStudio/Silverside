#!/usr/bin/env -S swift -O
// Looks at decoded audio for signs that it came from a lossy file, such as an MP3 burned to a
// CD-R, and ends with a call: YES, MAYBE, NO, or CAN'T TELL.
//
//     scripts/lossy-origin.swift <file or folder>...
//
// Reads anything AudioToolbox reads (FLAC, WAV, AIFF, ALAC, MP3, AAC). Two signs, calibrated
// on Willie Nelson's "Shotgun Willie" from a CD-R and on LAME 3.100 encodes of it (2026-11-07):
//
// - A cliff: the average spectrum falls by 20 dB or more within 500 Hz and stays down, with
//   sound in the 1 kHz below it (so a test tone, or a TV's 15.7 kHz whine on a tape, is not
//   one). Encoders cut everything above a fixed frequency: LAME 128 kbps near 16.5 kHz,
//   192 kbps near 18.5 kHz, 320 kbps at 20 kHz, V0 near 20.75 kHz. Real masters roll off
//   gently (the CD-R fell 14 dB per 500 Hz at most), but a steep resampling filter can look
//   like a cliff above about 21 kHz, so a cliff there counts for nothing.
// - Holes: in MP3-frame-sized windows, the 16-19.5 kHz band drops out (60 dB below 4-8 kHz)
//   in some frames and comes back in others. LAME 128 kbps: 47% of frames; 192 kbps: 11%;
//   V0: 2%; 320 kbps: 0%; both CD-Rs: 0%. Old recordings with noise reduction drop out a
//   little too (Django Reinhardt: 3%), so holes alone count from 5%, or from 0.5% with a cliff.
//
// A cliff from 19.5 to 21 kHz with no holes is MAYBE: LAME 320 kbps looks like that, and so
// do remasters with a steep filter near 20.5 kHz. In two tracks of each album of the test
// library (500 tracks, nearly all from pressed CDs), 34 were MAYBE, all of them pressed CDs,
// and the YES tracks were an album kept as MP3 and one track of a radio compilation. NO means
// no sign of the usual encoders; it cannot prove the source was lossless.

import Accelerate
import AudioToolbox
import Foundation

struct Analysis {
    var bands: [(hz: Double, db: Double)] = []
    var cliff: Double?
    var holes = 0.0
    var medianHigh = -200.0
    var framesWithMusic = 0
    var verdict = ""
    var reason = ""
}

func readMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
    var file: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else {
        throw NSError(domain: "lossy-origin", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open"])
    }
    defer { ExtAudioFileDispose(file) }
    var source = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source)
    let channels = max(Int(source.mChannelsPerFrame), 1)
    var client = AudioStreamBasicDescription(
        mSampleRate: source.mSampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    ExtAudioFileSetProperty(
        file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &client)
    var mono = [Float]()
    let chunk = 65536
    var buffer = [Float](repeating: 0, count: chunk * channels)
    while true {
        var frames = UInt32(chunk)
        let status = buffer.withUnsafeMutableBytes { bytes -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress))
            return ExtAudioFileRead(file, &frames, &list)
        }
        guard status == noErr else {
            throw NSError(
                domain: "lossy-origin", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "read failed"])
        }
        if frames == 0 { break }
        for i in 0..<Int(frames) {
            var sum: Float = 0
            for c in 0..<channels { sum += buffer[i * channels + c] }
            mono.append(sum / Float(channels))
        }
    }
    return (mono, source.mSampleRate)
}

func analyze(_ x: [Float], rate: Double) -> Analysis {
    let n = 2048
    let hop = 1152
    let log2n = vDSP_Length(11)
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    let fullScale = Double(window.reduce(0, +)) * Double(window.reduce(0, +))
    let binHz = rate / Double(n)
    func bin(_ hz: Double) -> Int { min(Int(hz / binHz), n / 2) }

    var sum = [Double](repeating: 0, count: n / 2)
    var ratios = [Double]()
    var windows = 0
    var re = [Float](repeating: 0, count: n / 2)
    var im = [Float](repeating: 0, count: n / 2)
    var frame = [Float](repeating: 0, count: n)
    var power = [Float](repeating: 0, count: n / 2)
    var start = 0
    while start + n <= x.count {
        x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        func mean(_ a: Double, _ b: Double) -> Double {
            var total: Float = 0
            power.withUnsafeBufferPointer {
                vDSP_sve($0.baseAddress! + bin(a), 1, &total, vDSP_Length(bin(b) - bin(a)))
            }
            return Double(total) / Double(bin(b) - bin(a))
        }
        let mid = mean(4000, 8000)
        if mid / fullScale > 1e-7 { ratios.append(10 * log10(max(mean(16000, 19500), 1e-30) / mid)) }
        for i in 0..<n / 2 { sum[i] += Double(power[i]) }
        windows += 1
        start += hop
    }

    var result = Analysis()
    guard windows > 0 else {
        result.verdict = "CAN'T TELL"
        result.reason = "too short"
        return result
    }
    let top = min(22000, rate / 2 - 50)
    var hz = 10000.0
    while hz + 250 <= top {
        var total = 0.0
        for i in bin(hz)..<bin(hz + 250) { total += sum[i] }
        let level = total / Double(windows * (bin(hz + 250) - bin(hz))) / fullScale
        result.bands.append((hz, 10 * log10(max(level, 1e-30))))
        hz += 250
    }
    // The lowest band whose level everything from 500 Hz above it stays 20 dB under, with
    // sound in each band of the 1 kHz below it, so that a test tone is not a cliff.
    for i in result.bands.indices where i >= 4 && i + 2 < result.bands.count {
        let after = result.bands[(i + 2)...].map(\.db).max()!
        let below = result.bands[(i - 4)...i].map(\.db).min()!
        if result.bands[i].db - after >= 20 && below - after >= 20 {
            result.cliff = result.bands[i].hz + 250
            break
        }
    }
    ratios.sort()
    result.framesWithMusic = ratios.count
    if !ratios.isEmpty {
        result.medianHigh = ratios[ratios.count / 2]
        result.holes = 100 * Double(ratios.filter { $0 < -60 }.count) / Double(ratios.count)
    }

    let holesCount = result.framesWithMusic >= 100 && result.medianHigh > -50
    let cliff = result.cliff.map { String(format: "%.2f kHz", $0 / 1000) }
    if let c = result.cliff, c < 19500 {
        result.verdict = "YES"
        result.reason =
            "a cliff at \(cliff!), where lossy encoders cut"
            + (abs(c - 16000) <= 250 ? " (or a source sampled at 32 kHz, as some broadcasts are)" : "")
    } else if let c = result.cliff, c < 21000, holesCount && result.holes >= 0.5 {
        result.verdict = "YES"
        result.reason =
            "a cliff at \(cliff!), and the band above 16 kHz drops out in "
            + String(format: "%.1f%% of frames", result.holes)
    } else if holesCount && result.holes >= 5 {
        result.verdict = "YES"
        result.reason = String(format: "the band above 16 kHz drops out in %.1f%% of frames", result.holes)
    } else if let c = result.cliff, c < 21000 {
        result.verdict = "MAYBE"
        result.reason = "a cliff at \(cliff!): MP3 at 320 kbps, or a master with a steep filter"
    } else if result.medianHigh <= -60 || result.framesWithMusic < 100 {
        result.verdict = "CAN'T TELL"
        result.reason = "too little sound above 16 kHz to judge"
    } else {
        result.verdict = "NO"
        result.reason =
            result.cliff == nil
            ? "no cliff, and no frame drops out above 16 kHz"
            : "only a steep filter at \(cliff!), as resampling leaves; no frame drops out"
    }
    return result
}

let extensions: Set<String> = ["flac", "wav", "aif", "aiff", "m4a", "mp3", "aac", "caf"]
var files = [URL]()
for argument in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
        print("Not found: \(argument)")
        continue
    }
    if isFolder.boolValue {
        let found =
            FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension.lowercased()) } ?? []
        files += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    } else {
        files.append(url)
    }
}
guard !files.isEmpty else {
    print("Usage: lossy-origin.swift <audio file or folder>...")
    exit(2)
}

var verdicts = [String: [String]]()
for file in files {
    print(file.lastPathComponent)
    do {
        let (samples, rate) = try readMono(file)
        let a = analyze(samples, rate: rate)
        let shown = a.bands.filter { $0.hz >= 15000 && Int($0.hz) % 1000 == 0 || $0.hz >= 19000 }
        print("  dBFS  " + shown.map { String(format: "%6.2fk", $0.hz / 1000) }.joined())
        print("        " + shown.map { String(format: "%7.0f", $0.db) }.joined())
        print(
            String(
                format: "  Above 16 kHz: median %.0f dB under 4-8 kHz; drops out in %.1f%% of %d frames",
                -a.medianHigh, a.holes, a.framesWithMusic))
        print("  \(a.verdict): \(a.reason)")
        verdicts[a.verdict, default: []].append(file.lastPathComponent)
    } catch {
        print("  Skipped: \(error.localizedDescription)")
    }
    print("")
}

let total = verdicts.values.map(\.count).reduce(0, +)
let order = ["YES", "MAYBE", "NO", "CAN'T TELL"]
print(order.compactMap { v in verdicts[v].map { "\(v): \($0.count)" } }.joined(separator: ", ") + " of \(total) files")
for v in ["YES", "MAYBE"] {
    if let names = verdicts[v] { print("\(v): " + names.joined(separator: ", ")) }
}
let call =
    verdicts["YES"] != nil ? "YES" : verdicts["MAYBE"] != nil ? "MAYBE" : verdicts["NO"] != nil ? "NO" : "CAN'T TELL"
print("Lossy origin: \(call)")
