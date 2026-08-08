"""
comfyui-inline-preview — preview images/video in the browser with zero files.

Results are encoded in-process and held in a byte-capped LRU dict. The node's
`ui` payload carries only an opaque id (~100 bytes), so prompt history and the
/history endpoint stay small; the browser fetches the actual bytes lazily from
/inline_preview?id=... exactly the way SaveImage's output is fetched from /view.

Nothing is ever written to disk, tmpfs, or anywhere else. ComfyUI never calls
open() for these results.

Store size:  INLINE_PREVIEW_MAX_MB     env var (default 2048)
Password:    INLINE_PREVIEW_TOKEN      env var. The gallery prompts for it and
             remembers the answer in a cookie. Unset = random per boot (logged
             at startup, so paste it once); empty = no password at all.
CORS:        INLINE_PREVIEW_ALLOW_ORIGIN  env var (default: same-origin only)
"""

import io
import os
import hmac
import time
import uuid
import asyncio
import logging
import secrets
import threading
from fractions import Fraction
from collections import OrderedDict

import numpy as np
from PIL import Image
from aiohttp import web
from server import PromptServer

log = logging.getLogger("inline_preview")

MAX_STORE_BYTES = int(os.environ.get("INLINE_PREVIEW_MAX_MB", "2048")) * 1024 * 1024

_env_token = os.environ.get("INLINE_PREVIEW_TOKEN")
TOKEN = secrets.token_urlsafe(16) if _env_token is None else _env_token

ALLOWED_ORIGIN = os.environ.get("INLINE_PREVIEW_ALLOW_ORIGIN", "")

COOKIE = "inline_preview_session"
COOKIE_MAX_AGE = 12 * 3600
_SESSION = secrets.token_urlsafe(24)
_fails = 0

_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/webp": ".webp",
    "video/mp4": ".mp4",
    "video/webm": ".webm",
}


class BlobStore:
    def __init__(self, max_bytes):
        self.max_bytes = max_bytes
        self._items = OrderedDict()
        self._bytes = 0
        self._lock = threading.Lock()

    def put(self, data, content_type, has_audio=False):
        key = uuid.uuid4().hex
        with self._lock:
            self._items[key] = (data, content_type, time.time(), has_audio)
            self._bytes += len(data)
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
                {"id": k, "type": v[1], "bytes": len(v[0]), "age": round(now - v[2], 1),
                 "audio": v[3]}
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
 label.tog{color:#888;font-size:12px;display:flex;align-items:center;gap:5px;
           cursor:pointer;user-select:none}
 #login{display:none;max-width:260px;margin:64px auto;text-align:center}
 #login p{color:#888;margin:0 0 12px}
 #login input{width:100%;box-sizing:border-box;background:#161616;color:#ddd;
   border:1px solid #333;border-radius:4px;padding:8px 10px;font:inherit}
 #login button{width:100%;margin-top:8px;padding:8px}
 #login .err{color:#c88;font-size:12px;min-height:18px;margin-top:8px}
 #tools{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
</style>
<header>
  <h1>inline preview &mdash; RAM store</h1>
  <div id="tools">
    <span class="meta" id="meta">loading...</span>
    <label class="tog"><input type="checkbox" id="blobmode" checked
      onchange="setBlobMode(this.checked)">keep in browser</label>
    <button onclick="load()">refresh</button>
    <button class="danger" onclick="wipe()">clear all</button>
  </div>
</header>
<div id="login">
  <p>This gallery is locked.</p>
  <input type="password" id="pw" placeholder="password" autocomplete="current-password">
  <button onclick="login()">unlock</button>
  <div class="err" id="pwerr"></div>
</div>
<div id="grid"></div>
<script>
const EXT = {'image/png':'.png','image/jpeg':'.jpg','image/webp':'.webp',
             'video/mp4':'.mp4','video/webm':'.webm'};
const human = b => { const u=['B','KB','MB','GB']; let i=0,n=b;
  while(n>=1024&&i<u.length-1){n/=1024;i++;} return n.toFixed(n<10&&i>0?1:0)+' '+u[i]; };
const ago = s => s<60?Math.round(s)+'s ago'
  : s<3600?Math.round(s/60)+'m ago' : (s/3600).toFixed(1)+'h ago';
const srcOf = it => '../inline_preview?id='+encodeURIComponent(it.id);
const TOK = new URLSearchParams(location.search).get('t') || '';
const tok = p => TOK ? p+(p.includes('?')?'&':'?')+'t='+encodeURIComponent(TOK) : p;

