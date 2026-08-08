import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const NODES = new Set(["PreviewImageInline", "PreviewVideoInline"]);

const EXT = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/webp": ".webp",
  "video/mp4": ".mp4",
  "video/webm": ".webm",
};

// The gallery lives on this same origin, so it shares both of these and needs
// nothing of its own. Incognito wipes them when the last window closes, which
// strands anything still in the store -- that is the deal with per-session keys
// rather than ones derived from something you can retype.
const KEY_ITEM = "inline_preview_session_key";   // uploads, symmetric
const DB_NAME = "inline_preview";                // outputs, RSA keypair
const DB_STORE = "keys";
const KP_ITEM = "output_keypair";

const b64 = buf => btoa(String.fromCharCode(...new Uint8Array(buf)));
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));

const hex16 = buf =>
  [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("").slice(0, 16);

let keyBytes = null;
let keyPublished = false;
let pubPublished = false;

// -- uploads: symmetric, because ComfyUI has to decrypt these to make a tensor.
function sessionKey() {
  if (keyBytes) return keyBytes;
  // crypto.subtle only exists in a secure context: https, or localhost (which
  // is what the tunnel gives you). Over plain http to an IP it is undefined.
  if (!globalThis.crypto?.subtle) return null;
  let stored = localStorage.getItem(KEY_ITEM);
  if (!stored) {
    stored = b64(crypto.getRandomValues(new Uint8Array(32)));
    localStorage.setItem(KEY_ITEM, stored);
  }
  keyBytes = unb64(stored);
  return keyBytes;
}

async function kidOf(raw) {
  return hex16(await crypto.subtle.digest("SHA-256", raw));
}

// -- outputs: the private key never leaves this browser, and is generated
// non-extractable so it cannot leave at all. That is why it lives in IndexedDB
// and not localStorage: localStorage stores strings, so anything kept there has
// to be extractable, and every custom node's JS shares this origin and can read
// it. generateKey applies `false` to the private key only -- the public half
// stays exportable, which is the half we register.
function idb() {
  return new Promise((res, rej) => {
    const rq = indexedDB.open(DB_NAME, 1);
    rq.onupgradeneeded = () => rq.result.createObjectStore(DB_STORE);
    rq.onsuccess = () => res(rq.result);
    rq.onerror = () => rej(rq.error);
  });
}

// Put-if-absent inside one transaction, returning whichever value won. Two tabs
// opening at once would otherwise both generate and the second would overwrite
// the first, leaving a tab holding a private key whose public half is gone.
function idbClaim(db, made) {
  return new Promise((res, rej) => {
    const tx = db.transaction(DB_STORE, "readwrite");
    const os = tx.objectStore(DB_STORE);
    const rq = os.get(KP_ITEM);
    let out = made;
    rq.onsuccess = () => { if (rq.result) out = rq.result; else os.put(made, KP_ITEM); };
    tx.oncomplete = () => res(out);
    tx.onerror = () => rej(tx.error);
  });
}

let kpPromise = null;

// Cached as the promise, not the result: concurrent callers must not each
// generate a pair and race.
function keyPair() {
  return (kpPromise ||= (async () => {
    if (!globalThis.crypto?.subtle || !globalThis.indexedDB) return null;
    try {
      const db = await idb();
      const made = await crypto.subtle.generateKey(
        // publicExponent is REQUIRED and must be a Uint8Array -- WebCrypto has no
        // default for it. Omitting it throws OperationError before any key
        // exists, which read as "this browser cannot do it" rather than as a
        // typo. 0x010001 = 65537, big-endian.
        { name: "RSA-OAEP", modulusLength: 2048,
          publicExponent: new Uint8Array([0x01, 0x00, 0x01]), hash: "SHA-256" },
        false,
        ["encrypt", "decrypt"]);
      return await idbClaim(db, made);
    } catch (e) {
      console.warn("inline_preview: no output keypair —", e);
      return null;
    }
  })());
}

async function myPkid() {
  const kp = await keyPair();
  if (!kp) return null;
  const spki = await crypto.subtle.exportKey("spki", kp.publicKey);
  return { spki, pkid: hex16(await crypto.subtle.digest("SHA-256", spki)) };
}

let lastPub = 0;

async function publishPubKey(force) {
  if (pubPublished && !force) return;
  // Re-registered on every run, not just once: the pod can restart under a tab
  // that still thinks it registered, and the fallback is plaintext storage.
  // Same burst-collapsing as publishKey, since `status` fires repeatedly.
  const now = Date.now();
  if (force && now - lastPub < 3000) return;
  lastPub = now;
  // Everything is inside the try, and every exit says why. This used to fail
  // silently: myPkid() was awaited outside it, so any throw in the keypair path
  // became an unhandled rejection and the only evidence anywhere was a server
  // log line saying previews were unencrypted.
  try {
    const me = await myPkid();
    if (!me) {
      console.warn("inline_preview: no keypair in this browser — previews will be stored "
                 + "UNENCRYPTED. Needs a secure context (https or localhost) and IndexedDB "
                 + "(blocked in some private windows).");
      return;
    }
    const r = await fetch(api.apiURL("/inline_preview/pubkey"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: b64(me.spki), client_id: api.clientId || "" }),
    });
    pubPublished = r.ok;   // 403 until this browser is unlocked; retried later
    if (r.ok) {
      console.info("inline_preview: public key registered, pkid", me.pkid);
    } else {
      console.warn("inline_preview: pubkey rejected (HTTP " + r.status + ") — previews will "
                 + "be stored UNENCRYPTED.", await r.text().catch(() => ""));
    }
  } catch (e) {
    console.warn("inline_preview: pubkey registration failed — previews will be stored "
               + "UNENCRYPTED.", e);
  }
}

