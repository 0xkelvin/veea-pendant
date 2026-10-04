# Validation — 2026-10-04

Completed on the development Mac:

| Check | Result |
| --- | --- |
| `flutter analyze` | No issues |
| `flutter test` | 6 tests passed |
| `cargo fmt --check` | Passed |
| `cargo test` | API integration test passed |
| Rust server startup and `/health` | Passed; cloud AI disabled |
| iPhone 17 / iOS 26.5 simulator Debug build | Passed |
| Simulator install and launch | Passed; Capture screen visually inspected |
| `flutter build ios --release --no-codesign` | Passed; physical-iPhone binary built, unsigned |
| Signed release build and physical installation | Passed on the user's iPhone 17 Pro, iOS 26.6.1 |
| Physical app launch | Capture screen verified through iPhone Mirroring after first-launch trust |
| Physical BLE discovery | Pendant verified in Sage at −68 dBm; discovery was initially intermittent |
| Pendant connection and live capture | Verified: UI showed 475 decoded audio frames; one packet-processing error was reported |
| Save received Pendant audio | Verified: Stop & save opened the saved `Pendant conversation` in Review; capture warning preserved |

The Swift bridge compiled with WhisperKit 1.1.0 and Apple Foundation Models. Bluetooth reception and decoding of real Pendant packets are now verified. Model downloads, speech inference, memory-generation quality, audible recording quality, and background/battery behavior have **not** been verified on physical hardware.

The installed development provisioning profile expires on 2026-10-10. Rebuild/sign and reinstall when it expires. The first launch was blocked by iOS trust; the signature was verified and the provisioning profile included the device. Sage subsequently opened successfully.

Discovery now waits for Bluetooth readiness, reports permission/off states, counts nearby devices, ends with an accurate status, and exposes bounded advertisement details. Unnamed devices can be identified by reading their GATT services; a device is promoted to the Pendant list only if the Limitless service is present. No streaming commands are sent during identification. The inspected unnamed device did not expose that service.

The user's nRF Scanner screenshot subsequently confirmed a connectable Pendant advertising the exact Limitless service UUID. Sage's native scanner was updated to search explicitly for that service first, with a foreground-only unfiltered fallback and merged advertisement metadata. Discovery was intermittent, but at 02:22 Mirroring visibly showed `Pendant` at −68 dBm. An agent-initiated connection attempt returned `Pendant disconnected` and zero audio saved. The original UI discarded the underlying connection failure.

The subsequent update preserves `ConnectionStateUpdate.failure` on screen, distinguishes Bluetooth/audio setup stages, and extends the initial connection timeout from 12 to 30 seconds (45 seconds for overall setup). `flutter analyze`, the signed release build, and physical installation passed. At 02:26 Mirroring displayed the actual failure: `CBErrorDomain Code=14 "Peer removed pairing information"`. This is consistent with the iPhone retaining the previous bond after the user's Pendant reset. The user was directed to forget the old Pendant entry in iOS Bluetooth Settings, then reconnect from Sage. No successful connection or received audio is yet verified. See `pendant-hardware-notes.md` for hardware observations.

Later physical verification supersedes that pending status: at 02:27 a setup attempt reached GATT writes but returned ATT error 15, insufficient encryption. At 02:29 a subsequent user retry succeeded: Mirroring showed `Receiving audio · 475 frames` and one decoding/packet-processing warning. The agent stopped capture, and Sage saved/opened `Pendant conversation` in Review. The specific rejected packet was not retained, so its cause and whether it represented audio loss remain unknown; `_receive` currently counts both protocol parsing and Opus exceptions together. No transcription or audible-quality claim is made.

The simulator build used `xcodebuild` with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` and an explicit iPhone 17 simulator destination. This avoids a Flutter/Xcode 27 issue in generic multi-architecture simulator builds, which incorrectly treats `arm64 x86_64` as one architecture string. From `app/ios`, after `flutter pub get` and `pod install`:

```sh
xcodebuild -workspace Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

