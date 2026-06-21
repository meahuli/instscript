#!/usr/bin/env bash
# ============================================================
# provision.sh — set up a fresh runpod-slim ComfyUI pod from git.
#
# Per-pod usage (paste once in the pod's WEB TERMINAL after first boot):
#   git clone https://github.com/meahuli/instscript.git /workspace/provision 2>/dev/null \
#     || git -C /workspace/provision pull
#   bash /workspace/provision/provision.sh
#
# Then RESTART THE POD so ComfyUI reloads with the new nodes + args.
# ============================================================
set -uo pipefail   # NOT -e: we handle per-node failures so one bad node won't abort everything

# ---- Locate the runpod-slim ComfyUI install + its venv --------------------
COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"

if [ ! -d "$COMFY" ]; then
  echo "ERROR: $COMFY not found. Let the pod finish first boot (ComfyUI up once), then re-run." >&2
  exit 1
fi
VENV="$COMFY/.venv-cu128"
[ -d "$VENV" ] || VENV=$(find "$COMFY" -maxdepth 1 -type d -name '.venv-*' | head -1)
if [ -z "${VENV:-}" ] || [ ! -f "$VENV/bin/activate" ]; then
  echo "ERROR: no venv found under $COMFY (.venv-cu128)." >&2; exit 1
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
echo "==> venv: $VENV  ($(python --version 2>&1))"

# ============================================================
# 1) CUSTOM NODES  —  EDIT THIS LIST to match your workflows.
#    Append @<commit-sha> to a URL to pin it (recommended once it works).
#    Nodes already baked into the image (Manager, KJNodes, Civicomfy,
#    RunpodDirect) are skipped automatically if present.
# ============================================================
NODES=(
  "https://github.com/city96/ComfyUI-GGUF"            # load GGUF-quantized models + GGUF text encoders (QuadrupleCLIPLoaderGGUF etc.)
  "https://github.com/Lightricks/ComfyUI-LTXVideo"    # LTX-2.x video nodes (LTXAVTextEncoderLoader, LTXVAudioVAELoader, ...) — needed by dl-ltx23.sh
  "https://github.com/ClownsharkBatwing/RES4LYF"      # advanced samplers/guiders (ClownSampler_Beta, MultimodalGuider, ManualSigmas) — needed by the LTX-2.3 workflow
  # add more when you need them, e.g.:
  # "https://github.com/Fannovel16/comfyui_controlnet_aux"
  # "https://github.com/Gourieff/ComfyUI-ReActor"
  # "https://github.com/balazik/ComfyUI-PuLID-Flux"   # Chroma/Flux PuLID
)

# Protect the image's cu128 torch from being clobbered by a node's requirements.
CONSTRAINTS="/tmp/torch-constraints.txt"
python - > "$CONSTRAINTS" 2>/dev/null <<'PY' || true
import importlib.metadata as m
for p in ("torch","torchvision","torchaudio","xformers"):
    try: print(f"{p}=={m.version(p)}")
    except Exception: pass
PY
echo "==> torch pinned to: $(tr '\n' ' ' < "$CONSTRAINTS")"

mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes"
for repo_spec in "${NODES[@]}"; do
  repo="${repo_spec%@*}"; sha=""; [ "$repo_spec" != "$repo" ] && sha="${repo_spec##*@}"
  name=$(basename "$repo" .git)
  if [ -d "$name/.git" ]; then
    echo "==> [$name] present — skipping clone"
  else
    echo "==> [$name] cloning"
    if [ -n "$sha" ]; then
      git clone "$repo" "$name" && git -C "$name" checkout -q "$sha" \
        || { echo "   CLONE/CHECKOUT FAILED: $repo_spec"; continue; }
    else
      git clone --depth 1 "$repo" "$name" || { echo "   CLONE FAILED: $repo"; continue; }
    fi
  fi
  if [ -f "$name/requirements.txt" ]; then
    echo "   installing deps for $name"
    pip install -q -r "$name/requirements.txt" -c "$CONSTRAINTS" \
      || echo "   DEP INSTALL FAILED for $name — see output above"
  fi
done

# ============================================================
# 2) MODELS — handled by SEPARATE scripts so a pod pulls only what it needs.
#    Run whichever you want this session, AFTER this script:
#       bash /workspace/provision/dl-chroma.sh
#       bash /workspace/provision/dl-hidream.sh
#       bash /workspace/provision/dl-qwen-image-2512.sh
#       bash /workspace/provision/dl-qwen-edit-2511.sh
#       bash /workspace/provision/dl-wan.sh            # video (Wan 2.2 14B fp8); MODE=i2v for image-to-video
#       bash /workspace/provision/dl-ltx.sh            # video (LTX 13B fp8, fast); VARIANT=dev for quality
#       bash /workspace/provision/dl-ltx23.sh          # video (LTX-2.3 22B); PRECISION=bf16 for max quality
#       bash /workspace/provision/dl-sulphur.sh        # video (UNCENSORED LTX-2.3 / Sulphur-2); PRECISION=bf16
#    Each is resumable and skips files already present. New models show up
#    in ComfyUI after a model-list refresh (no pod restart needed for models).
# ============================================================

# ============================================================
# 3) COMFYUI ARGS  —  written to the file runpod-slim reads on (re)start.
#    Appended after the image's fixed --listen 0.0.0.0 --port 8188 --enable-cors-header.
# ============================================================
cat > "$ARGS_FILE" <<'EOF'
# Managed by provision.sh. IMPORTANT: one flag per line, NO inline comments.
# The image only strips whole-line '#' comments, so a trailing '# ...' on a flag
# line would be passed to ComfyUI as garbage args and crash startup.
# Outputs + previews go to RAM (wiped on pod stop); no metadata embedded in PNGs.
--output-directory /dev/shm/output
--temp-directory /dev/shm/temp
--disable-metadata
# Optional — uncomment (one flag per line, still no inline comments):
# --listen 127.0.0.1
# --preview-method auto
# --lowvram
EOF
echo "==> wrote $ARGS_FILE"

echo ""
echo "============================================================"
echo "  Provision complete."
echo "  >>> RESTART THE POD now so ComfyUI reloads with your nodes + args. <<<"
echo "  (Restart re-runs /start.sh, which reads $ARGS_FILE and loads custom_nodes/.)"
echo "============================================================"
