import AudioToolbox

/// How Apple's AAC encoder spends bits.
public struct AACOptions: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// The same bit rate everywhere.
        case cbr
        /// The bit rate on average, over the whole track.
        case abr
        /// A variable bit rate near the bit rate: Apple's choice for iTunes Plus.
        case vbrConstrained = "vbr-constrained"
        /// A variable bit rate from the quality alone; the bit rate is not used.
        case vbr

        var audioToolboxMode: UInt32 {
            switch self {
            case .cbr: kAudioCodecBitRateControlMode_Constant
            case .abr: kAudioCodecBitRateControlMode_LongTermAverage
            case .vbrConstrained: kAudioCodecBitRateControlMode_VariableConstrained
            case .vbr: kAudioCodecBitRateControlMode_Variable
            }
        }
    }

    public var mode = Mode.vbrConstrained
    /// The bit rate in kbit/s, for every mode but `vbr`.
    public var bitRate = 256
    /// The quality for `vbr`, from 0 to 127 (the best).
    public var vbrQuality = 127

    public init(mode: Mode = .vbrConstrained, bitRate: Int = 256, vbrQuality: Int = 127) {
        self.mode = mode
        self.bitRate = bitRate
        self.vbrQuality = vbrQuality
    }
}

/// How `lame` encodes MP3.
public struct MP3Options: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Variable bit rate, from a quality preset (`-V 0` is the best).
        case vbr
        /// The same bit rate everywhere (`-b`, `--cbr`).
        case cbr
        /// The bit rate on average (`--abr`).
        case abr
    }

    public var mode = Mode.vbr
    /// The VBR preset, from 0 (the best, about 245 kbit/s) to 9.
    public var vbrQuality = 0
    /// The bit rate in kbit/s, for `cbr` and `abr`.
    public var bitRate = 320
    /// More options for `lame`, given after CDRip's own.
    public var extraArguments: [String] = []

    public init(mode: Mode = .vbr, vbrQuality: Int = 0, bitRate: Int = 320, extraArguments: [String] = []) {
        self.mode = mode
        self.vbrQuality = vbrQuality
        self.bitRate = bitRate
        self.extraArguments = extraArguments
    }

    /// The options for `lame`.
    public var lameArguments: [String] {
        let rate: [String] =
            switch mode {
            case .vbr: ["-V", String(vbrQuality)]
            case .cbr: ["-b", String(bitRate), "--cbr"]
            case .abr: ["--abr", String(bitRate)]
            }
        return rate + extraArguments
    }
}

// Every key may be missing from a settings file: it then has its default.

extension AACOptions {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AACOptions()
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? defaults.mode
        bitRate = try container.decodeIfPresent(Int.self, forKey: .bitRate) ?? defaults.bitRate
        vbrQuality = try container.decodeIfPresent(Int.self, forKey: .vbrQuality) ?? defaults.vbrQuality
    }
}

extension MP3Options {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MP3Options()
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? defaults.mode
        vbrQuality = try container.decodeIfPresent(Int.self, forKey: .vbrQuality) ?? defaults.vbrQuality
        bitRate = try container.decodeIfPresent(Int.self, forKey: .bitRate) ?? defaults.bitRate
        extraArguments =
            try container.decodeIfPresent([String].self, forKey: .extraArguments) ?? defaults.extraArguments
    }
}
