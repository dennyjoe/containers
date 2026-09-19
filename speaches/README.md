# speaches

Self-hosted [speaches](https://github.com/speaches-ai/speaches) — an OpenAI-compatible API for speech-to-text (faster-whisper) and text-to-speech (Kokoro/Piper), running on the GPU host with the NVIDIA container runtime.

## Deployment

- **Image:** `ghcr.io/speaches-ai/speaches:0.8.3-cuda-12.6.3` (pinned; `latest-cuda` tracked the same build at the time of writing)
- **URL:** `http://192.168.60.7:9900` (port `9900` → container `8000`)
- **GPU:** NVIDIA RTX 5000 Ada 32 GB, `runtime: nvidia`
- **Model cache:** `$INSTALL_DIR/hf-cache` → `/home/ubuntu/.cache/huggingface/hub`
- **Settings:** `WHISPER__TTL: -1` (keeps models resident in VRAM indefinitely)
- **Managed via Portainer** — the stack environment must define `INSTALL_DIR`

### Version distinctions (0.8.3 vs 0.9.0-rc/master)

| Behaviour | Deployed `0.8.3` | `0.9.0-rc` / `master` |
|---|---|---|
| `PRELOAD_MODELS` | **Ignored** (silently) | Downloads models at startup |
| Model TTL env vars | `WHISPER__TTL` (shared by STT + TTS) | `STT_MODEL_TTL`, `TTS_MODEL_TTL`, `VAD_MODEL_TTL` |
| Auto-download on inference | **No** → HTTP 404 `not installed locally` | **No** → HTTP 404 (preload is the only automatic path) |
| `vad_filter` request param | Supported (default `true`) | Ignored (VAD always applied) |
| `WHISPER__USE_BATCHED_MODE` | Optional, experimental | Default behaviour |

This deployment pins `0.8.3` because it supports the `vad_filter=false` workaround below (see [Known issues](#known-issues)).

## Models

Models are not downloaded automatically. Install them once (idempotent; returns `200` when downloaded, `201` when already present):

```bash
BASE=http://192.168.60.7:9900

# STT: ~3.1 GB
curl -X POST -m 3600 "$BASE/v1/models/Systran/faster-whisper-large-v3"
# TTS: ~350 MB
curl -X POST -m 3600 "$BASE/v1/models/speaches-ai/Kokoro-82M-v1.0-ONNX-fp16"
```

Verify with `GET /v1/models`. `GET /v1/registry` lists all supported remote models (~700).

## Speech-to-text

```bash
curl "$BASE/v1/audio/transcriptions" \
  -F "model=Systran/faster-whisper-large-v3" \
  -F "file=@audio.flac" \
  -F "vad_filter=false"
```

### Word timestamps

Word-level timestamps require **both** `response_format=verbose_json` and `timestamp_granularities[]=word`:

```bash
curl "$BASE/v1/audio/transcriptions" \
  -F "model=Systran/faster-whisper-large-v3" \
  -F "file=@audio.flac" \
  -F "response_format=verbose_json" \
  -F "timestamp_granularities[]=word" \
  -F "vad_filter=false" | jq '.words[:3]'
```

```json
[
  {"start": 0.18, "end": 0.6,  "word": " he",    "probability": 0.79},
  {"start": 0.6,  "end": 0.84, "word": " hoped", "probability": 0.999},
  {"start": 0.84, "end": 1.06, "word": " there", "probability": 0.995}
]
```

- Plain `json` (default) returns text only, no timestamps.
- `srt` / `vtt` return **segment-level** timestamps only, not per-word.
- `timestamp_granularities[]` is only honoured with `verbose_json`; other formats log a warning.

## Known issues

### Repeated words / garbled transcription

With the default `vad_filter=true`, short clips can get stuck in a repetition loop (e.g. `...20 minutes and 20 minutes and 20 minutes...`). This is upstream [speaches#616](https://github.com/speaches-ai/speaches/issues/616): speaches pins `temperature=0.0`, which disables faster-whisper's per-segment temperature-fallback retry, so segments cut badly by VAD loop.

**Workaround:** pass `vad_filter=false` per request. Verified on this deployment — the same clip that loops with VAD enabled transcribes cleanly with it disabled. Note the fix is not in `master`/`0.9.0-rc` yet, and those builds do not allow disabling VAD.

## Testing

`test-deployment.sh` runs an end-to-end check: health, model install, transcription, model residency, TTS, and optionally translations, word timestamps, and VAD.

```bash
./speaches/test-deployment.sh            # core checks (7 sections)
./speaches/test-deployment.sh --full     # + word timestamps, translations, VAD timestamps
./speaches/test-deployment.sh --diag     # collect docker/GPU diagnostics via ssh on failure
./speaches/test-deployment.sh --url http://other-host:9900
./speaches/test-deployment.sh --help
```

Environment overrides:

| Variable | Default | Purpose |
|---|---|---|
| `SPEACHES_URL` | `http://192.168.60.7:9900` | Base URL |
| `STT_MODEL` | `Systran/faster-whisper-large-v3` | STT model ID |
| `TTS_MODEL` | `speaches-ai/Kokoro-82M-v1.0-ONNX-fp16` | TTS model ID |
| `TTS_VOICE` | `af_heart` | Kokoro voice |
| `TTS_TEXT` | test sentence | TTS input text |
| `STT_TIMEOUT` | `3600` | Transcription timeout (s) |
| `MODEL_TIMEOUT` | `3600` | Model download timeout (s) |
| `CURL_TIMEOUT` | `120` | Other request timeout (s) |
| `STT_VAD_FILTER` | `false` | `vad_filter` sent for STT/translation tests |
| `SSH_HOST` | `athena` | Host for `--diag` |
| `SSH_IDENTITY` | `~/.ssh/athena_key` | Identity file for `--diag` |
| `CLIP_URL` | HF `1.flac` sample | Audio fixture URL |

Requires `curl`, `jq`, `ffprobe`, and (for `--diag`) SSH access to the Docker host.

## Troubleshooting

### `PermissionError: [Errno 13] Permission denied` on the HF cache

The container runs as uid `1000` (`ubuntu`). The host cache directory must be writable by that uid:

```bash
sudo mkdir -p "$INSTALL_DIR/hf-cache"
sudo chown -R 1000:1000 "$INSTALL_DIR/hf-cache"
```

### `404 Model '...' is not installed locally`

Expected on 0.8.3 until the model is downloaded — see [Models](#models). This is not an authentication problem; a HF token is only needed for rate limits or gated models (neither model here is gated).

### `--diag` SSH fails with `agent refused operation`

The `athena` SSH config uses a FIDO security key that fails without touch/agent support. The script works around this with `-o IdentityAgent=none -o IdentitiesOnly=yes -i "$SSH_IDENTITY"` (using the passphrase-protected `athena_key`); override `SSH_IDENTITY` if your key differs.
