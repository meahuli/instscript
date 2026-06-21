#!/usr/bin/env bash
# ============================================================
# LTX-Video 13B (0.9.8, fp8 safetensors, NO GGUF) — from Lightricks/LTX-Video.
# Much faster + lighter than Wan; fits 24/32 GB with lots of headroom.
#
# Run:  bash /workspace/provision/dl-ltx.sh             # default: distilled (fast)
#       VARIANT=dev bash /workspace/provision/dl-ltx.sh # dev = max quality, slower
#
# The LTXV checkpoint is all-in-one (transformer + VAE bundled) -> checkpoints/.
# Matches the standard ComfyUI LTXV setup: Load Checkpoint + a CLIPLoader (T5).
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

VARIANT="${VARIANT:-distilled}"    # distilled (fast) or dev (max quality)
PRECISION="${PRECISION:-bf16}"      # bf16 (full, default) or fp8 (smaller/faster)
case "$VARIANT" in distilled|dev) ;; *) echo "ERROR: VARIANT must be distilled or dev (got '$VARIANT')"; exit 1 ;; esac
case "$PRECISION" in
  bf16) SUF="" ;;
  fp8)  SUF="-fp8" ;;
  *) echo "ERROR: PRECISION must be bf16 or fp8 (got '$PRECISION')"; exit 1 ;;
esac
MODEL="ltxv-13b-0.9.8-${VARIANT}${SUF}.safetensors"   # bf16 ~27 GB, fp8 ~half

# LTXV all-in-one checkpoint (VAE is bundled inside) -> models/checkpoints/
get "https://huggingface.co/Lightricks/LTX-Video/resolve/main/$MODEL" checkpoints "$MODEL"

# T5-XXL text encoder (standard; shared with Flux/SD3 family) -> models/text_encoders/
# fp16 (~9.5 GB) is the common choice; swap to fp8 below to save download/VRAM.
get "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" text_encoders t5xxl_fp16.safetensors
# lighter T5 alternative:
# get "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" text_encoders t5xxl_fp8_e4m3fn.safetensors

# OPTIONAL: spatial/temporal upscalers for LTX's multi-scale (hi-res) pipeline:
# get "https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltxv-spatial-upscaler-0.9.8.safetensors"  checkpoints ltxv-spatial-upscaler-0.9.8.safetensors
# get "https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltxv-temporal-upscaler-0.9.8.safetensors" checkpoints ltxv-temporal-upscaler-0.9.8.safetensors

# UNCENSORED: add an NSFW LoRA/merge (e.g. Civitai "Rebels Sulphur", or Phr00t LTX
# merges) into models/loras and load it in the workflow.

echo "LTX-Video 13B $VARIANT ($PRECISION) ready — checkpoint in models/checkpoints/, T5 in models/text_encoders/"
