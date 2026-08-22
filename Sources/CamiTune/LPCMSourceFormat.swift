import CoreAudio
import Foundation

/// The channel order attached to an LPCM block as it crosses the private
/// driver boundary. Keeping semantic roles beside the samples prevents later
/// spatial processing from having to guess what channel 2 or channel 7 means.
struct LPCMChannelLayout: Hashable, Sendable {
    var coreAudioTag: UInt32
    var roles: [ChannelRole]

    var channelCount: Int { roles.count }

    static let stereo = LPCMChannelLayout(
        coreAudioTag: UInt32(kAudioChannelLayoutTag_Stereo),
        roles: [.left, .right]
    )

    /// ITU/MPEG order: L, R, C, LFE, Ls, Rs.
    static let fivePointOne = LPCMChannelLayout(
        coreAudioTag: UInt32(kAudioChannelLayoutTag_MPEG_5_1_A),
        roles: [
            .left, .right, .center, .lowFrequencyEffects,
            .leftSurround, .rightSurround
        ]
    )

    /// ITU/MPEG order: L, R, C, LFE, Ls, Rs, Rls, Rrs.
    static let sevenPointOne = LPCMChannelLayout(
        coreAudioTag: UInt32(kAudioChannelLayoutTag_MPEG_7_1_C),
        roles: [
            .left, .right, .center, .lowFrequencyEffects,
            .leftSurround, .rightSurround,
            .leftRearSurround, .rightRearSurround
        ]
    )

    init(coreAudioTag: UInt32, roles: [ChannelRole]) {
        self.coreAudioTag = coreAudioTag
        self.roles = roles
    }

    /// Resolves the layouts CamiTune accepts at the LPCM boundary. A zero tag
    /// is tolerated for older/internal producers only when the channel count
    /// identifies one of the three canonical layouts unambiguously.
    init?(coreAudioTag: UInt32, channelCount: Int) {
        let roles: [ChannelRole]?
        switch coreAudioTag {
        case UInt32(kAudioChannelLayoutTag_Stereo):
            roles = Self.stereo.roles
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_A):
            roles = Self.fivePointOne.roles
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_B):
            roles = [
                .left, .right, .leftSurround, .rightSurround,
                .center, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_C):
            roles = [
                .left, .center, .right, .leftSurround,
                .rightSurround, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_5_1_D):
            roles = [
                .center, .left, .right, .leftSurround,
                .rightSurround, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_7_1_A):
            // The last pair is the front left/right-center pair, which this
            // front-stage milestone intentionally keeps as unknown rather
            // than misclassifying as rear surrounds.
            roles = [
                .left, .right, .center, .lowFrequencyEffects,
                .leftSurround, .rightSurround, .unknown, .unknown
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_7_1_B):
            roles = [
                .center, .unknown, .unknown, .left, .right,
                .leftSurround, .rightSurround, .lowFrequencyEffects
            ]
        case UInt32(kAudioChannelLayoutTag_MPEG_7_1_C):
            roles = Self.sevenPointOne.roles
        case UInt32(kAudioChannelLayoutTag_Emagic_Default_7_1):
            roles = [
                .left, .right, .leftSurround, .rightSurround,
                .center, .lowFrequencyEffects, .unknown, .unknown
            ]
        default:
            switch channelCount {
            case 2 where coreAudioTag == 0:
                roles = Self.stereo.roles
            case 6 where coreAudioTag == 0:
                roles = Self.fivePointOne.roles
            case 8 where coreAudioTag == 0:
                roles = Self.sevenPointOne.roles
            default:
                roles = nil
            }
        }
        guard let roles, roles.count == channelCount else { return nil }
        self.init(coreAudioTag: coreAudioTag, roles: roles)
    }

    static func canonical(forChannelCount channelCount: Int) -> LPCMChannelLayout? {
        switch channelCount {
        case 2: return .stereo
        case 6: return .fivePointOne
        case 8: return .sevenPointOne
        default: return nil
        }
    }
}

enum SpatialSourceFormat: Hashable, Sendable {
    case stereo
    case fivePointOne(LPCMChannelLayout)
    case sevenPointOne(LPCMChannelLayout)
    case multichannel(LPCMChannelLayout)

    init(layout: LPCMChannelLayout) {
        switch layout.channelCount {
        case 2: self = .stereo
        case 6: self = .fivePointOne(layout)
        case 8: self = .sevenPointOne(layout)
        default: self = .multichannel(layout)
        }
    }

    var channelLayout: LPCMChannelLayout {
        switch self {
        case .stereo: return .stereo
        case .fivePointOne(let layout),
             .sevenPointOne(let layout),
             .multichannel(let layout):
            return layout
        }
    }

    var displayName: String {
        switch self {
        case .stereo: return "2.0"
        case .fivePointOne: return "5.1"
        case .sevenPointOne: return "7.1"
        case .multichannel(let layout): return "\(layout.channelCount)-channel"
        }
    }
}
