# ZoomBuddy

Your digital clone for Zoom meetings. macOS only, open source (MIT), local by default.

## What it is

ZoomBuddy is a small Mac app that sits in a Zoom meeting *as you*. It shows a video of you, listens to what
people say, and when someone addresses you by name it thinks up a short answer and says it in your own cloned
voice. Zoom sees it as just another camera and microphone.

Everything in the current version runs on your Mac with no accounts, no API keys and no data leaving the
machine: Apple's Personal Voice clones your voice, Apple's on-device speech recognizer transcribes the meeting,
and Apple's on-device foundation model decides what to say. The face is you, recorded from your webcam.

## Goal

Clone your **face** and **voice** from a webcam, photos, video and audio recordings, then let the clone
attend Zoom meetings for you: it shows up as a **virtual camera** and **virtual microphone** you select in
Zoom, animates like you, **listens to the meeting** (speech-to-text), **understands when it is expected to
speak**, **figures out what to say**, and answers in your voice. Where Zoom exposes richer signals (who is
speaking, participant list, chat), it should use them.

Visual + voice fidelity is the core of the product, not a nice-to-have. The face is not a replayed video:
the app records and stores videos and images of you and **constructs a lookalike** from them (a motion
bank of real footage with lip sync first, a real-time neural or 3D head later) that is animated in real
time, lip-synced to the cloned voice, and never loops the same motion.

## Principles

- **Local and open source first.** Everything in v1 runs on-device with Apple frameworks. If a hosted
  service is clearly faster/simpler/better for a component (e.g. Vapi or ElevenLabs for voice, HeyGen/Tavus
  for a talking head), it is welcome — behind the same interface.
- **Every component is swappable.** `Voice`, `Ears`, `Brain`, `Face` are protocols
  (`Sources/ZoomBuddy/Components.swift`); the Apple implementations live in `Apple.swift` and `Face.swift`.
  Add an engine by conforming and assigning it in `Buddy.swift`.
- **Simplest thing that works.** See `AGENTS.md`.

## v1 architecture (what exists today)

| Component | v1 (local) | Swap candidates |
|---|---|---|
| Face | **Placeholder:** two webcam clips (idle / talking) looped in a 1280×720 window; OBS captures it → **OBS Virtual Camera** | See "Face roadmap" below |
| Voice | macOS **Personal Voice** (on-device clone) → PCM → **BlackHole 2ch** (Zoom's mic) | ElevenLabs / Vapi / F5-TTS / Chatterbox; own virtual audio driver |
| Ears | On-device **SpeechAnalyzer** listening on the default mic (hears Zoom through the speakers) | whisper.cpp; Zoom SDK raw audio per participant |
| Brain | Apple **on-device Foundation Model**, persona prompt, last 8 utterances as context | Ollama / MLX local LLM; Claude / OpenAI; turn-taking model instead of name trigger |
| When to speak | Someone says one of your names (comma-separated aliases) | Brain judges every segment; Zoom active-speaker + "addressed to me" classifier |

Flow: `Ears → Trigger → Brain → Voice → Speaker`, with `Face` switched to *talking* while audio plays.

## Requirements

- Apple Silicon Mac on **macOS 26** or later, with **Apple Intelligence** enabled
  (System Settings › Apple Intelligence & Siri).
- **Xcode 26** (to build; `xcode-select --install` is not enough).
- **OBS Studio** (free) — provides the virtual camera. `brew install --cask obs`
- **BlackHole 2ch** (free) — provides the virtual microphone. `brew install blackhole-2ch`
- The regular **Zoom** desktop client on the same Mac.

## How to use

### 1. Clone your voice (once, ~15 minutes)
System Settings › Accessibility › **Personal Voice** › *Create a Personal Voice*. Read the prompts in a quiet
room. macOS builds the voice on-device (it can take a while in the background; the Mac must be plugged in).

### 2. Build and start the app
```sh
git clone https://github.com/ktamas77/zoombuddy && cd zoombuddy
make run          # builds build/ZoomBuddy.app and opens it
```
Grant camera and microphone access when asked. The control window shows the status of the voice, the
output device and the on-device model; fix anything marked ⚠️ before continuing.

### 3. Clone your face (once, ~1 minute)
In the app:
- **Record idle 20s** — sit as you would while listening: small movements, nods, the occasional glance.
- **Record talking 20s** — talk (anything), gesture as you normally do.
- **Open Face window** — a 1280×720 window that loops the current clip. Leave it open.

Clips live in `~/Library/Application Support/ZoomBuddy/`. Re-record any time.

### 4. Wire it into Zoom (once)
- OBS: add a **Window Capture** source pointing at the "ZoomBuddy Face" window, then **Start Virtual Camera**.
- Zoom › Settings › Video: camera = **OBS Virtual Camera**.
- Zoom › Settings › Audio: microphone = **BlackHole 2ch**; speaker = your real speakers
  (ZoomBuddy listens to the meeting through them).

### 5. Attend a meeting
- Enter the name(s) people call you, comma-separated (`Alex, Alexander` catches transcription variants).
- Edit the persona text — this is how the clone answers.
- Press **Test voice**: you should hear nothing locally, and Zoom's mic meter should move.
- Toggle **Attend**. Join the meeting with Zoom as usual, camera and mic on.

The transcript scrolls in the control window. When someone says your name, the status goes
*Listening → Thinking → Speaking*, the face switches to the talking clip, and the answer plays into Zoom.
Toggle **Attend** off (or just unmute yourself) to take over.

## Development

```sh
make build   # release build + ad-hoc signed .app in build/
make test    # XCTest
```

## Face roadmap

The `Face` protocol stays the same; the implementation behind it grows in three phases:

1. **Motion bank + lip sync** (next). Record many clips (listening, nodding, reacting, talking), cut them into
   short snippets, pick them stochastically with crossfades so idle motion never repeats. While speaking, run
   an audio-driven lip-sync model (MuseTalk, or Wav2Lip via CoreML) on the current snippet. TTS audio exists
   before playback starts, so the mouth can be rendered ahead of time. Real pixels of you = highest fidelity.
2. **Real-time neural head** from a reference frame + audio/motion (LivePortrait, Ditto). Limited by Apple
   Silicon throughput today; useful as a lighter alternative for a small Zoom tile.
3. **Constructed 3D head.** Train a Gaussian-splatting avatar (GaussianAvatars / FlashAvatar) from the stored
   footage, drive it with audio-to-expression (e.g. Audio2Face) plus procedural blinks and head motion, render
   with Metal. Training needs a CUDA GPU once; inference runs locally.

A hosted talking-head API (HeyGen, Tavus) can back the same protocol as a fallback if local quality is not enough.

## Roadmap

- [ ] Face phase 1: motion bank + lip sync (see above)
- [ ] Voice engine options: ElevenLabs / Vapi / open-source TTS behind `Voice`
- [ ] Zoom integration for granular signals: **Zoom Apps SDK** (`onActiveSpeakerChange`, participants, running
      inside the Zoom client) or the **Zoom Meeting SDK** (clone joins as its own participant, gets per-user raw
      audio, sends raw video/audio → no OBS/BlackHole needed). Both need a Zoom Marketplace app on your account.
- [ ] Turn-taking: let the Brain decide when a reply is expected, not only on name mention
- [ ] Native CMIO camera extension + audio driver so Zoom lists "ZoomBuddy" devices directly
- [ ] Language setting for Ears (fixed to en-US today)

## Disclosure

The clone is you, with your consent. Tell the other participants they are talking to a clone; some
jurisdictions and most companies require it.
