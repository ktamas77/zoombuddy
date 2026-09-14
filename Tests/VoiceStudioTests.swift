import XCTest
import AVFoundation
@testable import ZoomBuddy

/// Integration check against a locally running VoiceStudio; skips when it is not up.
final class VoiceStudioTests: XCTestCase {
    func testSynthesizeReturnsAudio() async throws {
        let vs = VoiceStudioVoice()
        guard await vs.available() else { throw XCTSkip("VoiceStudio not running on 127.0.0.1:3900") }
        vs.profile = (try? await vs.profiles().first?.id) ?? "default"
        var frames: AVAudioFrameCount = 0
        var rate = 0.0
        for try await b in vs.synthesize("Testing one two three.") { frames += b.frameLength; rate = b.format.sampleRate }
        XCTAssertGreaterThan(Double(frames) / rate, 0.5, "expected at least half a second of audio")
    }
}
