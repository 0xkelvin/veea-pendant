# Veea Pendant · Sage

A personal AI built from the moments and context of everyday life: conversations from a wearable, selected desktop activity, and information shared from a phone.

**Sage** is the Flutter iPhone app and local AI pipeline in this repository. The aim is an assistant that gradually understands your projects, goals, preferences and experiences, with memories you can inspect, correct and forget. It should help you revisit decisions, learn and reflect—with evidence for what it says about you.

**Status: working audio prototype; broader personal memory and unified desktop/phone recall are in development.** The current app connects to a Limitless Pendant and processes audio on an iPhone or a privately hosted Mac. It is not yet an all-day, production-ready companion.

## What works today

- **Limitless Pendant capture:** BLE discovery, saved-device reconnection, live Opus decoding, audio-file rotation, and stored-page recovery after reconnect. Received archive pages are persisted before acknowledgment.
- **Recording library:** timestamps, offline queues, source playback with seeking, and playback that pauses when leaving Review. Phone microphone recording and audio import are also available.
- **Transcription options:** on-device WhisperKit Small, Turbo and Large v3, or Whisper large-v3 on a Mac. Automatic, Vietnamese and English settings, a quiet-speech retry, saved model comparisons and editable transcripts support evaluation of mixed-language speech.
- **Mac processing:** authenticated Rust API, persistent encrypted transcription jobs, Silero voice activity detection and Qwen3:8B topic extraction. This path uses local models, without a paid inference API.
- **Conversation grouping:** recording times, pauses and optional model suggestions group short audio sections into longer conversations. Manual split/join controls preserve the original recordings and transcript versions.
- **Reviewed memory candidates:** on supported iPhones, Apple Foundation Models proposes memories with supporting transcript quotes. You approve candidates; transcript corrections invalidate their previous interpretations. This is not yet cross-conversation personal memory.

Real iPhone → Mac → transcript display and grouped playback have been observed. Bilingual accuracy, reduced phone heat, unattended background operation and loss-free recovery have **not** been established by those smoke tests. See the [validation history](docs/validation.md).

## Repository layout

| Path | Purpose | Status |
| --- | --- | --- |
| [`app/`](app/) | Flutter Sage app with native Swift BLE discovery, storage and AI bridge | iPhone prototype; Android is a scaffold |
| [`backend/`](backend/) | Rust/Axum transcription jobs, topic extraction, grouping suggestions and optional text backup | Local Mac prototype |
| [`scripts/`](scripts/) | Development setup, USB pairing, diagnostics and integration checks | Developer tools |
| [`veea/`](veea/) | Existing Rust desktop screenshot capture and local search/API experiment | Separate prototype; not integrated with Sage |
| [`device/firmware/`](device/firmware/) | Existing Zephyr camera firmware for XIAO ESP32-S3 Sense | Separate hardware experiment |
| [`docs/`](docs/) | Device notes, validation and architecture review | Implementation evidence and plans |

The XIAO firmware is **not** firmware for the Limitless Pendant. Sage currently talks to the existing Limitless device; it does not flash or replace its firmware. The desktop experiment and firmware retain their existing repository history.

## Current audio architecture

```mermaid
flowchart LR
    P[Limitless Pendant] -->|BLE audio and stored pages| I[Sage on iPhone]
    I --> F[Protected audio files and durable queue]
    F -->|Selected phone mode| W[WhisperKit]
    F -->|Selected Mac mode: WAV upload| R[Rust API on private LAN]
    R --> J[Encrypted persistent jobs]
    J --> S[Silero VAD + Whisper large-v3]
    S --> Q[Qwen3:8B topics and boundary suggestions]
    W --> T[Transcript review and source playback]
    Q --> T
    T --> M[User-reviewed memory candidates]
```

Audio files rotate approximately every minute; that is a storage/processing unit, not the intended conversation length. The conversation view joins compatible sections while preserving individual source files. Current boundaries operate between sections, with a two-minute gap/pause rule and optional AI suggestions; model confidence is a heuristic, not a calibrated probability.

In Mac mode, full WAV sections cross the local network **before** server-side silence filtering. Successful Mac jobs remove their audio payload and retain encrypted results; the phone keeps its originals. If the Mac is unreachable, audio waits on the phone without automatically switching to phone inference. Submitted jobs survive backend restarts. Phone upload/result retrieval currently requires Sage in the foreground; a failed topic request can remain pending for manual retry.

