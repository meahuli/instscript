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
Key TTL:     INLINE_PREVIEW_KEY_TTL    seconds the pod may sit IDLE -- queue
             drained -- before the browser's encryption key is scrubbed
             (default 300, 0 = never). It does not have to cover how long a
             generation takes: the key is held while there is work in flight,
             and the browser re-posts it on the way into every queue. Lower is
             tighter; 60 is reasonable.
"""

import io
import os
import hmac
import time
import uuid
import base64
import asyncio
import hashlib
import logging
import secrets
import threading
from fractions import Fraction
from collections import OrderedDict

import numpy as np
from PIL import Image, ImageOps
from aiohttp import web
from server import PromptServer

log = logging.getLogger("inline_preview")

MAX_STORE_BYTES = int(os.environ.get("INLINE_PREVIEW_MAX_MB", "2048")) * 1024 * 1024

_env_token = os.environ.get("INLINE_PREVIEW_TOKEN")
if _env_token is not None:
    # Both of these present as "wrong password" and are invisible from the
    # browser: template UIs leave trailing newlines, and a value typed with
    # quotes arrives with the quotes as part of the string.
    if _env_token != _env_token.strip():
        log.warning("inline_preview: stripped surrounding whitespace from INLINE_PREVIEW_TOKEN")
        _env_token = _env_token.strip()
    if len(_env_token) > 1 and _env_token[0] == _env_token[-1] and _env_token[0] in "\"'":
        log.warning("inline_preview: INLINE_PREVIEW_TOKEN begins and ends with %s -- those "
                    "quotes ARE part of the password. Set it unquoted if that was not intended.",
                    _env_token[0])
TOKEN = secrets.token_urlsafe(16) if _env_token is None else _env_token

ALLOWED_ORIGIN = os.environ.get("INLINE_PREVIEW_ALLOW_ORIGIN", "")

COOKIE = "inline_preview_auth"
COOKIE_MAX_AGE = 12 * 3600
_SESSION = secrets.token_urlsafe(24)
_fails = 0

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    AESGCM = None

# Posted over an authenticated route, never served back, never written anywhere,
# and dropped once the pod goes idle -- the browser re-posts before each queue.
# No key -> blobs are stored as-is and the password is the only thing in front.
KEY_TTL = int(os.environ.get("INLINE_PREVIEW_KEY_TTL", "300"))

_session_key = None      # bytearray, so the long-lived copy can be overwritten
_session_kid = ""
_key_touched = 0.0
_key_lock = threading.Lock()


def _kid(key):
    return hashlib.sha256(bytes(key)).hexdigest()[:16]


def _zero_locked():
    """Caller holds _key_lock. Only scrubs the copy we own -- the transient
    bytes handed to OpenSSL, and whatever the JSON parser made of the request
    body, are immutable and left to the GC. Nothing here is mlock'd either."""
    global _session_key, _session_kid
    if _session_key is not None:
        for i in range(len(_session_key)):
            _session_key[i] = 0
    _session_key = None
    _session_kid = ""


def forget_key(why):
    with _key_lock:
        had = _session_key is not None
        _zero_locked()
    if had:
        log.info("inline_preview: session key forgotten (%s)", why)


def _queue_busy():
    """The preview node encrypts at the very end of a graph, so a generation
    longer than the TTL would otherwise find the key already scrubbed and store
    plaintext. While ComfyUI still has work in flight, the pod is not idle."""
    try:
        return PromptServer.instance.prompt_queue.get_tasks_remaining() > 0
    except Exception:
        return True   # unsure -> keep the key rather than silently drop to plaintext


def _live_key():
    """None once the pod has been idle past the TTL, so a pod nobody is using
    holds no key at all."""
    with _key_lock:
        if _session_key is None:
            return None
        live = (bytes(_session_key), _session_kid)
        stale = bool(KEY_TTL) and time.time() - _key_touched > KEY_TTL
    if not stale:
        return live
    # Lock released before touching the queue -- never hold two at once.
    if _queue_busy():
        return live
    with _key_lock:
        if _session_key is None:
            return None
        _zero_locked()
    log.info("inline_preview: session key scrubbed after %ds idle", KEY_TTL)
    return None


