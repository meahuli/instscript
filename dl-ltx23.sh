#!/usr/bin/env bash
# ============================================================
# LTX-2.3 22B — T2V/I2V Single-Stage Distilled (Full) workflow + models.
# Mirrors Lightricks/ComfyUI-LTXVideo example_workflows/2.3/
#   LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json
#
# Run:  bash /workspace/provision/dl-ltx23.sh
#
# !!! HEAVY: ~63 GB total download. The 22B model is 44 GB bf16 — it does NOT
# !!! fit 24/32 GB VRAM without CPU offload/block-swap (slow); 48 GB+ recommended.
# !!! For 24-32 GB, the lighter LTX 0.9.8 (dl-ltx.sh) is far more practical.
#
# Files (verified):
#   ltx-2.3-22b-dev.safetensors (44 GB)            -> checkpoints/
#   ltx-2.3-22b-distilled-lora-384-1.1 (7.3 GB)    -> loras/ltxv/ltx2/
#   gemma-3-12B text encoder (fp8, ~12 GB)         -> text_encoders/comfy_gemma_3_12B_it.safetensors
#   (audio VAE is bundled in the checkpoint — no separate file)
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

LH="https://huggingface.co/Lightricks/LTX-2.3/resolve/main"
CO="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files"

# 1) 22B dev checkpoint (video+audio model, VAE bundled) -> checkpoints/
get "$LH/ltx-2.3-22b-dev.safetensors" checkpoints ltx-2.3-22b-dev.safetensors

# 2) Single-stage distilled LoRA -> loras/ltxv/ltx2/ (workflow references this subpath)
get "$LH/ltx-2.3-22b-distilled-lora-384-1.1.safetensors" loras/ltxv/ltx2 ltx-2.3-22b-distilled-lora-384-1.1.safetensors

# 3) Gemma-3-12B text encoder (LTX-2 uses Gemma, not T5). fp8 = lighter; saved under
#    the exact name the workflow's LTXAVTextEncoderLoader expects.
#    For full precision instead, swap to: gemma_3_12B_it.safetensors (~24 GB).
get "$CO/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" text_encoders comfy_gemma_3_12B_it.safetensors

# 4) The workflow JSON -> user/default/workflows/ (appears in ComfyUI's Workflows sidebar)
WF_DIR="$COMFY/user/default/workflows"
mkdir -p "$WF_DIR"
aria2c $ARIA_OPTS --dir="$WF_DIR" --out="LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json" \
  "https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/master/example_workflows/2.3/LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json" \
  || echo "  (workflow JSON download failed — fetch it manually from the repo)"

echo ""
echo "LTX-2.3 22B ready in $MODELS_DIR"
echo "Also needs the ComfyUI-LTXVideo custom node — add to provision.sh NODES:"
echo "  https://github.com/Lightricks/ComfyUI-LTXVideo"
echo "Reminder: 44 GB bf16 model — expect heavy offload (slow) on <48 GB VRAM."
