#!/usr/bin/env bash
set -uo pipefail

SPEACHES_URL="${SPEACHES_URL:-http://192.168.60.7:9900}"
STT_MODEL="${STT_MODEL:-Systran/faster-whisper-large-v3}"
TTS_MODEL="${TTS_MODEL:-speaches-ai/Kokoro-82M-v1.0-ONNX-fp16}"
TTS_VOICE="${TTS_VOICE:-af_heart}"
TTS_TEXT="${TTS_TEXT:-Hello, this is a test of the speaches text to speech deployment.}"
STT_TIMEOUT="${STT_TIMEOUT:-3600}"
MODEL_TIMEOUT="${MODEL_TIMEOUT:-3600}"
CURL_TIMEOUT="${CURL_TIMEOUT:-120}"
STT_VAD_FILTER="${STT_VAD_FILTER:-false}"
SSH_HOST="${SSH_HOST:-athena}"
SSH_IDENTITY="${SSH_IDENTITY:-$HOME/.ssh/athena_key}"
CLIP_URL="${CLIP_URL:-https://huggingface.co/datasets/Narsil/asr_dummy/resolve/main/1.flac}"

FULL=0
DIAG=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--full] [--diag] [--url URL] [--help]

Tests the speaches deployment end to end.

Options:
  --full       also test word timestamps, /v1/audio/translations and /v1/audio/speech/timestamps
  --diag       on failure, collect diagnostics from \$SSH_HOST (docker logs, nvidia-smi)
  --url URL    speaches base URL (default: $SPEACHES_URL)
  --help       show this help

Environment overrides:
  SPEACHES_URL  STT_MODEL  TTS_MODEL  TTS_VOICE  TTS_TEXT
  STT_TIMEOUT   MODEL_TIMEOUT  CURL_TIMEOUT  STT_VAD_FILTER  SSH_HOST  SSH_IDENTITY  CLIP_URL
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --diag) DIAG=1 ;;
    --url) SPEACHES_URL="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BOLD=$'\033[1m'; RESET=$'\033[0m'
fi

PASSED=0
FAILED=0

info() { printf '%s[INFO]%s %s\n' "$BOLD" "$RESET" "$*"; }
pass() { printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; FAILED=$((FAILED + 1)); }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RESET"; }

for dep in curl jq ffprobe; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing required dependency: $dep" >&2
    exit 2
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

show_body() {
  [ -s "$1" ] || return 0
  printf '       response: '
  head -c 300 "$1" | tr '\n' ' '
  echo
}

section "0/7 Configuration"
info "URL:        $SPEACHES_URL"
info "STT model:  $STT_MODEL"
info "TTS model:  $TTS_MODEL (voice: $TTS_VOICE)"
info "STT timeout: ${STT_TIMEOUT}s, model download: ${MODEL_TIMEOUT}s, other calls: ${CURL_TIMEOUT}s"
info "STT vad_filter: $STT_VAD_FILTER (false avoids the upstream VAD repetition artifact, issue #616)"

section "1/7 Health check"
code="$(curl -sS -o "$TMP/health.txt" -w '%{http_code}' -m "$CURL_TIMEOUT" "$SPEACHES_URL/health")"
if [ "$code" = "200" ] && [ "$(cat "$TMP/health.txt")" = "OK" ]; then
  pass "GET /health -> 200 OK"
else
  fail "GET /health -> HTTP $code, body: $(cat "$TMP/health.txt")"
fi

section "2/7 Loaded models before test"
if curl -sS -o "$TMP/models-before.json" -w '' -m "$CURL_TIMEOUT" "$SPEACHES_URL/v1/models" \
   && jq -e . "$TMP/models-before.json" >/dev/null 2>&1; then
  count="$(jq '.data | length' "$TMP/models-before.json")"
  if [ "$count" -gt 0 ]; then
    pass "/v1/models lists $count model(s)"
    jq -r '.data[].id' "$TMP/models-before.json" | sed 's/^/       /'
  else
    warn "/v1/models is empty - models are not installed yet; the next step will download them"
  fi
else
  fail "GET /v1/models did not return valid JSON"
  show_body "$TMP/models-before.json"
fi

