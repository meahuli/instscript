#!/usr/bin/env bash
# ============================================================
# model-lib.sh — shared helper for the dl-*.sh model scripts.
# It is SOURCED by them (don't run it directly). Locates the
# ComfyUI models dir (RunPod runpod-slim, Vast, or generic
# images) and provides a resumable, skip-if-present aria2c
# downloader.
#
# Token-free by default. For gated repos, set HF_TOKEN as an env
# var — RunPod env var, or on Vast pass "-e HF_TOKEN=..." / export
# it in the On-start Script; this reads it either way.
#
# ComfyUI location is auto-detected. Override on any host with:
#   COMFY=/path/to/ComfyUI bash dl-xxx.sh
# ============================================================
set -uo pipefail

# --- locate ComfyUI across providers (runpod-slim, Vast, generic) ---
# Priority: explicit $COMFY > known install paths > shallow search.
_find_comfy() {
  local c root
  if [ -n "${COMFY:-}" ]; then            # explicit override wins
    printf '%s\n' "$COMFY"; return 0
  fi
  for c in \
      /workspace/runpod-slim/ComfyUI \
      /workspace/ComfyUI \
      /opt/ComfyUI \
      "${HOME:-/root}/ComfyUI" \
      /ComfyUI ; do
    [ -f "$c/main.py" ] && { printf '%s\n' "$c"; return 0; }
  done
  for root in /workspace /opt /root / ; do
    [ -d "$root" ] || continue
    c=$(find "$root" -maxdepth 5 -name main.py -path '*/ComfyUI/main.py' 2>/dev/null | head -n1)
    [ -n "$c" ] && { dirname "$c"; return 0; }
  done
  return 1
}

COMFY="$(_find_comfy || true)"
if [ -z "$COMFY" ] || [ ! -d "$COMFY" ]; then
  echo "ERROR: ComfyUI not found." >&2
  echo "  Looked in: /workspace/runpod-slim/ComfyUI, /workspace/ComfyUI, /opt/ComfyUI, \$HOME/ComfyUI, /ComfyUI" >&2
  echo "  If the pod is still booting, wait for ComfyUI to come up once, then retry." >&2
  echo "  Or set the path explicitly:  COMFY=/path/to/ComfyUI bash $0" >&2
  exit 1
fi
echo "==> Using ComfyUI at: $COMFY"
MODELS_DIR="$COMFY/models"
mkdir -p "$MODELS_DIR"/{diffusion_models,text_encoders,vae,loras,pulid,controlnet,clip,clip_vision,unet,upscale_models}

command -v aria2c >/dev/null 2>&1 || { echo "==> installing aria2"; apt-get update -qq && apt-get install -y -qq aria2; }

ARIA_OPTS="--continue=true --max-connection-per-server=16 --split=16 --file-allocation=none --allow-overwrite=true --auto-file-renaming=false --console-log-level=warn --summary-interval=5"
HF_AUTH=()
[ -n "${HF_TOKEN:-}" ] && HF_AUTH=(--header="Authorization: Bearer $HF_TOKEN")

# get <url> <subdir-under-models> <outfile>
get() {
  local url="$1" sub="$2" name="$3" dir="$MODELS_DIR/$2"
  mkdir -p "$dir"
  if [ -s "$dir/$name" ]; then echo "  present, skipping: $sub/$name"; return 0; fi
  echo "==> $sub/$name"
  aria2c $ARIA_OPTS "${HF_AUTH[@]}" --dir="$dir" --out="$name" "$url" \
    || echo "  download failed for $sub/$name — re-run this script to resume."
}
