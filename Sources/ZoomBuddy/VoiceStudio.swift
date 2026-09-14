import AVFoundation

/// VoiceStudio (github.com/debpalash/VoiceStudio) running locally: zero-shot voice clone from a 3–10 s clip,
/// many engines, Apple Silicon MPS/MLX. AGPL app — it stays a separate install; we only talk to its
/// OpenAI-compatible endpoint on localhost:3900.
/// ponytail: whole utterance as one WAV; upgrade = response_format "pcm" streamed in chunks for lower first-audio latency.
final class VoiceStudioVoice: Voice {
    var base = URL(string: "http://127.0.0.1:3900")!
    var profile = "default"   // voice profile id (GET /v1/audio/voices → "type": "profile")
    var model = "tts-1"       // "tts-1" = VoiceStudio's active engine; or an engine id like "omnivoice", "mlx-audio"
    /// OmniVoice unmasking steps. VoiceStudio's own default is 16 (32 = its "quality" preset). Measured on an M1 Max:
    /// 16 → 6.7 s for a 2 s sentence, 8 → 3.6 s, 4 → 2.9 s. ponytail: 8 for meeting latency; raise if it sounds rough.
    var steps = 8

    struct Profile { let id: String; let name: String }

    func available() async -> Bool {
        var r = URLRequest(url: base.appendingPathComponent("v1/audio/voices")); r.timeoutInterval = 0.5
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Cloned voice profiles only (the OpenAI alias names are filtered out).
    func profiles() async throws -> [Profile] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("v1/audio/voices"))
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((j?["voices"] as? [[String: Any]]) ?? []).compactMap { v in
            guard v["type"] as? String == "profile", let id = v["voice_id"] as? String else { return nil }
            return Profile(id: id, name: v["name"] as? String ?? id)
        }
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { cont in
            Task {
                do {
                    var r = URLRequest(url: base.appendingPathComponent("v1/audio/speech"))
                    r.httpMethod = "POST"
                    r.timeoutInterval = 120
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    r.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "input": text, "voice": profile, "response_format": "wav", "num_step": steps,
                    ])
                    let (data, resp) = try await URLSession.shared.data(for: r)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        throw ZBError("VoiceStudio: \(String(data: data, encoding: .utf8) ?? "HTTP error")")
                    }
                    let tmp = BankFace.dir.appendingPathComponent("tmp/voicestudio-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
                    try data.write(to: tmp)
                    let file = try AVAudioFile(forReading: tmp)
                    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
                    else { throw ZBError("VoiceStudio: empty audio") }
                    try file.read(into: buf)
                    try? FileManager.default.removeItem(at: tmp)
                    cont.yield(buf)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
        }
    }
}
