#!/usr/bin/env bash
# ============================================================
# HiDream-I1 finetune + the 4 HiDream text encoders + VAE.
# Run:  bash /workspace/provision/dl-hidream.sh
#   VARIANT=full (default, best quality, negative prompts) or dev (lighter).
# The 4 standard encoders work with ComfyUI's built-in QuadrupleCLIPLoader
# (no extra node needed).
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

VARIANT="${VARIANT:-full}"
case "$VARIANT" in
  full) MODEL_FILE="hidream_i1_full_uncensored_fp8_v0.2.safetensors" ;;
  dev)  MODEL_FILE="hidream_i1_dev_uncensored_fp8_v0.2.safetensors" ;;
  *) echo "ERROR: VARIANT must be 'full' or 'dev' (got '$VARIANT')"; exit 1 ;;
esac
ENC="https://huggingface.co/Comfy-Org/HiDream-I1_ComfyUI/resolve/main/split_files"

# Model (~17 GB full). Filename is the upstream HF name (kept verbatim).
get "https://huggingface.co/e-n-v-y/hidream-uncensored/resolve/main/$MODEL_FILE" diffusion_models "$MODEL_FILE"

# HiDream text encoders (~16 GB total) + VAE
get "$ENC/text_encoders/clip_l_hidream.safetensors"                 text_encoders clip_l_hidream.safetensors
get "$ENC/text_encoders/clip_g_hidream.safetensors"                 text_encoders clip_g_hidream.safetensors
get "$ENC/text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors"        text_encoders t5xxl_fp8_e4m3fn_scaled.safetensors
get "$ENC/text_encoders/llama_3.1_8b_instruct_fp8_scaled.safetensors" text_encoders llama_3.1_8b_instruct_fp8_scaled.safetensors
get "$ENC/vae/ae.safetensors"                                       vae           ae.safetensors

# OPTIONAL abliterated Llama encoder swap (GGUF). Marginal extra effect, and it
# needs the ComfyUI-GGUF node (add to provision.sh NODES:
# https://github.com/city96/ComfyUI-GGUF). Uncomment to fetch:
# get "https://huggingface.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF/resolve/main/meta-llama-3.1-8b-instruct-abliterated.Q5_K_M.gguf" text_encoders meta-llama-3.1-8b-instruct-abliterated.Q5_K_M.gguf

echo "HiDream-I1 ($VARIANT) ready in $MODELS_DIR"
