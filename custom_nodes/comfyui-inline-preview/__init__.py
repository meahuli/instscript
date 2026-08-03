"""
comfyui-inline-preview — preview images/video in the browser with zero files.

Results are encoded in-process and held in a byte-capped LRU dict. The node's
`ui` payload carries only an opaque id (~100 bytes), so prompt history and the
/history endpoint stay small; the browser fetches the actual bytes lazily from
/inline_preview?id=... exactly the way SaveImage's output is fetched from /view.

Nothing is ever written to disk, tmpfs, or anywhere else. ComfyUI never calls
open() for these results.

Store size: INLINE_PREVIEW_MAX_MB env var (default 2048).
"""

import io
import os
import time
import uuid
import logging
import threading
from fractions import Fraction
from collections import OrderedDict

import numpy as np
from PIL import Image
from aiohttp import web
from server import PromptServer

log = logging.getLogger("inline_preview")

MAX_STORE_BYTES = int(os.environ.get("INLINE_PREVIEW_MAX_MB", "2048")) * 1024 * 1024

_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/webp": ".webp",
    "video/mp4": ".mp4",
    "video/webm": ".webm",
}


# --------------------------------------------------------------------------
# Bounded in-RAM blob store. Evicts oldest by total byte count, not entry
# count -- the thing PromptQueue.history gets wrong for large payloads.
# --------------------------------------------------------------------------
class BlobStore:
    def __init__(self, max_bytes):
        self.max_bytes = max_bytes
        self._items = OrderedDict()  # id -> (bytes, content_type, created_wall)
        self._bytes = 0
        self._lock = threading.Lock()

    def put(self, data, content_type):
        key = uuid.uuid4().hex
        with self._lock:
            self._items[key] = (data, content_type, time.time())
            self._bytes += len(data)
            # keep at least one entry so a single oversized result still shows
            while self._bytes > self.max_bytes and len(self._items) > 1:
                _, evicted = self._items.popitem(last=False)
                self._bytes -= len(evicted[0])
        return key

    def get(self, key):
        with self._lock:
            item = self._items.get(key)
            if item is not None:
                self._items.move_to_end(key)
            return item

    def listing(self):
        """Newest first. The store is the source of truth -- unlike prompt
        history, which keeps ids long after their bytes have been evicted."""
        now = time.time()
        with self._lock:
            items = [
                {"id": k, "type": v[1], "bytes": len(v[0]), "age": round(now - v[2], 1)}
                for k, v in self._items.items()
            ]
        items.reverse()
        return {"items": items, "bytes": self._bytes, "max_bytes": self.max_bytes}

    def stats(self):
        with self._lock:
            return {
                "entries": len(self._items),
                "bytes": self._bytes,
                "max_bytes": self.max_bytes,
            }

    def clear(self):
        with self._lock:
            self._items.clear()
            self._bytes = 0


STORE = BlobStore(MAX_STORE_BYTES)


