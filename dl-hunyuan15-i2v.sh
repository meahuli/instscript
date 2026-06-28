#!/usr/bin/env bash
# ============================================================
# HunyuanVideo 1.5 720p I2V workflow + models.
# Source workflow:
#   https://comfy.org/workflows/download/5427ef92c853.json?filename=video_hunyuan_video_1.5_720p_i2v
#
# Run:  bash /workspace/instscript/dl-hunyuan15-i2v.sh
#       WITH_SR=1 bash /workspace/instscript/dl-hunyuan15-i2v.sh
#
# Default downloads only the 720p I2V path used by the workflow. WITH_SR=1 also
# fetches the optional disabled 1080p super-resolution model + latent upsampler.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

WITH_SR="${WITH_SR:-0}"
case "$WITH_SR" in
  0|1) ;;
  *)
    echo "ERROR: WITH_SR must be 0 or 1 (got '$WITH_SR')" >&2
    exit 1
    ;;
esac

HV15="https://huggingface.co/Comfy-Org/HunyuanVideo_1.5_repackaged/resolve/main/split_files"
SIGCLIP="https://huggingface.co/Comfy-Org/sigclip_vision_384/resolve/main"
WF_URL="https://comfy.org/workflows/download/5427ef92c853.json?filename=video_hunyuan_video_1.5_720p_i2v"
WF_NAME="video_hunyuan_video_1.5_720p_i2v.json"
WF_DIR="$COMFY/user/default/workflows"

# Workflow JSON -> ComfyUI Workflows sidebar.
mkdir -p "$WF_DIR"
if [ -s "$WF_DIR/$WF_NAME" ]; then
  echo "  present, skipping: workflows/$WF_NAME"
else
  echo "==> workflows/$WF_NAME"
  aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$WF_NAME" "$WF_URL" \
    || echo "  workflow download failed - fetch it manually from comfy.org."
fi

# Required 720p I2V assets.
get "$HV15/diffusion_models/hunyuanvideo1.5_720p_i2v_fp16.safetensors" diffusion_models hunyuanvideo1.5_720p_i2v_fp16.safetensors
get "$HV15/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"       text_encoders    qwen_2.5_vl_7b_fp8_scaled.safetensors
get "$HV15/text_encoders/byt5_small_glyphxl_fp16.safetensors"         text_encoders    byt5_small_glyphxl_fp16.safetensors
get "$SIGCLIP/sigclip_vision_patch14_384.safetensors"                 clip_vision      sigclip_vision_patch14_384.safetensors
get "$HV15/vae/hunyuanvideo15_vae_fp16.safetensors"                   vae              hunyuanvideo15_vae_fp16.safetensors

# Optional 1080p super-resolution branch present in the workflow but disabled by default.
if [ "$WITH_SR" = "1" ]; then
  get "$HV15/diffusion_models/hunyuanvideo1.5_1080p_sr_distilled_fp16.safetensors" diffusion_models      hunyuanvideo1.5_1080p_sr_distilled_fp16.safetensors
  get "$HV15/latent_upscale_models/hunyuanvideo15_latent_upsampler_1080p.safetensors" latent_upscale_models hunyuanvideo15_latent_upsampler_1080p.safetensors
else
  echo "==> skipping optional 1080p SR assets (set WITH_SR=1 to download them)"
fi

echo ""
echo "HunyuanVideo 1.5 720p I2V ready in $MODELS_DIR"
echo "Workflow installed: $WF_DIR/$WF_NAME"
if [ "$WITH_SR" = "1" ]; then
  echo "Optional 1080p SR assets were also downloaded."
fi