let blobMode = true;
const held = new Map();
let heldBytes = 0;
let listing = {items:[],bytes:0,max_bytes:0};
let io = null;

function revokeAll(){
  for(const u of held.values()) URL.revokeObjectURL(u);
  held.clear(); heldBytes = 0;
}

function updateMeta(){
  document.getElementById('meta').textContent =
    listing.items.length+' items \\u00b7 '+human(listing.bytes)+' / '
    +human(listing.max_bytes)
    +(blobMode && heldBytes ? ' \\u00b7 '+human(heldBytes)+' held in browser' : '');
}

function setBlobMode(on){ blobMode = on; revokeAll(); load(); }

function setLocked(on){
  document.getElementById('login').style.display = on ? 'block' : 'none';
  document.getElementById('tools').style.display = on ? 'none' : 'flex';
  if(on) document.getElementById('grid').replaceChildren();
}

function showLogin(msg){
  setLocked(true);
  document.getElementById('pwerr').textContent = msg;
  document.getElementById('pw').focus();
}

async function login(){
  const pw = document.getElementById('pw');
  document.getElementById('pwerr').textContent = 'checking...';
  let r;
  try{
    r = await fetch('login', {method:'POST', headers:{'Content-Type':'application/json'},
                              body: JSON.stringify({password: pw.value})});
  }catch(e){ showLogin('could not reach ComfyUI'); return; }
  if(!r.ok){ pw.select(); showLogin('wrong password'); return; }
  pw.value = '';
  setLocked(false);
  load();
}

document.getElementById('pw').addEventListener('keydown', e => {
  if(e.key === 'Enter') login();
});

async function hydrate(card, it){
  if(!blobMode || held.has(it.id)) return;
  try{
    const r = await fetch(srcOf(it), {cache:'no-store'});
    if(!r.ok) return;
    const b = await r.blob();
    if(!blobMode || !card.isConnected) return;
    const o = URL.createObjectURL(b);
    held.set(it.id, o); heldBytes += b.size;
    const m = card.querySelector('img,video'); if(m) m.src = o;
    const a = card.querySelector('a');         if(a) a.href = o;
    updateMeta();
  }catch(e){}
}

async function load(){
  const grid = document.getElementById('grid');
  if(io){ io.disconnect(); io = null; }

  let r;
  try { r = await fetch(tok('list'),{cache:'no-store'}); }
  catch(e){ grid.innerHTML='<div class="empty">could not reach ComfyUI</div>'; return; }
  if(r.status === 403){ showLogin(''); return; }
  setLocked(false);
  try { listing = await r.json(); }
  catch(e){ grid.innerHTML='<div class="empty">could not read the listing</div>'; return; }

  updateMeta();
  grid.replaceChildren();
  if(!listing.items.length){
    grid.innerHTML='<div class="empty">store is empty &mdash; queue a prompt</div>';
    return;
  }

  const owner = new Map();
  io = new IntersectionObserver(es => {
    for(const e of es) if(e.isIntersecting){
      io.unobserve(e.target);
      hydrate(e.target, owner.get(e.target));
    }
  }, {rootMargin:'300px'});

  for(const it of listing.items){
    const url = srcOf(it);
    const card = document.createElement('div');
    card.className = 'card';

    const media = document.createElement(it.type.startsWith('video/')?'video':'img');
    if(media.tagName === 'VIDEO'){
      media.controls = true; media.loop = true; media.muted = !it.audio;
      media.playsInline = true; media.preload = 'none';
    } else {
      media.loading = 'lazy';
    }
    if(!blobMode) media.src = url;

    const row = document.createElement('div');
    row.className = 'row';
    const span = document.createElement('span');
    span.textContent = human(it.bytes)+' \\u00b7 '+ago(it.age);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'preview-'+it.id.slice(0,8)+(EXT[it.type]||'');
    a.textContent = 'save';
    row.append(span, a);

    card.append(media, row);
    grid.appendChild(card);
    owner.set(card, it);
    if(blobMode) io.observe(card);
  }
}

async function wipe(){
  if(!confirm('Drop every preview held in RAM? This cannot be undone.')) return;
  await fetch(tok('clear'),{method:'POST'});
  revokeAll();
  load();
}