section "3/7 Ensure models installed"
ensure_model() {
  local model_id="$1" out="$2"
  local code
  code="$(curl -sS -o "$out" -w '%{http_code}' -m "$MODEL_TIMEOUT" -X POST "$SPEACHES_URL/v1/models/$model_id")"
  case "$code" in
    200) pass "$model_id downloaded" ;;
    201) pass "$model_id already present" ;;
    *)   fail "POST /v1/models/$model_id -> HTTP $code"; show_body "$out" ;;
  esac
}
info "POST /v1/models (idempotent; large-v3 is ~3.1 GB on first run, up to ${MODEL_TIMEOUT}s)"
ensure_model "$STT_MODEL" "$TMP/model-stt.txt"
ensure_model "$TTS_MODEL" "$TMP/model-tts.txt"

section "4/7 Download test clip"
if curl -sS -fL -o "$TMP/1.flac" -m "$CURL_TIMEOUT" "$CLIP_URL"; then
  pass "Downloaded test clip ($(stat -c %s "$TMP/1.flac") bytes)"
else
  fail "Could not download test clip from $CLIP_URL"
fi

section "5/7 Speech-to-text"
info "POST /v1/audio/transcriptions (model loads into VRAM on first call, up to ${STT_TIMEOUT}s)"
start=$(date +%s)
code="$(curl -sS -o "$TMP/stt.json" -w '%{http_code}' -m "$STT_TIMEOUT" \
  -F "model=$STT_MODEL" -F "file=@$TMP/1.flac" \
  -F "vad_filter=$STT_VAD_FILTER" \
  "$SPEACHES_URL/v1/audio/transcriptions")"
elapsed=$(( $(date +%s) - start ))
if [ "$code" = "200" ]; then
  text="$(jq -r '.text // empty' "$TMP/stt.json" 2>/dev/null)"
  if [ -n "$text" ]; then
    pass "Transcription succeeded in ${elapsed}s: $text"
  else
    fail "HTTP 200 but no transcript text returned"
    show_body "$TMP/stt.json"
  fi
else
  fail "POST /v1/audio/transcriptions -> HTTP $code after ${elapsed}s"
  show_body "$TMP/stt.json"
fi

section "6/7 Model residency after transcription"
if curl -sS -o "$TMP/models-after.json" -w '' -m "$CURL_TIMEOUT" "$SPEACHES_URL/v1/models"; then
  if jq -e --arg m "$STT_MODEL" '.data[] | select(.id == $m)' "$TMP/models-after.json" >/dev/null 2>&1; then
    pass "/v1/models now includes $STT_MODEL"
  else
    warn "$STT_MODEL not listed in /v1/models after transcription"
  fi
else
  fail "GET /v1/models (after) failed"
fi
if curl -sS -o "$TMP/ps.json" -w '' -m "$CURL_TIMEOUT" "$SPEACHES_URL/api/ps"; then
  loaded="$(jq '.models | length' "$TMP/ps.json" 2>/dev/null)"
  if [ "${loaded:-0}" -gt 0 ]; then
    pass "/api/ps reports ${loaded} loaded model(s) (WHISPER__TTL=-1 keeps it resident)"
  else
    warn "/api/ps reports no loaded models"
  fi
fi

section "7/7 Text-to-speech"
code="$(curl -sS -o "$TMP/tts.wav" -w '%{http_code}' -m "$CURL_TIMEOUT" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$TTS_MODEL\",\"input\":\"$TTS_TEXT\",\"voice\":\"$TTS_VOICE\",\"response_format\":\"wav\"}" \
  "$SPEACHES_URL/v1/audio/speech")"
if [ "$code" = "200" ]; then
  duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/tts.wav" 2>/dev/null)"
  if [ -n "$duration" ] && awk -v d="$duration" 'BEGIN { exit !(d > 0) }'; then
    pass "TTS generated valid WAV (${duration}s, $(stat -c %s "$TMP/tts.wav") bytes)"
  else
    fail "TTS returned HTTP 200 but output is not a valid audio file"
  fi
else
  fail "POST /v1/audio/speech -> HTTP $code"
  show_body "$TMP/tts.wav"
fi

