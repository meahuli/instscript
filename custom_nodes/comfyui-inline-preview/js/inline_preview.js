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

function revokeAll(node) {
  for (const u of node._inlineObjectUrls || []) URL.revokeObjectURL(u);
  node._inlineObjectUrls = [];
}

async function hydrate(node, item, wrap) {
  const url = api.apiURL(`/inline_preview?id=${encodeURIComponent(item.id)}`);

  let obj;
  try {
    const r = await fetch(url, { cache: "no-store" });
    if (!r.ok) throw new Error(r.status === 404 ? "expired" : `HTTP ${r.status}`);
    obj = URL.createObjectURL(await r.blob());
  } catch (e) {
    note(wrap, e.message === "expired"
      ? "preview expired (evicted from the RAM store) — re-queue to regenerate"
      : `could not load preview (${e.message})`, "#c88");
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

app.registerExtension({
  name: "inline.preview.ram",

  async beforeRegisterNodeDef(nodeType, nodeData) {
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
