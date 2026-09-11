import Foundation
import Combine
import AVFoundation

enum Trigger {
    /// True if any comma-separated alias in `names` appears as a whole word in `text`.
    static func mentions(_ names: String, in text: String) -> Bool {
        let aliases = names.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return false }
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return aliases.contains { words.contains($0) }
    }
}

/// Orchestrator: Ears → Trigger → Brain → Voice → Speaker, with Face state in step.
@MainActor
final class Buddy: ObservableObject {
    enum State: String { case off = "Off", listening = "Listening…", thinking = "Thinking…", speaking = "Speaking…" }

    @Published var name = UserDefaults.standard.string(forKey: "name") ?? (NSFullUserName().split(separator: " ").first.map(String.init) ?? "Buddy") {
        didSet { UserDefaults.standard.set(name, forKey: "name") }
    }
    @Published var persona = UserDefaults.standard.string(forKey: "persona") ?? "Friendly, concise software engineer. Short, conversational answers." {
        didSet { UserDefaults.standard.set(persona, forKey: "persona") }
    }
    @Published var outputDevice = UserDefaults.standard.string(forKey: "outputDevice") ?? "BlackHole 2ch" {
        didSet { UserDefaults.standard.set(outputDevice, forKey: "outputDevice"); speaker = Speaker(outputDevice: outputDevice); refreshVoiceStatus() }
    }
    @Published var attending = false { didSet { attending ? startEars() : stopEars() } }
    @Published var state = State.off
    @Published var transcript: [String] = []
    @Published var lipSync = UserDefaults.standard.object(forKey: "lipSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lipSync, forKey: "lipSync") }
    }
    @Published var lipSyncStatus = "Lip sync: checking…"
    @Published var voiceStatus = "Voice: checking…"
    @Published var brainStatus = AppleBrain.status

    // Components — swap here.
    let face = BankFace()
    private let personalVoice = PersonalVoice()
    private var voice: Voice { personalVoice }
    private let ears: Ears = AppleEars()
    private var brain: Brain { AppleBrain(name: firstName, persona: persona) }
    private var speaker = Speaker(outputDevice: UserDefaults.standard.string(forKey: "outputDevice") ?? "BlackHole 2ch")

    var firstName: String { name.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name }
    private var earsTask: Task<Void, Never>?

    init() {
        (ears as? AppleEars)?.onStatus = { [weak self] s in Task { @MainActor in self?.brainStatus = s } }
        Task { await personalVoice.setup(); refreshVoiceStatus() }
        Task { await refreshLipSync() }
    }

    @discardableResult
    func refreshLipSync() async -> Bool {
        let up = await LipSync.available()
        lipSyncStatus = up ? "Lip sync: sidecar ready" : "Lip sync: sidecar not running (make sidecar-setup && make sidecar) — using raw talking clips"
        return up
    }

    private func refreshVoiceStatus() {
        voiceStatus = personalVoice.status + (speaker.deviceFound ? "" : "  ⚠️ “\(outputDevice)” not found, using default output (brew install blackhole-2ch)")
    }

    func say(_ text: String) {
        state = .speaking
        Task {
            do {
                var buffers: [AVAudioPCMBuffer] = []
                for try await b in voice.synthesize(text) { buffers.append(b) }
                let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
                var video: URL?
                // ponytail: whole utterance is rendered before playback starts (≈1–3 s). Upgrade: chunked streaming render.
                if lipSync, await refreshLipSync(), let clip = face.randomSnippet("talking", minDuration: seconds) {
                    do { video = try await LipSync.render(audio: LipSync.writeWAV(buffers), video: clip.url, start: clip.start) }
                    catch { lipSyncStatus = "Lip sync: \(error.localizedDescription)" }
                }
                face.show(.talking(video: video))
                try await speaker.play(buffers)
            } catch { voiceStatus = "Voice error: \(error.localizedDescription)" }
            face.show(.idle)
            state = attending ? .listening : .off
        }
    }

    private func startEars() {
        earsTask = Task { [self] in
            state = .listening
            do { for try await text in ears.listen() { heard(text) } }
            catch where !(error is CancellationError) {
                brainStatus = "Ears failed: \(error.localizedDescription)"
                attending = false
            } catch {}
        }
    }

    private func stopEars() {
        earsTask?.cancel(); earsTask = nil
        ears.stop()
        state = .off
    }

    private func heard(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript.append(t)
        if transcript.count > 40 { transcript.removeFirst() }
        // ponytail: "when to speak" = someone said my name. Upgrade: ask the Brain on every segment whether a reply is expected
        // (and feed it the active speaker from the Zoom SDK when we have it).
        guard state == .listening, Trigger.mentions(name, in: t) else { return }
        state = .thinking
        Task {
            var reply = "Sorry, I missed that — could you repeat?"
            do { reply = try await brain.reply(transcript: transcript) }
            catch { brainStatus = "Brain error: \(error.localizedDescription)" }
            guard !reply.isEmpty else { state = .listening; return }
            transcript.append("→ \(firstName): \(reply)")
            say(reply)
        }
    }
}
