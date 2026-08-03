# comfyui-inline-preview

Two output nodes that show results in the ComfyUI browser **without writing a
file anywhere** — not to the volume, not to the container disk, not to tmpfs.

- **Preview Image (RAM, no file)** — `PreviewImageInline`
- **Preview Video (RAM, no file)** — `PreviewVideoInline`

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
| `GET /inline_preview/stats` | `{entries, bytes, max_bytes}` |
| `POST /inline_preview/clear` | drop everything |

A node whose blob has been evicted shows "preview expired" instead of a broken
image. Re-queue to regenerate.

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
