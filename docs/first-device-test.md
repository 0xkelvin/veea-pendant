# First Pendant and bilingual accuracy test

Use a short conversation with participants who agree to recording. Keep the app open during the initial tests. This is a prototype, not a reliable all-day recorder yet.

## Capture

1. Disconnect the Pendant from the Limitless/Omi apps. Turn Bluetooth on and allow Sage access.
2. Tap Find my Pendant, select the device, and wait for the receiving-audio frame counter. No audio after eight seconds produces a warning. If setup fails, stop, check competing connections, and try again.
3. Speak for 30–60 seconds, stop/save, and play back the source. Check that the beginning/end and language switches are audible. Note the Pendant firmware version manually.
4. Repeat once with the phone microphone. This separates BLE/audio problems from transcription problems.
5. During another short test, move out of range, return, and stop/save. Confirm a gap/disconnect warning. This version does not automatically reconnect; start a new session. Silence is not proof that a connection is healthy.

The connector sends clock sync and live-stream commands only. It does not import or acknowledge flash backlog. Device-specific behavior remains unverified until this test passes. Background modes are declared, but lock-screen, suspension, interruption, and long-duration reliability are not proven. Force-quitting mid-recording can leave an unfinished WAV; automatic recovery is not implemented.

## Compare transcription

Use 8–10 short clips spanning quiet speech, ambient noise, names, engineering terms, and language switches. Include examples such as:

> Hôm nay mình chưa gửi firmware cho Minh. I'll send it tomorrow, after the BLE test.

> The meeting is at three, không phải hai giờ. Mình hơi mệt hôm nay, nhưng không phải ngày nào cũng vậy.

These are test scripts, not stored facts about the user.

1. Download/load Small, transcribe the clip, then repeat with Turbo. Both originals remain visible.
2. Listen and write one accurate reference transcript, preserving code switches. Confirm it only after checking the source.
3. Compare token error rate and processing seconds. The score uses space-separated tokens, not Vietnamese linguistic words, and can exceed 100% for many insertions. It is not an understanding or emotional-accuracy score.
4. Separately mark critical errors: speaker ownership, names, dates/numbers, negation, planned versus completed actions, and missed speech. A low aggregate error rate can still hide a dangerous meaning change.
5. Record battery percentage before/after a consistent series, elapsed time, thermal behavior, model, and clip duration. Do not infer daily cost/battery from a single short test.

Choose the smaller model only if its critical-error rate is acceptable on these clips. No accuracy equivalence is assumed. This build makes zero paid cloud API calls; energy, storage, downloads, and future hosted-service costs still exist.

## Check memories

Generate candidates only after confirming the reference. Apple Intelligence must be available; language support and mixed-language quality must be tested on the actual OS/model combination. If unavailable or generation fails, transcripts remain usable. Memory input is limited to 6,000 characters in this milestone, with a visible error instead of silent truncation.

- “Chưa gửi” must not become “sent.”
- An unidentified speaker must not automatically become “you.”
- Feeling tired today must not become a permanent personality trait or diagnosis.
- Quotes must match the checked transcript; interpretations still need human review.
- Accept, edit, or reject candidates. Editing returns a candidate to pending.
- Correct the reference afterward: all derived candidates, including accepted ones, must disappear while original model runs remain.
- Relaunch to confirm persistence. Delete the test session to confirm local cleanup. If backed up, delete the server copy separately.
