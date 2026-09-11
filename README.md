# ZoomBuddy

Your digital clone for Zoom meetings. macOS only, open source (MIT), local by default.

## Goal

Clone your **face** and **voice** from a webcam, photos, video and audio recordings, then let the clone
attend Zoom meetings for you: it shows up as a **virtual camera** and **virtual microphone** you select in
Zoom, animates like you, **listens to the meeting** (speech-to-text), **understands when it is expected to
speak**, **figures out what to say**, and answers in your voice. Where Zoom exposes richer signals (who is
speaking, participant list, chat), it should use them.

Visual + voice fidelity is the core of the product, not a nice-to-have.

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
| Face | Two webcam clips (idle / talking) looped in a 1280×720 window; OBS captures it → **OBS Virtual Camera** | Lip-synced talking head (MuseTalk, LivePortrait, Ditto) fed by TTS audio; HeyGen / Tavus; native CMIO camera extension so Zoom lists "ZoomBuddy Camera" |
| Voice | macOS **Personal Voice** (on-device clone) → PCM → **BlackHole 2ch** (Zoom's mic) | ElevenLabs / Vapi / F5-TTS / Chatterbox; own virtual audio driver |
| Ears | On-device **SpeechAnalyzer** listening on the default mic (hears Zoom through the speakers) | whisper.cpp; Zoom SDK raw audio per participant |
| Brain | Apple **on-device Foundation Model**, persona prompt, last 8 utterances as context | Ollama / MLX local LLM; Claude / OpenAI; turn-taking model instead of name trigger |
| When to speak | Someone says one of your names (comma-separated aliases) | Brain judges every segment; Zoom active-speaker + "addressed to me" classifier |

Flow: `Ears → Trigger → Brain → Voice → Speaker`, with `Face` switched to *talking* while audio plays.

## Setup (once)

1. macOS 26+, Apple Silicon, Xcode 26. Enable **Apple Intelligence** (System Settings › Apple Intelligence & Siri).
2. **Personal Voice**: System Settings › Accessibility › Personal Voice › Create (≈15 min of reading prompts, on-device).
3. `brew install blackhole-2ch` (free virtual audio device).
4. OBS: add a **Window Capture** source of the "ZoomBuddy Face" window, then **Start Virtual Camera**.
5. Zoom: Video → *OBS Virtual Camera*; Audio → Microphone: *BlackHole 2ch*; Speaker: your real speakers.

## Run

```sh
make run        # builds build/ZoomBuddy.app and opens it
make test
```

In the app: enter your name(s), record the *idle* and *talking* clips, open the Face window, press **Test voice**,
then toggle **Attend**. Join the Zoom meeting with the regular Zoom client on the same Mac.

## Roadmap

- [ ] Real lip-sync talking head from the TTS audio (visual fidelity)
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