Do not run Flutter dependency-generating commands concurrently with Xcode builds; both modify the generated Swift package directory. The pinned Opus iOS fork supplies the missing arm64 simulator slice. CocoaPods remains necessary for that package, and reports a missing upstream podspec license path; the actual package license is preserved in `THIRD_PARTY_NOTICES.md`.

## Automatic capture and quiet-speech update

Implemented and checked after the user's bilingual/transcription feedback:

- Selected Pendant UUID/name and explicit pause preference persist in Keychain-backed settings. Startup reconnect uses the saved UUID, with bounded retry intervals and a stop on pairing failures.
- Live PCM writes and one-minute file rotations share an ordered queue; rotation does not disconnect BLE. Every recording is journaled before file creation. Headers checkpoint every five seconds of received PCM; interrupted recordings recover from complete samples on next startup.
- Persistent processing states distinguish recording, queued, transcribing, no speech recognized, transcript ready/topics pending, ready, and failed. Existing saved Pendant recordings migrate into the queue. Transcription is committed before optional topic generation; topic failure cannot discard it.
- Turbo is the default. Automatic/vi/en language options and a quiet-speech retry preserve the original WAV. Quiet retry applies capped gain to the inference copy and disables Whisper's no-speech threshold; this may increase hallucinations in noise and requires review. Sequential Whisper windows replace energy-based split points. Manual clips are limited to ten minutes to bound RAM.
- Capture diagnostics separate protocol parsing, other/status notifications, incomplete messages, and individual Opus decode failures. A single bad frame no longer aborts later frames in the same payload. Short Opus candidates are not rejected solely for being under ten bytes; 64-bit protobuf scalar metadata is handled.
- The downloaded model cache is reused, with validation of actual compiled-model files so Hugging Face metadata-only directories are not mistaken for models.

`flutter analyze` passed. All **11 Flutter tests** passed, including queued PCM rotation, WAV crash recovery, selected-device reconnect/persistent pause, post-setup disconnect saving, and transcript preservation across classification retries. The signed iOS release compiled successfully.

Physical observations during the update: Mirroring displayed the new Capture UI, but an explicit connection attempt returned ATT Code 15 (insufficient encryption). The user was asked to retry from the unlocked phone and accept the pairing prompt. Reconnection and automatic processing of a new live session are therefore **not yet physically verified** in this build. Long background operation, force-closed capture, offline Pendant backlog import, and Vietnamese recognition improvement are not claimed.

A read-only local measurement of the user's latest previously saved clip (08:36) found a valid 16 kHz mono, 16-bit PCM WAV: 42.82 seconds; actual and header-derived lengths both 1,370,284 bytes; RMS −35.4 dBFS; peak −18.6 dBFS; no clipped samples. This confirms nonempty, relatively quiet audio, not word accuracy or completeness of Bluetooth capture. The diagnostic copy is owner-readable only at `/tmp/sage-audio-level-check.wav`; no audio was uploaded.

The final signed release was installed and launched on the physical iPhone. Mirroring showed the updated Capture screen and then `Transcribing a saved conversation on this iPhone…` without a manual Transcribe action, confirming migration and automatic queue startup. Successful completion and accuracy of the resulting transcription/topic jobs have not yet been inspected. A subsequent explicit scan was visible while processing continued.

At 09:25–09:27, physical verification progressed: Mirroring showed active reception increasing from 3,800 to 4,486 frames, while automatic transcription was running. The warning counter remained one malformed Bluetooth message; no specific Opus decode failure was shown. A read-only app-container listing confirmed two new approximately 1.9 MB audio sections (09:25 and 09:26) and a third growing section (1.2 MB at 09:27), verifying automatic file rotation during continued live capture. Capture was left running. The exact malformed-message diagnostic, completed topics, and recognition quality remain unverified.

## Large v3 comparison option

Added the Argmax `large-v3_947MB` compressed Core ML model to Flutter's selector and the native whitelist. Turbo remains the explicit default. Selecting a comparison model no longer changes the automatic transcription preference; a separate action verifies the selected model is cached before saving it as the automatic default. Original transcript runs, timing, settings and checked reference survive comparisons. Manual operations hold queued inference to prevent model switching between preparation and transcription.

