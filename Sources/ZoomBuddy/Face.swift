import AVFoundation

/// Records two webcam clips (idle / talking) and loops the current one.
/// ponytail: no lip-sync — a "talking" loop at Zoom tile size reads fine. Upgrade: a Face that drives
/// MuseTalk/LivePortrait (or HeyGen/Tavus) from the TTS audio.
final class ClipFace: NSObject, ObservableObject, Face, AVCaptureFileOutputRecordingDelegate {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoomBuddy")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func url(_ state: FaceState) -> URL { dir.appendingPathComponent("\(state).mov") }

    @Published var isRecording = false
    @Published var status = ""

    var layer: CALayer { isRecording ? previewLayer : playerLayer }

    private let player = AVQueuePlayer()
    private lazy var playerLayer: AVPlayerLayer = {
        let l = AVPlayerLayer(player: player); l.videoGravity = .resizeAspectFill; return l
    }()
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspectFill; return l
    }()
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var looper: AVPlayerLooper?
    private var current: FaceState?

    override init() {
        super.init()
        player.isMuted = true
        show(.idle)
        refreshStatus()
    }

    func refreshStatus() {
        let have = [FaceState.idle, .talking].filter { FileManager.default.fileExists(atPath: Self.url($0).path) }
        status = have.isEmpty
            ? "No clips yet. Record “idle” (listening, nodding) and “talking” (mouth moving, gesturing)."
            : "Clips: \(have.map { "\($0)" }.joined(separator: ", ")) — \(Self.dir.path)"
    }

    func show(_ state: FaceState) {
        guard state != current, FileManager.default.fileExists(atPath: Self.url(state).path) else { return }
        current = state
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.url(state)))
        player.play()
    }

    func record(_ state: FaceState, seconds: Double = 20) {
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
        status = "Recording “\(state)” for \(Int(seconds))s — look at the camera"
        DispatchQueue.global().async {
            self.session.startRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {  // let exposure settle
                try? FileManager.default.removeItem(at: Self.url(state))
                self.output.startRecording(to: Self.url(state), recordingDelegate: self)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.output.stopRecording() }
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from _: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.session.stopRunning()
            self.isRecording = false
            self.current = nil  // force reload so a re-recorded clip is picked up
            self.refreshStatus()
            if let error { self.status = "Recording failed: \(error.localizedDescription)" }
            self.show(.idle)
        }
    }
}