# All URLs below are relative to /inline_preview/ so the page works unchanged
# behind a proxied path prefix (RunPod) as well as on a bare localhost tunnel.
_GALLERY_HTML = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>inline preview - RAM store</title>
<style>
 :root{color-scheme:dark}
 body{margin:0;padding:16px;background:#0d0d0d;color:#ddd;
      font:13px/1.5 system-ui,sans-serif}
 h1{font-size:15px;font-weight:600;margin:0}
 header{display:flex;flex-wrap:wrap;gap:12px;align-items:center;
        justify-content:space-between;margin-bottom:14px}
 .meta{color:#888;font-size:12px}
 button{background:#1e1e1e;color:#ddd;border:1px solid #333;border-radius:4px;
        padding:5px 11px;font:inherit;cursor:pointer}
 button:hover{background:#2a2a2a}
 button.danger:hover{background:#5a2020;border-color:#7a3030}
 #grid{display:grid;gap:12px;
       grid-template-columns:repeat(auto-fill,minmax(240px,1fr))}
 .card{background:#161616;border:1px solid #262626;border-radius:6px;
       overflow:hidden;display:flex;flex-direction:column}
 .card img,.card video{width:100%;aspect-ratio:1;object-fit:contain;
                       background:#000;display:block}
 .row{display:flex;justify-content:space-between;align-items:center;
      gap:8px;padding:7px 9px;font-size:11px;color:#8a8a8a}
 .row a{color:#7db3e8;text-decoration:none}
 .row a:hover{text-decoration:underline}
 .empty{color:#666;padding:32px 0;text-align:center}
</style>
<header>
  <h1>inline preview &mdash; RAM store</h1>
  <div style="display:flex;gap:8px;align-items:center">
    <span class="meta" id="meta">loading...</span>
    <button onclick="load()">refresh</button>
    <button class="danger" onclick="wipe()">clear all</button>
  </div>
</header>
<div id="grid"></div>
<script>
const human = b => { const u=['B','KB','MB','GB']; let i=0,n=b;
  while(n>=1024&&i<u.length-1){n/=1024;i++;} return n.toFixed(n<10&&i>0?1:0)+' '+u[i]; };
const ago = s => s<60?Math.round(s)+'s ago'
  : s<3600?Math.round(s/60)+'m ago' : (s/3600).toFixed(1)+'h ago';

async function load(){
  const grid = document.getElementById('grid');
  let d;
  try { d = await (await fetch('list',{cache:'no-store'})).json(); }
  catch(e){ grid.innerHTML='<div class="empty">could not reach ComfyUI</div>'; return; }

  document.getElementById('meta').textContent =
    d.items.length+' items \\u00b7 '+human(d.bytes)+' / '+human(d.max_bytes);

  grid.replaceChildren();
  if(!d.items.length){
    grid.innerHTML='<div class="empty">store is empty &mdash; queue a prompt</div>';
    return;
  }
  for(const it of d.items){
    const url = '../inline_preview?id='+encodeURIComponent(it.id);
    const card = document.createElement('div');
    card.className='card';
    // preload="none" so opening the gallery does not pull every clip at once
    card.innerHTML = (it.type.startsWith('video/')
        ? '<video src="'+url+'" controls loop muted playsinline preload="none"></video>'
        : '<img src="'+url+'" loading="lazy">')
      + '<div class="row"><span>'+human(it.bytes)+' \\u00b7 '+ago(it.age)+'</span>'
      + '<a href="'+url+'" download="preview-'+it.id.slice(0,8)+'">save</a></div>';
    grid.appendChild(card);
  }
}

async function wipe(){
  if(!confirm('Drop every preview held in RAM? This cannot be undone.')) return;
  await fetch('clear',{method:'POST'});
  load();
}

load();
</script>
"""


# --------------------------------------------------------------------------
# HTTP routes
# --------------------------------------------------------------------------
@PromptServer.instance.routes.get("/inline_preview")
async def _inline_preview(request):
    key = request.rel_url.query.get("id", "")
    item = STORE.get(key)
    if item is None:
        return web.Response(status=404, text="expired: evicted from the RAM store")
    data, content_type, _created = item
    return web.Response(
        body=data,
        content_type=content_type,
        headers={
            "Cache-Control": "no-store",
            "Content-Disposition": 'inline; filename="preview-%s%s"'
            % (key[:8], _EXT.get(content_type, "")),
        },
    )


@PromptServer.instance.routes.get("/inline_preview/list")
async def _inline_preview_list(request):
    return web.json_response(STORE.listing())


@PromptServer.instance.routes.get("/inline_preview/stats")
async def _inline_preview_stats(request):
    return web.json_response(STORE.stats())


@PromptServer.instance.routes.post("/inline_preview/clear")
async def _inline_preview_clear(request):
    STORE.clear()
    return web.json_response(STORE.stats())


@PromptServer.instance.routes.get("/inline_preview/gallery")
async def _inline_preview_gallery(request):
    return web.Response(text=_GALLERY_HTML, content_type="text/html",
                        headers={"Cache-Control": "no-store"})


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def _to_uint8(images):
    """IMAGE tensor [B,H,W,C] float 0..1 -> uint8 ndarray."""
    arr = images.cpu().numpy()
    return np.clip(arr * 255.0, 0, 255).astype(np.uint8)


def _encode_still(arr_hwc, fmt, quality):
    pil = Image.fromarray(arr_hwc)
    buf = io.BytesIO()
    if fmt == "png":
        pil.save(buf, format="PNG", compress_level=4)
        return buf.getvalue(), "image/png"
    if fmt == "jpeg":
        pil.convert("RGB").save(buf, format="JPEG", quality=quality)
        return buf.getvalue(), "image/jpeg"
    pil.save(buf, format="WEBP", quality=quality, method=4)
    return buf.getvalue(), "image/webp"


# (av codec, container, mime, pix_fmt, encoder options)
_VIDEO_CANDIDATES = [
    ("libx264", "mp4", "video/mp4", "yuv420p", {"crf": "20", "preset": "veryfast"}),
    ("libvpx-vp9", "webm", "video/webm", "yuv420p",
     {"crf": "32", "b:v": "0", "deadline": "realtime", "cpu-used": "5"}),
    ("libvpx", "webm", "video/webm", "yuv420p", {"crf": "10", "b:v": "1M"}),
]

_codec_cache = None


def _available_video_codecs():
    """PyAV wheels vary in which encoders they bundle -- probe, don't assume."""
    global _codec_cache
    if _codec_cache is not None:
        return _codec_cache
    try:
        import av  # noqa: F401
    except ImportError:
        _codec_cache = []
        return _codec_cache
    import av
    ok = []
    for spec in _VIDEO_CANDIDATES:
        try:
            av.codec.Codec(spec[0], "w")
            ok.append(spec)
        except Exception:
            pass
    _codec_cache = ok
    log.info("inline_preview: video encoders available: %s",
             [c[0] for c in ok] or "none (falling back to animated WebP)")
    return ok


def _mux_audio(container, audio, container_fmt):
    """Best-effort. Any PyAV quirk here degrades to a silent video."""
    import av

    wav = audio["waveform"]
    sr = int(audio["sample_rate"])
    w = wav[0].cpu().numpy().astype(np.float32)  # [C, N]
    if w.shape[0] > 2:
        w = w[:2]
    channels = w.shape[0]
    layout = "mono" if channels == 1 else "stereo"

    codec = "libopus" if container_fmt == "webm" else "aac"
    out_sr = 48000 if codec == "libopus" else sr
    astream = container.add_stream(codec, rate=out_sr)

    frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(w), format="fltp", layout=layout)
    frame.sample_rate = sr
    frame.time_base = Fraction(1, sr)

    resampler = av.audio.resampler.AudioResampler(format="fltp", layout=layout, rate=out_sr)
    fifo = av.audio.fifo.AudioFifo()
    for rf in resampler.resample(frame):
        if rf is not None:
            fifo.write(rf)

    # encoders want an exact frame_size; opus sometimes reports 0
    fsize = getattr(astream, "frame_size", 0) or 960
    while True:
        chunk = fifo.read(fsize)
        if chunk is None:
            break
        for p in astream.encode(chunk):
            container.mux(p)
    tail = fifo.read()
    if tail is not None:
        for p in astream.encode(tail):
            container.mux(p)
    for p in astream.encode():
        container.mux(p)


def _encode_video(arr, fps, audio=None):
    import av

    # yuv420p needs even dimensions
    h, w = arr.shape[1], arr.shape[2]
    h -= h % 2
    w -= w % 2
    arr = arr[:, :h, :w, :]

    rate = Fraction(fps).limit_denominator(1000)
    last_err = None
    for name, fmt, mime, pix_fmt, opts in _available_video_codecs():
        try:
            buf = io.BytesIO()
            container = av.open(buf, mode="w", format=fmt)
            stream = container.add_stream(name, rate=rate)
            stream.width = w
            stream.height = h
            stream.pix_fmt = pix_fmt
            stream.options = opts

            for f in arr:
                frame = av.VideoFrame.from_ndarray(f, format="rgb24")
                for p in stream.encode(frame):
                    container.mux(p)
            for p in stream.encode():
                container.mux(p)

            if audio is not None:
                try:
                    _mux_audio(container, audio, fmt)
                except Exception as e:
                    log.warning("inline_preview: audio mux failed (%s) -- silent video", e)

            container.close()
            return buf.getvalue(), mime
        except Exception as e:
            last_err = e
            log.warning("inline_preview: encoder %s failed: %s", name, e)

    if last_err is not None:
        log.warning("inline_preview: all video encoders failed, using animated WebP")
    return None, None


def _encode_animated_webp(arr, fps, quality):
    pils = [Image.fromarray(f) for f in arr]
    buf = io.BytesIO()
    pils[0].save(
        buf,
        format="WEBP",
        save_all=True,
        append_images=pils[1:],
        duration=max(1, int(round(1000.0 / max(fps, 0.1)))),
        loop=0,
        quality=quality,
        method=4,
    )
    return buf.getvalue(), "image/webp"


# --------------------------------------------------------------------------
# nodes
# --------------------------------------------------------------------------
class PreviewImageInline:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images": ("IMAGE",),
                "format": (["webp", "png", "jpeg"], {"default": "webp"}),
                "quality": ("INT", {"default": 92, "min": 1, "max": 100}),
            },
        }

    RETURN_TYPES = ()
    FUNCTION = "preview"
    OUTPUT_NODE = True
    CATEGORY = "image"
    DESCRIPTION = "Preview images in the browser without writing any file."

    @classmethod
    def IS_CHANGED(cls, *args, **kwargs):
        # Force re-execution so a cached run never replays an id the store has
        # already evicted. Upstream nodes stay cached, so this is cheap.
        return float("nan")

    def preview(self, images, format="webp", quality=92):
        out = []
        for frame in _to_uint8(images):
            data, mime = _encode_still(frame, format, quality)
            out.append({"id": STORE.put(data, mime), "type": mime, "bytes": len(data)})
        return {"ui": {"inline": out}}


class PreviewVideoInline:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "fps": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 240.0, "step": 0.1,
                                  "tooltip": "0 = use the VIDEO input's own frame rate "
                                             "(or 16 for a bare IMAGE batch)."}),
                "quality": ("INT", {"default": 85, "min": 1, "max": 100,
                                    "tooltip": "Only used by the animated-WebP fallback."}),
            },
            "optional": {
                "video": ("VIDEO",),
                "images": ("IMAGE",),
                "audio": ("AUDIO",),
            },
        }

    RETURN_TYPES = ()
    FUNCTION = "preview"
    OUTPUT_NODE = True
    CATEGORY = "image/video"
    DESCRIPTION = ("Preview video in the browser without writing any file. Takes either a "
                   "VIDEO (drop-in for SaveVideo) or a raw IMAGE frame batch.")

    @classmethod
    def IS_CHANGED(cls, *args, **kwargs):
        return float("nan")

    def preview(self, fps=0.0, quality=85, video=None, images=None, audio=None):
        src_fps = None

        if video is not None:
            # Re-encode from components rather than VideoInput.save_to(), which
            # only takes a filesystem path -- that would defeat the whole point.
            comps = video.get_components()
            images = comps.images
            if audio is None:
                audio = getattr(comps, "audio", None)
            if getattr(comps, "frame_rate", None):
                src_fps = float(comps.frame_rate)

        if images is None:
            raise ValueError("PreviewVideoInline: connect either 'video' or 'images'.")

        rate = fps if fps and fps > 0 else (src_fps or 16.0)

        arr = _to_uint8(images)
        if arr.shape[0] == 0:
            return {"ui": {"inline": []}}

        data, mime = _encode_video(arr, rate, audio)
        if data is None:
            data, mime = _encode_animated_webp(arr, rate, quality)

        return {"ui": {"inline": [
            {"id": STORE.put(data, mime), "type": mime, "bytes": len(data),
             "frames": int(arr.shape[0]), "fps": round(rate, 3)}
        ]}}


try:
    from . import history_redact
    history_redact.install()
except Exception as e:  # never let this take the nodes down with it
    log.error("inline_preview: history redaction could not be installed (%s). "
              "Prompts REMAIN readable via GET /history.", e)


NODE_CLASS_MAPPINGS = {
    "PreviewImageInline": PreviewImageInline,
    "PreviewVideoInline": PreviewVideoInline,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "PreviewImageInline": "Preview Image (RAM, no file)",
    "PreviewVideoInline": "Preview Video (RAM, no file)",
}

WEB_DIRECTORY = "./js"

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
