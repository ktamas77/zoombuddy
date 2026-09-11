import AVFoundation
import CoreAudio

// Swap points. Defaults are local/Apple. Add a cloud or OSS engine by conforming (e.g. ElevenLabsVoice,
// VapiVoice, WhisperEars, OllamaBrain, TalkingHeadFace) and assigning it in Buddy.

/// Text → PCM audio chunks.
protocol Voice {
    func synthesize(_ text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}

/// Meeting audio → final utterances (one string per finished sentence/segment).
protocol Ears {
    func listen() -> AsyncThrowingStream<String, Error>
    func stop()
}

/// Recent transcript → what to say. Return "" to stay quiet.
protocol Brain {
    func reply(transcript: [String]) async throws -> String
}

enum FaceState { case idle, talking }

/// Renders the clone's face into a CALayer (shown in the Face window, captured by OBS → virtual camera).
protocol Face: AnyObject {
    var layer: CALayer { get }
    func show(_ state: FaceState)
}

struct ZBError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }

/// Plays PCM buffers to a named output device (BlackHole → selected as mic in Zoom).
final class Speaker {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    let deviceFound: Bool

    init(outputDevice: String) {
        engine.attach(node)
        if let id = Speaker.deviceID(named: outputDevice), let au = engine.outputNode.audioUnit {
            var dev = id
            deviceFound = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                               &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        } else { deviceFound = false }
    }

    /// Streams buffers to the device and returns once the last one has been played.
    func play(_ buffers: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async throws {
        var played = false
        for try await pcm in buffers {
            if format != pcm.format {
                format = pcm.format
                engine.stop()
                engine.connect(node, to: engine.mainMixerNode, format: pcm.format)
            }
            if !engine.isRunning { try engine.start(); node.play() }
            node.scheduleBuffer(pcm, completionHandler: nil)
            played = true
        }
        guard played, let format, let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
        tail.frameLength = 1
        await withCheckedContinuation { c in
            node.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in c.resume() }
        }
    }

    static func deviceID(named name: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        return ids.first { id in
            var cf: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &s, &cf) == noErr, let cf else { return false }
            return (cf.takeRetainedValue() as String).caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