// b"IP1" | uint16 len(wrapped) | wrapped | 12-byte nonce | ciphertext
const SEAL_MAGIC = [0x49, 0x50, 0x31];

async function unseal(buf, item) {
  if (!item.kid) return buf;                       // stored in the clear
  const u8 = new Uint8Array(buf);
  if (u8.length < 5 || SEAL_MAGIC.some((b, i) => u8[i] !== b)) throw new Error("badseal");
  const wlen = (u8[3] << 8) | u8[4];
  const wrapped = u8.subarray(5, 5 + wlen);
  const nonce = u8.subarray(5 + wlen, 17 + wlen);
  const ct = u8.subarray(17 + wlen);

  const me = await myPkid();
  if (!me) throw new Error("nokey");
  if (me.pkid !== item.kid) throw new Error("otherkey");
  const kp = await keyPair();
  const raw = await crypto.subtle.decrypt({ name: "RSA-OAEP" }, kp.privateKey, wrapped);
  const ck = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["decrypt"]);
  return crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, ck, ct);
}

let lastPublish = 0;

async function publishKey(force) {
  if (keyPublished && !force) return;
  // status fires repeatedly; collapse bursts. The window is tiny next to a
  // generation, so the post still lands long before the preview node runs.
  const now = Date.now();
  if (force && now - lastPublish < 3000) return;
  const raw = sessionKey();
  if (!raw) return;
  lastPublish = now;
  try {
    const r = await fetch(api.apiURL("/inline_preview/key"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: b64(raw) }),
    });
    keyPublished = r.ok;   // 403 until this browser is unlocked; retried later
    if (!r.ok) console.warn("inline_preview: key not accepted — previews will be unencrypted");
  } catch (e) {}
}

// The server drops the key once the pod is idle, so it has to be re-established
// before the next run -- otherwise the first generation after a lull is stored
// in plaintext. Patching api.queuePrompt does not survive frontend versions
// (it silently stopped firing on 1.47), so drive this off ComfyUI's own socket
// events instead: they are broadcast to every connected tab, fire whoever
// queued the prompt including the API, and land at the START of a graph while
// the preview node runs at the end.
function armKey() {
  if (typeof api?.addEventListener !== "function") {
    console.warn("inline_preview: no api.addEventListener — previews may be unencrypted");
    return;
  }
  for (const ev of ["execution_start", "promptQueued", "status"]) {
    api.addEventListener(ev, () => { publishKey(true); publishPubKey(true); });
  }
}

// Uploads only. Outputs go through unseal() -- they are sealed to the public
// key, and this key never opens them.
async function decryptUpload(buf, item) {
  if (!item.kid) return buf;
  const raw = sessionKey();
  if (!raw) throw new Error("nokey");
  if (await kidOf(raw) !== item.kid) throw new Error("otherkey");
  const ck = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["decrypt"]);
  return crypto.subtle.decrypt({ name: "AES-GCM", iv: buf.slice(0, 12) }, ck, buf.slice(12));
}

function container() {
  const el = document.createElement("div");
  el.style.cssText = [
    "width:100%", "height:100%", "overflow:auto",
    "display:flex", "flex-direction:column", "gap:6px",
    "align-items:center", "justify-content:center",
    "background:#0d0d0d", "border-radius:4px", "padding:4px",
    "box-sizing:border-box",
  ].join(";");
  return el;
}

