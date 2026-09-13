import Testing
@testable import PMSKit

struct EmbyStartupPrewarmPolicyTests {
    @Test func warmsOnlyColdAV1Transcodes() {
        for resume in [nil, 0] as [Int?] {
            #expect(EmbyStartupPrewarmPolicy.shouldPrewarm(isTranscode: true, videoCodec: "AV1", resumeMilliseconds: resume))
            #expect(!EmbyStartupPrewarmPolicy.shouldPrewarm(isTranscode: false, videoCodec: "av1", resumeMilliseconds: resume))
            for codec in [nil, "h264", "hevc", ""] as [String?] {
                #expect(!EmbyStartupPrewarmPolicy.shouldPrewarm(isTranscode: true, videoCodec: codec, resumeMilliseconds: resume))
            }
        }
        for resume in [-1, 1, 60_000] {
            #expect(!EmbyStartupPrewarmPolicy.shouldPrewarm(isTranscode: true, videoCodec: "av1", resumeMilliseconds: resume))
        }
        #expect(EmbyStartupPrewarmPolicy.budgetSeconds == 20)
    }
}
