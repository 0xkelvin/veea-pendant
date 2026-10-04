#!/bin/sh
# Run in a terminal; Ctrl-C stops only Sage's Mac services. Ollama is separate.
set -eu
cd "$(dirname "$0")/../backend"
umask 077
set -a
. ./.env
set +a
if [ -n "${SAGE_MAC_BIND:-}" ]; then
  export SAGE_BIND="$SAGE_MAC_BIND"
else
  mac_address="$(ipconfig getifaddr en0)"
  export SAGE_BIND="${mac_address}:8789"
fi
export SAGE_DB="data/mac-sage.sqlite"
export SAGE_TOPIC_MODEL="${SAGE_TOPIC_MODEL:-qwen3:8b}"
mkdir -p runtime
whisper_pid=''
cleanup() {
  if [ -n "$whisper_pid" ]; then kill "$whisper_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM
if ! curl --fail -sS --max-time 2 http://127.0.0.1:8788/health >/dev/null 2>&1; then
  whisper-server --host 127.0.0.1 --port 8788 -m models/ggml-large-v3.bin -l auto -t 8 \
    --vad --vad-model models/ggml-silero-v6.2.0.bin --vad-threshold 0.35 \
    --vad-speech-pad-ms 300 > runtime/whisper.log 2>&1 &
  whisper_pid=$!
fi
exec_backend() { ./target/release/sage-backend; }
exec_backend
