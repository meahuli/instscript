#!/usr/bin/env bash
# ============================================================
# Qwen-Image-Edit 2511 (image edit) + Qwen2.5-VL encoder + VAE.
# Run:  bash /workspace/provision/dl-qwen-edit-2511.sh
#   VARIANT=fp8 (default) or bf16 (48+ GB VRAM).
# fp8 = fp8mixed format -> needs a recent ComfyUI (MixedPrecisionOps). The
# runpod-slim image is recent, so it should load; if it doesn't, use the
# e4m3fn fallback at the bottom.
# Companion workflow: qwen-image-edit-2511.json
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

VARIANT="${VARIANT:-fp8}"
case "$VARIANT" in
  fp8)  EDIT="qwen_image_edit_2511_fp8mixed.safetensors"; TENC="qwen_2.5_vl_7b_fp8_scaled.safetensors" ;;
  bf16) EDIT="qwen_image_edit_2511_bf16.safetensors";     TENC="qwen_2.5_vl_7b.safetensors" ;;
  *) echo "ERROR: VARIANT must be 'fp8' or 'bf16' (got '$VARIANT')"; exit 1 ;;
esac
EBASE="https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files"
QBASE="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files"

get "$EBASE/diffusion_models/$EDIT"          diffusion_models "$EDIT"
get "$QBASE/text_encoders/$TENC"             text_encoders    "$TENC"
get "$QBASE/vae/qwen_image_vae.safetensors"  vae              qwen_image_vae.safetensors

# OPTIONAL: 4-step Lightning LoRA (fast previews). Uncomment to fetch:
# get "https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning/resolve/main/qwen_image_edit_2511_fp8_e4m3fn_scaled_lightning_comfyui_4steps_v1.0.safetensors" loras qwen_image_edit_2511_fp8_e4m3fn_scaled_lightning_comfyui_4steps_v1.0.safetensors

# FALLBACK if fp8mixed won't load on this ComfyUI (community e4m3fn build).
# Then set unet_name in the workflow to this file:
# get "https://huggingface.co/drbaph/Qwen-Image-Edit-2511-FP8/resolve/main/qwen_image_edit_2511_fp8_e4m3fn.safetensors" diffusion_models qwen_image_edit_2511_fp8_e4m3fn.safetensors

echo "Qwen-Image-Edit 2511 ($VARIANT) ready in $MODELS_DIR"