def _key_sweeper():
    """_live_key() only runs when something encrypts, so on its own the key
    would sit in RAM untouched for exactly as long as the pod is idle -- which
    is the case the TTL exists for. This is what actually scrubs it."""
    interval = max(5, min(30, KEY_TTL // 2))
    while True:
        time.sleep(interval)
        try:
            with _key_lock:
                idle = _session_key is not None and time.time() - _key_touched > KEY_TTL
            if idle and not _queue_busy():
                forget_key("idle %ds" % KEY_TTL)
        except Exception:
            pass


def _decrypt_input(blob, kid):
    """Inputs must come back in the clear HERE, not in the browser, because the
    graph needs a tensor. The browser re-posts its key on execution_start and
    _queue_busy() holds it for the run, so the key is present exactly when this
    needs it -- but say plainly what to do when it is not."""
    if not kid:
        return blob
    live = _live_key()
    if live is None:
        raise ValueError(
            "LoadImageInline: this image is encrypted and no session key is loaded. "
            "Open ComfyUI in the browser that uploaded it and queue again -- it "
            "hands the key over on every run.")
    key, current = live
    if current != kid:
        raise ValueError(
            "LoadImageInline: this image was encrypted with a different key (%s, "
            "loaded %s). Whichever browser uploaded it must be the one that queues, "
            "or re-upload it here." % (kid[:8], current[:8]))
    try:
        return AESGCM(key).decrypt(bytes(blob[:12]), bytes(blob[12:]), None)
    except Exception as e:
        raise ValueError("LoadImageInline: could not decrypt the stored image (%s)." % e)


class LoadImageInline:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image_id": ("STRING", {"default": "", "multiline": False,
                                        "tooltip": "Filled in by the upload button. "
                                                   "Points at bytes held in RAM."}),
            },
        }

    RETURN_TYPES = ("IMAGE", "MASK")
    RETURN_NAMES = ("image", "mask")
    FUNCTION = "load"
    CATEGORY = "image"
    DESCRIPTION = ("Load an image the browser uploaded straight into RAM. Nothing is "
                   "written to the input directory, so it is not served by /view and "
                   "its name never appears in /object_info.")

    @classmethod
    def IS_CHANGED(cls, image_id="", **kwargs):
        # The id identifies the bytes, so this is a correct cache key -- unlike the
        # preview nodes, which must re-run every time.
        return image_id

    @classmethod
    def VALIDATE_INPUTS(cls, image_id=""):
        return True if image_id else "LoadImageInline: no image uploaded yet."

    def load(self, image_id=""):
        import torch

        item = INPUTS.get(image_id)
        if item is None:
            raise ValueError(
                "LoadImageInline: that image is no longer in the RAM store. It is "
                "held in memory only, so a ComfyUI restart or an eviction loses it "
                "-- re-upload it on the node.")

        data = _decrypt_input(item[0], item[4])
        try:
            img = ImageOps.exif_transpose(Image.open(io.BytesIO(data)))
        except Exception as e:
            raise ValueError("LoadImageInline: the stored bytes are not a readable "
                             "image (%s)." % e)
        arr = np.array(img.convert("RGB")).astype(np.float32) / 255.0
        image = torch.from_numpy(arr)[None, ]

        if "A" in img.getbands():
            alpha = np.array(img.getchannel("A")).astype(np.float32) / 255.0
            mask = 1.0 - torch.from_numpy(alpha)
        else:
            mask = torch.zeros((64, 64), dtype=torch.float32)
        return (image, mask.unsqueeze(0))


_warned = set()


def _warn_once(tag, msg):
    if tag not in _warned:
        _warned.add(tag)
        log.warning(msg)


