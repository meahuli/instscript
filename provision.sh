#!/usr/bin/env bash
set -uo pipefail

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
  source "$VENV/bin/activate"
  echo "==> venv: $VENV  ($(python --version 2>&1))"
elif command -v python >/dev/null 2>&1; then
  echo "==> WARN: no venv dir found — using current python ($(python --version 2>&1))"
else
  echo "ERROR: no venv found and no python on PATH." >&2; exit 1
fi

if command -v uv >/dev/null 2>&1; then PIP="uv pip"; else PIP="python -m pip"; fi
echo "==> installer: $PIP"

if [ -f /etc/supervisor/conf.d/comfyui.conf ] || [ -n "${CONTAINER_ID:-}" ]; then PROVIDER=vast
elif [ -d /workspace/runpod-slim ]; then PROVIDER=runpod
else PROVIDER=other; fi
echo "==> provider: $PROVIDER"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

NODES=(
  "https://github.com/city96/ComfyUI-GGUF"
  "https://github.com/Lightricks/ComfyUI-LTXVideo"
  "https://github.com/ClownsharkBatwing/RES4LYF"
  "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect"
)

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

$PIP install "transformers[timm]>=4.50.0,<5" "kornia==0.7.4" -c "$CONSTRAINTS" \
  || echo "   LTX dep-pin FAILED — run manually: pip install 'transformers[timm]<5' 'kornia==0.7.4'"

if [ -d "$SELF_DIR/custom_nodes" ]; then
  for d in "$SELF_DIR"/custom_nodes/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    echo "==> [$n] installing local node"
    rm -rf "${COMFY:?}/custom_nodes/$n"
    cp -r "$d" "$COMFY/custom_nodes/$n"
    rm -rf "$COMFY/custom_nodes/$n/__pycache__"
    if [ -f "$COMFY/custom_nodes/$n/requirements.txt" ]; then
      $PIP install -r "$COMFY/custom_nodes/$n/requirements.txt" -c "$CONSTRAINTS" \
        || echo "   DEP INSTALL FAILED for $n"
    fi
  done
fi

WF_DIR="$COMFY/user/default/workflows"
mkdir -p "$WF_DIR"
if ls "$SELF_DIR"/*.json >/dev/null 2>&1; then
  cp -f "$SELF_DIR"/*.json "$WF_DIR/"
  echo "==> deployed workflow JSONs -> $WF_DIR:"
  ls -1 "$SELF_DIR"/*.json | sed 's#.*/#     #'
else
  echo "==> no workflow JSONs next to provision.sh — skipping sidebar deploy"
fi


if [ "$PROVIDER" = "runpod" ]; then
  ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
  cat > "$ARGS_FILE" <<'EOF'
# Managed by provision.sh. IMPORTANT: one flag per line, NO inline comments.
--output-directory /dev/shm/output
--temp-directory /dev/shm/temp
--disable-metadata
# Do NOT add a bare --enable-cors-header: it means '*', and lets any page open in
# your browser read this ComfyUI through the tunnel. The built-in UI is same-origin.
# Optional (one flag per line, still no inline comments):
# --listen 127.0.0.1
# --preview-method auto
# --lowvram
EOF
  echo "==> wrote $ARGS_FILE"
else
  echo "==> $PROVIDER: ComfyUI args come from the COMFYUI_ARGS env var (set in the template), not a file."
  echo "    Ensure the template sets: --port 18188 --output-directory /dev/shm/output --temp-directory /dev/shm/temp --disable-metadata"
fi

case " ${COMFYUI_ARGS:-} " in
  *" --enable-cors-header "*|*" --enable-cors-header")
    echo ""
    echo "!!  COMFYUI_ARGS contains a bare --enable-cors-header, which means '*'."
    echo "!!  Every response then carries Access-Control-Allow-Origin: *, so any page"
    echo "!!  open in your browser can read this ComfyUI through the tunnel -- /history,"
    echo "!!  /queue, and every preview blob. The tunnel does not stop it; the browser"
    echo "!!  resolves localhost itself."
    echo "!!  Drop the flag (the built-in UI is same-origin and does not need it). If the"
    echo "!!  Vast portal turns out to need it, scope it: --enable-cors-header <origin>"
    echo ""
    ;;
esac

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
