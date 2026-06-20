#!/usr/bin/env bash
# ============================================================
# Qwen-Image 2512 (text-to-image) + Qwen2.5-VL encoder + VAE.
# Run:  bash /workspace/provision/dl-qwen-image-2512.sh
#   VARIANT=fp8 (default, ~20 GB, fits 24 GB) or bf16 (~40 GB, 48+ GB VRAM).
# Companion workflow: qwen-image-t2i-2512.json
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

VARIANT="${VARIANT:-fp8}"
case "$VARIANT" in
  fp8)  IMG="qwen_image_2512_fp8_e4m3fn.safetensors"; TENC="qwen_2.5_vl_7b_fp8_scaled.safetensors" ;;
  bf16) IMG="qwen_image_2512_bf16.safetensors";       TENC="qwen_2.5_vl_7b.safetensors" ;;
  *) echo "ERROR: VARIANT must be 'fp8' or 'bf16' (got '$VARIANT')"; exit 1 ;;
esac
BASE="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files"

get "$BASE/diffusion_models/$IMG"                 diffusion_models "$IMG"
get "$BASE/text_encoders/$TENC"                   text_encoders    "$TENC"
get "$BASE/vae/qwen_image_vae.safetensors"        vae              qwen_image_vae.safetensors

echo "Qwen-Image 2512 ($VARIANT) ready in $MODELS_DIR"
