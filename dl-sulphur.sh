#!/usr/bin/env bash
# ============================================================
# LTX-2.3 22B (bf16) + Sulphur uncensoring — "base + LoRA" setup that works
# for BOTH workflows, unmodified, via symlinks:
#   - Sulphur:  ltx23_t2v base.json   (uncensored: base + Sulphur LoRA + distill)
#   - Official: LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json (base + distill)
#
# Downloads ONE canonical set of files, then symlinks the name variants each
# workflow expects (so no JSON editing). Uncensoring strength = the Sulphur
# LoRA's strength in the UI (dial 0.5–1.0). Files already present are skipped;
# symlinks are (re)created every run.
#
# Run:  bash /workspace/provision/dl-sulphur.sh
# ~85 GB (bf16) — fits a 48 GB+ pod. Needs nodes ComfyUI-LTXVideo + RES4LYF.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

LH="https://huggingface.co/Lightricks/LTX-2.3/resolve/main"
S="https://huggingface.co/SulphurAI/Sulphur-2-base/resolve/main"
CO="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files"

# symlink helper: link <relative-target> <subdir-under-models> <linkname>
link() {
  local target="$1" sub="$2" name="$3" dir="$MODELS_DIR/$2"
  mkdir -p "$dir"
  ln -sfn "$target" "$dir/$name" && echo "  link: $sub/$name -> $target"
}

# ---- Canonical real files (bf16; skipped if already on disk) ----
get "$LH/ltx-2.3-22b-dev.safetensors"                 checkpoints   ltx-2.3-22b-dev.safetensors                  # base model (44 GB)
get "$S/sulphur_lora_rank_768.safetensors"            loras         sulphur_lora_rank_768.safetensors            # Sulphur uncensoring LoRA (9.8 GB)
get "$LH/ltx-2.3-22b-distilled-lora-384.safetensors"  loras         ltx-2.3-22b-distilled-lora-384.safetensors   # distill LoRA (7.3 GB)
get "$CO/text_encoders/gemma_3_12B_it.safetensors"    text_encoders gemma_3_12B_it.safetensors                   # Gemma encoder bf16 (23 GB)
#   To save ~17 GB (encoder precision doesn't affect output), use fp8 instead and
#   the symlinks below still work — comment the line above and uncomment this:
# get "$CO/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" text_encoders gemma_3_12B_it.safetensors
get "$LH/ltx-2.3-spatial-upscaler-x2-1.0.safetensors" latent_upscale_models ltx-2.3-spatial-upscaler-x2-1.0.safetensors  # spatial upscaler (0.95 GB) — node scans latent_upscale_models/
get "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/taeltx2_3.safetensors" vae taeltx2_3.safetensors   # preview TAE (22 MB, Kijai)

# ---- Symlinks so BOTH workflows resolve their (differently-named) refs ----
# Checkpoint: Sulphur workflow's "stock dev" slot is named *-fp8 -> point at the bf16 file
link ltx-2.3-22b-dev.safetensors             checkpoints   ltx-2.3-22b-dev-fp8.safetensors
# Sulphur LoRA placeholder name used in the workflow
link sulphur_lora_rank_768.safetensors       loras         sulphur_final.safetensors
# Distill-LoRA name variants -> the one real distill LoRA
link ltx-2.3-22b-distilled-lora-384.safetensors loras      ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors
link ../../ltx-2.3-22b-distilled-lora-384.safetensors loras/ltxv/ltx2 ltx-2.3-22b-distilled-lora-384-1.1.safetensors
# Gemma encoder name variants -> the one real encoder
link gemma_3_12B_it.safetensors              text_encoders comfy_gemma_3_12B_it.safetensors
link gemma_3_12B_it.safetensors              text_encoders gemma_3_12B_it_fp4_mixed.safetensors
# Upscaler real file is in latent_upscale_models/; mirror into upscale_models/ + checkpoints/ as fallback
link ../latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.0.safetensors upscale_models ltx-2.3-spatial-upscaler-x2-1.0.safetensors
link ../latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.0.safetensors checkpoints   ltx-2.3-spatial-upscaler-x2-1.0.safetensors
# Preview TAE mirrored into vae_approx/ (in case the preview node looks there)
link ../vae/taeltx2_3.safetensors vae_approx taeltx2_3.safetensors

# ---- Both workflow JSONs (unmodified — the symlinks make their refs resolve) ----
WF_DIR="$COMFY/user/default/workflows"; mkdir -p "$WF_DIR"
aria2c $ARIA_OPTS --dir="$WF_DIR" --out="LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json" \
  "https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/master/example_workflows/2.3/LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json" \
  || echo "  (LTX official workflow JSON download failed)"
aria2c $ARIA_OPTS --dir="$WF_DIR" --out="ltx23_t2v_base_sulphur.json" \
  "https://huggingface.co/SulphurAI/Sulphur-2-base/resolve/main/workflows/ltx23_t2v%20base.json" \
  || echo "  (Sulphur workflow JSON download failed)"

echo ""
echo "Done. Both workflows resolve via symlinks (no JSON editing):"
echo "  Sulphur (uncensored):  ltx23_t2v_base_sulphur.json"
echo "  Official (stock):      LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json"
echo "Uncensoring = the Sulphur LoRA (sulphur_final). Dial its strength (0.5-1.0) in the UI."
echo "Preview TAE (taeltx2_3) fetched to vae/ (+ vae_approx/). If LTX2SamplingPreviewOverride still"
echo "can't find it, point it at that file or bypass the node (Ctrl+B) — it's preview-only."
