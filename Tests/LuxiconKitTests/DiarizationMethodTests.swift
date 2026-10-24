import Testing
@testable import LuxiconKit

@Suite struct DiarizationMethodTests {
    @Test func defaultIsClassic() {
        #expect(DiarizationMethod.default == .classic)
    }

    @Test func v2DefaultThresholdIsPoint4() {
        #expect(DiarizationMethod.v2DefaultThreshold == 0.4)
    }

    @Test func cliParsing() {
        #expect(DiarizationMethod(cliValue: "v2", threshold: nil) == .pyannoteV2(threshold: 0.4))
        #expect(DiarizationMethod(cliValue: "v2", threshold: 0.5) == .pyannoteV2(threshold: 0.5))
        #expect(DiarizationMethod(cliValue: "classic", threshold: nil) == .classic)
        #expect(DiarizationMethod(cliValue: "x", threshold: nil) == nil)
    }
}