function note(el, text, colour) {
  const p = document.createElement("div");
  p.textContent = text;
  p.style.cssText = `color:${colour};font:11px sans-serif;text-align:center;padding:8px;`;
  el.replaceChildren(p);
}

function human(bytes) {
  if (!bytes && bytes !== 0) return "";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0, n = bytes;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${u[i]}`;
}

function ago(s) {
  return s < 60 ? `${Math.round(s)}s ago`
       : s < 3600 ? `${Math.round(s / 60)}m ago`
       : `${(s / 3600).toFixed(1)}h ago`;
}

function revokeAll(node) {
  for (const u of node._inlineObjectUrls || []) URL.revokeObjectURL(u);
  node._inlineObjectUrls = [];
}

async function hydrate(node, item, wrap) {
  const url = api.apiURL(`/inline_preview?id=${encodeURIComponent(item.id)}`);

  const MSG = {
    expired: "preview expired (evicted from the RAM store) — re-queue to regenerate",
    locked: "locked — open /inline_preview/gallery?t=<password> once to unlock this browser",
    nokey: "no keypair in this browser (needs https or localhost)",
    otherkey: "sealed to another browser's key — re-queue to regenerate one for this browser",
    badseal: "unrecognised preview format — hard-reload the page to pick up the current script",
  };

  let obj;
  try {
    const r = await fetch(url, { cache: "no-store" });
    if (r.status === 403) { keyPublished = pubPublished = false; throw new Error("locked"); }
    if (r.status === 404) throw new Error("expired");
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const buf = await unseal(await r.arrayBuffer(), item);
    obj = URL.createObjectURL(new Blob([buf], { type: item.type }));
  } catch (e) {
    // Sealed to a public key that is not ours -- another browser queued this, or
    // the pod restarted and fell back before we re-registered. Register now so
    // the next generation is readable here rather than failing the same way.
    if (e.message === "otherkey") publishPubKey(true);
    note(wrap, MSG[e.message] || `could not load preview (${e.message})`, "#c88");
    return;
  }

  if (!wrap.isConnected) { URL.revokeObjectURL(obj); return; }
  (node._inlineObjectUrls ||= []).push(obj);

  let media;
  if (String(item.type).startsWith("video/")) {
    media = document.createElement("video");
    media.controls = true;
    media.loop = true;
    media.playsInline = true;
    if (item.audio) {
      // Unmuted autoplay is only allowed once the page has media engagement, so
      // ask for sound and drop back to a muted autoplay if the browser refuses.
      media.muted = false;
      media.addEventListener("loadeddata", () => {
        media.play().catch(() => {
          media.muted = true;
          media.play().catch(() => {});
        });
      }, { once: true });
    } else {
      media.muted = true;
      media.autoplay = true;
    }
  } else {
    media = document.createElement("img");
  }
  media.src = obj;
  media.style.cssText =
    "max-width:100%;max-height:100%;object-fit:contain;border-radius:3px;";

  const dl = document.createElement("a");
  dl.href = obj;
  dl.download = `preview-${item.id.slice(0, 8)}${EXT[item.type] || ""}`;
  dl.textContent = `save${item.bytes ? ` (${human(item.bytes)})` : ""}`;
  dl.style.cssText = [
    "position:absolute", "right:6px", "top:6px",
    "font:10px sans-serif", "color:#ddd", "text-decoration:none",
    "background:rgba(0,0,0,.65)", "padding:2px 6px", "border-radius:3px",
  ].join(";");

  wrap.replaceChildren(media, dl);
}

function render(node, items) {
  const el = node._inlineEl;
  if (!el) return;

  // Both no-op once accepted; they retry after the browser is unlocked.
  publishKey();
  publishPubKey();
  revokeAll(node);
  el.replaceChildren();

  if (!items || items.length === 0) {
    note(el, "no result yet — queue the prompt", "#666");
    return;
  }

  for (const item of items) {
    const wrap = document.createElement("div");
    wrap.style.cssText =
      "position:relative;width:100%;display:flex;justify-content:center;";
    note(wrap, "loading…", "#666");
    el.appendChild(wrap);
    hydrate(node, item, wrap);
  }
}

// ---------------------------------------------------------------- uploads --

const INPUT_NODE = "LoadImageInline";

function inputURL(id) {
  return api.apiURL(`/inline_input?id=${encodeURIComponent(id)}`);
}

// Encrypt before the bytes ever leave the tab, so the plaintext image is never
// in the server's memory except while a graph is actually decoding it.
async function sealForUpload(file) {
  const buf = await file.arrayBuffer();
  const raw = sessionKey();
  if (!raw) return { body: buf, kid: "" };
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ck = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, ck, buf));
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv, 0);
  out.set(ct, iv.length);
  return { body: out, kid: await kidOf(raw) };
}

async function upload(node, file, ui) {
  if (!file) return;
  ui.status.textContent = `uploading ${file.name}…`;
  let r, d = {};
  try {
    const { body, kid } = await sealForUpload(file);
    const headers = { "Content-Type": file.type || "application/octet-stream" };
    headers["X-Inline-Name"] = encodeURIComponent(file.name || "image");
    if (kid) {
      headers["X-Inline-Kid"] = kid;
      headers["X-Inline-Type"] = file.type || "image/png";
    }
    r = await fetch(api.apiURL("/inline_input"), { method: "POST", headers, body });
    d = await r.json().catch(() => ({}));
  } catch (e) {
    ui.status.textContent = "upload failed: could not reach ComfyUI";
    return;
  }
  if (!r.ok) {
    ui.status.textContent =
      r.status === 403 ? "locked — unlock the gallery once in this browser"
    : d.reason === "too-large"   ? "too large for the RAM store"
    : d.reason === "not-an-image" ? "that is not an image"
    : `upload failed (HTTP ${r.status})`;
    return;
  }
  const w = node.widgets?.find(x => x.name === "image_id");
  if (w) w.value = d.id;
  // Get the key over now rather than racing the first queue for it.
  if (d.kid) publishKey(true);
  refreshPicker(ui);
  // Draw from the local File. Re-fetching what we just sent would double the
  // traffic over the tunnel, which is the slow part of this whole operation.
  show(node, ui, d.id,
       `${file.name} · ${human(d.bytes)} · ${d.kid ? "encrypted in RAM" : "in RAM (plain)"}`,
       file);
}

// The thumbnail cannot be a plain <img src>: encrypted bytes have to come
// through JS first, exactly like the gallery.
async function show(node, ui, id, label, localFile) {
  if (ui.url) { URL.revokeObjectURL(ui.url); ui.url = null; }
  if (!id) { ui.img.style.display = "none"; ui.status.textContent = "no image"; return; }

  if (localFile) {
    ui.url = URL.createObjectURL(localFile);
    ui.img.src = ui.url;
    ui.img.style.display = "block";
    if (label) ui.status.textContent = label;
    return;
  }

  let r;
  try { r = await fetch(inputURL(id), { cache: "no-store" }); }
  catch (e) { ui.status.textContent = "could not reach ComfyUI"; return; }
  if (!r.ok) {
    ui.img.style.display = "none";
    ui.status.textContent = r.status === 403 ? "locked — unlock the gallery first"
                                             : "gone from RAM — re-upload";
    return;
  }

  const kid = r.headers.get("X-Inline-Kid") || "";
  let buf;
  try { buf = await decryptUpload(await r.arrayBuffer(), { kid }); }
  catch (e) {
    ui.img.style.display = "none";
    ui.status.textContent = e.message === "otherkey"
      ? "encrypted with a key this browser no longer has — re-upload"
      : "no decryption key in this browser";
    return;
  }

  ui.url = URL.createObjectURL(new Blob([buf], { type: r.headers.get("Content-Type") }));
  ui.img.src = ui.url;
  ui.img.style.display = "block";
  if (label) ui.status.textContent = label;
}

// What is already in the RAM store, so a second node does not mean a second
// upload of the same file over a slow link.
async function refreshPicker(ui) {
  const keep = ui.sel.value;
  let items = [];
  try {
    const r = await fetch(api.apiURL("/inline_input/list"), { cache: "no-store" });
    if (r.ok) items = (await r.json()).items || [];
    else if (r.status === 403) {
      ui.sel.replaceChildren(new Option("locked — unlock the gallery first", ""));
      return;
    }
  } catch (e) { return; }

  ui.sel.replaceChildren(
    new Option(items.length ? `— reuse an upload (${items.length}) —` : "— nothing uploaded yet —", ""),
    ...items.map(it => new Option(
      `${it.name || "image"} · ${human(it.bytes)} · ${ago(it.age)}${it.kid ? "" : " · plain"}`,
      it.id)));
  if (keep) ui.sel.value = keep;
}

function buildUploader(node) {
  const el = container();
  el.style.justifyContent = "flex-start";

  const img = document.createElement("img");
  img.style.cssText = "max-width:100%;max-height:180px;object-fit:contain;"
                    + "border-radius:3px;display:none";

  const status = document.createElement("div");
  status.style.cssText = "color:#888;font:11px sans-serif;text-align:center";
  status.textContent = "no image";

  const pick = document.createElement("input");
  pick.type = "file";
  pick.accept = "image/*";
  pick.style.display = "none";

  const btn = document.createElement("button");
  btn.textContent = "upload — or drop / paste";
  btn.style.cssText = "background:#1e1e1e;color:#ddd;border:1px solid #333;"
                    + "border-radius:4px;padding:5px 11px;font:11px sans-serif;cursor:pointer";

  // Names only, no thumbnail grid: every thumbnail would cross the tunnel, and
  // that is exactly the slow part. One image loads once you pick it.
  const sel = document.createElement("select");
  sel.style.cssText = "width:100%;background:#161616;color:#ddd;border:1px solid #333;"
                    + "border-radius:4px;padding:4px;font:11px sans-serif";

  const ui = { img, status, sel };
  btn.onclick = () => pick.click();
  pick.onchange = () => { upload(node, pick.files?.[0], ui); pick.value = ""; };
  sel.onmousedown = () => refreshPicker(ui);
  sel.onchange = () => {
    const id = sel.value;
    if (!id) return;
    const w = node.widgets?.find(x => x.name === "image_id");
    if (w) w.value = id;
    show(node, ui, id, sel.options[sel.selectedIndex]?.textContent || "");
  };

  el.addEventListener("dragover", e => { e.preventDefault(); el.style.outline = "1px dashed #567"; });
  el.addEventListener("dragleave", () => { el.style.outline = "none"; });
  el.addEventListener("drop", e => {
    e.preventDefault(); e.stopPropagation();
    el.style.outline = "none";
    upload(node, e.dataTransfer?.files?.[0], ui);
  });
  el.addEventListener("paste", e => {
    const f = [...(e.clipboardData?.items || [])]
      .find(i => i.type.startsWith("image/"))?.getAsFile();
    if (f) { e.preventDefault(); upload(node, f, ui); }
  });
  el.tabIndex = 0;   // so the element can receive paste

  el.append(img, status, btn, sel, pick);
  refreshPicker(ui);
  return { el, ui };
}

app.registerExtension({
  name: "inline.preview.ram",

  async setup() {
    armKey();
    publishKey();
    publishPubKey();
  },

  async beforeRegisterNodeDef(nodeType, nodeData) {
    if (nodeData.name === INPUT_NODE) {
      const onNodeCreated = nodeType.prototype.onNodeCreated;
      nodeType.prototype.onNodeCreated = function () {
        const r = onNodeCreated?.apply(this, arguments);
        const { el, ui } = buildUploader(this);
        this._inlineUploadUi = ui;
        this.addDOMWidget("inline_upload", "upload", el, { serialize: false });
        this.size = [Math.max(this.size[0], 260), Math.max(this.size[1], 300)];
        return r;
      };

      // A restored workflow still carries the id, but the bytes are long gone if
      // ComfyUI restarted -- show that rather than a broken image.
      const onConfigure = nodeType.prototype.onConfigure;
      nodeType.prototype.onConfigure = function () {
        const r = onConfigure?.apply(this, arguments);
        const id = this.widgets?.find(x => x.name === "image_id")?.value;
        if (id && this._inlineUploadUi) show(this, this._inlineUploadUi, id, "restored from workflow");
        return r;
      };
      return;
    }

    if (!NODES.has(nodeData.name)) return;

    const onNodeCreated = nodeType.prototype.onNodeCreated;
    nodeType.prototype.onNodeCreated = function () {
      const r = onNodeCreated?.apply(this, arguments);
      this._inlineEl = container();
      this._inlineObjectUrls = [];
      this.addDOMWidget("inline_preview", "preview", this._inlineEl, {
        serialize: false,
        hideOnZoom: false,
      });
      this.size = [Math.max(this.size[0], 320), Math.max(this.size[1], 340)];
      render(this, null);
      return r;
    };

    const onExecuted = nodeType.prototype.onExecuted;
    nodeType.prototype.onExecuted = function (message) {
      onExecuted?.apply(this, arguments);
      render(this, message?.inline);
    };

    const onRemoved = nodeType.prototype.onRemoved;
    nodeType.prototype.onRemoved = function () {
      revokeAll(this);
      return onRemoved?.apply(this, arguments);
    };
  },
});