if [ "$FULL" = "1" ]; then
  section "Extra: /v1/audio/transcriptions word timestamps"
  code="$(curl -sS -o "$TMP/words.json" -w '%{http_code}' -m "$STT_TIMEOUT" \
    -F "model=$STT_MODEL" -F "file=@$TMP/1.flac" \
    -F "response_format=verbose_json" -F "timestamp_granularities[]=word" \
    -F "vad_filter=$STT_VAD_FILTER" \
    "$SPEACHES_URL/v1/audio/transcriptions")"
  if [ "$code" = "200" ] && jq -e '(.words // []) | length > 0 and (.[0] | has("start") and has("end") and has("word"))' "$TMP/words.json" >/dev/null 2>&1; then
    pass "Word timestamps returned ($(jq '.words | length' "$TMP/words.json") words, first: $(jq -c '.words[0]' "$TMP/words.json"))"
  else
    fail "POST /v1/audio/transcriptions (verbose_json + word timestamps) -> HTTP $code"
    show_body "$TMP/words.json"
  fi

  section "Extra: /v1/audio/translations"
  code="$(curl -sS -o "$TMP/tr.json" -w '%{http_code}' -m "$STT_TIMEOUT" \
    -F "model=$STT_MODEL" -F "file=@$TMP/1.flac" \
    -F "vad_filter=$STT_VAD_FILTER" \
    "$SPEACHES_URL/v1/audio/translations")"
  if [ "$code" = "200" ] && [ -n "$(jq -r '.text // empty' "$TMP/tr.json" 2>/dev/null)" ]; then
    pass "Translation: $(jq -r .text "$TMP/tr.json")"
  else
    fail "POST /v1/audio/translations -> HTTP $code"
    show_body "$TMP/tr.json"
  fi

  section "Extra: /v1/audio/speech/timestamps (VAD)"
  code="$(curl -sS -o "$TMP/vad.json" -w '%{http_code}' -m "$CURL_TIMEOUT" \
    -F "file=@$TMP/1.flac" \
    "$SPEACHES_URL/v1/audio/speech/timestamps")"
  if [ "$code" = "200" ] && [ -s "$TMP/vad.json" ]; then
    pass "VAD timestamps returned: $(head -c 200 "$TMP/vad.json" | tr '\n' ' ')"
  else
    fail "POST /v1/audio/speech/timestamps -> HTTP $code"
    show_body "$TMP/vad.json"
  fi
fi

section "Summary"
printf 'Passed: %s%d%s  Failed: %s%d%s\n' "$GREEN" "$PASSED" "$RESET" "$RED" "$FAILED" "$RESET"

if [ "$FAILED" -gt 0 ] && [ "$DIAG" = "1" ]; then
  section "Diagnostics via ssh $SSH_HOST"
  SSH_OPTS=(-o ConnectTimeout=5 -o IdentityAgent=none -o IdentitiesOnly=yes)
  [ -n "$SSH_IDENTITY" ] && SSH_OPTS+=(-i "$SSH_IDENTITY")
  if ssh "${SSH_OPTS[@]}" "$SSH_HOST" '
      echo "--- docker ps ---"
      docker ps --filter name=speaches --format "{{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1
      echo "--- nvidia-smi ---"
      nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv 2>&1
      echo "--- nvidia runtime / env ---"
      docker inspect speaches --format "runtime={{.HostConfig.Runtime}}" 2>&1
      docker inspect speaches --format "{{range .Config.Env}}{{println .}}{{end}}" 2>&1 | grep -E "WHISPER|TTL|HF_" || true
      echo "--- mounts ---"
      docker inspect speaches --format "{{range .Mounts}}{{println .Source \"->\" .Destination}}{{end}}" 2>&1
      echo "--- cache dir ownership ---"
      CACHE_DIR="$(docker inspect speaches --format "{{range .Mounts}}{{if eq .Destination \"/home/ubuntu/.cache/huggingface/hub\"}}{{.Source}}{{end}}{{end}}" 2>&1)"
      ls -ld "$CACHE_DIR" 2>&1
      echo "--- logs (tail 80) ---"
      docker logs --tail 80 speaches 2>&1
    '; then
    info "Diagnostics collected"
  else
    warn "SSH diagnostics failed (host $SSH_HOST unreachable or key not accepted)"
  fi
elif [ "$FAILED" -gt 0 ]; then
  info "Re-run with --diag to collect docker logs and GPU info via ssh $SSH_HOST"
fi

[ "$FAILED" -eq 0 ]