def _encrypt(data):
    """-> (blob, kid). AES-GCM with a fresh 96-bit nonce per blob, prepended.
    Distinct nonces under one key are what keeps GCM safe across many blobs."""
    global _key_touched
    if AESGCM is None:
        _warn_once("nocrypto",
                   "inline_preview: cryptography is not installed, so previews are stored "
                   "UNENCRYPTED (the password still gates them). Re-run provision.sh, or "
                   "pip install cryptography, and restart.")
        return data, ""
    live = _live_key()
    if live is None:
        _warn_once("nokey",
                   "inline_preview: no session key has been posted, so previews are stored "
                   "UNENCRYPTED (the password still gates them). Unlock the gallery once in "
                   "the browser running ComfyUI -- POST /inline_preview/key needs the password, "
                   "so a locked tab cannot hand its key over.")
        return data, ""
    key, kid = live
    with _key_lock:
        _key_touched = time.time()
    nonce = os.urandom(12)
    return nonce + AESGCM(key).encrypt(nonce, data, None), kid

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
        self._seq = 0
        self._lock = threading.Lock()

    def put(self, data, content_type, has_audio=False, kid=""):
        key = uuid.uuid4().hex
        with self._lock:
            self._seq += 1
            self._items[key] = (data, content_type, time.time(), has_audio, kid, self._seq)
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

    def remove(self, key):
        with self._lock:
            item = self._items.pop(key, None)
            if item is None:
                return False
            self._bytes -= len(item[0])
            return True

    def listing(self):
        """Newest first. The store is the source of truth -- unlike prompt
        history, which keeps ids long after their bytes have been evicted.

        Sorted on the put sequence, NOT on dict order: get() moves entries to
        the end to drive LRU eviction, so dict order is most-recently-viewed,
        and reading the gallery would shuffle itself. Not on the timestamp
        either -- wall clock ties within a batch, and NTP can step it back."""
        now = time.time()
        with self._lock:
            rows = sorted(self._items.items(), key=lambda kv: kv[1][5], reverse=True)
            items = [
                {"id": k, "type": v[1], "bytes": len(v[0]), "age": round(now - v[2], 1),
                 "audio": v[3], "kid": v[4]}
                for k, v in rows
            ]
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

