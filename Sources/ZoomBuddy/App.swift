import SwiftUI
import AVFoundation

@main
struct ZoomBuddyApp: App {
    @StateObject private var buddy = Buddy()

    var body: some Scene {
        WindowGroup("ZoomBuddy") {
            ControlView().environmentObject(buddy).environmentObject(buddy.face)
        }
        .defaultSize(width: 540, height: 680)

        // OBS captures this window (Window Capture) and exposes it as "OBS Virtual Camera".
        Window("ZoomBuddy Face", id: "face") {
            FaceView().environmentObject(buddy.face)
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentSize)
    }
}

struct FaceView: View {
    @EnvironmentObject var face: BankFace
    var body: some View {
        LayerView(layer: face.layer)
            .frame(width: 1280, height: 720)
            .background(.black)
    }
}

/// Hosts any CALayer (AVPlayerLayer / AVCaptureVideoPreviewLayer) in SwiftUI.
struct LayerView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> NSView { let v = NSView(); v.wantsLayer = true; return v }
    func updateNSView(_ v: NSView, context: Context) {
        guard v.layer?.sublayers?.first !== layer else { return }
        v.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)
    }
}

struct ControlView: View {
    @EnvironmentObject var buddy: Buddy
    @EnvironmentObject var face: BankFace
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Form {
            Section("Who") {
                TextField("Name(s) people call you, comma-separated", text: $buddy.name)
                TextEditor(text: $buddy.persona).frame(height: 80)
            }
            Section("Face  (motion bank plays in the Face window → capture it in OBS → Virtual Camera)") {
                HStack {
                    Button("+ idle take (20s)") { face.record("idle") }
                    Button("+ talking take (20s)") { face.record("talking") }
                    Button("Open Face window") { openWindow(id: "face") }
                    Button("Clips…") { face.revealClips() }
                }.disabled(face.isRecording)
                Text(face.status).font(.caption).foregroundStyle(.secondary)
                Toggle("Lip sync while speaking (needs sidecar)", isOn: $buddy.lipSync)
                Text(buddy.lipSyncStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice / Brain") {
                TextField("Output device (select this as mic in Zoom)", text: $buddy.outputDevice)
                Text(buddy.voiceStatus).font(.caption).foregroundStyle(.secondary)
                Text(buddy.brainStatus).font(.caption).foregroundStyle(.secondary)
                Button("Test voice") { buddy.say("Hi, this is \(buddy.firstName)'s clone. I can hear you.") }
            }
            Section("Meeting") {
                Toggle("Attend: listen and answer when addressed by name", isOn: $buddy.attending)
                Text(buddy.state.rawValue).bold()
                ScrollView {
                    Text(buddy.transcript.suffix(10).joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(height: 140)
            }
        }
        .formStyle(.grouped)
    }
}