`flutter analyze` passed and all **12 Flutter tests** passed, including the manual queue hold and saved comparison/reference regression. Signed release build, installation and launch passed on the physical iPhone. At 09:44 Mirroring verified the three model choices, Large v3 selection, unchanged Turbo automatic preference, and the initial Large v3 download. Existing conversations were visibly ready with topic labels. Capture was already paused and was left paused. Accuracy, thermal behavior and speed comparison are still pending.

At 09:45–09:46 the download/load completed and Large v3 successfully transcribed an existing approximately 45-second Pendant recording. Mirroring showed both retained outputs under Transcript comparisons: Turbo **3.8 seconds**, Large v3 **9.4 seconds**, both automatic language and normal speech settings. This is one English recording, not a controlled performance benchmark or evidence of Vietnamese improvement. The reference wording was not checked against playback, so no accuracy winner is claimed. The app was left displaying the saved comparisons, with Turbo still the automatic default.

## Source audio playback controls

Added elapsed/total time, a draggable seek slider, ten-second back/forward controls and a Play/Pause toggle that resumes at the selected position. Seeking is clamped to the recording duration, new sources reset the timeline, and replay after completion starts at zero. Audio files are unchanged.

Static analysis passed, all 12 existing Flutter tests passed, and the signed release was built and installed. At 09:55 physical iPhone verification showed 00:00 / 00:44, seeking before playback to 00:22, rewind to 00:12, forward to 00:22, and playback starting at that position. Dragging the slider backward during playback moved to approximately 00:07 and continued playing. Playback was then paused at 00:12. This verifies visible transport behavior; audible output quality was not assessed by the agent.

## Conversation back button

Added a persistent app-bar back arrow when Review has an open conversation. It returns to Capture's existing conversation list, retaining its scroll position through the existing IndexedStack. Static analysis and the signed release build passed; the update installed on the iPhone. Mirroring was unavailable because the phone was in use, so the new button was not physically clicked by the agent.

## Playback during automatic Pendant capture

Removed the blanket `capturing` playback restriction: saved WAVs can play while BLE captures to a different file. The live section remains disabled until saved, with explanatory text. iPhone microphone recording still blocks playback and now pauses an already playing source before starting the microphone.

Static analysis and signed release build passed; installed and launched on the physical phone. At 10:47–10:48 saved audio played from 00:00 through 00:19 with automatic capture enabled, and the back arrow returned to Capture successfully. The Pendant's reconnect attempt failed without detailed iOS error information and automatic retries continued, so concurrent playback with actual incoming frames remains unverified. Playback was left paused at 00:05; automatic capture preference remains enabled.


## Stored Pendant recovery and recording timestamps

Implemented automatic storage query and batch download after BLE reconnection, followed by live capture. Raw pages are flushed to a local archive before cumulative acknowledgements advance; acknowledgements cannot jump a missing page. Import creates playable WAVs and queued conversations, retains the original compressed pages, and retries pending imports after restart. Exact page identities prevent duplicate imports where the existing live WAV has matching page metadata. Older builds did not record these identities, so the initial backlog can overlap older live recordings.

Conversation list and detail now show local recording date and time. Recovered audio uses the Pendant timestamp, with pre-sync clock correction when available. Missing or implausible timestamps are explicitly unavailable rather than replaced by download time. Live timestamps use the phone's first received frame time.

All **18 Flutter tests** and `flutter analyze --no-pub` passed. Recovery tests cover wire parsing, contiguous acknowledgements, restart recovery, duplicate suppression, failed library commits, unknown timestamps, and retained undecodable pages. Signed release build, installation, and launch passed on the physical iPhone 17 Pro.

Physical verification on 4 October 2026:

