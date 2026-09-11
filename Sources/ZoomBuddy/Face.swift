import AVFoundation
import AppKit

/// Motion bank. Many webcam recordings per state live under clips/<idle|talking>/; playback picks random
/// snippets (2.5–6 s) from random clips and crossfades between them, so idle motion never repeats.
/// While speaking, a lip-synced render from the sidecar can be played instead of a raw talking snippet.
/// ponytail: snippet boundaries are random + a 0.5 s crossfade; upgrade = choose boundaries by head-pose similarity.
final class BankFace: NSObject, ObservableObject, Face, AVCaptureFileOutputRecordingDelegate {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoomBuddy")
        for sub in ["clips/idle", "clips/talking", "tmp"] {
            try? FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return d
    }()
    static let clipsDir = dir.appendingPathComponent("clips")
    static func dir(for kind: String) -> URL { clipsDir.appendingPathComponent(kind) }

    struct Clip { let url: URL; let duration: Double }
    struct Snippet { let url: URL; let start: Double; let duration: Double }

    @Published var isRecording = false
    @Published var status = ""
    var layer: CALayer { isRecording ? previewLayer : stage }

    private(set) var clips: [String: [Clip]] = ["idle": [], "talking": []]
    private let stage = StageLayer()
    private let players = [AVPlayer(), AVPlayer()]
    private lazy var layers: [AVPlayerLayer] = players.map {
        let l = AVPlayerLayer(player: $0); l.videoGravity = .resizeAspectFill; l.opacity = 0; return l
    }
    private var active = 0
    private var kind = "idle"
    private var override: URL?
    private var advance: DispatchWorkItem?
    private var recent: [Snippet] = []

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspectFill; return l
    }()

    override init() {
        super.init()
        stage.backgroundColor = .black
        layers.forEach { stage.addSublayer($0) }
        players.forEach { $0.isMuted = true; $0.actionAtItemEnd = .pause }
        // Legacy single-clip layout from v0.1.
        for k in ["idle", "talking"] {
            let old = Self.dir.appendingPathComponent("\(k).mov")
            if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.moveItem(at: old, to: Self.dir(for: k).appendingPathComponent("legacy.mov"))
            }
        }
        Task { await reload(); show(.idle) }
    }

    // MARK: bank

    func reload() async {
        var all: [String: [Clip]] = [:]
        for k in ["idle", "talking"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: Self.dir(for: k), includingPropertiesForKeys: nil)) ?? []
            var list: [Clip] = []
            for u in urls where u.pathExtension == "mov" || u.pathExtension == "mp4" {
                if let d = try? await AVURLAsset(url: u).load(.duration).seconds, d >= 2 { list.append(Clip(url: u, duration: d)) }
            }
            all[k] = list
        }
        clips = all
        let desc = ["idle", "talking"].map { k in "\(k): \(all[k]!.count) clip\(all[k]!.count == 1 ? "" : "s") (\(Int(all[k]!.map(\.duration).reduce(0, +)))s)" }
        status = all.values.allSatisfy(\.isEmpty)
            ? "No clips yet. Record several “idle” (listening, nodding, reacting) and “talking” takes; more takes = less repetition."
            : desc.joined(separator: " · ")
    }

    /// Random snippet of `kind` (falls back to idle), avoiding recently used regions.
    func randomSnippet(_ kind: String, minDuration: Double = 0) -> Snippet? {
        let pool = (clips[kind]?.isEmpty == false ? clips[kind] : clips["idle"]) ?? []
        guard !pool.isEmpty else { return nil }
        for _ in 0..<8 {
            let clip = pool.randomElement()!
            let len = min(clip.duration, max(minDuration, Double.random(in: 2.5...6)))
            let start = Double.random(in: 0...max(0, clip.duration - len))
            let s = Snippet(url: clip.url, start: start, duration: len)
            if !recent.contains(where: { $0.url == s.url && abs($0.start - s.start) < 1.5 }) || pool.count == 1 && clip.duration < 8 {
                recent.append(s); if recent.count > 8 { recent.removeFirst() }
                return s
            }
        }
        let clip = pool.randomElement()!
        return Snippet(url: clip.url, start: 0, duration: clip.duration)
    }

    func show(_ state: FaceState) {
        switch state {
        case .idle: kind = "idle"; override = nil
        case .talking(let video): kind = "talking"; override = video
        }
        next()
    }

    private func next() {
        advance?.cancel()
        Task { @MainActor in
            let s: Snippet
            if let v = override, let d = try? await AVURLAsset(url: v).load(.duration).seconds {
                override = nil
                s = Snippet(url: v, start: 0, duration: d)
            } else if let r = randomSnippet(kind) {
                s = r
            } else { return }
            play(s)
        }
    }

    private func play(_ s: Snippet) {
        let idx = 1 - active
        let p = players[idx]
        p.replaceCurrentItem(with: AVPlayerItem(url: s.url))
        p.seek(to: CMTime(seconds: s.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [self] _ in
            DispatchQueue.main.async { [self] in
                p.play()
                crossfade(to: idx)
                let work = DispatchWorkItem { [weak self] in self?.next() }
                advance = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.6, s.duration - 0.5), execute: work)
            }
        }
    }

    private func crossfade(to idx: Int, duration: Double = 0.5) {
        let old = active
        active = idx
        layers[idx].zPosition = 1
        layers[old].zPosition = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layers[idx].opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [self] in
            guard active == idx else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layers[old].opacity = 0
            CATransaction.commit()
            players[old].pause()
        }
    }

    // MARK: recording (appends a new take)

    func record(_ kind: String, seconds: Double = 20) {
        if session.inputs.isEmpty {
            guard let cam = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input), session.canAddOutput(output)
            else { status = "No camera available"; return }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
        }
        isRecording = true
        status = "Recording “\(kind)” take for \(Int(seconds))s — look at the camera, be yourself"
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.dir(for: kind).appendingPathComponent("\(f.string(from: Date())).mov")
        DispatchQueue.global().async {
            self.session.startRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {  // let exposure settle
                self.output.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.output.stopRecording() }
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from _: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.session.stopRunning()
            self.isRecording = false
            Task {
                await self.reload()
                if let error { self.status = "Recording failed: \(error.localizedDescription)" }
                self.show(.idle)
            }
        }
    }

    func revealClips() { NSWorkspace.shared.activateFileViewerSelecting([Self.clipsDir]) }
}

/// Keeps sublayers sized to itself.
final class StageLayer: CALayer {
    override func layoutSublayers() { sublayers?.forEach { $0.frame = bounds } }
}