## Run Sage on an iPhone

You need a Mac with Flutter/Dart compatible with [`app/pubspec.yaml`](app/pubspec.yaml), Xcode with the iOS 26+ SDK, CocoaPods, and Apple development signing. The deployment minimum is iOS 16 for capture/transcription; Apple Foundation Models requires iOS 26+, supported hardware and available Apple Intelligence.

```sh
git clone https://github.com/0xkelvin/veea-pendant.git
cd veea-pendant/app
flutter pub get
cd ios
pod install
open Runner.xcworkspace
```

In Xcode, choose **Runner → Signing & Capabilities**, select your own development team, and choose an appropriate bundle identifier. The current identifier is `app.veea.veeaSage`. Then, from `app/`:

```sh
flutter devices
flutter run -d YOUR_IPHONE_ID
```

For a signed release build, run `flutter build ios --release`. Allow Bluetooth and microphone access when needed, and Local Network access for Mac processing. Native Android AI/storage support has not been implemented.

To start:

1. Open Sage and select **Find my Pendant**. Disconnect the Pendant from another receiving app if necessary.
2. Select the device. Sage remembers it for subsequent reconnects; no reset is normally required.
3. Review a short recording and use **Play source** to check audio against the transcript.
4. Try model/language settings on the same recording before relying on automatic results.

**Pause & save** pauses Sage's reception and persists that preference. It does not guarantee that the Pendant itself has stopped recording. Keep Sage open for recovery and uploads during prototype testing. See the [first-device checklist](docs/first-device-test.md) and [hardware notes](docs/pendant-hardware-notes.md).

## Use a Mac as the AI server

This development path has been exercised on Apple Silicon with Metal acceleration. It uses whisper.cpp, Ollama and the Rust backend; downloaded model weights are not committed to Git.

### 1. Install runtimes and models

