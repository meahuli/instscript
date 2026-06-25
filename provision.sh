#!/usr/bin/env bash
# ============================================================
# provision.sh — install ComfyUI custom nodes on a fresh pod.
# Works on BOTH:
#   • RunPod runpod-slim  (ComfyUI /workspace/runpod-slim/ComfyUI, venv .venv-cu128)
#   • Vast  vastai/comfyui (ComfyUI /workspace/ComfyUI,            venv /venv/main)
# Auto-detects the ComfyUI dir + venv, installs the NODES below (protecting the
# image's torch), and tells you how to reload ComfyUI for your provider.
#
# Usage (after the pod is up and ComfyUI has come up once):
#   git clone https://github.com/meahuli/instscript.git /workspace/instscript 2>/dev/null \
#     || git -C /workspace/instscript pull
#   bash /workspace/instscript/provision.sh
#   # Vast:   supervisorctl restart comfyui
#   # RunPod: restart the pod
#
# ComfyUI launch ARGS:
#   • Vast   -> set via the COMFYUI_ARGS env var in the template (this script does NOT touch them)
#   • RunPod -> written to /workspace/runpod-slim/comfyui_args.txt by this script
# ============================================================
set -uo pipefail   # NOT -e: we handle per-node failures so one bad node won't abort everything

# ---- Locate ComfyUI (RunPod runpod-slim, Vast, or generic) ----------------
_find_comfy() {
  local c root
  if [ -n "${COMFY:-}" ]; then printf '%s\n' "$COMFY"; return 0; fi
  for c in /workspace/runpod-slim/ComfyUI /workspace/ComfyUI /opt/ComfyUI "${HOME:-/root}/ComfyUI" /ComfyUI; do
    [ -f "$c/main.py" ] && { printf '%s\n' "$c"; return 0; }
  done
  for root in /workspace /opt /root /; do
    [ -d "$root" ] || continue
    c=$(find "$root" -maxdepth 5 -name main.py -path '*/ComfyUI/main.py' 2>/dev/null | head -n1)
    [ -n "$c" ] && { dirname "$c"; return 0; }
  done
  return 1
}
COMFY="$(_find_comfy || true)"
if [ -z "$COMFY" ] || [ ! -d "$COMFY" ]; then
  echo "ERROR: ComfyUI not found. If the pod is still booting, wait for ComfyUI to come up once and retry; or set COMFY=/path/to/ComfyUI." >&2
  exit 1
fi
echo "==> ComfyUI: $COMFY"

