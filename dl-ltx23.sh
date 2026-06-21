#!/usr/bin/env bash
# ============================================================
# LTX-2.3 22B — T2V/I2V Single-Stage Distilled (Full) workflow + models.
# Mirrors Lightricks/ComfyUI-LTXVideo example_workflows/2.3/
#   LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json
# (distilled/fast pipeline = dev checkpoint + distill-LoRA + Gemma encoder)
#
# Run:  bash /workspace/provision/dl-ltx23.sh             # default: fp8
#       PRECISION=bf16 bash /workspace/provision/dl-ltx23.sh
#
#   fp8  (DEFAULT) — ltx-2.3-22b-dev-fp8 (~28 GB). Native fp8: fits 32 GB, no
#                    extra flag. ~47 GB total download.
#   bf16           — ltx-2.3-22b-dev (44 GB). Max fidelity; needs 48 GB+ VRAM
#                    (or add --fp8_e4m3fn-unet on 32 GB). ~63 GB total.
#
# Requires custom nodes ComfyUI-LTXVideo + RES4LYF (both in provision.sh NODES).
# Audio VAE is bundled in the checkpoint (no separate file).
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

PRECISION="${PRECISION:-bf16}"
case "$PRECISION" in
  fp8)  CKPT="ltx-2.3-22b-dev-fp8.safetensors"
        CKPT_URL="https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-dev-fp8.safetensors" ;;
  bf16) CKPT="ltx-2.3-22b-dev.safetensors"
        CKPT_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-dev.safetensors" ;;
  *) echo "ERROR: PRECISION must be fp8 or bf16 (got '$PRECISION')"; exit 1 ;;
esac
LH="https://huggingface.co/Lightricks/LTX-2.3/resolve/main"
CO="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files"

# 1) dev checkpoint (fp8 or bf16) -> checkpoints/
get "$CKPT_URL" checkpoints "$CKPT"

# 2) distilled LoRA -> loras/ltxv/ltx2/  (workflow references this subpath)
get "$LH/ltx-2.3-22b-distilled-lora-384-1.1.safetensors" loras/ltxv/ltx2 ltx-2.3-22b-distilled-lora-384-1.1.safetensors

# 3) Gemma-3-12B text encoder (fp8) -> text_encoders/ (named as the workflow expects)
get "$CO/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" text_encoders comfy_gemma_3_12B_it.safetensors

# 4) workflow JSON -> user/default/workflows/ ; if fp8, patch its checkpoint to the fp8 file
WF_NAME="LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json"
WF_DIR="$COMFY/user/default/workflows"
mkdir -p "$WF_DIR"
aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$WF_NAME" \
  "https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/master/example_workflows/2.3/$WF_NAME" \
  || echo "  (workflow JSON download failed — fetch it manually from the repo)"
if [ "$PRECISION" = "fp8" ] && [ -f "$WF_DIR/$WF_NAME" ]; then
  sed -i 's/ltx-2\.3-22b-dev\.safetensors/ltx-2.3-22b-dev-fp8.safetensors/g' "$WF_DIR/$WF_NAME"
  echo "==> patched workflow checkpoint -> $CKPT (drop-in, no dropdown change)"
fi

echo ""
echo "LTX-2.3 ($PRECISION) ready in $MODELS_DIR"
echo "Required nodes (provision.sh NODES): ComfyUI-LTXVideo + RES4LYF"
if [ "$PRECISION" = "bf16" ]; then
  echo "bf16: 44 GB model — needs 48 GB+ VRAM, or add '--fp8_e4m3fn-unet' to comfyui_args.txt on 32 GB."
else
  echo "fp8: ~28 GB model, native fp8 — fits 32 GB, no extra flag needed."
fi