- At 11:29–11:46, the app downloaded and retained 7,113 original stored pages. Import initially failed because live capture and the archive both initialized the process-wide Opus library. Shared, single-flight initialization fixed this; retained pages required no second download.
- After the corrected release was installed at 11:50, automatic capture was resumed. By 11:54 a read-only app-container inventory showed **7,867 `.done` pages and no pending `.json` pages**. This count includes metadata-only or already-known pages; it is not a conversation or audio-frame count.
- Mirroring showed live reception at 8,351 frames, automatic transcription, and a status reporting 27 recovered sections from the latest import. The conversation list contained 789 total entries including existing recordings and earlier recovered sections.
- At 11:55 a recovered conversation displayed **04/10/2026 · 11:50:24** in both list and detail, with the Pendant clock identified as its time source. Its source player advanced from 00:00 to completion at 00:04 while automatic capture remained enabled. Audible quality was not assessed by the agent.

A fresh controlled ten-minute out-of-range walk and completeness comparison have not yet been performed. Background/locked-screen catch-up is not verified; the UI asks the user to keep Sage open during recovery. Malformed BLE envelopes were observed during transfer; diagnostics now include envelope fields, and raw downloaded pages imported successfully, but this does not establish zero audio loss. Capture was left enabled and recovered transcripts continue through the existing on-phone processing queue.


## Stop source playback when leaving Review

Source playback is enabled only while Review is visible. Leaving the tab pauses the player while preserving its position; pending load/seek actions recheck eligibility before starting playback. This covers both the conversation back arrow and bottom navigation.

Static analysis and signed release build passed; installed on the physical iPhone. At 12:11–12:12, a 61-second recording played, then the back arrow returned to Capture; revisiting Review showed Play source at 00:05. Playback was resumed, then Capture was selected using bottom navigation; revisiting Review showed Play source at 00:12. Neither route automatically resumed playback. Automatic Pendant capture was resumed after installation.


## Transcript visibility and backlog priority

At 13:19–13:20 Mirroring showed the user's selected 61-second conversation in `queued` state with its Transcribe and Retry controls disabled while the automatic queue was busy. The current queue drained the oldest-first snapshot, leaving recent conversations behind the recovered backlog. Existing transcript runs were also displayed below the full model-comparison controls. No device telemetry proving a stuck native inference task was available.

Added a primary Transcript panel near the top of Review, explicit queued/transcribing/no-speech/error messages, a waiting count, and a Transcribe next action available while another job is active. The queue now chooses one recording per turn, prioritises the requested recording then original recording time newest-first, and pauses ten seconds between automatic turns. Topic generation has its own persisted `classifying` state; interrupted classification resumes without retranscribing its saved run. This pacing is not a measured thermal fix.

Static analysis passed and all **19 Flutter tests** passed, including an in-flight priority test that confirms no overlapping transcription, newest-first selection, and one job per turn. The signed release build passed (37.1 MB). Installation was attempted but CoreDevice returned error 4016 and listed the physical phone as unavailable. The update is therefore **not yet installed or physically verified**; the user has been asked to connect the iPhone by USB. Mac backend migration remains next, after this transcript issue is verified.


### Follow-up: enable the original transcription control

The model-comparison panel now queues an explicit transcription request instead of disabling its action whenever automatic inference is active. Model, language, and quiet-speech choices are captured in the request and persisted with the encrypted local session; an explicit request creates a new run even when earlier runs exist. Checked transcript text is preserved. Model/language controls remain selectable during another conversation's job. The current recording or currently processing conversation still cannot start a duplicate job. Model download/loading continues to wait for the inference engine.

All **20 Flutter tests** and static analysis passed. The new regression test queues a comparison during an in-flight job, round-trips its request through session JSON, verifies the selected model/language/quiet-speech settings reach transcription, and preserves the earlier run and checked text.

At 13:36 on 4 October 2026, the signed release (37.1 MB) installed successfully on the physical iPhone and launched. At 13:37–13:38, Mirroring showed 358 queued conversations while the newest recording was processing. Opening the 13:02:16 recording and tapping **Transcribe next** changed its status to **This conversation is next after the current job**. The original model-panel action was green/enabled, labelled **Update queued transcription**, with the persisted Turbo/auto request displayed. This physically verifies queue submission and enabled controls; completion of that requested transcript has not yet been observed. Capture was already paused before installation and was left paused. Mac backend migration remains pending.


