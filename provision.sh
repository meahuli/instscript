#!/usr/bin/env bash
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Which revision the pod provisions from. The nodes under custom_nodes/ are
# installed by copying out of SELF_DIR, not by cloning, so this is the only
# thing that decides which version of them reaches the pod.
#
#   bash provision.sh                      -> PROVISION_REF_DEFAULT below
#   PROVISION_REF=other bash provision.sh  -> that branch, tag or sha
#   PROVISION_REF= bash provision.sh       -> no switch, use what is checked out
#
# Point this at a branch to make every pod provision from it -- useful while
# testing one, and worth moving back here afterwards, since a default left on a
# merged branch keeps dragging provisions onto something stale. A default that
# no longer resolves (deleted branch) only warns and carries on; a ref asked for
# explicitly is a hard failure.
PROVISION_REF_DEFAULT="main"

if [ -z "${PROVISION_REF+isset}" ]; then
  PROVISION_REF="$PROVISION_REF_DEFAULT"; PROVISION_REF_SOFT=1
else
  PROVISION_REF_SOFT=""
fi

# Done first and followed by a re-exec, because bash reads a script
# incrementally: checking out a different version of the file we are currently
# executing can drop the running shell into the middle of unrelated text.
# PROVISION_REF_DONE stops the re-exec looping if the ref we land on is older
# than this block.
if [ -n "${PROVISION_REF:-}" ] && [ -z "${PROVISION_REF_DONE:-}" ]; then
  _ref_at() { git -C "$SELF_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown; }
  _ref_bail() {
    if [ -n "$PROVISION_REF_SOFT" ]; then
      echo "!!  $1" >&2
      echo "!!  staying on $(_ref_at) — set PROVISION_REF explicitly to override." >&2
    else
      echo "ERROR: $1" >&2; exit 1
    fi
  }
  if [ ! -d "$SELF_DIR/.git" ]; then
    [ -n "$PROVISION_REF_SOFT" ] \
      || echo "!!  PROVISION_REF=$PROVISION_REF ignored — $SELF_DIR is not a git checkout." >&2
  elif [ -n "$(git -C "$SELF_DIR" status --porcelain 2>/dev/null)" ]; then
    _ref_bail "$SELF_DIR has uncommitted changes — refusing to switch to $PROVISION_REF."
  elif [ "$(_ref_at)" = "$PROVISION_REF" ]; then
    # Already there. Deliberately no fetch and no checkout -B: re-resetting the
    # branch on every single provision would discard anything committed here,
    # and updating is the bootstrap's job (clone || pull), not this block's.
    echo "==> provision on $PROVISION_REF ($(git -C "$SELF_DIR" rev-parse --short HEAD))"
  else
    echo "==> switching provision checkout to $PROVISION_REF"
    git -C "$SELF_DIR" fetch -q origin || echo "   FETCH FAILED — trying what is already local"
    if git -C "$SELF_DIR" checkout -q -B "$PROVISION_REF" "origin/$PROVISION_REF" 2>/dev/null \
       || git -C "$SELF_DIR" checkout -q "$PROVISION_REF" 2>/dev/null; then
      echo "==> provision now at $(git -C "$SELF_DIR" rev-parse --short HEAD) ($PROVISION_REF)"
      export PROVISION_REF_DONE=1
      exec bash "$0" "$@"
    else
      _ref_bail "cannot check out $PROVISION_REF"
    fi
  fi
fi

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

# Pinned at 2026-08-08. These run in-process with full access to prompts, images
# and the encryption key, so an unpinned clone means whatever landed on their
# default branch since you last provisioned goes straight onto the pod.
#
# To update one: check what changed, then bump its sha.
#   git ls-remote https://github.com/OWNER/REPO HEAD
# Drop the @sha to track the branch again.
NODES=(
  # main   2026-01-12
  "https://github.com/city96/ComfyUI-GGUF@6ea2651e7df66d7585f6ffee804b20e92fb38b8a"
  # master 2026-07-27
  "https://github.com/Lightricks/ComfyUI-LTXVideo@3b9c5cde4700917074823d45e25401d81049f8fc"
  # main   2026-08-07
  "https://github.com/ClownsharkBatwing/RES4LYF@26036f647ca15d3048a193daf99a40cecfc3820d"
  # main   2026-06-29
  "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect@809065c9d2f3874dc215106784af49f3f0cb368f"
  # main   2026-08-09  MiniMax-H3 prompt enhancer: the only nodes that can load the
  # layers 50-63 generation tail (dl-minimax-h3.sh WITH_TAIL=1). Repo was 6 days old
  # at this pin, so treat a sha bump as a re-review, not a formality. Reviewed at this
  # sha: no outbound network calls, no subprocess/eval/pickle, no third-party deps, no
  # credential reads. It does register two token-guarded POST routes on ComfyUI's own
  # server (/minimax_h3/prompt_review/{recover,decision}) for the Plan v2 review gate.
  "https://github.com/ethanfel/ComfyUI-MiniMax-H3-Guide@ae0789c2423dd72c4ad50ac2da10535882e87713"
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
    # An already-cloned node used to be left alone, so adding a pin did nothing
    # on a pod that had provisioned before -- it kept whatever it first cloned.
    at="$(git -C "$name" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$sha" ] && [ "$at" != "$sha" ]; then
      echo "==> [$name] at ${at:0:8}, pinning to ${sha:0:8}"
      git -C "$name" fetch -q origin "$sha" 2>/dev/null \
        || git -C "$name" fetch -q --tags origin \
        || echo "   FETCH FAILED for $name"
      git -C "$name" checkout -q "$sha" \
        || echo "   CHECKOUT FAILED for $name — still at ${at:0:8}"
    else
      echo "==> [$name] present at ${at:0:8} — skipping clone"
    fi
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
  # Say which revision these came from. They are copied out of this checkout, so
  # "why is the pod running old code" is always answered by this line.
  if [ -d "$SELF_DIR/.git" ]; then
    echo "==> local nodes from $(git -C "$SELF_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git -C "$SELF_DIR" rev-parse --short HEAD 2>/dev/null)"
  else
    echo "==> local nodes from $SELF_DIR (not a git checkout — cannot report a revision)"
  fi
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

  # pip exiting 0 is not proof the venv can actually use it, and the failure is
  # silent at runtime: previews and uploads just get stored unencrypted.
  python - <<'PY'
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    AESGCM(b"0" * 32)
    print("==> cryptography usable — previews and uploads will be encrypted")
except Exception as e:
    print("")
    print("!!  cryptography is NOT usable in this venv (%s)." % e)
    print("!!  The nodes still work, but previews and uploads are stored")
    print("!!  UNENCRYPTED. The gallery password still gates them.")
    print("!!  Fix with:  pip install cryptography   then restart ComfyUI.")
    print("")
PY
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
# Caching left at ComfyUI's default (--cache-ram, evicts under RAM pressure) so node
# outputs survive between runs. --cache-none re-executed every node each queue, which
# re-ran CLIP and reloaded the text encoder on every generation — a full model swap per
# run on big models. Cost of the default: decoded frames sit in RAM until evicted.
# Add --cache-lru 4 to bound that instead (mutually exclusive with the other cache flags).
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
  echo "    (No cache flag: the default --cache-ram keeps node outputs between runs, so a"
  echo "     seed-only change reuses the cached conditioning instead of reloading the encoder.)"
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
