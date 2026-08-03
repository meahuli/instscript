# comfyui-inline-preview

Two output nodes that show results in the ComfyUI browser **without writing a
file anywhere** — not to the volume, not to the container disk, not to tmpfs.

- **Preview Image (RAM, no file)** — `PreviewImageInline`, takes `IMAGE`
- **Preview Video (RAM, no file)** — `PreviewVideoInline`, takes `VIDEO` *or* `IMAGE`

`PreviewVideoInline` is a drop-in for `SaveVideo`: connect the `VIDEO` from
`CreateVideo` (as in `LTX-2.3_T2V_I2V_Two_Stage_NonDistilledStage1.json`) and it
pulls frames, audio and frame rate off the video via `get_components()`, then
re-encodes in memory. It deliberately avoids `VideoInput.save_to()`, which only
accepts a filesystem path.

Alternatively feed a raw `IMAGE` batch straight off `VAEDecode` — useful for
Hunyuan/Wan/LTX graphs where you want to look at frames before they're muxed.
Leave `fps` at `0` to inherit the source frame rate (16 for a bare `IMAGE`
batch), or set it to override.

## Why not just base64 into the `ui` payload

Because anything returned under a node's `ui` key is retained in three places:
`PromptQueue.history` (capped by *entry count*, not bytes), the execution UI
cache, and the `executed` websocket message — and `GET /history` re-serialises
all of it on every page load.

So these nodes return only an opaque id (~100 bytes) and keep the actual bytes
in a byte-capped LRU dict inside the ComfyUI process. The browser fetches them
lazily from `/inline_preview?id=...`. That's exactly `SaveImage`'s architecture
with a dict where the filesystem was.

## Store

Byte-capped LRU, oldest evicted first. Default 2 GiB:

```bash
INLINE_PREVIEW_MAX_MB=4096
```

| route | purpose |
|---|---|
| `GET /inline_preview?id=` | the bytes (404 once evicted) |
| `GET /inline_preview/gallery` | browse everything still in RAM |
| `GET /inline_preview/list` | `{items:[{id,type,bytes,age}], bytes, max_bytes}` |
| `GET /inline_preview/stats` | `{entries, bytes, max_bytes}` |
| `POST /inline_preview/clear` | drop everything |

A node whose blob has been evicted shows "preview expired" instead of a broken
image. Re-queue to regenerate.

## Browsing past generations

A node only ever shows its latest result, and the frontend's queue sidebar
ignores these nodes entirely — it renders `ui.images` entries fetched from
`/view`, and this emits a custom `ui.inline` key it doesn't understand.

So open **`/inline_preview/gallery`** in a tab. It lists everything currently in
the store, newest first, with sizes, ages and download links. It reads the store
directly rather than prompt history, so it can't offer you an id whose bytes are
already gone — and it keeps working after you wipe history.

Videos there use `preload="none"`, so opening the page doesn't pull every clip.

## History redaction

`PromptQueue.task_done()` stores the whole queue tuple, so ComfyUI's in-RAM
history holds the API graph (every widget value, prompt text included) and
`extra_data.extra_pnginfo.workflow`. `GET /history` serves all of it with no
auth. **`--disable-metadata` does not cover this** — that flag only governs what
gets embedded into saved image files.

`history_redact.py` wraps `task_done` and blanks those two slots, leaving
`outputs` intact so blob ids stay reachable. Disable with:

```bash
INLINE_PREVIEW_REDACT_HISTORY=0
```

It patches ComfyUI internals, so it is version-fragile by construction. It is
written to fail *loudly*: the parameter list of `task_done` is checked before
patching, the blanking is verified against the stored record rather than a local
copy, and any mismatch logs `PROMPTS ARE BEING STORED IN /history` and leaves
history alone. Confirm which state you're in:

```bash
grep 'inline_preview: history redaction' /workspace/runpod-slim/ComfyUI/comfyui.log
```

Redaction applies going forward only. Anything queued before the node loaded is
still in history — clear it once with:

```bash
curl -X POST localhost:8188/history -H 'Content-Type: application/json' -d '{"clear":true}'
```

## Video encoding

Encoded in memory via PyAV (already a ComfyUI dependency) straight into a
`BytesIO`. PyAV wheels differ in which encoders they bundle, so the node probes
at runtime and takes the first that works:

`libx264`/mp4 → `libvpx-vp9`/webm → `libvpx`/webm → animated WebP via PIL

The WebP fallback needs no codecs at all, so the node always produces something
playable. Check which one you got:

```bash
grep inline_preview /workspace/runpod-slim/ComfyUI/comfyui.log
```

Optional `audio` input is muxed when present (opus for webm, aac for mp4). It's
best-effort — any PyAV quirk degrades to a silent video rather than failing the
run.

## Notes

- `IS_CHANGED` returns `NaN`, so these nodes re-execute every queue. That
  prevents a cached run from replaying an id the store has already evicted.
  Upstream nodes stay cached, so only the encode repeats. Delete the
  `IS_CHANGED` methods if you'd rather have caching and accept stale ids.
- The DOM widget is `serialize: false`, so nothing lands in saved workflows.
- The store lives in the ComfyUI process. Restarting ComfyUI clears it.
- `/inline_preview` serves whole responses without Range support. Fine for
  playback from RAM; seeking in long videos will be less smooth than a file.