load();
</script>
"""


def _same_origin(request):
    """ComfyUI's --enable-cors-header stamps Access-Control-Allow-Origin on every
    response, which would let any page the browser happens to have open read
    these routes. Browsers send Origin only on cross-origin requests, so an
    absent Origin (curl, or the ComfyUI UI itself) passes; a mismatch does not."""
    origin = request.headers.get("Origin")
    if not origin or ALLOWED_ORIGIN == "*":
        return True
    if ALLOWED_ORIGIN and origin == ALLOWED_ORIGIN:
        return True
    return origin.split("://", 1)[-1] == request.headers.get("Host", "")


def _secret_eq(a, b):
    """compare_digest rejects non-ASCII str, and a password may well be."""
    return hmac.compare_digest(str(a).encode("utf-8"), str(b).encode("utf-8"))


def _guard(request, need_token=True):
    """-> a Response to return immediately, or None to carry on. Blob reads skip
    the password: the node's widget only ever knows the id, and a uuid4 is not
    enumerable without /list."""
    if not _same_origin(request):
        return web.Response(status=403, text="cross-origin request refused")
    if need_token and TOKEN:
        if _secret_eq(request.cookies.get(COOKIE, ""), _SESSION):
            return None
        got = (request.rel_url.query.get("t")
               or request.headers.get("X-Inline-Preview-Token", ""))
        if not _secret_eq(got, TOKEN):
            return web.Response(status=403, text="locked")
    return None


@PromptServer.instance.routes.post("/inline_preview/login")
async def _inline_preview_login(request):
    global _fails
    if not _same_origin(request):
        return web.Response(status=403, text="cross-origin request refused")
    if not TOKEN:
        return web.json_response({"ok": True})

    try:
        given = (await request.json()).get("password", "")
    except Exception:
        given = ""

    if not _secret_eq(given, TOKEN):
        _fails += 1
        # No rate limiter in front of this, so make guessing cost wall time.
        await asyncio.sleep(min(2.0, 0.25 * _fails))
        return web.json_response({"ok": False}, status=403)

    _fails = 0
    resp = web.json_response({"ok": True})
    # Path-scoped so it never rides along with the rest of ComfyUI's routes;
    # SameSite=Strict keeps it off cross-site requests even before _same_origin.
    resp.set_cookie(COOKIE, _SESSION, httponly=True, samesite="Strict",
                    path="/inline_preview", max_age=COOKIE_MAX_AGE)
    return resp


@PromptServer.instance.routes.get("/inline_preview")
async def _inline_preview(request):
    deny = _guard(request, need_token=False)
    if deny is not None:
        return deny
    key = request.rel_url.query.get("id", "")
    item = STORE.get(key)
    if item is None:
        return web.Response(status=404, text="expired: evicted from the RAM store")
    data, content_type = item[0], item[1]
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
    deny = _guard(request)
    if deny is not None:
        return deny
    return web.json_response(STORE.listing())


@PromptServer.instance.routes.get("/inline_preview/stats")
async def _inline_preview_stats(request):
    deny = _guard(request)
    if deny is not None:
        return deny
    return web.json_response(STORE.stats())


@PromptServer.instance.routes.post("/inline_preview/clear")
async def _inline_preview_clear(request):
    deny = _guard(request)
    if deny is not None:
        return deny
    STORE.clear()
    return web.json_response(STORE.stats())


@PromptServer.instance.routes.get("/inline_preview/gallery")
async def _inline_preview_gallery(request):
    # The page itself carries no data -- it asks for the password and then
    # fetches /list, which is where the check actually bites.
    deny = _guard(request, need_token=False)
    if deny is not None:
        return deny
    return web.Response(text=_GALLERY_HTML, content_type="text/html",
                        headers={"Cache-Control": "no-store"})


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
        import av
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


_AAC_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
              16000, 12000, 11025, 8000, 7350)

_AUDIO_CANDIDATES = {"mp4": ("aac",), "webm": ("libopus", "libvorbis")}


def _waveform(audio):
    """ComfyUI AUDIO -> (float32 [channels, samples], sample_rate, layout), or None."""
    wav = audio.get("waveform") if isinstance(audio, dict) else None
    if wav is None:
        return None
    if hasattr(wav, "cpu"):
        wav = wav.cpu().numpy()
    wav = np.asarray(wav, dtype=np.float32)

    if wav.ndim == 3:
        wav = wav[0]
    elif wav.ndim == 1:
        wav = wav[None, :]
    if wav.ndim != 2 or wav.shape[1] == 0:
        return None
    if wav.shape[0] > 2:
        wav = wav[:2]

    layout = "mono" if wav.shape[0] == 1 else "stereo"
    return np.ascontiguousarray(wav), int(audio["sample_rate"]), layout


def _add_audio_stream(container, container_fmt, sample_rate, layout):
    """Must run BEFORE the first mux(): the header carries the stream table, and
    PyAV refuses add_stream() once encoding has started."""
    import av

    for name in _AUDIO_CANDIDATES.get(container_fmt, ()):
        try:
            av.codec.Codec(name, "w")
        except Exception:
            continue
        rate = sample_rate
        if name == "libopus":
            rate = 48000
        elif name == "aac" and sample_rate not in _AAC_RATES:
            rate = 48000
        try:
            astream = container.add_stream(name, rate=rate)
            try:
                astream.codec_context.layout = layout
            except Exception:
                astream.layout = layout
            return astream
        except Exception as e:
            log.warning("inline_preview: audio encoder %s unusable: %s", name, e)
    return None


def _encode_audio(container, astream, wav, sample_rate, layout):
    """One frame in; PyAV's encoder resamples to the codec's format/rate and
    re-chunks to its frame_size on its own, provided pts is set."""
    import av

    frame = av.AudioFrame.from_ndarray(wav, format="fltp", layout=layout)
    frame.sample_rate = sample_rate
    frame.time_base = Fraction(1, sample_rate)
    frame.pts = 0

    for p in astream.encode(frame):
        container.mux(p)
    for p in astream.encode():
        container.mux(p)


def _encode_video(arr, fps, audio=None):
    """-> (bytes, mime, has_audio). has_audio is False whenever the clip came
    out silent, so the browser knows not to open it muted."""
    import av

    h, w = arr.shape[1], arr.shape[2]
    h -= h % 2
    w -= w % 2
    arr = arr[:, :h, :w, :]

    track = None
    if audio is not None:
        try:
            track = _waveform(audio)
        except Exception as e:
            log.warning("inline_preview: unreadable AUDIO input (%s) -- silent video", e)

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

            astream = None
            if track is not None:
                astream = _add_audio_stream(container, fmt, track[1], track[2])
                if astream is None:
                    log.warning("inline_preview: no audio encoder for .%s -- silent video", fmt)

            for f in arr:
                frame = av.VideoFrame.from_ndarray(f, format="rgb24")
                for p in stream.encode(frame):
                    container.mux(p)
            for p in stream.encode():
                container.mux(p)

            has_audio = False
            if astream is not None:
                try:
                    _encode_audio(container, astream, *track)
                    has_audio = True
                except Exception as e:
                    log.warning("inline_preview: audio encode failed (%s) -- silent video", e)

            container.close()
            return buf.getvalue(), mime, has_audio
        except Exception as e:
            last_err = e
            log.warning("inline_preview: encoder %s failed: %s", name, e)

    if last_err is not None:
        log.warning("inline_preview: all video encoders failed, using animated WebP")
    return None, None, False


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

        data, mime, has_audio = _encode_video(arr, rate, audio)
        if data is None:
            if audio is not None:
                log.warning("inline_preview: the animated-WebP fallback cannot carry audio")
            data, mime = _encode_animated_webp(arr, rate, quality)
            has_audio = False

        return {"ui": {"inline": [
            {"id": STORE.put(data, mime, has_audio), "type": mime, "bytes": len(data),
             "audio": has_audio, "frames": int(arr.shape[0]), "fps": round(rate, 3)}
        ]}}


if not TOKEN:
    log.warning("inline_preview: INLINE_PREVIEW_TOKEN is empty -- /inline_preview/list "
                "enumerates every preview id to anyone who reaches the port")
elif _env_token is None:
    # Nobody chose this one, so it has to be printed or it is unknowable.
    log.info("inline_preview: gallery locked with a random password: %s\n"
             "               open /inline_preview/gallery and paste it, or set "
             "INLINE_PREVIEW_TOKEN to pick your own", TOKEN)
else:
    log.info("inline_preview: gallery locked with INLINE_PREVIEW_TOKEN "
             "(not logged) -- open /inline_preview/gallery")

try:
    from . import history_redact
    history_redact.install()
except Exception as e:
    log.error("inline_preview: redaction could not be installed (%s). "
              "Prompts REMAIN readable via GET /history and GET /queue.", e)


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
