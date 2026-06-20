#!/usr/bin/env bash
# ============================================================
# Chroma (FLUX-based finetune) + FLUX encoders/VAE + PuLID model.
# Run:  bash /workspace/provision/dl-chroma.sh
# Bump CHROMA_VERSION if a newer one is out on huggingface.co/lodestones/Chroma.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

CHROMA_VERSION="${CHROMA_VERSION:-v40}"
CHROMA_FILE="chroma-unlocked-${CHROMA_VERSION}.safetensors"

# Chroma diffusion model (~12-15 GB)
get "https://huggingface.co/lodestones/Chroma/resolve/main/$CHROMA_FILE" diffusion_models "$CHROMA_FILE"

# FLUX.1 text encoders + VAE (shared with FLUX workflows; ungated)
get "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" text_encoders t5xxl_fp8_e4m3fn.safetensors
get "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"            text_encoders clip_l.safetensors
get "https://huggingface.co/camenduru/FLUX.1-dev-ungated/resolve/main/ae.safetensors"                     vae          ae.safetensors

# PuLID-FLUX face-identity model.
# NOTE: to USE this you also need the PuLID-Flux custom node — add it to
# provision.sh NODES:  https://github.com/sipie800/ComfyUI-PuLID-Flux-Enhanced
get "https://huggingface.co/guozinan/PuLID/resolve/main/pulid_flux_v0.9.1.safetensors" pulid pulid_flux_v0.9.1.safetensors

echo "Chroma set ready in $MODELS_DIR"
