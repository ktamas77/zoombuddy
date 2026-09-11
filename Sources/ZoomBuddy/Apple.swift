import AVFoundation
import Speech
import FoundationModels

// Local, on-device implementations. No network, no model downloads beyond Apple's own.

/// macOS Personal Voice (System Settings › Accessibility › Personal Voice) via AVSpeechSynthesizer.
final class PersonalVoice: Voice {
    private let synth = AVSpeechSynthesizer()
    private(set) var voice: AVSpeechSynthesisVoice?
    private(set) var status = "Voice: checking…"

    func setup() async {
        let auth = await withCheckedContinuation { c in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { c.resume(returning: $0) }
        }
        voice = AVSpeechSynthesisVoice.speechVoices().first { $0.voiceTraits.contains(.isPersonalVoice) }
        status = voice.map { "Voice: Personal Voice “\($0.name)”" }
            ?? "Voice: no Personal Voice (auth=\(auth.rawValue)) — create one in System Settings › Accessibility › Personal Voice; using default voice"
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { cont in
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            synth.write(u) { buf in
                guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else { cont.finish(); return }
                cont.yield(pcm)
            }
        }
    }
}

/// On-device SpeechAnalyzer on the default input device. Zoom plays through the speakers; we hear it.
/// ponytail: fixed en-US; make it a setting when a non-English meeting shows up.
final class AppleEars: Ears {
    var onStatus: (String) -> Void = { _ in }
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var task: Task<Void, Never>?

    func listen() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            task = Task { [self] in
                do {
                    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
                    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        onStatus("Downloading on-device speech model…")
                        try await req.downloadAndInstall()
                        onStatus("Speech model installed")
                    }
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    else { throw ZBError("no transcriber audio format") }
                    let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
                    self.analyzer = analyzer
                    self.input = builder

                    let node = engine.inputNode
                    let inFmt = node.outputFormat(forBus: 0)
                    guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw ZBError("no audio converter") }
                    node.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { buf, _ in
                        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / inFmt.sampleRate) + 16
                        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
                        var fed = false
                        var err: NSError?
                        conv.convert(to: out, error: &err) { _, status in
                            if fed { status.pointee = .noDataNow; return nil }
                            fed = true; status.pointee = .haveData; return buf
                        }
                        if err == nil { builder.yield(AnalyzerInput(buffer: out)) }
                    }
                    try engine.start()
                    try await analyzer.start(inputSequence: stream)
                    for try await result in transcriber.results where result.isFinal {
                        cont.yield(String(result.text.characters))
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish(); input = nil
        let a = analyzer; analyzer = nil
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
    }
}

/// Apple's on-device foundation model (needs Apple Intelligence enabled).
struct AppleBrain: Brain {
    let name: String
    let persona: String

    static var status: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Brain: Apple on-device model ready"
        case .unavailable(let r): return "Brain: unavailable (\(r)) — enable Apple Intelligence in System Settings"
        }
    }

    func reply(transcript: [String]) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You are \(name), attending a video meeting; the audio is transcribed live and may contain errors.
            Persona: \(persona)
            Someone just addressed you by name. Reply as \(name) in first person: 1-3 short spoken sentences, \
            plain text, no lists or markdown. If you cannot know the answer, say you'll follow up after the meeting.
            """)
        let context = transcript.suffix(8).joined(separator: "\n")
        return try await session.respond(to: "Recent transcript (oldest first):\n\(context)\n\nRespond to what was just said to you.").content
    }
}
