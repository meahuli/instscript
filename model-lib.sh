#!/usr/bin/env bash
# ============================================================
# model-lib.sh — shared helper for the dl-*.sh model scripts.
# It is SOURCED by them (don't run it directly). Locates the
# runpod-slim ComfyUI models dir and provides a resumable,
# skip-if-present aria2c downloader.
#
# Token-free by default. For gated repos, set HF_TOKEN as a RunPod
# env var; this reads it.
# ============================================================
set -uo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
MODELS_DIR="$COMFY/models"

if [ ! -d "$COMFY" ]; then
  echo "ERROR: $COMFY not found — let the pod finish first boot (ComfyUI up once), then retry." >&2
  exit 1
fi
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
