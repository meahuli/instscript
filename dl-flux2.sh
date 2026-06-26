#!/usr/bin/env bash
# ============================================================
# FLUX.2 [dev] — 32B diffusion + Mistral 3 Small text encoder + VAE.
#   VARIANT=bf16 (DEFAULT) — flux2-dev (~64 GB) + bf16 Mistral (~36 GB). Max
#                  fidelity; needs 80 GB VRAM with ComfyUI offloading (the
#                  encoder offloads to RAM after encoding). ~100 GB download.
#   VARIANT=fp8  — flux2_dev_fp8mixed (~32 GB) + fp8 Mistral (~18 GB). Fits
#                  24 GB VRAM with offloading. ~50 GB download.
#   ENC=bf16|fp8|fp4 — encoder precision, defaults to match VARIANT. Mix it to
#                  trim the (huge) encoder, e.g. ENC=fp8 with VARIANT=bf16.
#
# Run:  bash /workspace/provision/dl-flux2.sh                    # bf16 model + bf16 encoder
#       VARIANT=fp8 bash /workspace/provision/dl-flux2.sh        # full fp8
#       ENC=fp8 bash /workspace/provision/dl-flux2.sh            # bf16 model + fp8 encoder
#
# GATED — every FLUX.2 file needs a HuggingFace token:
#   1. Accept the license:  https://huggingface.co/black-forest-labs/FLUX.2-dev
#      (if the Comfy-Org files 403, accept https://huggingface.co/Comfy-Org/flux2-dev too)
#   2. Create a CLASSIC read token:  https://huggingface.co/settings/tokens
#   3. export HF_TOKEN=hf_xxxx   (model-lib.sh's get() sends it automatically)
#
# FLUX.2 uses a SINGLE CLIPLoader (type=flux2, Mistral) — NOT DualCLIPLoader —
# and its own flux2-vae (not FLUX.1's ae.safetensors). FLUX.1 workflows won't load.
# Companion workflow: flux2-t2i.json
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

# FLUX.2-dev is gated everywhere (incl. the Comfy-Org repackage) — fail early without a token.
if [ -z "${HF_TOKEN:-}" ]; then
  echo "ERROR: HF_TOKEN not set — every FLUX.2 file is gated and will 401/403." >&2
  echo "  Accept https://huggingface.co/black-forest-labs/FLUX.2-dev , make a classic read token," >&2
  echo "  then:  export HF_TOKEN=hf_xxxx   and re-run." >&2
  exit 1
fi

# Diffusion model precision: bf16 (default) | fp8
VARIANT="${VARIANT:-bf16}"
case "$VARIANT" in
  bf16) IMG="flux2-dev.safetensors"                                                                              # 64 GB
        IMG_URL="https://huggingface.co/black-forest-labs/FLUX.2-dev/resolve/main/flux2-dev.safetensors" ;;
  fp8)  IMG="flux2_dev_fp8mixed.safetensors"                                                                     # 32 GB
        IMG_URL="https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/diffusion_models/flux2_dev_fp8mixed.safetensors" ;;
  *) echo "ERROR: VARIANT must be 'bf16' or 'fp8' (got '$VARIANT')"; exit 1 ;;
esac

# Mistral encoder precision — defaults to match VARIANT; override to mix, e.g.
# ENC=fp8 VARIANT=bf16  ->  bf16 model + lighter fp8 encoder (~18 GB less, ~no quality loss).
ENC="${ENC:-$VARIANT}"
case "$ENC" in
  bf16) TENC="mistral_3_small_flux2_bf16.safetensors" ;;       # 36 GB
  fp8)  TENC="mistral_3_small_flux2_fp8.safetensors" ;;        # 18 GB
  fp4)  TENC="mistral_3_small_flux2_fp4_mixed.safetensors" ;;  # 12 GB
  *) echo "ERROR: ENC must be 'bf16', 'fp8', or 'fp4' (got '$ENC')"; exit 1 ;;
esac
CO="https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files"

get "$IMG_URL"                       diffusion_models "$IMG"
get "$CO/text_encoders/$TENC"        text_encoders    "$TENC"
get "$CO/vae/flux2-vae.safetensors"  vae              flux2-vae.safetensors

echo ""
echo "FLUX.2 [dev] ($VARIANT) ready in $MODELS_DIR"
echo "Workflow nodes: UNETLoader=$IMG | CLIPLoader=$TENC type=flux2 | VAELoader=flux2-vae.safetensors"
echo "Sampling: FluxGuidance ~3.5, KSampler euler/simple, steps 20-25, cfg 1.0 (FLUX.2 uses guidance, not CFG)."
if [ "$VARIANT" = "bf16" ]; then
  echo "bf16: ~100 GB total, ~64 GB model — needs 80 GB VRAM (encoder offloads to RAM after encoding)."
fi