## Mac backend processing — 4 October 2026

Implemented the first local offload path for the user's Apple M5 Max / 128 GB Mac:

- Authenticated Rust API on private LAN port 8789, using a separate encrypted SQLite database (`backend/data/mac-sage.sqlite`). Existing text-backup service/data on port 8787 are unchanged. Updated the backup schema to accept current app recording metadata, diagnostics, topics, multilingual run settings, and recovered-Pendant source values.
- Whisper large-v3 full GGML model through the installed whisper.cpp Metal runtime, loopback port 8788; Silero v6.2.0 VAD with 0.35 threshold and 300 ms padding. Quiet retry normalizes a copy and bypasses VAD. Digital-zero PCM completes as empty without inference. All original audio stays on the phone.
- Qwen3 8B via existing loopback Ollama for evidence-backed topics. The previously installed custom Qwen3-VL model returned an empty content field in a smoke test, so the standard text model was downloaded and used instead.
- Encrypted persistent audio jobs, settings/audio digest deduplication, polling, interrupted-job recovery on server startup, and removal of the Mac job's audio payload after success. Encrypted transcript results remain cached for retry/reconnect.
- Flutter **Process on Mac** setting, local-network client, durable phone request, explicit Mac/offline status, one-minute offline retry without automatic phone inference fallback, source transcript saved before topic generation, and USB pairing into Keychain without embedding credentials in the binary.

Validation: **23 Flutter tests passed**, static analysis passed, **3 Rust tests passed** (including authenticated/idempotent/encrypted jobs and removal of completed job audio), and a signed iOS release built successfully (37.1 MB). The authenticated local integration test sent the bundled public 11-second JFK sample through the Rust queue, verified duplicate submissions returned the same job, received three transcript segments with approximately **0.46 seconds of measured Whisper inference**, and verified two topics with exact supporting quotes from a synthetic Vietnamese sentence. This is a single English sample, not a Vietnamese accuracy or all-day performance benchmark.

The Mac backend and local models are running. Physical-phone installation was attempted but failed with CoreDevice error 4016; `devicectl` listed the phone as unavailable, and Mirroring reported iPhone in use. The Mac-connected build is **not yet installed or paired on the physical iPhone**. The user was asked to connect USB and use the same Wi-Fi. Real Pendant audio through this backend, app-to-Mac network permissions, mixed-language accuracy, heat reduction, locked-screen operation, and a fresh out-of-range recovery remain unverified. No private recordings have been sent to any third-party AI API.

Operational scope: foreground Mac development processes, no login/reboot service; private HTTP LAN transport (not TLS); no public listener/tunnel/router changes; original full WAV sections cross the LAN before server-side VAD. Model and runtime instructions are in README, with `scripts/run_mac_backend.sh`, `scripts/pair_mac_backend.py`, and `scripts/check_mac_backend.py`.


### Physical installation and pairing follow-up

At 16:01–16:03 on 4 October 2026, the physical iPhone became available. The active capture was paused and its final 12 seconds saved before installation. The Mac-connected release installed successfully. USB pairing imported the existing backend token into Keychain and enabled Mac processing; Mirroring showed “Your Mac prepares transcripts and topics.” The pairing file was removed from Application Support after import.

Automatic capture was resumed and the Pendant reconnected, showing stored-audio recovery advancing to page 136638 / 143803. Thirteen malformed Bluetooth messages were reported during this recovery; this is not a claim of complete/no-loss recovery. The phone still displayed 5G and the app reported “Waiting for your Mac.” Mac health checks succeeded on the configured `.local` hostname and port 8789, but the job database still contained only the public test job, so no phone-to-Mac transcription had yet been verified. The user was asked to join the same Wi-Fi and lock the phone again for Mirroring. Original recordings remain queued on the phone; no local inference fallback is enabled in Mac mode.


