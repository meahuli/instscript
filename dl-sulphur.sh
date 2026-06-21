#!/usr/bin/env bash
# ============================================================
# Sulphur-2 — UNCENSORED finetune of LTX-2.3 22B (SulphurAI/Sulphur-2-base).
# A drop-in replacement for the LTX-2.3 diffusion checkpoint: reuses the same
# Gemma encoder + distill LoRA + workflow, just swaps in the uncensored model.
#
# Files already on disk are SKIPPED (model-lib.sh's get() checks size first),
# so if you already ran dl-ltx23.sh the encoder + LoRA are reused and only the
# ~28 GB Sulphur checkpoint downloads. Re-runs are cheap / resumable.
#
# Run:  bash /workspace/provision/dl-sulphur.sh              # default: fp8 (~28 GB, fits 32 GB)
#       PRECISION=bf16 bash /workspace/provision/dl-sulphur.sh    # bf16 (44 GB, 48 GB+)
#
# Needs custom nodes ComfyUI-LTXVideo + RES4LYF (in provision.sh NODES).
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

PRECISION="${PRECISION:-bf16}"
case "$PRECISION" in
  fp8)  CKPT="sulphur_dev_fp8mixed.safetensors" ;;   # ~28 GB, native fp8, fits 32 GB
  bf16) CKPT="sulphur_dev_bf16.safetensors" ;;       # 44 GB, max fidelity, 48 GB+
  *) echo "ERROR: PRECISION must be fp8 or bf16 (got '$PRECISION')"; exit 1 ;;
esac
S="https://huggingface.co/SulphurAI/Sulphur-2-base/resolve/main"
LH="https://huggingface.co/Lightricks/LTX-2.3/resolve/main"
CO="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files"

# 1) Uncensored Sulphur checkpoint (VAE bundled) -> checkpoints/
get "$S/$CKPT" checkpoints "$CKPT"

# 2) Distill LoRA (fast few-step) -> loras/ltxv/ltx2/
#    Sulphur's OWN distill LoRA — the one the author recommends pairing with the dev model.
SDLORA="ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors"
get "$S/distill_loras/$SDLORA" loras/ltxv/ltx2 "$SDLORA"
#    (the generic LTX-2.3 distill LoRA also works, if you'd rather reuse dl-ltx23.sh's:)
# get "$LH/ltx-2.3-22b-distilled-lora-384-1.1.safetensors" loras/ltxv/ltx2 ltx-2.3-22b-distilled-lora-384-1.1.safetensors

# 3) Gemma-3-12B text encoder -> text_encoders/  (reused/skipped if already present)
get "$CO/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" text_encoders comfy_gemma_3_12B_it.safetensors

# 4) Workflow JSON -> user/default/workflows/, patched to use the Sulphur checkpoint
WF_NAME="LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json"
WF_DIR="$COMFY/user/default/workflows"
mkdir -p "$WF_DIR"
aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$WF_NAME" \
  "https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/master/example_workflows/2.3/$WF_NAME" \
  || echo "  (workflow JSON download failed — fetch it manually)"
if [ -f "$WF_DIR/$WF_NAME" ]; then
  sed -i -E "s/ltx-2\.3-22b-dev(-fp8)?\.safetensors/$CKPT/g" "$WF_DIR/$WF_NAME"
  sed -i "s/ltx-2\.3-22b-distilled-lora-384-1\.1\.safetensors/$SDLORA/g" "$WF_DIR/$WF_NAME"
  echo "==> patched workflow: checkpoint -> $CKPT, distill LoRA -> $SDLORA"
fi

# OPTIONAL: Sulphur uncensored prompt enhancer (local LLM that rewrites prompts; ~9-20 GB):
# get "$S/prompt_enhancer_uncensored/prompt_enhancer_uncensored-q8_0.gguf" text_encoders prompt_enhancer_uncensored-q8_0.gguf

echo ""
echo "Sulphur-2 UNCENSORED LTX-2.3 ($PRECISION) ready in $MODELS_DIR"
echo "Open the LTX-2.3 workflow (checkpoint now -> $CKPT). Needs ComfyUI-LTXVideo + RES4LYF."
if [ "$PRECISION" = "bf16" ]; then
  echo "bf16: 44 GB — needs 48 GB+ VRAM (or add '--fp8_e4m3fn-unet' to comfyui_args.txt on 32 GB)."
else
  echo "fp8: ~28 GB, native — fits 32 GB."
fi
