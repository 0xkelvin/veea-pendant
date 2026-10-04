# Pendant hardware observations — 2026-10-04

USB identifies the device as `Pendant`, vendor string `ZEPHYR`, VID `0x2fe3`, PID `0x0110`. Its CDC ACM port on this Mac is `/dev/cu.usbmodem1101`. The other USB modem port belongs to the monitor and was not opened.

The CDC port provides a Zephyr interactive shell at the tested host setting of 115200 baud. A passive capture returned buffered boot/runtime logs. Firmware identifies itself as `1.1.20 b312ca1efaaa`, using nRF Connect SDK and an nRF53 Bluetooth controller. The shell's read-only `ble get_name` query returned `Pendant`.

Buffered logs included an existing Bluetooth pairing, a connection followed by advertising stopping, and remote synchronization commands. A subsequent 15-second passive capture returned no output, so the old connection log alone does not prove a current connection. Old flash/CPU reset messages are also insufficient to diagnose a current hardware fault.

The firmware exposes these Bluetooth shell commands: `get_name`, `set_name`, `start_advertising`, `stop_advertising`, and `unpair`. Only help/name queries and advertising control were used. No reset, unpair, erase, firmware update, key extraction, or flash access was requested.

`ble start_advertising` initially returned `-120`. The locally installed Zephyr errno definitions map 120 to `EALREADY`. A subsequent `ble stop_advertising` followed by `ble start_advertising` both succeeded; fresh firmware logs confirmed advertising restarted at uptime 11:24:32.

Initial Sage scans saw nearby advertisements but no Pendant. GATT inspection of the unnamed device did not find the Limitless service. Service inspection sends no streaming commands.

The user subsequently performed a factory reset. Fresh UART boot logs reported `Device is not bluetooth paired` and successful advertising startup. At 02:15 the user's nRF Scanner screenshot showed a connectable `Pendant` advertising Battery Service and `632DE001-604C-446B-A80F-7963E950F3FB`, with ongoing RSSI observations. This confirms the phone can discover the expected advertisement; it does not establish a Sage connection or audio reception.

Native Sage discovery now scans explicitly for the Limitless UUID first, retrieves already-connected peripherals exposing that service, and preserves names/services across repeated advertisements. If no match is found, a foreground-only broad scan provides diagnostics. The signed update built and installed successfully. The user reported finding the Pendant but a connection failure; the error was no longer visible after the app update. A subsequent scan in Mirroring again showed no Pendant. The connection failure and differing discovery results remain under investigation; no specific radio or firmware fault is established.

Firmware boot configuration reports `allow_recording_on_usb: 0`, so live-audio testing should use the Pendant disconnected from USB. The previously observed USB port was absent during the later connection investigation.

At 02:22 Sage visibly discovered `Pendant` at −68 dBm through Mirroring. Tapping it led to `Connecting…`, then a disconnect and zero seconds saved. The first implementation discarded the `ConnectionStateUpdate.failure` details; the installed follow-up now retains them, shows setup stages, and allows 30 seconds for initial Bluetooth connection and 45 seconds for overall setup. No successful GATT/audio session has been established yet.

At 02:26 the updated UI exposed `failedToConnect: Error Domain=CBErrorDomain Code=14 "Peer removed pairing information"` while the candidate showed −56 dBm. This provides a concrete pairing failure, consistent with the phone retaining the bond deleted by the user's factory reset. The requested recovery is iPhone Settings → Bluetooth → Pendant information → Forget This Device, followed by pairing from Sage. This is the iOS pairing record, not the Limitless app's reset/forget command. Recovery verification is pending.

Subsequent observations: at 02:27 setup reached GATT writes and returned `CBATTErrorDomain Code=15 "Encryption is insufficient."` A later retry succeeded: at 02:29 Sage displayed `Receiving audio · 475 frames`, with one packet-processing error. The test recording was stopped, saved, and opened in Review as `Pendant conversation`. The precise user pairing steps were not observed, so the successful retry is verified without attributing it to an unobserved action. The rejected packet was not retained, and `_receive` groups parsing and decoding exceptions; it is not yet known whether actual audio was lost.

`scripts/inspect_pendant_serial.py` defaults to passive reading, caps capture duration and size, and stores output locally with owner-only permissions. Optional flags permit only the specific diagnostic/advertising commands above. Raw captures stay under `/tmp`; they are not included in the repository because device identifiers and historical operational details can appear in logs.

A factory reset is not a harmless discovery test: Limitless's [official guide](https://help.limitless.ai/en/articles/10547401-how-do-i-factory-reset-my-pendant) states it deletes unsynced recordings. It has not been performed by the agent.
