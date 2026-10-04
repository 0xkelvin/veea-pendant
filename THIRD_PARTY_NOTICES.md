# Third-party notices

## Omi / BasedHardware

The Limitless BLE protocol implementation was derived from the protocol described in
[`limitless_connection.dart`](https://github.com/BasedHardware/omi/blob/7b40315647e938894b791b6c928a7e8ff25e5900/app/lib/services/devices/connectors/limitless_connection.dart)
and device UUID definitions at Omi commit `7b40315647e938894b791b6c928a7e8ff25e5900`.
Sage is an independent prototype, not an official Limitless or Omi client.

Stored-page transfer, status fields, timestamp interpretation and durable-before-ACK behavior were also studied in `app/ios/Runner/Limitless/LimitlessProtocol.swift`, `LimitlessFlashDrainEngine.swift` and `app/lib/services/devices/connectors/limitless_clock_drift.dart` at the same pinned Omi commit. Sage's archive, cumulative contiguous watermark, deduplication and import pipeline are implemented in Dart.

MIT License

Copyright (c) 2024 Based Hardware Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Dependencies

WhisperKit / Argmax OSS is linked from its pinned Swift package. Flutter packages,
Rust crates, CocoaPods, Opus, and downloaded model weights retain their respective
licenses. See the dependency lockfiles and upstream distributions for full notices.
Review and bundle all applicable licenses before distributing a release.

## Opus Flutter iOS fork

Pinned to `04696ff930a464bd47677026d45c3c3004f6daab` from [mdmohsin7/opus_flutter](https://github.com/mdmohsin7/opus_flutter). Its package license is reproduced below because its podspec references a missing license path.

opus_flutter_ios license:
Copyright 2021 Eric Prokop und Nils Wieler Hard- und Softwareentwicklung GbR

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

opus license:
Copyright 2001-2011 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Opus is subject to the royalty-free patent licenses which are
specified at:

Xiph.Org Foundation:
https://datatracker.ietf.org/ipr/1524/

Microsoft Corporation:
https://datatracker.ietf.org/ipr/1914/

Broadcom Corporation:
https://datatracker.ietf.org/ipr/1526/


## Local Mac inference

- whisper.cpp runtime and Whisper large-v3 converted GGML weights: https://github.com/ggml-org/whisper.cpp and https://huggingface.co/ggerganov/whisper.cpp (MIT; original Whisper https://github.com/openai/whisper).
- Silero VAD converted weights: https://huggingface.co/ggml-org/whisper-vad (upstream https://github.com/snakers4/silero-vad, MIT).
- Qwen3 8B, distributed locally through Ollama: https://huggingface.co/Qwen/Qwen3-8B (Apache-2.0); Ollama runtime https://github.com/ollama/ollama (MIT).

Models are downloaded to the developer Mac and are not bundled into the iPhone app. Runtime dependencies retain their own upstream notices.