# Uploads live here instead of the input directory. Kept separate from STORE so
# a busy generation session cannot evict the image a workflow still depends on.
INPUT_MAX_BYTES = int(os.environ.get("INLINE_INPUT_MAX_MB", "512")) * 1024 * 1024
INPUTS = BlobStore(INPUT_MAX_BYTES)


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
       overflow:hidden;display:flex;flex-direction:column;position:relative}
 .del{position:absolute;right:6px;top:6px;width:22px;height:22px;border-radius:4px;
      background:rgba(0,0,0,.6);color:#bbb;border:1px solid #333;cursor:pointer;
      font:13px/1 sans-serif;display:flex;align-items:center;justify-content:center;
      padding:0;opacity:0;transition:opacity .12s}
 .card:hover .del,.del:focus{opacity:1}
 .del:hover{background:#5a2020;border-color:#7a3030;color:#fff}
 @media (hover:none){.del{opacity:1}}
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
const srcOf = it => tok('../inline_preview?id='+encodeURIComponent(it.id));
const TOK = new URLSearchParams(location.search).get('t') || '';
const tok = p => TOK ? p+(p.includes('?')?'&':'?')+'t='+encodeURIComponent(TOK) : p;

// Same origin as the ComfyUI tab, so this is the very same key it generated.
const KEY_ITEM = 'inline_preview_session_key';
const b64 = b => btoa(String.fromCharCode(...new Uint8Array(b)));
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
let keyBytes = null, keyPublished = false;

function sessionKey(){
  if(keyBytes) return keyBytes;
  if(!globalThis.crypto?.subtle) return null;
  let s = localStorage.getItem(KEY_ITEM);
  if(!s){ s = b64(crypto.getRandomValues(new Uint8Array(32)));
          localStorage.setItem(KEY_ITEM, s); }
  keyBytes = unb64(s);
  return keyBytes;
}

async function kidOf(raw){
  const h = await crypto.subtle.digest('SHA-256', raw);
  return [...new Uint8Array(h)].map(b=>b.toString(16).padStart(2,'0')).join('').slice(0,16);
}

async function publishKey(){
  if(keyPublished) return;
  const raw = sessionKey();
  if(!raw) return;
  try{
    const r = await fetch(tok('key'), {method:'POST',
      headers:{'Content-Type':'application/json'}, body: JSON.stringify({key: b64(raw)})});
    keyPublished = r.ok;
  }catch(e){}
}

async function decryptBlob(buf, it){
  if(!it.kid) return buf;
  const raw = sessionKey();
  if(!raw) throw new Error('nokey');
  if(await kidOf(raw) !== it.kid) throw new Error('otherkey');
  const ck = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt']);
  return crypto.subtle.decrypt({name:'AES-GCM', iv: buf.slice(0,12)}, ck, buf.slice(12));
}

let blobMode = true;
const held = new Map();
let heldBytes = 0;
let listing = {items:[],bytes:0,max_bytes:0};
let io = null;

function revokeAll(){
  for(const h of held.values()) URL.revokeObjectURL(h.url);
  held.clear(); heldBytes = 0;
}

async function drop(it, card){
  if(!confirm('Delete this preview? It only exists in RAM, so it cannot be recovered.'))
    return;
  const fail = msg => {
    const s = card.querySelector('.row span');
    if(s) s.textContent = msg;          // leave the card: it is still on the server
  };

  let r, d = null;
  try{ r = await fetch(tok('delete?id='+encodeURIComponent(it.id)), {method:'POST'}); }
  catch(e){ fail('delete failed: could not reach ComfyUI'); return; }
  if(r.status === 403){ showLogin('session expired'); return; }
  try{ d = await r.json(); }catch(e){}

  // Our handler always answers with JSON carrying "ok", so a 404 WITH that body
  // means the blob was already gone and the caller got what it wanted. A bare
  // 404 means the route is not registered -- an older node still running -- and
  // dropping the card there would claim a deletion that never happened.
  if(!r.ok && !(r.status === 404 && d && 'ok' in d)){
    fail(r.status === 404 ? 'delete unsupported \\u2014 node needs redeploying'
                          : 'delete failed (HTTP '+r.status+')');
    return;
  }

  const h = held.get(it.id);
  if(h){ URL.revokeObjectURL(h.url); heldBytes -= h.size; held.delete(it.id); }
  card.remove();
  listing.items = listing.items.filter(x => x.id !== it.id);
  listing.bytes = Math.max(0, listing.bytes - it.bytes);
  if(!listing.items.length)
    document.getElementById('grid').innerHTML =
      '<div class="empty">store is empty &mdash; queue a prompt</div>';
  updateMeta();
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
  if(!r.ok){
    let d = {};
    try{ d = await r.json(); }catch(e){}
    pw.select();
    showLogin(
      d.reason === 'origin'    ? 'blocked: this request looked cross-origin'
    : d.reason === 'no-crypto' ? 'server is missing the cryptography package'
    : d.reason === 'password'  ? (d.from_env ? 'wrong password'
                                  : 'wrong password \\u2014 INLINE_PREVIEW_TOKEN never '
                                    + 'reached ComfyUI, so it wants the random one from the log')
    : 'login failed (HTTP '+r.status+')');
    return;
  }
  pw.value = '';
  setLocked(false);
  load();
}

document.getElementById('pw').addEventListener('keydown', e => {
  if(e.key === 'Enter') login();
});

const CRYPTMSG = {nokey:'no key in this browser', otherkey:'different session key'};

async function hydrate(card, it){
  if(held.has(it.id)) return;
  try{
    const r = await fetch(srcOf(it), {cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const b = new Blob([await decryptBlob(await r.arrayBuffer(), it)], {type: it.type});
    if(!card.isConnected) return;
    const o = URL.createObjectURL(b);
    held.set(it.id, {url:o, size:b.size}); heldBytes += b.size;
    const m = card.querySelector('img,video'); if(m) m.src = o;
    const a = card.querySelector('a');         if(a) a.href = o;
    updateMeta();
  }catch(e){
    const m = card.querySelector('img,video');
    if(m) m.replaceWith(Object.assign(document.createElement('div'), {
      textContent: CRYPTMSG[e.message] || 'could not load',
      style: 'aspect-ratio:1;display:flex;align-items:center;justify-content:center;'
           + 'background:#000;color:#c88;font-size:11px;text-align:center;padding:8px'}));
  }
}

async function load(){
  const grid = document.getElementById('grid');
  if(io){ io.disconnect(); io = null; }

  let r;
  try { r = await fetch(tok('list'),{cache:'no-store'}); }
  catch(e){ grid.innerHTML='<div class="empty">could not reach ComfyUI</div>'; return; }
  if(r.status === 403){ showLogin(''); return; }
  setLocked(false);
  publishKey();
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
    // Encrypted bytes can never go straight into src -- they have to come
    // through JS to be decrypted, whatever the toggle says.
    const viaJs = blobMode || !!it.kid;
    if(!viaJs) media.src = url;

    const row = document.createElement('div');
    row.className = 'row';
    const span = document.createElement('span');
    span.textContent = human(it.bytes)+' \\u00b7 '+ago(it.age)
      + (it.kid ? '' : ' \\u00b7 plain');
    const a = document.createElement('a');
    a.href = url;
    a.download = 'preview-'+it.id.slice(0,8)+(EXT[it.type]||'');
    a.textContent = 'save';
    row.append(span, a);

    // Deliberately in the far corner rather than beside "save" -- one is
    // irreversible and the store is the only copy.
    const del = document.createElement('button');
    del.className = 'del';
    del.type = 'button';
    del.title = 'delete this preview';
    del.textContent = '\\u00d7';
    del.onclick = () => drop(it, card);

    card.append(media, row, del);
    grid.appendChild(card);
    owner.set(card, it);
    if(viaJs) io.observe(card);
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
    # Distinct reasons: the page renders these, and "wrong password" for an
    # origin refusal sends you hunting for the wrong problem.
    if not _same_origin(request):
        return web.json_response({"ok": False, "reason": "origin"}, status=403)
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
        return web.json_response({"ok": False, "reason": "password",
                                  "from_env": _env_token is not None}, status=403)

    _fails = 0
    return _with_cookie(web.json_response({"ok": True}))


def _with_cookie(resp):
    # path="/" is deliberate, not laziness. ComfyUI mirrors every route under
    # /api, and the node widget reaches us through api.apiURL(), so it requests
    # /api/inline_preview... . A cookie scoped to /inline_preview is simply not
    # sent there, which left the in-canvas previews permanently "locked" while
    # the gallery -- relative URLs under /inline_preview/ -- worked fine.
    # SameSite=Strict plus the origin check are what actually contain this; the
    # path never was. The value is an opaque per-boot token, meaningless to any
    # other handler it now rides along with.
    resp.set_cookie(COOKIE, _SESSION, httponly=True, samesite="Strict",
                    path="/", max_age=COOKIE_MAX_AGE)
    return resp


@PromptServer.instance.routes.post("/inline_preview/key")
async def _inline_preview_key(request):
    """Take the browser's session key. Authenticated, so the password is what
    stops anyone else from swapping the key out from under you."""
    global _session_key, _session_kid, _key_touched
    deny = _guard(request)
    if deny is not None:
        return deny
    if AESGCM is None:
        return web.json_response({"ok": False, "reason": "no-crypto"}, status=501)
    try:
        raw = base64.b64decode((await request.json()).get("key", ""), validate=True)
    except Exception:
        raw = b""
    if len(raw) != 32:
        return web.json_response({"ok": False, "reason": "bad-key"}, status=400)

    with _key_lock:
        fresh = _session_key is None or bytes(_session_key) != raw
        if fresh:
            _zero_locked()
            _session_key = bytearray(raw)
            _session_kid = _kid(raw)
        _key_touched = time.time()
        kid = _session_kid
    if fresh:
        _warned.discard("nokey")   # so a later lapse warns again rather than staying quiet
        log.info("inline_preview: session key set (kid %s) -- new previews are encrypted", kid)
    return web.json_response({"ok": True, "kid": kid, "ttl": KEY_TTL})


@PromptServer.instance.routes.get("/inline_preview")
async def _inline_preview(request):
    # Gated: /history keeps the ui payload intact, so the blob ids are public to
    # anyone who reaches the port. The id alone must not be enough.
    deny = _guard(request)
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


@PromptServer.instance.routes.post("/inline_preview/delete")
async def _inline_preview_delete(request):
    deny = _guard(request)
    if deny is not None:
        return deny
    gone = STORE.remove(request.rel_url.query.get("id", ""))
    # 404 means someone else got there first, or the LRU already evicted it --
    # either way the caller's intent is satisfied, so the page treats it as done.
    return web.json_response(dict(STORE.stats(), ok=gone), status=200 if gone else 404)


@PromptServer.instance.routes.post("/inline_preview/clear")
async def _inline_preview_clear(request):
    deny = _guard(request)
    if deny is not None:
        return deny
    STORE.clear()
    # "clear all" means all of it -- otherwise the key outlives every blob it
    # was ever used on. The browser re-posts before the next queue.
    forget_key("store cleared")
    return web.json_response(STORE.stats())


@PromptServer.instance.routes.post("/inline_input")
async def _inline_input_put(request):
    deny = _guard(request)
    if deny is not None:
        return deny

    data = await request.read()
    if not data:
        return web.json_response({"ok": False, "reason": "empty"}, status=400)
    if len(data) > INPUT_MAX_BYTES:
        return web.json_response({"ok": False, "reason": "too-large"}, status=413)

    kid = request.headers.get("X-Inline-Kid", "")
    if kid:
        # Ciphertext: the server cannot tell whether this is an image until the
        # graph runs and it holds the key. load() checks after decrypting.
        ctype = request.headers.get("X-Inline-Type", "image/png").split(";")[0].strip()
    else:
        try:
            # verify() consumes the object, so load() re-opens from the bytes.
            Image.open(io.BytesIO(data)).verify()
        except Exception:
            return web.json_response({"ok": False, "reason": "not-an-image"}, status=415)
        ctype = request.headers.get("Content-Type", "image/png").split(";")[0].strip()

    return web.json_response({"ok": True, "id": INPUTS.put(data, ctype, False, kid),
                              "bytes": len(data), "kid": kid})


@PromptServer.instance.routes.get("/inline_input")
async def _inline_input_get(request):
    deny = _guard(request)
    if deny is not None:
        return deny
    item = INPUTS.get(request.rel_url.query.get("id", ""))
    if item is None:
        return web.Response(status=404, text="expired: evicted from the RAM store")
    # Served exactly as stored. If it is encrypted the browser decrypts it with
    # the key it uploaded under -- the bytes never leave here in the clear.
    return web.Response(body=item[0], content_type=item[1],
                        headers={"Cache-Control": "no-store", "X-Inline-Kid": item[4]})


@PromptServer.instance.routes.post("/inline_input/clear")
async def _inline_input_clear(request):
    deny = _guard(request)
    if deny is not None:
        return deny
    INPUTS.clear()
    return web.json_response(INPUTS.stats())


@PromptServer.instance.routes.get("/inline_preview/gallery")
async def _inline_preview_gallery(request):
    # The page itself carries no data -- it asks for the password and then
    # fetches /list, which is where the check actually bites.
    deny = _guard(request, need_token=False)
    if deny is not None:
        return deny
    resp = web.Response(text=_GALLERY_HTML, content_type="text/html",
                        headers={"Cache-Control": "no-store"})
    # A valid ?t= counts as logging in. Without minting the cookie here the
    # ComfyUI tab's widget would have no credential and every preview would 403.
    if TOKEN and _secret_eq(request.rel_url.query.get("t", ""), TOKEN):
        resp = _with_cookie(resp)
    return resp


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
            blob, kid = _encrypt(data)
            out.append({"id": STORE.put(blob, mime, False, kid), "type": mime,
                        "bytes": len(blob), "kid": kid})
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

        blob, kid = _encrypt(data)
        return {"ui": {"inline": [
            {"id": STORE.put(blob, mime, has_audio, kid), "type": mime, "bytes": len(blob),
             "audio": has_audio, "kid": kid,
             "frames": int(arr.shape[0]), "fps": round(rate, 3)}
        ]}}


if KEY_TTL:
    threading.Thread(target=_key_sweeper, daemon=True,
                     name="inline_preview_key_sweeper").start()
else:
    log.warning("inline_preview: INLINE_PREVIEW_KEY_TTL=0 -- the encryption key "
                "stays in RAM for the life of the process once posted")

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
    "LoadImageInline": LoadImageInline,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "PreviewImageInline": "Preview Image (RAM, no file)",
    "PreviewVideoInline": "Preview Video (RAM, no file)",
    "LoadImageInline": "Load Image (RAM, no file)",
}

WEB_DIRECTORY = "./js"

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