# ---- Locate + activate the venv (Vast /venv/main, runpod-slim $COMFY/.venv-*) ----
_find_venv() {
  local v
  if [ -n "${VIRTUAL_ENV:-}" ] && [ -f "$VIRTUAL_ENV/bin/activate" ]; then printf '%s\n' "$VIRTUAL_ENV"; return 0; fi
  for v in "$COMFY"/.venv-* /venv/main "$COMFY/venv" "$COMFY/.venv" /opt/venv; do
    [ -f "$v/bin/activate" ] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
VENV="${VENV:-$(_find_venv || true)}"
if [ -n "${VENV:-}" ] && [ -f "$VENV/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  echo "==> venv: $VENV  ($(python --version 2>&1))"
elif command -v python >/dev/null 2>&1; then
  echo "==> WARN: no venv dir found — using current python ($(python --version 2>&1))"
else
  echo "ERROR: no venv found and no python on PATH." >&2; exit 1
fi

# Installer: the vastai image uses uv; fall back to pip elsewhere.
if command -v uv >/dev/null 2>&1; then PIP="uv pip"; else PIP="python -m pip"; fi
echo "==> installer: $PIP"

# ---- Provider (for args handling + restart hint) ----
if [ -f /etc/supervisor/conf.d/comfyui.conf ] || [ -n "${CONTAINER_ID:-}" ]; then PROVIDER=vast
elif [ -d /workspace/runpod-slim ]; then PROVIDER=runpod
else PROVIDER=other; fi
echo "==> provider: $PROVIDER"

# ============================================================
# 1) CUSTOM NODES  —  EDIT THIS LIST to match your workflows.
#    Append @<commit-sha> to a URL to pin it (recommended once it works).
# ============================================================
NODES=(
  "https://github.com/city96/ComfyUI-GGUF"            # load GGUF-quantized models + GGUF text encoders
  "https://github.com/Lightricks/ComfyUI-LTXVideo"    # LTX-2.x video nodes — needed by dl-ltx23.sh
  "https://github.com/ClownsharkBatwing/RES4LYF"      # advanced samplers/guiders — LTX-2.3 workflow
  "https://github.com/FNGarvin/ComfyUI-AutoModelDownloader"  # "Missing Models -> Download All" from workflow-embedded URLs (de-RunPod'd fork; flat folders only)
  # add more when you need them, e.g.:
  # "https://github.com/Fannovel16/comfyui_controlnet_aux"
  # "https://github.com/Gourieff/ComfyUI-ReActor"
  # "https://github.com/balazik/ComfyUI-PuLID-Flux"   # Chroma/Flux PuLID
)

# Protect the image's torch from being clobbered by a node's requirements.
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
if [ "${#NODES[@]}" -eq 0 ]; then echo "==> NODES list is empty — add repo URLs to provision.sh. Nothing to install."; fi
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
    $PIP install -r "$name/requirements.txt" -c "$CONSTRAINTS" \
      || echo "   DEP INSTALL FAILED for $name — see output above"
  fi
done

# --- Pin deps that ComfyUI-LTXVideo leaves unbounded (its requirements.txt has no
#     upper bound, so a fresh install grabs incompatible 'latest' and shows IMPORT FAILED):
#       transformers 5.x removed APIs the node imports;
#       latest kornia dropped 'pad' from kornia.geometry.transform.pyramid.
#     0.7.4 still exports pad + the pyramid helpers; transformers 4.5x is fine.
$PIP install "transformers[timm]>=4.50.0,<5" "kornia==0.7.4" -c "$CONSTRAINTS" \
  || echo "   LTX dep-pin FAILED — run manually: pip install 'transformers[timm]<5' 'kornia==0.7.4'"

# ============================================================
# 2) MODELS — separate scripts; run whichever you need AFTER this, from this
#    same folder, e.g.:
#       bash "$(dirname "$0")/dl-chroma.sh"
#       bash "$(dirname "$0")/dl-wan.sh"            # MODE=i2v for image-to-video
#       bash "$(dirname "$0")/dl-ltx23.sh"         # PRECISION=bf16 for max quality
#    Each is resumable and skips files already present (model-lib auto-detects ComfyUI).
# ============================================================

# ============================================================
# 3) COMFYUI ARGS
#    RunPod runpod-slim -> written to comfyui_args.txt (read on restart).
#    Vast / other       -> args come from the COMFYUI_ARGS env var (template); not written here.
# ============================================================
if [ "$PROVIDER" = "runpod" ]; then
  ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
  cat > "$ARGS_FILE" <<'EOF'
# Managed by provision.sh. IMPORTANT: one flag per line, NO inline comments.
--output-directory /dev/shm/output
--temp-directory /dev/shm/temp
--disable-metadata
# Optional (one flag per line, still no inline comments):
# --listen 127.0.0.1
# --preview-method auto
# --lowvram
EOF
  echo "==> wrote $ARGS_FILE"
else
  echo "==> $PROVIDER: ComfyUI args come from the COMFYUI_ARGS env var (set in the template), not a file."
  echo "    Ensure the template sets: --port 18188 --enable-cors-header --output-directory /dev/shm/output --temp-directory /dev/shm/temp --disable-metadata"
fi

echo ""
echo "============================================================"
echo "  Nodes installed under $COMFY/custom_nodes"
if [ "$PROVIDER" = "vast" ]; then
  echo "  >>> Reload ComfyUI:   supervisorctl restart comfyui   <<<"
  echo "  (re-reads custom_nodes/; first restart reinstalls ComfyUI requirements, ~30-60s)"
else
  echo "  >>> RESTART THE POD so ComfyUI reloads with the new nodes + args. <<<"
fi
echo "============================================================"
