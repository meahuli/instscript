#!/usr/bin/env bash
# ============================================================
# HunyuanVideo 720p (Comfy-Org repackage) - text/image-to-video.
# Uses stock ComfyUI HunyuanVideo loaders; no GGUF or custom node required.
#
# Run:  bash /workspace/instscript/dl-hunyuan.sh              # default: t2v
#       MODE=i2v bash /workspace/instscript/dl-hunyuan.sh     # image-to-video, V2 replacement
#       MODE=i2v-v1 bash /workspace/instscript/dl-hunyuan.sh  # original image-to-video
#
#   ENCODER=fp8  (DEFAULT) - llava_llama3_fp8_scaled (~9 GB)
#   ENCODER=fp16           - llava_llama3_fp16 (~16 GB)
#
# Downloads the selected diffusion model, shared CLIP-L + LLaVA-Llama3 text
# encoder, Hunyuan VAE, and clip_vision only for I2V modes.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

MODE="${MODE:-t2v}"
case "$MODE" in
  t2v)
    MODEL="hunyuan_video_t2v_720p_bf16.safetensors"
    NEED_VISION=0
    ;;
  i2v)
    MODEL="hunyuan_video_v2_replace_image_to_video_720p_bf16.safetensors"
    NEED_VISION=1
    ;;
  i2v-v1)
    MODEL="hunyuan_video_image_to_video_720p_bf16.safetensors"
    NEED_VISION=1
    ;;
  *)
    echo "ERROR: MODE must be t2v, i2v, or i2v-v1 (got '$MODE')" >&2
    exit 1
    ;;
esac

ENCODER="${ENCODER:-fp8}"
case "$ENCODER" in
  fp8)  TENC="llava_llama3_fp8_scaled.safetensors" ;;
  fp16) TENC="llava_llama3_fp16.safetensors" ;;
  *)
    echo "ERROR: ENCODER must be fp8 or fp16 (got '$ENCODER')" >&2
    exit 1
    ;;
esac

HV="https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files"

# HunyuanVideo diffusion model. The upstream files are bf16.
get "$HV/diffusion_models/$MODEL" diffusion_models "$MODEL"

# Shared text encoders + VAE.
get "$HV/text_encoders/clip_l.safetensors" text_encoders clip_l.safetensors
get "$HV/text_encoders/$TENC"             text_encoders "$TENC"
get "$HV/vae/hunyuan_video_vae_bf16.safetensors" vae hunyuan_video_vae_bf16.safetensors

# I2V needs the LLaVA vision encoder in models/clip_vision/.
if [ "$NEED_VISION" -eq 1 ]; then
  get "$HV/clip_vision/llava_llama3_vision.safetensors" clip_vision llava_llama3_vision.safetensors
fi

echo ""
echo "HunyuanVideo $MODE ready in $MODELS_DIR"
echo "Workflow nodes: UNETLoader=$MODEL | DualCLIPLoader=clip_l.safetensors + $TENC | VAELoader=hunyuan_video_vae_bf16.safetensors"
if [ "$NEED_VISION" -eq 1 ]; then
  echo "I2V also uses CLIPVisionLoader=llava_llama3_vision.safetensors"
fi
