#!/usr/bin/env python3
"""ZoomBuddy lip-sync sidecar.

POST /lipsync {"audio": "<wav>", "video": "<clip>", "start": <sec>}  ->  {"video": "<mp4>", "seconds": n}
GET  /health                                                         ->  {"ok": true, "device": "mps"}

Renders the clip from `start` for the length of the audio with the mouth re-synthesised by Wav2Lip
(vendored at setup, non-commercial license) so it matches the audio. Face boxes come from Wav2Lip's own
s3fd detector, run on a downscaled frame for speed. Swappable: anything that fulfils the same HTTP contract.
"""
import json, os, subprocess, sys, tempfile, time
from http.server import BaseHTTPRequestHandler, HTTPServer

import cv2, librosa, numpy as np, torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "vendor", "Wav2Lip"))
import face_detection  # noqa: E402  (vendored)
from models import Wav2Lip  # noqa: E402  (vendored)

DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
FPS, MEL_STEP, IMG, DET_W, DET_STRIDE = 25, 16, 96, 320, 4
PADS = (0, 10, 0, 0)  # top, bottom, left, right (Wav2Lip default)
OUT_DIR = os.path.join(os.path.expanduser("~/Library/Application Support/ZoomBuddy"), "tmp")
os.makedirs(OUT_DIR, exist_ok=True)


def load_model():
    ck = torch.load(os.path.join(HERE, "weights", "wav2lip_gan.pth"), map_location="cpu", weights_only=False)
    sd = {k.replace("module.", ""): v for k, v in ck["state_dict"].items()}
    m = Wav2Lip()
    m.load_state_dict(sd)
    return m.to(DEVICE).eval()


def mel_spectrogram(path):
    """Wav2Lip hparams re-implemented against current librosa: 16 kHz, n_fft 800, hop 200, 80 mels,
    fmin 55, fmax 7600, pre-emphasis .97, ref 20 dB, min -100 dB, symmetric normalisation to [-4, 4]."""
    wav, _ = librosa.load(path, sr=16000)
    wav = np.append(wav[0], wav[1:] - 0.97 * wav[:-1])
    S = np.abs(librosa.stft(wav, n_fft=800, hop_length=200, win_length=800))
    mel = librosa.filters.mel(sr=16000, n_fft=800, n_mels=80, fmin=55, fmax=7600) @ S
    db = 20 * np.log10(np.maximum(1e-5, mel)) - 20
    return np.clip(8 * ((db + 100) / 100) - 4, -4, 4), len(wav) / 16000


def read_frames(path, start, n):
    cap = cv2.VideoCapture(path)
    src_fps = cap.get(cv2.CAP_PROP_FPS) or FPS
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000)
    frames, idx, nxt = [], 0, 0.0
    while len(frames) < n:  # resample to 25 fps by timestamp
        ok, f = cap.read()
        if not ok:
            break
        if idx / src_fps + 1e-6 >= nxt:
            frames.append(f)
            nxt += 1 / FPS
        idx += 1
    cap.release()
    if not frames:
        raise RuntimeError(f"no frames in {path} at {start}s")
    loop = frames + frames[::-1]  # ping-pong if the clip is shorter than the audio
    while len(frames) < n:
        frames += loop[: n - len(frames)]
    return frames[:n]


def face_boxes(detector, frames):
    """s3fd boxes (what Wav2Lip was trained on), detected on every DET_STRIDE-th downscaled frame and
    linearly interpolated in between, then smoothed like Wav2Lip does.
    ponytail: stride 4 assumes a webcam head that moves slowly; drop to 1 for fast-moving footage."""
    h, w = frames[0].shape[:2]
    scale = w / DET_W
    keys = list(range(0, len(frames), DET_STRIDE))
    if keys[-1] != len(frames) - 1:
        keys.append(len(frames) - 1)
    small = [cv2.resize(frames[k], (DET_W, int(h / scale))) for k in keys]
    found, last = [], None
    for i in range(0, len(small), 32):
        for rect in detector.get_detections_for_batch(np.array(small[i : i + 32])):
            if rect is not None:
                x1, y1, x2, y2 = [v * scale for v in rect]
                last = (max(0, x1 - PADS[2]), max(0, y1 - PADS[0]), min(w, x2 + PADS[3]), min(h, y2 + PADS[1]))
            if last is None:
                raise RuntimeError("no face detected at the start of the clip")
            found.append(last)
    found = np.array(found, dtype=float)
    idx = np.arange(len(frames))
    arr = np.stack([np.interp(idx, keys, found[:, c]) for c in range(4)], axis=1)
    return np.array([arr[max(0, i - 2) : i + 3].mean(axis=0) for i in range(len(arr))]).astype(int)


