#!/usr/bin/env bash
# ============================================================
# Wan 2.2 14B (fp8 safetensors, NO GGUF) — text/image-to-video.
# Official Comfy-Org repackaged files; matches ComfyUI's built-in Wan 2.2
# template (Workflow > Browse Templates > Video > Wan 2.2).
#
# Run:  bash /workspace/provision/dl-wan.sh            # default: t2v
#       MODE=i2v bash /workspace/provision/dl-wan.sh   # image-to-video
#
# 14B is a two-expert MoE (high-noise + low-noise) — both are downloaded.
# Fits 24 GB (480p) / 32 GB (720p). Loads on stock ComfyUI nodes.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

MODE="${MODE:-t2v}"
case "$MODE" in t2v|i2v) ;; *) echo "ERROR: MODE must be t2v or i2v (got '$MODE')"; exit 1 ;; esac

WB="https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files"

# 14B MoE: high-noise + low-noise experts (need both)
get "$WB/diffusion_models/wan2.2_${MODE}_high_noise_14B_fp8_scaled.safetensors" diffusion_models "wan2.2_${MODE}_high_noise_14B_fp8_scaled.safetensors"
get "$WB/diffusion_models/wan2.2_${MODE}_low_noise_14B_fp8_scaled.safetensors"  diffusion_models "wan2.2_${MODE}_low_noise_14B_fp8_scaled.safetensors"

# UMT5 text encoder (shared) + Wan 2.1 VAE (used by the 14B)
get "$WB/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" text_encoders umt5_xxl_fp8_e4m3fn_scaled.safetensors
get "$WB/vae/wan_2.1_vae.safetensors"                          vae           wan_2.1_vae.safetensors

# OPTIONAL: 4-step Lightning LoRAs (lightx2v) — ~5x faster gen. Uncomment the pair for your MODE.
#   t2v:
# get "$WB/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors" loras wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors
# get "$WB/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"  loras wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors
#   i2v:
# get "$WB/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" loras wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors
# get "$WB/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"  loras wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors

# LIGHTER ALTERNATIVE: Wan 2.2 5B (TI2V) — single model, fp16 (~10 GB), uses wan2.2_vae.
# Faster/smaller for tighter VRAM. Still uses the umt5 encoder above.
# get "$WB/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors" diffusion_models wan2.2_ti2v_5B_fp16.safetensors
# get "$WB/vae/wan2.2_vae.safetensors"                       vae              wan2.2_vae.safetensors

# UNCENSORED: base Wan is fairly permissive; for explicit content add an NSFW LoRA
# (e.g. a Civitai "Wan 2.2 Remix NSFW" LoRA) into models/loras and load it in the workflow.

echo "Wan 2.2 14B $MODE (fp8) ready in $MODELS_DIR"
