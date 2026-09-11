# Instructions for coding agents

Read `README.md` first — it is the product brief. Then:

## What this is
A macOS-only, open-source (MIT) app that clones the user's face and voice and attends Zoom meetings as them:
virtual camera + virtual mic selectable in Zoom, listens (STT), decides when to speak, decides what to say,
answers in the cloned voice with the cloned face. Visual and voice fidelity matter most.

## Rules
1. **Local / open source first.** Apple on-device frameworks or OSS models by default. A hosted service
   (Vapi, ElevenLabs, HeyGen, Tavus, Claude, …) is fine when it is clearly faster, simpler or better — but only
   behind the existing component protocols, never wired directly into the orchestrator.
2. **Keep the abstraction layer.** `Voice`, `Ears`, `Brain`, `Face` in `Sources/ZoomBuddy/Components.swift`
   are the swap points. New engines = new conforming type + one assignment in `Buddy.swift`. Do not add a
   plugin system, registry, or config framework until there are ≥3 implementations of something.
3. **Simplest thing that works.** Native platform feature > installed tool > dependency > new code. Mark
   deliberate shortcuts with a `// ponytail:` comment naming the ceiling and the upgrade path.
4. **Everything runs on the user's Mac.** Zoom desktop client on the same machine; the app feeds
   OBS Virtual Camera (window capture of the "ZoomBuddy Face" window) and BlackHole 2ch (Zoom mic). Keep that
   working while building native CMIO / audio-driver replacements.
5. **Zoom signals.** Prefer the Zoom Apps SDK or Meeting SDK for active speaker / participants when the user
   has Marketplace credentials; degrade gracefully to audio-only otherwise.
6. **Tests.** One runnable check per non-trivial piece of logic (`Tests/`). `make test` must pass.
7. **Don't touch the user's clone data** in `~/Library/Application Support/ZoomBuddy/` except through the app.

## Build / run
```sh
make build   # swift build -c release + ad-hoc signed build/ZoomBuddy.app
make run
make test
```
Stack: Swift 6.3 (Swift 5 language mode), SwiftUI, AVFoundation, Speech (SpeechAnalyzer), FoundationModels,
CoreAudio. SwiftPM only — no Xcode project; `Info.plist` + `Makefile` produce the bundle.

## Layout
- `Sources/ZoomBuddy/App.swift` — SwiftUI: control window + 1280×720 Face window (captured by OBS)
- `Sources/ZoomBuddy/Components.swift` — protocols + `Speaker` (PCM → named CoreAudio output device)
- `Sources/ZoomBuddy/Apple.swift` — `PersonalVoice`, `AppleEars`, `AppleBrain` (all on-device)
- `Sources/ZoomBuddy/Face.swift` — `ClipFace`: records/loops idle + talking webcam clips
- `Sources/ZoomBuddy/Buddy.swift` — orchestrator + `Trigger` (name-mention detection)
- `Tests/` — XCTest