def render(model, detector, audio, video, start):
    t0 = time.time()
    mel, seconds = mel_spectrogram(audio)
    n = int(np.ceil(seconds * FPS))
    frames = read_frames(video, start, n)
    t1 = time.time()
    boxes = face_boxes(detector, frames)
    t2 = time.time()
    idx_mult = 80.0 / FPS
    chunks = []
    for i in range(n):
        s = int(i * idx_mult)
        if s + MEL_STEP > mel.shape[1]:
            s = mel.shape[1] - MEL_STEP
        chunks.append(mel[:, s : s + MEL_STEP])

    out = os.path.join(OUT_DIR, f"lipsync-{int(t0)}.mp4")
    h, w = frames[0].shape[:2]
    ff = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}", "-r", str(FPS),
         "-i", "-", "-i", audio, "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", out],
        stdin=subprocess.PIPE)
    B = 64
    with torch.no_grad():
        for i in range(0, n, B):
            faces, mels = [], []
            for j in range(i, min(n, i + B)):
                x1, y1, x2, y2 = boxes[j]
                faces.append(cv2.resize(frames[j][y1:y2, x1:x2], (IMG, IMG)))
                mels.append(chunks[j])
            img = np.asarray(faces, dtype=np.float32) / 255.0
            masked = img.copy()
            masked[:, IMG // 2 :] = 0
            img = torch.from_numpy(np.concatenate((masked, img), axis=3)).permute(0, 3, 1, 2).to(DEVICE)
            m = torch.from_numpy(np.asarray(mels, dtype=np.float32)[:, None]).to(DEVICE)
            pred = (model(m, img).permute(0, 2, 3, 1).cpu().numpy() * 255.0).astype(np.uint8)
            for k, p in enumerate(pred):
                j = i + k
                x1, y1, x2, y2 = boxes[j]
                f = frames[j].copy()
                f[y1:y2, x1:x2] = cv2.resize(p, (x2 - x1, y2 - y1))
                ff.stdin.write(f.tobytes())
    ff.stdin.close()
    if ff.wait() != 0:
        raise RuntimeError("ffmpeg failed")
    print(f"rendered {n} frames ({seconds:.1f}s audio) in {time.time() - t0:.1f}s on {DEVICE} "
          f"[prep {t1 - t0:.1f} detect {t2 - t1:.1f} synth+encode {time.time() - t2:.1f}]", flush=True)
    return out, seconds


def load_detector():
    # The vendored code only accepts cpu/cuda in its constructor; move the net to MPS afterwards.
    fa = face_detection.FaceAlignment(face_detection.LandmarksType._2D, flip_input=False, device="cpu")
    if DEVICE != "cpu":
        try:
            fa.face_detector.face_detector.to(DEVICE)
            fa.face_detector.device = DEVICE
        except Exception as e:  # noqa: BLE001
            print("detector stays on cpu:", e, flush=True)
    return fa


def serve(port=8765):
    model, detector = load_model(), load_detector()
    print(f"lipsync sidecar on http://127.0.0.1:{port} ({DEVICE})", flush=True)

    class H(BaseHTTPRequestHandler):
        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self._send(200, {"ok": True, "device": DEVICE})

        def do_POST(self):
            try:
                req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                out, seconds = render(model, detector, req["audio"], req["video"], float(req.get("start", 0)))
                self._send(200, {"video": out, "seconds": seconds})
            except Exception as e:  # noqa: BLE001
                print("error:", e, flush=True)
                self._send(500, {"error": str(e)})

        def log_message(self, *_):
            pass

    HTTPServer(("127.0.0.1", port), H).serve_forever()


if __name__ == "__main__":
    if len(sys.argv) == 4:  # CLI check: lipsync.py audio.wav clip.mov start
        m, d = load_model(), load_detector()
        print(render(m, d, sys.argv[1], sys.argv[2], float(sys.argv[3]))[0])
    else:
        serve()
