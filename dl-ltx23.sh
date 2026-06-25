#!/usr/bin/env bash
# ============================================================
# LTX-2.3 22B — T2V/I2V Distilled workflows (Single-Stage + Two-Stage) + models.
# Mirrors Lightricks/ComfyUI-LTXVideo example_workflows/2.3/
#   LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json
#   LTX-2.3_T2V_I2V_Two_Stage_Distilled.json  (adds spatial-upscaler 2nd stage)
# (distilled/fast pipeline = dev checkpoint + distill-LoRA + Gemma encoder;
#  the two-stage variant also uses the x2 spatial upscaler.)
#
# Run:  bash /workspace/provision/dl-ltx23.sh             # default: fp8
#       PRECISION=bf16 bash /workspace/provision/dl-ltx23.sh
#
#   fp8  (DEFAULT) — ltx-2.3-22b-dev-fp8 (~28 GB). Native fp8: fits 32 GB, no
#                    extra flag. ~48 GB total download (incl. ~1 GB upscaler).
#   bf16           — ltx-2.3-22b-dev (44 GB) + full bf16 Gemma encoder (24 GB).
#                    Max fidelity; needs 48 GB+ VRAM (or add --fp8_e4m3fn-unet
#                    on 32 GB). ~75 GB total (incl. ~1 GB upscaler).
#
# Requires custom nodes ComfyUI-LTXVideo + RES4LYF (both in provision.sh NODES).
# Audio VAE is bundled in the checkpoint (no separate file).
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

PRECISION="${PRECISION:-bf16}"
case "$PRECISION" in
  fp8)  CKPT="ltx-2.3-22b-dev-fp8.safetensors"
        CKPT_URL="https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-dev-fp8.safetensors"
        TENC="gemma_3_12B_it_fp8_scaled.safetensors" ;;
  bf16) CKPT="ltx-2.3-22b-dev.safetensors"
        CKPT_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-dev.safetensors"
        TENC="gemma_3_12B_it.safetensors" ;;
  *) echo "ERROR: PRECISION must be fp8 or bf16 (got '$PRECISION')"; exit 1 ;;
esac
LH="https://huggingface.co/Lightricks/LTX-2.3/resolve/main"
CO="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files"

# 1) dev checkpoint (fp8 or bf16) -> checkpoints/
get "$CKPT_URL" checkpoints "$CKPT"

# 2) distilled LoRA -> loras/  (FLAT. The official workflows' ltxv/ltx2/ subpath is
#    flattened on deploy below, so this one flat copy serves every workflow — and lets
#    auto-downloaders that can't write subfolders, e.g. ComfyUI-AutoModelDownloader, find it.)
get "$LH/ltx-2.3-22b-distilled-lora-384-1.1.safetensors" loras ltx-2.3-22b-distilled-lora-384-1.1.safetensors

# 3) spatial upscaler (x2) -> latent_upscale_models/  (the 2nd stage of the Two-Stage
#    workflow; loaded by LatentUpscaleModelLoader, which reads the 'latent_upscale_models'
#    folder — NOT upscale_models). Same file for both precisions. ~1 GB.
get "$LH/ltx-2.3-spatial-upscaler-x2-1.1.safetensors" latent_upscale_models ltx-2.3-spatial-upscaler-x2-1.1.safetensors

# 4) Gemma-3-12B text encoder (fp8 for fp8 path, full bf16 for bf16 path)
#    -> text_encoders/ (always saved as the name the workflow expects, so it stays drop-in)
get "$CO/text_encoders/$TENC" text_encoders comfy_gemma_3_12B_it.safetensors

# 5) workflow JSONs -> user/default/workflows/ ; if fp8, patch each checkpoint to the fp8 file.
#    Single-Stage uses the checkpoint + LoRA + encoder; Two-Stage adds the spatial upscaler.
WF_DIR="$COMFY/user/default/workflows"
WFBASE="https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/master/example_workflows/2.3"
mkdir -p "$WF_DIR"
for WF_NAME in \
    LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json \
    LTX-2.3_T2V_I2V_Two_Stage_Distilled.json ; do
  aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$WF_NAME" "$WFBASE/$WF_NAME" \
    || echo "  (workflow JSON download failed: $WF_NAME — fetch it manually from the repo)"
  if [ -f "$WF_DIR/$WF_NAME" ]; then
    # flatten the distill-LoRA subpath (ltxv/ltx2/...) to match the flat loras/ download above
    sed -i 's|ltxv/ltx2/ltx-2.3-22b-distilled|ltx-2.3-22b-distilled|g' "$WF_DIR/$WF_NAME"
  fi
  if [ "$PRECISION" = "fp8" ] && [ -f "$WF_DIR/$WF_NAME" ]; then
    sed -i 's/ltx-2\.3-22b-dev\.safetensors/ltx-2.3-22b-dev-fp8.safetensors/g' "$WF_DIR/$WF_NAME"
    echo "==> patched $WF_NAME checkpoint -> $CKPT (drop-in, no dropdown change)"
  fi
done

echo ""
echo "LTX-2.3 ($PRECISION) ready in $MODELS_DIR"
echo "Required nodes (provision.sh NODES): ComfyUI-LTXVideo + RES4LYF"
if [ "$PRECISION" = "bf16" ]; then
  echo "bf16: 44 GB model — needs 48 GB+ VRAM, or add '--fp8_e4m3fn-unet' to comfyui_args.txt on 32 GB."
else
  echo "fp8: ~28 GB model, native fp8 — fits 32 GB, no extra flag needed."
fi
