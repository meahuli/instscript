#!/usr/bin/env bash
# ============================================================
# cleanup-models.sh — delete downloaded model files (and symlinks) under
# ComfyUI's models/ to free disk. Keeps the folder structure intact.
#
# Usage:
#   bash cleanup-models.sh              # show sizes, then ask y/N
#   bash cleanup-models.sh loras        # only empty models/loras
#   FORCE=1 bash cleanup-models.sh       # skip the confirmation prompt
#   DRYRUN=1 bash cleanup-models.sh      # just list what WOULD be deleted
#
# Scope: ONLY under <ComfyUI>/models. Does NOT touch comfyui_args.txt,
# workflows, outputs, or anything outside models/.
# ============================================================
set -uo pipefail

# --- locate ComfyUI across providers (runpod-slim, Vast, generic) ---
# Override on any host with:  COMFY=/path/to/ComfyUI bash cleanup-models.sh
if [ -z "${COMFY:-}" ]; then
  for c in /workspace/runpod-slim/ComfyUI /workspace/ComfyUI /opt/ComfyUI "${HOME:-/root}/ComfyUI" /ComfyUI; do
    [ -f "$c/main.py" ] && { COMFY="$c"; break; }
  done
fi
if [ -z "${COMFY:-}" ] || [ ! -d "$COMFY" ]; then
  echo "ERROR: ComfyUI not found. Set it explicitly:  COMFY=/path/to/ComfyUI bash $0" >&2
  exit 1
fi
MODELS="$COMFY/models"
SUB="${1:-}"
TARGET="$MODELS${SUB:+/$SUB}"

if [ ! -d "$TARGET" ]; then echo "ERROR: $TARGET not found." >&2; exit 1; fi
case "$(cd "$TARGET" && pwd)/" in "$MODELS"/*|"$MODELS"/) ;; *) echo "ERROR: refusing — $TARGET is outside $MODELS." >&2; exit 1 ;; esac

echo "==> Current usage under $TARGET:"
du -sh "$TARGET"/* 2>/dev/null | sort -rh | head -40
echo "    TOTAL: $(du -sh "$TARGET" 2>/dev/null | cut -f1)"
echo ""

N=$(find "$TARGET" -mindepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l)
if [ "$N" -eq 0 ]; then echo "Nothing to delete."; exit 0; fi

if [ "${DRYRUN:-0}" = "1" ]; then
  echo "==> DRYRUN — $N files/symlinks that WOULD be deleted:"
  find "$TARGET" -mindepth 1 \( -type f -o -type l \) 2>/dev/null
  exit 0
fi

echo "==> This will DELETE $N files/symlinks under $TARGET (folders kept)."
if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "    Proceed? (y/N): " ans || true
  case "${ans:-}" in [Yy]*) ;; *) echo "Aborted."; exit 0 ;; esac
fi

find "$TARGET" -mindepth 1 \( -type f -o -type l \) -delete
echo "==> Done. Disk now:"
df -h "$COMFY" 2>/dev/null | tail -1