### Wi-Fi end-to-end verification

At 16:07–16:11 on 4 October 2026, after the user joined Wi-Fi, the Mac queue began receiving phone recordings. It advanced from the single public smoke-test job to 37 completed jobs at the read-only verification snapshot. This total includes silent/no-speech results and is not a count of successfully recognized conversations.

Mirroring showed completed conversation entries with transcript previews, generated topic labels, and `ready` status. The 16:07:42 Pendant recording (7.82 seconds) displayed a transcript and the topic “Interrupted Speech”; its text was matched against the authenticated Mac job result, whose model was `mac-whisper-large-v3`, created at 16:08:44, with 0.317 seconds of measured inference. Other recordings also returned nonempty Mac transcripts. The 16:01:34 conversation displayed a saved transcript and topic in its detail panel, but its transcript was not found among Mac job outputs and is not evidence of Mac ASR; existing on-phone runs are reused for topic processing.

This verifies physical iPhone upload → Mac transcription → app transcript display, plus completed topic presentation. It does not verify transcription accuracy or prove that every short result represents actual speech. Heat/battery improvement and Vietnamese-English accuracy still need user comparison against source playback. Automatic Pendant capture remained enabled. Mirroring subsequently locked and requested the user's Mac login, so no further UI interaction was attempted. No third-party inference service was used.


## Meaningful conversation grouping — 4 October 2026

Implemented a reversible conversation view over existing source sessions. Capture lists groups; Review shows the time range, chronological timestamped passages, original corrections, and one playlist with a combined seek bar. Per-passage review retains original model comparison/memory tools. Manual split/join overrides persist in the encrypted library and can be reset to automatic grouping. Original audio files and transcript runs are not merged, rewritten, or discarded.

Grouping uses original recording time, a two-minute gap/pause threshold, ASR speech timestamps where available, and conservative Qwen3 boundary suggestions from the Mac. Confidence >= 0.85 is a heuristic threshold, not a calibrated probability. Unknown recovered timestamps, imports, microphone recordings, and substantially overlapping sections are not automatically combined. AI decisions are fingerprinted against both transcripts and invalidated by corrections or changed adjacency. Grouping errors leave the temporal fallback intact. Decisions are evaluated progressively on old and new recordings while Sage is active. Titles currently combine existing section topics, not a whole-conversation summary.

The UI caches grouping by library revision rather than recomputing for each Bluetooth notification. Playlist refreshes append new recordings only on request so incoming audio does not interrupt playback. Membership changes that remove/reorder source files invalidate the loaded playlist. Recording gaps are skipped rather than synthesized; displayed audio duration differs from wall-clock span when gaps exist.

Validation: **30 Flutter tests passed**, Flutter analysis clean, **3 Rust tests passed**, signed release built (37.1 MB). New tests cover minute-file grouping, long gaps, overlaps, unknown times, separate imports, segment-timed silence, conservative semantic confidence, invalidation after corrections, late recovered adjacency, durable manual overrides, and seeking/clamping across files. The live Qwen endpoint correctly kept a synthetic Vietnamese-English BLE discussion continuous and split an explicit goodbye followed by an unrelated cooking lesson; this is not a segmentation accuracy benchmark.

Physical verification at 16:29–16:35: Mirroring showed a group with 17 saved sections and about 6m37s of audio. Combined playback started and seeking moved to 03:51 across original files. Switching to Capture and back showed Play source at 03:57, confirming pause-on-navigation. A newly captured section appeared through Load newer audio. Capture showed 247 grouped conversations at one snapshot, compared with 1,095 source entries before grouping; counts change as new audio and AI decisions arrive. Final refinements capped the conversation heading at three lines, added undo for internal manual joins, and clarified pending audio-section counts.

The final release installed on the physical iPhone at 16:36; Mac pairing persisted. Capture was saved before each install and automatic capture was resumed afterwards. Speaker-aware boundaries, within-section splitting, a whole-conversation summary, and calibrated segmentation/accuracy evaluation remain future work.