Install Rust, [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the `whisper-server` executable, and [Ollama](https://ollama.com/). On Homebrew, the whisper.cpp package is named `whisper-cpp`.

Place these files in `backend/models/`:

| File | Source |
| --- | --- |
| `ggml-large-v3.bin` | [whisper.cpp converted Whisper models](https://huggingface.co/ggerganov/whisper.cpp) |
| `ggml-silero-v6.2.0.bin` | [whisper.cpp VAD models](https://huggingface.co/ggml-org/whisper-vad) |

Start Ollama, then download the topic model:

```sh
ollama pull qwen3:8b
```

### 2. Create credentials and start Sage

From the repository root:

```sh
python3 scripts/init_backend.py
cargo build --release --manifest-path backend/Cargo.toml
./scripts/run_mac_backend.sh
```

The credential script creates an owner-only `backend/.env` and refuses to overwrite an existing file. Preserve its `SAGE_DATA_KEY`; losing or changing it prevents reading existing encrypted data.

The launcher selects the Mac's `en0` address. If your active network uses a different interface, set `SAGE_MAC_BIND=YOUR_LAN_IP:8789` when launching the script. The Mac must remain awake and reachable.

| Service | Default address |
| --- | --- |
| Sage Mac API | Mac LAN address, port `8789` |
| whisper.cpp | `127.0.0.1:8788` |
| Ollama | `127.0.0.1:11434` |

This is a foreground development launcher, not a login/reboot service. It starts whisper.cpp when needed and expects Ollama to be running separately.

### 3. Pair the iPhone

With the app installed and the iPhone connected by USB:

```sh
python3 scripts/pair_mac_backend.py \
  --device YOUR_IPHONE_ID \
  --url http://YOUR_MAC.local:8789
```

Open Sage to import the pairing into Keychain and enable **Process on Mac**. Both devices need the same trusted network for this setup. If you changed the bundle identifier, also update the identifier used by the pairing script.

The pairing file is temporary and is removed after import. Credentials are not compiled into the app.

### 4. Check the pipeline

With the services running:

```sh
python3 scripts/check_mac_backend.py --url http://YOUR_MAC.local:8789
```

This sends the public whisper.cpp JFK sample and a synthetic Vietnamese sentence, verifies job deduplication, transcription and topic extraction, and does not print credentials. Use `--sample /path/to/jfk.wav` if the sample is not installed under `/opt/homebrew/share/whisper-cpp/`.

The Mac endpoint currently accepts mono 16 kHz PCM16 WAV, up to ten minutes and 20 MB. Other imported formats require conversion. Phone models remain selectable by disabling **Process on Mac**.

## Data handling and current limits

- The phone transcript library uses AES-GCM with a device-only Keychain key. Audio uses iOS file protection and is excluded from backup. The library is currently rewritten as one encrypted document; incremental storage is planned.
- The backend encrypts stored session/job payloads. The running server can decrypt them; this is not end-to-end encryption against the server operator.
- Development phone-to-Mac transport is **HTTP on a trusted LAN**, without TLS. Add secure transport before wider access. No public tunnel or router configuration is provided.
- Audio/model inference can remain local. Model downloads contact their distribution hosts; no third-party AI service receives recordings through the implemented inference path.
- Storage retention and cross-device deletion are not complete. Local deletion does not automatically delete separately backed-up server data or operator backups. Do not treat the Mac's completed-job result cache as a durable audio archive.
- Speaker identity, emotion detection, cross-session retrieval and autonomous mentoring are not implemented. Exact quote validation does not prove an interpretation is correct.

The optional text-backup server starts with `./scripts/run_backend.sh` and defaults to loopback port `8787`. It supports authenticated `GET /v1/sessions` and `PUT`, `GET`, `DELETE /v1/sessions/{id}`. Backup is explicit per session, excludes audio/local paths, and has no automatic restore/merge UI. Its default port overlaps the separate `veea/` desktop prototype; configure different ports before running both.

## Where this is going

The next version brings wearable audio and digital context into one searchable timeline and a personal memory you control.

1. **Reliable, efficient capture:** measure phone heat/battery use; introduce incremental encrypted storage, compressed audio transfer, background uploads and durable retries for every Mac processing stage.
2. **Desktop and phone recall:** integrate selected Mac screen activity and OCR; add **Share to Sage** for phone links, text, screenshots and files. Ordinary iPhone apps cannot silently inspect other apps; optional user-started recording sessions need a separate design.
3. **Evidence-backed personal memory:** connect projects, people, goals and preferences to source passages; keep uncertain speakers unattributed; propagate corrections and deletion through search and derived memories.
4. **Useful conversation and reflection:** answer questions across days, revisit decisions, track goals you choose, and offer support with explicit evidence and uncertainty. A viewed page is not a belief, and a topic mention does not prove time spent working or a completed commitment.

The model plan is to keep small local models on routine extraction, evaluate multilingual embeddings for retrieval, and test a larger local model for conversation and reflection. These upgrades are proposals, not installed features. Personalization should grow through correctable context and feedback before considering per-user fine-tuning.

Read the [architecture discussion and implementation direction](docs/claude-architecture-review-2026-10-04.txt). It includes the Claude review, challenges to its assumptions, and the subsequent desktop/phone scope addition.

## Development checks

```sh
cd app
flutter analyze
flutter test
cd ../backend
cargo fmt --check
cargo test
```

The current Sage suite covers protocol parsing, durable recording/recovery behavior, queueing, model comparisons, memory invalidation, grouping, playback seeking, backend authentication, encrypted persistence and transcription job idempotency. Hardware, recognition quality and all-day energy use need separate measurements; see [validation](docs/validation.md). These checks do not validate the separate desktop or firmware prototypes.

Dart, Rust, CocoaPods and Swift lockfiles are included. WhisperKit is pinned to `1.1.0`. `scripts/configure_ios.py` records the native project wiring for regeneration; normal builds do not require rerunning it.

## Attribution

Sage's Limitless protocol work uses Omi/BasedHardware references. It is an independent prototype, not an official Limitless or Omi client. See [third-party notices](THIRD_PARTY_NOTICES.md) for source references and license notices. The separate hardware project targets [Seeed Studio XIAO ESP32-S3 Sense](https://www.seeedstudio.com/XIAO-ESP32S3-Sense-p-5639.html); its build instructions are in the [firmware README](device/firmware/README.md).

Credentials, recordings, transcripts, runtime databases, downloaded models and build output are excluded from version control.
